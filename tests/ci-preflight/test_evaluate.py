#!/usr/bin/env python3
"""Fixture tests for tools/ci-preflight/evaluate.py (stdlib only).

The facts below are SYNTHETIC — shaped like collect.sh output on a host like
dc1-x86 — and say nothing about the real host. Each case changes one thing
and asserts the verdict for the check it concerns, including that anything
unreadable is UNKNOWN (a failure), never assumed fine.
"""
import copy
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "tools", "ci-preflight"))
import evaluate  # noqa: E402

GIB = 1024**3


def sec(stdout, rc=0, cmd="synthetic"):
    return {"cmd": cmd, "rc": rc, "stdout": stdout, "stderr": ""}


def base_facts():
    lxc = [{"name": "dc1-ci-1", "status": "Running", "type": "virtual-machine",
            "config": {"limits.cpu": "8", "limits.memory": "14GiB"},
            "expanded_config": {"limits.cpu": "8", "limits.memory": "14GiB"}}]
    return {"schema": "ci-preflight-facts/1", "sections": {
        "nproc": sec("16\n"),
        "meminfo": sec(f"MemTotal:       {32 * 1024 * 1024} kB\nMemAvailable:   {12 * 1024 * 1024} kB\n"),
        "lxc_list": sec(json.dumps(lxc)),
        "lxc_networks": sec(json.dumps([
            {"name": "lxdbr0", "managed": True, "config": {"ipv4.address": "10.71.0.1/24", "ipv6.address": "none"}},
            {"name": "eno1", "managed": False, "config": {}}])),
        "lxc_storage": sec(json.dumps([{"name": "ci-pool"}])),
        "vgs": sec(json.dumps({"report": [{"vg": [{"vg_name": "ubuntu-vg", "vg_size": str(400 * GIB), "vg_free": str(120 * GIB)}]}]})),
        "lvs": sec(json.dumps({"report": [{"lv": [{"lv_name": "ci-lxd", "vg_name": "ubuntu-vg", "lv_size": str(180 * GIB), "lv_attr": "-wi-ao----"}]}]})),
        "docker_stats": sec("\n".join(json.dumps({"Name": n, "MemUsage": u}) for n, u in [
            ("keel-web-1", "612.4MiB / 31.3GiB"), ("keel-postgres-1", "1.1GiB / 31.3GiB"), ("caddy", "40MiB / 31.3GiB")])),
        "docker_limits": sec("\n".join(json.dumps({"name": n, "memory": 0, "nanoCpus": 0}) for n in ["keel-web-1", "keel-postgres-1"])),
        "ip4_addr": sec(json.dumps([
            {"ifname": "eno1", "addr_info": [{"local": "10.0.0.20", "prefixlen": 24}]},
            {"ifname": "lxdbr0", "addr_info": [{"local": "10.71.0.1", "prefixlen": 24}]},
            {"ifname": "docker0", "addr_info": [{"local": "172.17.0.1", "prefixlen": 16}]},
            {"ifname": "tailscale0", "addr_info": [{"local": "100.101.1.2", "prefixlen": 32}]}])),
        "ip4_routes": sec(json.dumps([
            {"dst": "default", "gateway": "10.0.0.1", "dev": "eno1"},
            {"dst": "10.0.0.0/24", "dev": "eno1"}, {"dst": "10.71.0.0/24", "dev": "lxdbr0"},
            {"dst": "100.64.0.0/10", "dev": "tailscale0", "table": "52"}])),
        "nft_tables": sec(json.dumps({"nftables": [{"metainfo": {}}, {"table": {"family": "ip", "name": "filter"}},
                                                   {"table": {"family": "inet", "name": "ci_egress"}}]})),
        "docker_forward": sec("-P FORWARD DROP\n-A FORWARD -j DOCKER-USER\n"),
        "units": sec("snap.lxd.daemon.service enabled\ndocker.service enabled\nci-egress.service enabled\n"),
    }}


