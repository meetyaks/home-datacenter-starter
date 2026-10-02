# `roles/coredns`

Installs CoreDNS as an authoritative resolver for `dc1.lan` on both LAN nodes — launchd on the macOS primary, systemd on the Linux secondary.

**The authoritative document is [docs/dc1-lan-dns.md](../../docs/dc1-lan-dns.md).** It covers why this exists, what the zone serves, why `keel.dc1.lan` is absent, the deployment order relative to the router, the Orbi settings, and the upgrade procedure. This file deliberately does not restate any of it — two hand-maintained copies of one explanation drift, and the drift is silent.

## What this role does

1. Asks the machine which platform it is, and **refuses one it has no verified checksum for**.
2. Downloads the pinned CoreDNS release and verifies the bytes **before** installing them, then unpacks them **with the tar that platform ships** (see below).
3. Renders the `Corefile` and the zone from `defaults/main.yml` — the only copy of either.
4. Installs the right service definition: launchd on Darwin, systemd elsewhere.
5. **Queries the running resolver** to confirm it serves every record and returns an authoritative NXDOMAIN for the reserved `keel.dc1.lan`.

Step 5 is the one that matters. Everything before it proves the configuration was *written*; only a real query proves the daemon parsed it, bound its port and serves the zone — a Corefile that parses but serves nothing looks identical from the filesystem.

## Unpacking is platform-split, and GNU tar was deliberately not installed

The first watched deployment, run from dc1-arm-1, stopped on the primary before dc1-x86 was touched:

```
TASK [coredns : Unpack it]
Failed to find handler for ".../coredns.tgz"
Command "/usr/bin/tar" detected as tar type bsd. GNU tar required.
```

The download had already matched the pinned SHA-256. Nothing was wrong with the archive — macOS ships **bsdtar** as `/usr/bin/tar`, it extracts this tarball perfectly well, and `ansible.builtin.unarchive` simply refuses to use it.

| platform | how it unpacks |
|---|---|
| Darwin | `ansible.builtin.command` with `argv`, calling `/usr/bin/tar -xzf … -C …` |
| Linux | `ansible.builtin.unarchive`, unchanged |

**Installing GNU tar was rejected.** It would make Homebrew (or a source build) a prerequisite of the LAN's primary resolver, on the management node, to work around a module's preference — a permanent dependency, an extra update surface and a bootstrap ordering problem, in exchange for nothing the platform's own tar cannot already do. The archive is a single-file `.tgz`.

`argv` rather than shell text because the staging path comes from a tempfile and is interpolated in: as a shell string, a path containing a space or a quote would be re-split, on the node that serves the whole LAN's DNS.

Either branch is followed by an assertion that extraction actually produced a **regular file** at `<staging>/coredns`, before the copy. Without it a silent extraction failure reaches `copy` and reports `Source .../coredns not found` — the symptom, not the cause, diagnosed in front of a down resolver.

Enforced by `tests/dns-install-platform.yml`, which parses the task file as YAML (so it reads executable structure, not comments), and by seven mutations in `tests/run-dns-mutations.sh` that remove the Darwin branch, invert the split, drop its `needs_install` gate, replace `argv` with a shell string, delete the assertion, move it after the copy, and drop the download checksum.

## Required per-host variable

`coredns_bind_addresses` — this node's own LAN address plus loopback. There is **no default** and the wildcard is refused: a resolver on `0.0.0.0` listens on every interface the host happens to have, including a VPN or tunnel, and then the ACL is the only thing between it and the world.

Set in `inventory/hosts.yml` under `dns_servers`.

## Run it

```bash
# On dc1-arm-1 only — playbooks/dns-controller-guard.yml refuses anywhere else.
ansible-playbook playbooks/dns.yml --ask-become-pass
```

## Tests

`tests/dns-zone.yml`, `tests/dns-services.yml`, `tests/dns-inventory.yml`, `tests/dns-install-platform.yml`, `tests/run-dns-controller-guard.sh`, `tests/run-dns-mutations.sh` — all controller-only; they connect to nothing and install nothing. The mutation runner breaks each guard in turn and requires the suites to go red *for the matching reason*.
