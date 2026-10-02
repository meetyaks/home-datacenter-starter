# LAN DNS for `dc1.lan`

Two CoreDNS resolvers, authoritative for `dc1.lan`, rendered from this repository and deployed by `playbooks/dns.yml`.

## Why this exists

`dc1.lan` was never DNS.

`keel.dc1.lan` resolved from a single line in **one workstation's** `/etc/hosts`, whose own comment admitted it: `10.0.0.3 keel.dc1.lan # temporary until dc1.lan DNS exists`. The router at `10.0.0.1` served no `dc1.lan` record at all, no host on the LAN ran a resolver, and `dig` — which bypasses `/etc/hosts` — returned nothing but the root SOA. A name that appeared in runbooks, issuer URLs and CORS origins was reachable from exactly one machine, by hand-edited state that nothing re-created and nothing noticed the loss of.

That is the same class of defect as the hand-placed `compose.dev-mode.yml` this repository replaced in PR #11: real, load-bearing state living outside Git.

It also made a circular dependency that could not be broken from inside: DNS is deployed *by* Ansible, and `inventory/hosts.yml` reached the managed host as `ansible_host: dc1-x86` — a name only DNS could resolve. The inventory now uses `10.0.0.3`, which breaks the cycle while leaving `inventory_hostname` as `dc1-x86`, because that string appears in group membership, evidence paths and release records.

## What is served

| name | address |
|---|---|
| `dc1-arm-1.dc1.lan` | `10.0.0.22` |
| `dc1-x86.dc1.lan` | `10.0.0.3` |
| `keel-dev.dc1.lan` | `10.0.0.3` |

Everything else under `dc1.lan` is an **authoritative NXDOMAIN**. Everything outside it is forwarded to explicit public upstreams.

### `keel.dc1.lan` is deliberately absent

It is the reserved **future production** identity, on separate hardware. Creating it now — even pointed at dc1-x86 "for now" — would give this DEV installation a second issuer, and would mean the eventual production cutover has to take a live name away from a running environment. DEV's canonical name is `keel-dev.dc1.lan` and nothing else.

Enforced, not merely intended: `tests/dns-zone.yml` fails if `keel` appears in the zone, `roles/coredns/tasks/configure.yml` refuses it on the host as well (so an `-e` override cannot sneak it past CI), and `tests/run-dns-mutations.sh` plants it and requires the refusal.

### There is no reverse zone, on purpose

Serving PTR records for these hosts would mean claiming `0.0.10.in-addr.arpa` — the whole of `10.0.0.0/24`. This repository owns exactly two addresses in that range; the router hands out the rest. An authoritative reverse zone would answer NXDOMAIN for every other host on the LAN instead of letting those queries go where they should. If reverse lookups are ever genuinely needed, delegate the two addresses rather than claiming the `/24`.

## Two resolvers, and why the second is not optional

Once the router advertises these addresses to every DHCP client, a single resolver makes LAN name resolution a single point of failure — **including for the machine you would use to repair it**.

| | node | platform | service |
|---|---|---|---|
| primary | `dc1-arm-1` (`10.0.0.22`) | macOS ARM64 | launchd |
| secondary | `dc1-x86` (`10.0.0.3`) | Linux AMD64 | systemd |

Both are **authoritative from the same Git content**. There is no zone transfer and no primary/secondary relationship in the DNS sense — which is simpler than AXFR and has no master to lose. The property that keeps them consistent is that they render the same bytes, and that is tested directly (`tests/dns-zone.yml`, "both nodes render byte-identical zones"). It is also why the SOA serial is derived from the record content rather than from the clock: a timestamp would differ purely because the two nodes were deployed a minute apart.

## 🚫 A public secondary DNS service is prohibited

**Do not delegate, mirror, or register `dc1.lan` with any public or third-party DNS service** — not a cloud zone, not a dynamic-DNS provider, not a public secondary or "backup DNS" offering, and not the router's Dynamic DNS feature.

`dc1.lan` is internal namespace describing private `10.0.0.0/24` addresses. Publishing it would:

- disclose the internal topology — host names, roles and addresses — to anyone who queries it,
- publish records that are useless outside the LAN, since they point at unroutable addresses,
- create a second authority for the zone, so a client could get an answer this repository did not write, and
- put the canonical DEV identity, which appears in JWT issuers and CORS origins, under someone else's control.