PLAN = {"vm_name": "dc1-ci-tw-1", "cpu": 4, "memory_mib": 6144, "reserve_cpu": 4, "reserve_memory_mib": 6144,
        "production_headroom_factor": 1.5, "vg_name": "ubuntu-vg", "lv_name": "ci-tw-lxd",
        "lv_size_bytes": 50 * GIB, "vg_reserve_bytes": 20 * GIB, "bridge": "citwbr0", "subnet": "10.72.0.0/24",
        "pool": "ci-tw-pool", "egress_table": "ci_egress_tw", "egress_unit": "ci-egress-tw",
        "siblings": ["dc1-ci-1"], "lan_cidrs": ["10.0.0.0/24"]}


def verdicts(facts, plan=PLAN):
    return {name: status for status, name, _ in evaluate.evaluate(facts, plan)}


def mutate(fn):
    f = base_facts()
    fn(f["sections"])
    return f


def set_json(s, key, fn):
    d = json.loads(s[key]["stdout"])
    fn(d)
    s[key]["stdout"] = json.dumps(d)


class Preflight(unittest.TestCase):
    def test_a_host_with_room_passes_everything(self):
        v = verdicts(base_facts())
        self.assertEqual({k for k, s in v.items() if s != "PASS"}, set(), v)

    def test_an_instance_with_no_effective_memory_limit_is_unknown(self):
        def f(s):
            set_json(s, "lxc_list", lambda d: d[0]["expanded_config"].pop("limits.memory"))
        v = verdicts(mutate(f))
        self.assertEqual(v["memory"], "UNKNOWN")
        self.assertEqual(v["production headroom"], "UNKNOWN")

    def test_a_limit_inherited_from_a_profile_is_counted(self):
        # Local config empty, profile supplies the limit via expanded_config.
        def f(s):
            set_json(s, "lxc_list", lambda d: (d[0]["config"].clear(), d[0]["expanded_config"].update({"limits.memory": "21GiB"})))
        self.assertEqual(verdicts(mutate(f))["memory"], "FAIL")  # 32 − 21 (inherited) − 6 = 5 < 6

    def test_a_percentage_limit_is_resolved_against_the_host(self):
        def f(s):
            set_json(s, "lxc_list", lambda d: d[0]["expanded_config"].update({"limits.memory": "50%"}))
        self.assertEqual(verdicts(mutate(f))["memory"], "PASS")  # 32 − 16 − 6 = 10 ≥ 6

    def test_not_enough_cpu_fails(self):
        def f(s):
            s["nproc"]["stdout"] = "14\n"
        self.assertEqual(verdicts(mutate(f))["cpu"], "FAIL")  # 14 − 8 − 4 = 2 < 4

    def test_a_pinned_cpu_set_is_counted(self):
        def f(s):
            set_json(s, "lxc_list", lambda d: d[0]["expanded_config"].update({"limits.cpu": "0-9"}))
        self.assertEqual(verdicts(mutate(f))["cpu"], "FAIL")  # 16 − 10 − 4 = 2

    def test_heavy_production_use_fails_headroom(self):
        def f(s):
            s["docker_stats"]["stdout"] = json.dumps({"Name": "keel-postgres-1", "MemUsage": "7.5GiB / 31.3GiB"})
        self.assertEqual(verdicts(mutate(f))["production headroom"], "FAIL")

    def test_no_observed_production_is_unknown(self):
        def f(s):
            s["docker_stats"]["stdout"] = ""
        self.assertEqual(verdicts(mutate(f))["production headroom"], "UNKNOWN")

    def test_too_little_volume_group_space_fails(self):
        def f(s):
            set_json(s, "vgs", lambda d: d["report"][0]["vg"][0].update({"vg_free": str(60 * GIB)}))
        self.assertEqual(verdicts(mutate(f))["volume group"], "FAIL")

    def test_a_missing_volume_group_is_unknown(self):
        def f(s):
            set_json(s, "vgs", lambda d: d["report"][0]["vg"][0].update({"vg_name": "other-vg"}))
        self.assertEqual(verdicts(mutate(f))["volume group"], "UNKNOWN")

    def test_an_existing_lv_pool_bridge_or_instance_name_fails(self):
        def f(s):
            set_json(s, "lvs", lambda d: d["report"][0]["lv"].append({"lv_name": "ci-tw-lxd", "vg_name": "ubuntu-vg", "lv_size": "1", "lv_attr": ""}))
            set_json(s, "lxc_storage", lambda d: d.append({"name": "ci-tw-pool"}))
            set_json(s, "lxc_networks", lambda d: d.append({"name": "citwbr0", "managed": True, "config": {"ipv4.address": "10.99.0.1/24"}}))
            set_json(s, "lxc_list", lambda d: d.append({"name": "dc1-ci-tw-1", "expanded_config": {"limits.cpu": "4", "limits.memory": "6GiB"}}))
        v = verdicts(mutate(f))
        for k in ("logical volume name", "LXD pool name", "subnet vs LXD networks", "instance name"):
            self.assertEqual(v[k], "FAIL", k)

    def test_an_unexpected_instance_fails(self):
        def f(s):
            set_json(s, "lxc_list", lambda d: d.append({"name": "someone-elses-vm", "expanded_config": {"limits.cpu": "1", "limits.memory": "1GiB"}}))
        self.assertEqual(verdicts(mutate(f))["sibling instances"], "FAIL")

    def test_the_subnet_on_a_host_address_fails(self):
        def f(s):
            set_json(s, "ip4_addr", lambda d: d.append({"ifname": "wg0", "addr_info": [{"local": "10.72.0.9", "prefixlen": 24}]}))
        self.assertEqual(verdicts(mutate(f))["subnet vs host addresses"], "FAIL")

    def test_the_subnet_in_another_routing_table_fails(self):
        # e.g. a Tailscale subnet route in table 52
        def f(s):
            set_json(s, "ip4_routes", lambda d: d.append({"dst": "10.72.0.0/16", "dev": "tailscale0", "table": "52"}))
        self.assertEqual(verdicts(mutate(f))["subnet vs routes (all tables)"], "FAIL")

    def test_an_lxd_network_with_an_auto_subnet_is_unknown(self):
        def f(s):
            set_json(s, "lxc_networks", lambda d: d.append({"name": "lxdbr1", "managed": True, "config": {"ipv4.address": "auto"}}))
        self.assertEqual(verdicts(mutate(f))["subnet vs LXD networks"], "UNKNOWN")

    def test_a_known_lan_overlap_fails(self):
        plan = dict(PLAN, lan_cidrs=["10.72.0.0/16"])
        self.assertEqual(verdicts(base_facts(), plan)["subnet vs known LAN ranges"], "FAIL")

    def test_a_tool_that_failed_is_unknown_not_zero(self):
        def f(s):
            s["lxc_list"] = sec("", rc=127)
            s["vgs"] = sec("", rc=5)
        v = verdicts(mutate(f))
        for k in ("cpu", "memory", "instance name", "sibling instances", "volume group"):
            self.assertEqual(v[k], "UNKNOWN", k)

    def test_garbage_output_is_unknown(self):
        def f(s):
            s["ip4_routes"]["stdout"] = "not json"
        self.assertEqual(verdicts(mutate(f))["subnet vs routes (all tables)"], "UNKNOWN")

    def test_an_existing_egress_table_fails(self):
        def f(s):
            set_json(s, "nft_tables", lambda d: d["nftables"].append({"table": {"family": "inet", "name": "ci_egress_tw"}}))
        self.assertEqual(verdicts(mutate(f))["egress table name"], "FAIL")

    def test_forward_policy_not_drop_fails(self):
        def f(s):
            s["docker_forward"]["stdout"] = "-P FORWARD ACCEPT\n"
        self.assertEqual(verdicts(mutate(f))["forward policy"], "FAIL")

    def test_not_a_facts_document(self):
        self.assertEqual(evaluate.evaluate({"schema": "x"}, PLAN)[0][0], "UNKNOWN")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--dump-fixture":
        # For the playbook test: the passing synthetic host, as collect.sh would emit it.
        json.dump(base_facts(), open(sys.argv[2], "w"))
        sys.exit(0)
    if len(sys.argv) == 3 and sys.argv[1] == "--dump-overlap-fixture":
        json.dump(mutate(lambda s: set_json(s, "ip4_routes", lambda d: d.append({"dst": "10.72.0.0/16", "dev": "tailscale0", "table": "52"}))), open(sys.argv[2], "w"))
        sys.exit(0)
    unittest.main(verbosity=1)
