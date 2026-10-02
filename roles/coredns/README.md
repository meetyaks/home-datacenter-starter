# `roles/coredns`

Installs CoreDNS as an authoritative resolver for `dc1.lan` on both LAN nodes — launchd on the macOS primary, systemd on the Linux secondary.

**The authoritative document is [docs/dc1-lan-dns.md](../../docs/dc1-lan-dns.md).** It covers why this exists, what the zone serves, why `keel.dc1.lan` is absent, the deployment order relative to the router, the Orbi settings, and the upgrade procedure. This file deliberately does not restate any of it — two hand-maintained copies of one explanation drift, and the drift is silent.

## What this role does

1. Asks the machine which platform it is, and **refuses one it has no verified checksum for**.
2. Downloads the pinned CoreDNS release and verifies the bytes **before** installing them.
3. Renders the `Corefile` and the zone from `defaults/main.yml` — the only copy of either.
4. Installs the right service definition: launchd on Darwin, systemd elsewhere.
5. **Queries the running resolver** to confirm it serves every record and returns an authoritative NXDOMAIN for the reserved `keel.dc1.lan`.

Step 5 is the one that matters. Everything before it proves the configuration was *written*; only a real query proves the daemon parsed it, bound its port and serves the zone — a Corefile that parses but serves nothing looks identical from the filesystem.

## Required per-host variable

`coredns_bind_addresses` — this node's own LAN address plus loopback. There is **no default** and the wildcard is refused: a resolver on `0.0.0.0` listens on every interface the host happens to have, including a VPN or tunnel, and then the ACL is the only thing between it and the world.

Set in `inventory/hosts.yml` under `dns_servers`.

## Run it

```bash
# On dc1-arm-1 only — playbooks/dns-controller-guard.yml refuses anywhere else.
ansible-playbook playbooks/dns.yml --ask-become-pass
```

## Tests

`tests/dns-zone.yml`, `tests/dns-services.yml`, `tests/dns-inventory.yml`, `tests/run-dns-controller-guard.sh`, `tests/run-dns-mutations.sh` — all controller-only; they connect to nothing and install nothing. The mutation runner breaks each guard in turn and requires the suites to go red *for the matching reason*.