Redundancy for this zone is the **second internal resolver** described above, and nothing else. `tests/dns-zone.yml` asserts this prohibition is still stated here, so it cannot quietly disappear from the documentation.

The same reasoning forbids a public resolver in the router's DNS fields — see below.

## Deployment order, which is not a formality

```bash
# On dc1-arm-1 — the playbook refuses to run anywhere else.
ansible-playbook playbooks/dns.yml --ask-become-pass
```

**Deploy both resolvers before changing the router.** Until the router forwards to these addresses, nothing depends on them and a failure costs nothing. Afterwards, a broken resolver is a LAN-wide outage. The play is `serial: 1`, primary first, so a mistake lands on one node at a time.

Prove both answer before touching the router:

```bash
dig @10.0.0.22 keel-dev.dc1.lan A      # must be 10.0.0.3, and only that
dig @10.0.0.3  keel-dev.dc1.lan A
dig @10.0.0.22 keel.dc1.lan A          # must be an authoritative NXDOMAIN
dig @10.0.0.22 github.com A            # the forwarder works
dig +tcp @10.0.0.22 keel-dev.dc1.lan A # TCP as well as UDP
```

Then stop each resolver in turn and confirm the other still answers — the redundancy is the reason there are two, and an untested failover is a guess.

## The router

The router is a NETGEAR Orbi at `10.0.0.1`. It is configured **by hand, in its UI**; nothing in this repository logs into it and its password is not stored anywhere here.

### Address reservations

`ADVANCED → Setup → LAN Setup → Address Reservation`

| device name | IP | MAC |
|---|---|---|
| `dc1-x86` | `10.0.0.3` | `38:d5:7a:26:26:f7` |
| `dc1-arm-1` | `10.0.0.22` | `d0:11:e5:e9:c9:bc` |

The zone hard-codes these addresses, so the reservations are what keep the DHCP lease table agreeing with Git.

### Pointing clients at the resolvers

`ADVANCED → Setup → Internet Setup → Domain Name Server (DNS) Address → Use These DNS Servers`

- Primary `10.0.0.22`
- Secondary `10.0.0.3`

⚠️ **Do not put `1.1.1.1`, `8.8.8.8` or any other public resolver in those fields.** CoreDNS performs external forwarding itself. A public resolver there would answer `dc1.lan` queries with NXDOMAIN — intermittently, depending on which server a client happened to ask — which is harder to diagnose than a clean failure.

⚠️ **And CoreDNS must never forward back to `10.0.0.1`.** The router forwards *to* these resolvers; forwarding external queries back to it would bounce every cache miss between the two. That failure appears only *after* the router change lands, which is why `tests/dns-zone.yml` refuses a LAN address in `coredns_upstreams` and `tests/run-dns-mutations.sh` plants `10.0.0.1` there and requires the refusal.

### Afterwards

Verify through the **ordinary client resolver**, not `@server` queries — that is the path real clients take:

```bash
sudo dscacheutil -flushcache; sudo killall -HUP mDNSResponder   # macOS
dig keel-dev.dc1.lan A
dig github.com A
```

Only once `keel-dev.dc1.lan` resolves LAN-wide should the temporary `keel.dc1.lan` line be removed from any client's `/etc/hosts` — and record what it said first. Removing it before `keel-dev` is live takes away the only working path to the deployment.

## Upgrading CoreDNS

The version and **both** platform checksums move together:

1. Fetch `coredns_<version>_darwin_arm64.tgz.sha256` and `coredns_<version>_linux_amd64.tgz.sha256` from [the releases page](https://github.com/coredns/coredns/releases).
2. Verify each against the real download (`shasum -a 256`), not just the checksum file.
3. Update `coredns_version` and `coredns_checksums` in `roles/coredns/defaults/main.yml` **and** the matching assertion in `tests/dns-zone.yml`, in the same change.

A version bumped without its checksums is a test failure, and on the host `get_url` refuses the download rather than installing unverified bytes. Current pin: **CoreDNS 1.14.7**, verified against both tarballs.

## Tests

```bash
ansible-playbook tests/dns-zone.yml          # zone, pins, forwarding, ACL, rendered output
ansible-playbook tests/dns-services.yml      # launchd and systemd definitions
ansible-playbook tests/dns-inventory.yml     # connection by address, group membership
tests/run-dns-controller-guard.sh            # the management-node guard, executed
tests/run-dns-mutations.sh                   # every guard proved to fail when broken
```

All five are controller-only: they connect to nothing, bind no port and install nothing.
