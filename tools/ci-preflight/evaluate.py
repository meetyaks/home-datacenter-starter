#!/usr/bin/env python3
"""Decide, from READ-ONLY facts, whether a new CI runner VM fits on the host.

    evaluate.py <facts.json from collect.sh> <plan.json>

Pure and offline (stdlib only; tests/ci-preflight/ drives it with fixtures).
Every check reports PASS, FAIL or UNKNOWN. UNKNOWN is a failure: a value that
could not be read is never assumed to be fine. Exit 0 only if every check
passes.

plan.json (rendered by playbooks/ci-runner-truewealth-preflight.yml from the
play vars):
  vm_name, cpu, memory_mib, reserve_cpu, reserve_memory_mib,
  production_headroom_factor, vg_name, lv_name, lv_size_bytes,
  vg_reserve_bytes, bridge, subnet, pool, egress_table, egress_unit,
  siblings (instance names expected to exist), lan_cidrs (known LAN ranges
  that must not overlap)
"""
import ipaddress
import json
import re
import sys

MIB = 1024 * 1024
UNITS = {"": 1, "B": 1, "KB": 1000, "MB": 1000**2, "GB": 1000**3, "TB": 1000**4,
         "KIB": 1024, "MIB": 1024**2, "GIB": 1024**3, "TIB": 1024**4}


class Unknown(Exception):
    pass


def section(facts, name, parse=None):
    s = facts.get("sections", {}).get(name)
    if s is None:
        raise Unknown(f"{name}: not collected")
    if s["rc"] != 0:
        raise Unknown(f"{name}: `{s['cmd']}` exited {s['rc']} ({s['stderr'].strip()[:160]})")
    out = s["stdout"]
    if parse is None:
        return out
    try:
        return parse(out)
    except Exception as e:  # noqa: BLE001 — any parse failure is UNKNOWN
        raise Unknown(f"{name}: unparseable output ({e})") from e


def size_bytes(v, total=None):
    """LXD memory limit → bytes. Percentages need the host total."""
    v = str(v).strip()
    m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*%", v)
    if m:
        if total is None:
            raise Unknown(f"percentage limit {v} without a host total")
        return int(total * float(m.group(1)) / 100)
    m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*([A-Za-z]*)", v)
    if not m or m.group(2).upper() not in UNITS:
        raise Unknown(f"unrecognised size '{v}'")
    return int(float(m.group(1)) * UNITS[m.group(2).upper()])


def cpu_count(v):
    v = str(v).strip()
    if re.fullmatch(r"\d+", v):
        return int(v)
    if re.fullmatch(r"[\d,\-]+", v):  # a pinned set such as 0-3,6
        n = 0
        for part in v.split(","):
            a, _, b = part.partition("-")
            n += (int(b) - int(a) + 1) if b else 1
        return n
    raise Unknown(f"unrecognised limits.cpu '{v}'")


def meminfo_bytes(text, key):
    m = re.search(rf"^{key}:\s+(\d+) kB$", text, re.M)
    if not m:
        raise Unknown(f"/proc/meminfo has no {key}")
    return int(m.group(1)) * 1024


def docker_mem_bytes(s):
    # docker stats MemUsage: "412.3MiB / 26.9GiB"
    return size_bytes(s.split("/")[0].strip())

