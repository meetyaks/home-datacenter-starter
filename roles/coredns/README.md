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

## The role creates the directories it installs into

Including **`coredns_bin_dir`**. A stock macOS has no `/usr/local/sbin` — Homebrew creates `/usr/local/bin`, nothing creates `/usr/local/sbin` — and `ansible.builtin.copy` will not create a missing destination. The second deployment attempt on dc1-arm-1 got through the corrected extraction and then stopped:

```
TASK [coredns : Install it]
Destination directory /usr/local/sbin does not exist
```

One task owns all three directories (`coredns_conf_dir`, `coredns_log_dir`, `coredns_bin_dir`) so the ownership and mode are stated once: `state: directory`, `owner: root`, `mode: 0755`, group `wheel` on Darwin and `root` on Linux, with `become`. It is the **first** task in `install.yml`, because everything after it assumes the directories exist — the installed-version check runs `{{ coredns_bin_dir }}/coredns`, the download stages beside it, and the copy writes into it. Creating it later only moves the failure.

`/usr/local/sbin` is on the default `PATH` and will hold a binary that runs as root, so root ownership and `0755` are load-bearing, not cosmetic.

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

## The role installs its own verifier prerequisite

`tasks/verify.yml` asks the running resolver questions with `dig`, and until now the role never declared that. It worked on dc1-x86 only because `dnsutils` happened to be installed there; a clean Debian host has no `dig`, and the role would have installed a resolver it could not check.

`tasks/verifier-prereq.yml` runs **before** install and makes that ownership explicit: on Debian-family hosts it installs `bind9-dnsutils`; on macOS it *asserts* `/usr/bin/dig` is present and never reaches for Homebrew — making a package manager a prerequisite of the LAN's primary resolver is the same trade that was refused for GNU tar; on any other family it fails with a message naming the package to add.

## `coredns_dns_port` is a testability seam, not a tuning knob

It defaults to `53` and production must leave it there — `tests/dns-zone.yml` fails if the shipped default is anything else.

It exists because the macOS launchd path had nowhere to run. The live daemon holds `127.0.0.1:53`, and macOS refuses to bind another `127/8` address without an explicit `ifconfig lo0 alias`, so a disposable instance could use neither another address nor another port. That path stayed unexecuted, and three of this rollout's six defects reached a real deployment through it.

Only the disposable test overrides it.

## Running the role for real, against a throwaway host

Every other DNS suite renders templates or parses YAML. These two *execute the role* and then interrogate the running process — which is what the rest could not do, and why six defects reached deployment, four of them in verification code no test ran.

```bash
tests/run-coredns-role.sh          # Linux: disposable systemd container
tests/run-coredns-role.sh --red    # the same, with the handler flush removed
tests/run-coredns-launchd.sh       # macOS: disposable launchd daemon
```

**Linux** needs Docker and a **native amd64** host — the role pins `linux_amd64`, and `dig` segfaults under qemu — so on an Apple Silicon workstation it skips loudly and runs for real on the CI runner. The image deliberately ships **without** `dig`, which is what makes the prerequisite above a proof rather than an assumption.

**`--red`** removes `meta: flush_handlers` from the role inside the container and requires the run to **fail**, with the old PID still alive, the old health port still listening and the new one absent. It exits 0 when the defect reproduces and non-zero if the role converges without the flush, so the fix cannot be quietly reverted. The flush is restored from a byte-for-byte copy on exit, interrupt included. CI runs both directions.

**macOS is operator-run on the management node**, beside the live resolver, because it needs interactive sudo for a launchd system daemon. It takes a `mktemp` prefix, a per-run unique label (`org.dc1.corednsdisposable${STAMP}` — never the live `org.coredns.coredns`) and three free high ports; it records the live daemon's PID, Corefile fingerprint, binary and answers before it starts and proves all four unchanged afterwards. Teardown is trapped on success, failure and interrupt, boots out only its own label, kills only the PID it recorded and started, and refuses to remove any path that is not its own prefix.

`tests/dns-harness-integrity.yml` checks those properties statically, because **a broken harness passes**: nothing about running it reveals that it has lost its teardown trap, or its PID comparison, or — worst — that its label now points at the live resolver.

## Required per-host variable

`coredns_bind_addresses` — this node's own LAN address plus loopback. There is **no default** and the wildcard is refused: a resolver on `0.0.0.0` listens on every interface the host happens to have, including a VPN or tunnel, and then the ACL is the only thing between it and the world.

Set in `inventory/hosts.yml` under `dns_servers`.

## Run it

```bash
# On dc1-arm-1 only — playbooks/dns-controller-guard.yml refuses anywhere else.
ansible-playbook playbooks/dns.yml --ask-become-pass
```

## Tests

`tests/dns-zone.yml`, `tests/dns-services.yml`, `tests/dns-inventory.yml`, `tests/dns-install-platform.yml`, `tests/dns-task-shape.yml`, `tests/dns-harness-integrity.yml`, `tests/run-dns-controller-guard.sh`, `tests/run-dns-mutations.sh` — all controller-only; they connect to nothing and install nothing. The mutation runner breaks each guard in turn and requires the suites to go red *for the matching reason*, and that now includes the end-to-end harnesses' own safety properties.

The two suites that **execute** the role are described above. `tests/run-all.sh` runs everything in order.