def evaluate(facts, plan):
    results = []

    def check(name, fn):
        try:
            ok, detail = fn()
            results.append(("PASS" if ok else "FAIL", name, detail))
        except Unknown as e:
            results.append(("UNKNOWN", name, str(e)))

    if facts.get("schema") != "ci-preflight-facts/1":
        return [("UNKNOWN", "facts", "not a ci-preflight-facts/1 document")]

    # Older Ansible renders templated plan values as strings ("4"); accept
    # exact numbers only, and refuse anything else rather than guess.
    plan = dict(plan)
    try:
        for k in ("cpu", "memory_mib", "reserve_cpu", "reserve_memory_mib", "lv_size_bytes", "vg_reserve_bytes"):
            v = str(plan[k]).strip()
            if not re.fullmatch(r"\d+", v):
                raise ValueError(f"{k}={plan[k]!r}")
            plan[k] = int(v)
        plan["production_headroom_factor"] = float(str(plan["production_headroom_factor"]))
    except (KeyError, ValueError) as e:
        return [("UNKNOWN", "plan", f"plan value missing or not a number: {e}")]

    # ── CPU and memory: every OTHER instance's EFFECTIVE limits ──────────────
    def others():
        insts = section(facts, "lxc_list", json.loads)
        mine = [i for i in insts if i["name"] == plan["vm_name"]]
        rest = [i for i in insts if i["name"] != plan["vm_name"]]
        return mine, rest

    def eff(i, key):
        # expanded_config includes what profiles contribute: an instance with
        # no local limit can still inherit one — or inherit none (unbounded).
        v = (i.get("expanded_config") or {}).get(key)
        if v in (None, ""):
            raise Unknown(f"instance {i['name']} has no effective {key} (unbounded or unreadable); "
                          f"it could consume the host")
        return v

    def cpu_check():
        host = int(section(facts, "nproc").strip())
        _, rest = others()
        used = sum(cpu_count(eff(i, "limits.cpu")) for i in rest)
        left = host - used - plan["cpu"]
        return left >= plan["reserve_cpu"], (
            f"host {host} vCPU − other instances {used} − this VM {plan['cpu']} = {left} "
            f"left for the host and production (need ≥ {plan['reserve_cpu']})")
    check("cpu", cpu_check)

    def mem_check():
        info = section(facts, "meminfo")
        total = meminfo_bytes(info, "MemTotal")
        _, rest = others()
        used = sum(size_bytes(eff(i, "limits.memory"), total) for i in rest)
        want = plan["memory_mib"] * MIB
        left = total - used - want
        return left >= plan["reserve_memory_mib"] * MIB, (
            f"host {total // MIB} MiB − other instances {used // MIB} MiB − this VM {want // MIB} MiB "
            f"= {left // MIB} MiB left (need ≥ {plan['reserve_memory_mib']} MiB)")
    check("memory", mem_check)

    def production_headroom():
        # Production containers run on the HOST (not in a VM limit), so they
        # live inside the reserve. Their observed use, times a headroom factor
        # for peaks, must fit the reserve left after all VM limits.
        info = section(facts, "meminfo")
        total = meminfo_bytes(info, "MemTotal")
        stats = [json.loads(l) for l in section(facts, "docker_stats").splitlines() if l.strip()]
        if not stats:
            raise Unknown("no running production containers observed; the headroom cannot be measured")
        prod = sum(docker_mem_bytes(s["MemUsage"]) for s in stats)
        _, rest = others()
        vms = sum(size_bytes(eff(i, "limits.memory"), total) for i in rest) + plan["memory_mib"] * MIB
        reserve = total - vms
        need = int(prod * plan["production_headroom_factor"]) + 2048 * MIB  # + host OS/LXD/Docker overhead
        return reserve >= need, (
            f"production containers use {prod // MIB} MiB now (×{plan['production_headroom_factor']} "
            f"+ 2048 MiB host overhead = {need // MIB} MiB); memory outside VM limits: {reserve // MIB} MiB")
    check("production headroom", production_headroom)

    def unlimited_production():
        limits = [json.loads(l) for l in section(facts, "docker_limits").splitlines() if l.strip()]
        unl = [l["name"] for l in limits if not l.get("memory")]
        # Informational FAIL is too strong: unlimited containers are expected
        # (Keel). They are covered by the headroom check; report them.
        return True, ("containers without a memory limit (sized by observation above): "
                      + (", ".join(sorted(unl)) or "none"))
    check("production limits", unlimited_production)

    # ── Storage ──────────────────────────────────────────────────────────────
    def vg_check():
        vgs = section(facts, "vgs", json.loads)["report"][0]["vg"]
        vg = [v for v in vgs if v["vg_name"] == plan["vg_name"]]
        if not vg:
            raise Unknown(f"volume group {plan['vg_name']} not found")
        free = int(vg[0]["vg_free"])
        need = plan["lv_size_bytes"] + plan["vg_reserve_bytes"]
        return free >= need, f"{plan['vg_name']} free {free / 1024**3:.1f} GiB (need {need / 1024**3:.1f} GiB: volume + reserve)"
    check("volume group", vg_check)

    def lv_absent():
        lvs = section(facts, "lvs", json.loads)["report"][0]["lv"]
        clash = [l for l in lvs if l["lv_name"] == plan["lv_name"] and l["vg_name"] == plan["vg_name"]]
        return not clash, (f"{plan['vg_name']}/{plan['lv_name']} already exists — adopt only after review"
                           if clash else f"{plan['vg_name']}/{plan['lv_name']} is free")
    check("logical volume name", lv_absent)

    def pool_absent():
        pools = section(facts, "lxc_storage", json.loads)
        clash = [p for p in pools if p["name"] == plan["pool"]]
        return not clash, f"LXD pool {plan['pool']} {'exists' if clash else 'is free'}"
    check("LXD pool name", pool_absent)

    # ── Names already on the host ────────────────────────────────────────────
    def vm_absent():
        mine, _ = others()
        return not mine, f"instance {plan['vm_name']} {'already exists' if mine else 'is free'}"
    check("instance name", vm_absent)

    def siblings_present():
        _, rest = others()
        names = {i["name"] for i in rest}
        missing = [s for s in plan["siblings"] if s not in names]
        strangers = sorted(names - set(plan["siblings"]))
        ok = not missing and not strangers
        return ok, (f"expected siblings {plan['siblings']}; missing {missing or 'none'}; "
                    f"unexpected instances {strangers or 'none'} (the role refuses strangers)")
    check("sibling instances", siblings_present)

    def nft_absent():
        tables = section(facts, "nft_tables", json.loads)["nftables"]
        names = [t["table"]["name"] for t in tables if "table" in t]
        return plan["egress_table"] not in names, (
            f"nft table inet {plan['egress_table']} {'already loaded' if plan['egress_table'] in names else 'is free'}; "
            f"tables present: {sorted(set(names))}")
    check("egress table name", nft_absent)

    # ── Network: the subnet must be unused everywhere ───────────────────────
    subnet = ipaddress.ip_network(plan["subnet"])

    def overlap_addrs():
        addrs = section(facts, "ip4_addr", json.loads)
        hits = []
        for link in addrs:
            for a in link.get("addr_info", []):
                net = ipaddress.ip_interface(f"{a['local']}/{a['prefixlen']}").network
                if net.overlaps(subnet):
                    hits.append(f"{link['ifname']} {a['local']}/{a['prefixlen']}")
        return not hits, f"no host address in {subnet}" if not hits else f"in use: {hits}"
    check("subnet vs host addresses", overlap_addrs)

    def overlap_routes():
        routes = section(facts, "ip4_routes", json.loads)
        hits = []
        for r in routes:
            dst = r.get("dst", "")
            if dst in ("", "default"):
                continue
            try:
                net = ipaddress.ip_network(dst if "/" in dst else f"{dst}/32", strict=False)
            except ValueError:
                raise Unknown(f"unparseable route destination {dst}")
            if net.overlaps(subnet):
                hits.append(f"{dst} dev {r.get('dev', '?')} table {r.get('table', 'main')}")
        return not hits, f"no route (any table) overlaps {subnet}" if not hits else f"overlapping routes: {hits}"
    check("subnet vs routes (all tables)", overlap_routes)

    def overlap_lxd():
        nets = section(facts, "lxc_networks", json.loads)
        hits = []
        for n in nets:
            a = (n.get("config") or {}).get("ipv4.address", "")
            if a and a not in ("none", "auto"):
                if ipaddress.ip_interface(a).network.overlaps(subnet):
                    hits.append(f"{n['name']} {a}")
            elif a == "auto":
                raise Unknown(f"LXD network {n['name']} has ipv4.address=auto (subnet chosen at runtime)")
        bridge = [n for n in nets if n["name"] == plan["bridge"]]
        return not hits and not bridge, (
            f"LXD networks overlapping {subnet}: {hits or 'none'}; bridge {plan['bridge']} "
            f"{'already exists' if bridge else 'is free'}")
    check("subnet vs LXD networks", overlap_lxd)

    def lan_overlap():
        hits = [c for c in plan.get("lan_cidrs", []) if ipaddress.ip_network(c).overlaps(subnet)]
        return not hits, f"known LAN ranges {plan.get('lan_cidrs', [])} {'overlap: ' + str(hits) if hits else 'do not overlap'}"
    check("subnet vs known LAN ranges", lan_overlap)

    def ipv6_bridges():
        nets = section(facts, "lxc_networks", json.loads)
        with6 = [n["name"] for n in nets if n.get("managed") and (n.get("config") or {}).get("ipv6.address", "none") not in ("none", "")]
        # Informational for siblings; the new bridge is created with none and
        # its policy drops IPv6 regardless.
        return True, f"managed LXD bridges with IPv6: {with6 or 'none'}"
    check("IPv6 on existing bridges", ipv6_bridges)

    def forward_policy():
        rules = section(facts, "docker_forward")
        return "-P FORWARD DROP" in rules, "iptables FORWARD policy is DROP (Docker)" if "-P FORWARD DROP" in rules \
            else "iptables FORWARD policy is not DROP; the egress design assumes Docker's DROP"
    check("forward policy", forward_policy)

    def lxd_units():
        u = section(facts, "units")
        found = [x for x in ("snap.lxd.daemon.service", "lxd.service", "lxd.socket") if x in u]
        return bool(found), f"LXD units present: {found or 'none'} (the early egress unit orders before these)"
    check("LXD service unit", lxd_units)

    return results


def main():
    facts = json.load(open(sys.argv[1]))
    plan = json.load(open(sys.argv[2]))
    results = evaluate(facts, plan)
    width = max(len(n) for _, n, _ in results)
    for status, name, detail in results:
        print(f"  {status:<7} {name:<{width}}  {detail}")
    bad = [r for r in results if r[0] != "PASS"]
    print(f"\npreflight: {'PASS' if not bad else 'NOT READY'} — {len(results) - len(bad)} passed, "
          f"{sum(1 for r in bad if r[0] == 'FAIL')} failed, {sum(1 for r in bad if r[0] == 'UNKNOWN')} unknown")
    sys.exit(0 if not bad else 1)


if __name__ == "__main__":
    main()
