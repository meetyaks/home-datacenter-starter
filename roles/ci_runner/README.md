# roles/ci_runner

A **self-hosted GitHub Actions runner for `meetyaks/keel`**, in a dedicated
virtual machine on `dc1-x86`, isolated from the production Keel deployment that
shares the same metal.

This role owns one LXD storage pool, one LXD bridge, one virtual machine
(`dc1-ci-1`), the host firewall table that constrains it, and everything
installed inside it.

## Why it exists

GitHub-hosted Actions stopped running for this account. The work is blocked on
a lane that cannot execute, and `dc1-x86` has 16 vCPU and 27 GiB sitting at 0.31
load — so the capacity is already paid for.

The difficulty is *where* that capacity is. `dc1-x86` also runs production Keel,
and `/srv/data/services/keel` holds:

- the **RS256 JWT signing private key** — mints a token for any user, any tenant
- the **credential-vault master key** and the **MFA master key**
- **ten** database and object-store passwords
- **Caddy's internal CA private key** — mints a certificate trusted for
  `keel.dc1.lan`

and a Docker socket that is root on the host.

## The threat model

**The working assumption is arbitrary code execution as the runner user.** Not
"our own code, so it is fine". A CI runner exists to check out a repository and
run what it says; a malicious dependency pulled during a build reaches the same
position without anyone landing a commit, and restricting triggers to trusted
branches changes *who* can start a job, not what the isolation must withstand.

| # | Threat | Control | Where it is enforced |
|---|---|---|---|
| T1 | Job reads production secrets from disk | The VM has **no disk device but its own root** — there is no path to `/srv/data`, because none is provided | `tasks/vm.yml` assertion; `tests/` §3 |
| T2 | Job uses the host Docker socket to become root on the host | The guest runs **its own Docker daemon**; the host socket is never passed in | `tasks/vm.yml`; started hook refuses if production containers are visible |
| T3 | Kernel escape from a shared kernel | It is a **virtual machine (`--vm`)**, not a container: the boundary is the hypervisor, not a namespace | `tasks/vm.yml` |
| T4 | Job reaches production Keel over the network | Host nftables drops the CI subnet to every private range **and to the host's own addresses** | `templates/ci-egress.nft.j2` |
| T5 | Job reaches other LAN or Tailscale hosts | Same policy: `10.0.0.0/24`, `100.64.0.0/10`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16` dropped | same |
| T6 | Job escalates inside the VM and disables its own constraints | The policy is on the **host**, not in the guest; the hooks are **root-owned**; the runner user is **not in sudo** | host firewall; `guest-provision.sh.j2` |
| T7 | One job poisons the next | Workspace wiped before every job; containers, volumes and networks destroyed after every job | the two job hooks |
| T8 | A GitHub credential is stolen from the CI VM | The only credential it holds is its own runner registration. **No PAT, no app key, no deploy key** | see *Ephemeral*, below |
| T9 | A fork's pull request runs on our hardware | The workflow guards on `head.repo.full_name == github.repository` and never uses `pull_request_target` | the Keel repository's workflow |
| T10 | The runner replaces its verified binaries by self-update | `--disableupdate`; upgrades happen by changing `ci_runner_version` | `guest-register.sh.j2` |

### What it does *not* defend against

Stated plainly, because an overstated control is worse than a missing one:

- **A hypervisor escape.** If KVM is broken, the host is lost. Nothing here
  helps; that is the accepted residual risk of putting CI on this host at all.
- **Exfiltration to the public internet.** A job can reach `:80` and `:443`
  anywhere. It has nothing of the lab's to send — that is the point of T1–T6 —
  but this is not a data-loss-prevention boundary.
- **A compromised public dependency running in a job.** It gets a clean VM with
  no lab secrets, which is the mitigation; it is not prevented.

## The egress policy is a subnet deny, not a domain allow-list

nftables cannot match hostnames. The honest statement of policy is:

```
tcp/80 and tcp/443 to the PUBLIC internet          permitted
udp/123 to the PUBLIC internet (time)              permitted
every RFC1918 range, CGNAT and link-local          DENIED
every service on dc1-x86 itself, bar DNS and DHCP  DENIED
anything else from the CI bridge                   DENIED
```

NTP is in the list because a guest with no path to it drifts, and a drifted
clock fails every TLS handshake as an expired or not-yet-valid certificate —
weeks later, as a CI outage that looks nothing like a firewall rule.

A true "GitHub and registries only" list needs an egress proxy doing SNI
inspection. That is a deliberate non-goal, recorded rather than implied by the
phrase "outbound-only".

### It takes two firewalls, and that is not an accident

Docker sets the iptables `FORWARD` policy to **DROP** on this host. In nftables
terms that is a base chain in `ip filter` at priority 0, while `inet ci_egress`
sits at **-10** and is evaluated first. That ordering is what makes this role's
drops authoritative: a drop is terminal, so a denied packet never reaches
Docker's chain at all.

An **accept**, though, is not terminal across tables. It ends evaluation of our
chain and the packet carries on into `ip filter`, where Docker's DROP policy
discards it. The symptom is precise and misleading — the CI VM resolves DNS
(that is INPUT, a different hook), the accept counter climbs into the hundreds,
every drop counter reads zero, and not one connection completes. It cost a
provisioning run to find, because `apt-get update` does not fail, it hangs.

So `/usr/local/sbin/ci-egress-apply` installs both halves: the nftables policy
that decides, and a broad `ACCEPT` for the CI bridge in **DOCKER-USER**, the
extension point Docker documents for exactly this. The breadth is safe because
of the ordering: whatever must be denied was already dropped before that chain
is reached. DOCKER-USER lets the survivors out; it decides nothing.

`ci-egress.service` is `PartOf=docker.service`, because **Docker recreates
DOCKER-USER empty every time it restarts** — silently removing the half without
which CI has no network.

**The input chain is load-bearing and non-obvious.** A packet addressed to one
of the host's own addresses — the bridge address, its LAN address, its Tailscale
address — is delivered through `INPUT` and never reaches the forward chain.
Production Caddy listens on `0.0.0.0:443`, so without that chain the CI VM
reaches production Keel by asking the host it runs on, while a forward-chain-only
policy reads as airtight.

## Ownership boundary

| | owned by | may change |
|---|---|---|
| `ubuntu-vg/ci-lxd`, `/var/lib/ci-lxd` | **roles/ci_runner** | this role only |
| LXD pool `ci-pool`, bridge `lxdbr0` | **roles/ci_runner** | this role only |
| instance `dc1-ci-1` and everything in it | **roles/ci_runner** | this role only |
| nftables table `inet ci_egress` | **roles/ci_runner** | this role only |
| nftables table `ip filter` | **Tailscale** | never this role |
| `/srv/data/services/keel`, Keel's containers | **roles/keel** | never this role |

LXD was installed on `dc1-x86` and never initialised — no pools, no managed
networks, no instances — so this role is its first and only owner. `preflight.yml`
refuses to proceed if it ever finds an instance it did not create.

`inet ci_egress` is a **separate table** on purpose: `dc1-x86` already has an
`ip filter` ruleset belonging to Tailscale, and adding rules to a table someone
else owns is how one of the two gets flushed by the other's next reload.

## Resources

| | | why |
|---|---|---|
| 8 vCPU | of 16 | leaves the host and production half the machine |
| 14 GiB | of 27 | an LXD VM allocates memory at boot, so over-committing is felt by production, not by CI |
| 180 GiB LV | of 254.68 GiB free | **not 250**: that would have left 4.68 GiB in `ubuntu-vg` — no room to ever extend `/` or `/srv/data`, and no LVM snapshot headroom, on a host running production |

## Operating it

```bash
# provision (repeatable, unattended, no credential involved)
ansible-playbook playbooks/ci-runner.yml --ask-become-pass

# dry run
ansible-playbook playbooks/ci-runner.yml --check --diff --ask-become-pass

# register — needs a one-time token you generate in the repository settings.
# Never pass it with -e (argv and shell history; the role refuses it): export it
# from a hidden read, or leave it unset and answer the hidden prompt.
read -rs CI_RUNNER_TOKEN && export CI_RUNNER_TOKEN
ansible-playbook playbooks/ci-runner.yml --tags register --ask-become-pass
unset CI_RUNNER_TOKEN

# remove — needs a one-time removal token from the runner's Remove button
read -rs CI_RUNNER_REMOVAL_TOKEN && export CI_RUNNER_REMOVAL_TOKEN
ansible-playbook playbooks/ci-runner.yml --tags unregister --ask-become-pass
unset CI_RUNNER_REMOVAL_TOKEN

# destroy and rebuild the VM (refuses while a runner is registered)
ansible-playbook playbooks/ci-runner.yml --tags rebuild \
  --ask-become-pass -e ci_rebuild_confirm=dc1-ci-1
```

`playbooks/ci-runner.yml` is deliberately **not** part of `site.yml`. An
ordinary site run manages production Keel; it must not also build or alter a
machine that runs untrusted code. Registration, removal and rebuild are
`never`-tagged, so none of them can happen as a side effect.

### The token never touches disk

A registration token is single-use and expires within the hour. It is passed
for one run, delivered to the guest **on stdin**, and the one task that carries
it is `no_log`. It never appears in a file, in an `lxc exec` argument vector, in
`ps` on `dc1-x86`, in shell history, or in Ansible's recorded task arguments.
The single place it becomes an argument is `config.sh --token` inside the VM,
for the seconds that call runs — GitHub's runner offers no stdin form, and that
residue is inside the machine already entitled to use it.

### Administration is `lxc exec`, not SSH

The CI VM runs **no sshd**: no inbound listener, no host key to rotate, no
account with remote login. It is reached from the host with `lxc exec`, which
already requires root on `dc1-x86` — privilege that could read the VM's disk
directly, so it grants nothing new.

```bash
sudo lxc exec dc1-ci-1 -- journalctl -u 'actions.runner.*' -n 50
sudo lxc exec dc1-ci-1 -- ls /var/log/ci-runner
```

## Ephemeral registration is OFF, deliberately

`--ephemeral` de-registers the runner after every job, which is genuinely
stronger isolation between jobs. But a runner that de-registers can only come
back by configuring itself again, and registration tokens are single-use.
Automating that means storing, **inside the least-trusted machine in the lab**,
a credential that can mint them — a PAT or app key that in practice also carries
repository read.

That is a worse trade than the one it buys: a real GitHub credential parked
where arbitrary CI code runs, to defend against one job poisoning the next on a
single-committer private repository. So isolation between jobs is enforced by
the hooks instead — workspace wiped before, every container, volume and network
destroyed after — and `ci_runner_ephemeral` stays `false`.

Set it `true` if you ever mint short-lived tokens out of band on the controller.
The path is implemented and covered by a test that renders both variants and
proves they differ; it simply is not the default.

## Upgrading the runner

`--disableupdate` means the runner never replaces its own binaries, so upgrades
are a change to this role:

```bash
gh api repos/actions/runner/releases/latest --jq .tag_name
gh api repos/actions/runner/releases/tags/v<version> --jq .body \
  | grep -oE 'BEGIN SHA linux-x64 -->[0-9a-f]{64}'
```

Put both in `defaults/main.yml` and re-run. The provisioning script unpacks a
new version over the old one when the stamp file disagrees, and the service
picks it up on its next restart.

⚠️ **Copy the digest, never reconstruct it.** The first pin in this role was a
plausible-looking value that was never copied from anywhere: provisioning
failed with a computed hash whose first sixteen bytes matched and whose tail did
not, which is not what a real mismatch looks like. A checksum that is *about*
right fails every honest download and catches nothing. The test suite now
compares the pin against the published release notes.

GitHub eventually refuses runners below a minimum version, so an
un-upgraded runner stops being able to register rather than silently running old
code.

## Logs

Per-job diagnostics are preserved under `/var/log/ci-runner/<timestamp>-<run>/`:
a job summary, the container inventory, and the logs of anything the job left
running — the usual reason a compose-based integration test fails in a way the
step output does not explain. Directories older than 14 days are removed.

Logs are passed through a redactor for the shapes that leak most often
(`gh*_` tokens, AWS key ids, JWTs, `password=`, `secret=`, `token=`, PEM private
key headers). **That is a reduction, not a guarantee** — the runner masks values
it was given as secrets, but these are container output it never saw. The real
control is that this VM holds no production credential to leak.

## Verification

```bash
tests/run-ci-runner-isolation.sh                    # 39 static checks
CI_RUNNER_LIVE=dc1-x86 tests/run-ci-runner-isolation.sh   # + probes inside the VM
```

The static half proves the role cannot build an unsafe machine. The live half
runs the probes from inside the VM, because *a policy that was once applied* and
*a policy that is in force* are different claims.

The same probes run again before **every job**, in the started hook: if
`/srv/data` becomes visible, if a production container appears, or if the host
answers on 443 or 5432, the job fails before the first step instead of quietly
succeeding with a path to production.

## A second instance: TrueWealth's runner (dc1-ci-tw-1)

`playbooks/ci-runner-truewealth.yml` builds a **second, independent** runner VM
from this role for `meetyaks/truewealth`. Every value that differs from
dc1-ci-1 lives in `playbooks/vars/ci-runner-truewealth.yml` — play vars, not
inventory, so `playbooks/ci-runner.yml` renders and behaves exactly as before
(`tests/run-ci-runner-truewealth.sh` proves Keel's artefacts are
byte-identical to 934ca20).

**Why a VM and not a second runner in dc1-ci-1.** Keel's completed hook removes
every container and volume on its daemon after each job; a TrueWealth job on
that daemon would be destroyed by Keel's cleanup, and vice versa. A second
user or work directory does not change that. The boundary is the hypervisor.

| | dc1-ci-1 (Keel) | dc1-ci-tw-1 (TrueWealth) |
|---|---|---|
| scope | `meetyaks/keel` | `meetyaks/truewealth` |
| labels | `self-hosted,linux,x64,keel-ci` | `self-hosted,linux,x64,local-dc-ci` |
| vCPU / memory | 8 / 14 GiB | **4 / 6 GiB** (proposed) |
| logical volume | `ubuntu-vg/ci-lxd` 180g | `ubuntu-vg/ci-tw-lxd` **50g** (+20g VG reserve kept) |
| root disk | 170 GiB | 45 GiB |
| LXD pool / bridge | `ci-pool` / `lxdbr0` | `ci-tw-pool` / `citwbr0` |
| subnet | 10.71.0.0/24 | 10.72.0.0/24 |
| egress table / unit | `inet ci_egress` / `ci-egress` | `inet ci_egress_tw` / `ci-egress-tw` (+ `ci-egress-tw-early`) |
| denies | LAN /24, CGNAT, 172.16/12, 192.168/16, link-local | **all of 10/8** (LAN and dc1-ci-1), CGNAT, 172.16/12, 192.168/16, link-local |
| sibling isolation | off (unchanged) | on: no NEW connection into `citwbr0`; DNS only from its own gateway |
| hardening (`ci_isolation_hardening`) | off (unchanged) | on: rules keyed on the interface (spoofed sources refused), IPv6 dropped both ways, existing bridge verified, policy loaded before LXD and kept when Docker stops |

Isolation contract it meets: repository-scoped registration; its own kernel,
Docker daemon, disk, bridge, egress table and runner state; the role's
job hooks clean only this VM; no host device, production mount, Docker socket,
secret, SSH key or route to production/administration services; one job at a
time (one non-ephemeral registration); outbound 80/443 (+NTP) to the public
internet only, over IPv4 only.

`tests/run-ci-runner-truewealth.sh` section 10 sends real packets through both
rendered policies in network namespaces (with IPv6 deliberately present on the
bridge). For dc1-ci-tw-1 every probe is refused except 443 out, its own
resolver and DHCP. **Recorded finding for Keel's unchanged policy:** IPv6 to
host services (if the bridge ever carries IPv6) and one-way traffic from a
spoofed source address to the LAN or the host pass it; enabling
`ci_isolation_hardening` for dc1-ci-1 is a separate, reviewed change.

**Persistent runner state.** The runner is not ephemeral: a job that gains
root in the VM (Docker access is enough) can leave state that affects later
jobs on it. The job hooks remove containers, volumes and the workspace, not
arbitrary files or processes a job planted. This matters for release builds;
see the TrueWealth activation runbook (docs/activation.md in that repository).

### Capacity — measure it live before provisioning (read-only, from dc1-arm-1)

The figures above are **proposals**. The host facts in this repository (16
vCPU, 27 GiB, `ubuntu-vg` 74.68 GiB free after dc1-ci-1) were recorded when
dc1-ci-1 was built and are **not re-verified**. The preflight playbook reads
the live host without changing it and decides, failing closed on anything it
cannot read:

```bash
ansible-playbook playbooks/ci-runner-truewealth-preflight.yml --ask-become-pass
```

It checks, on live values: CPU and memory after every other instance's
**effective** limits (profile-inherited ones included; an instance with no
limit is UNKNOWN, because it could take the host); production containers'
observed memory ×1.5 + 2 GiB host overhead inside what VM limits leave; VG free
≥ 50g + 20g reserve; the volume, pool, bridge, instance and nft table names
unused; the subnet 10.72.0.0/24 absent from every host address, every route in
every table (Tailscale's table 52 included), every LXD network and the
recorded LAN; Docker's FORWARD policy DROP; the LXD unit present. The facts
and the plan are kept (0700) under `~/ci-preflight/dc1-ci-tw-1/` on the
controller. If it reports NOT READY, lower `ci_vm_memory` / `ci_lv_size` (not
the reserves) or free capacity first. The play also needs the host's LAN IPv4
for the isolation probes: read it from the collected `ip4_addr` section.

### Provisioning and registration (each step a separate authorisation)

```bash
# 0. read-only preflight (above); stop unless it PASSES
ansible-playbook playbooks/ci-runner-truewealth-preflight.yml --ask-become-pass
# 1. dry run (no VM is created; preflight capacity runs on live values)
ansible-playbook playbooks/ci-runner-truewealth.yml --check --diff \
  --ask-become-pass -e ci_tw_host_lan_ip=<dc1-x86 LAN IPv4>
# 2. provision the VM, volume, bridge, egress policy and runner binaries
ansible-playbook playbooks/ci-runner-truewealth.yml \
  --ask-become-pass -e ci_tw_host_lan_ip=<…>
# 3. prove isolation from inside the VM (probes run again before every job)
CI_RUNNER_LIVE=dc1-x86 CI_RUNNER_VM=dc1-ci-tw-1 tests/run-ci-runner-isolation.sh
# 4. register: mint a ONE-TIME token in
#    https://github.com/meetyaks/truewealth/settings/actions/runners/new
#    (expires in 1 h; never paste it into chat, a file or a command line),
#    then immediately, on the controller:
read -rs CI_RUNNER_TOKEN && export CI_RUNNER_TOKEN      # or skip: hidden prompt
ansible-playbook playbooks/ci-runner-truewealth.yml --tags register \
  --ask-become-pass -e ci_tw_host_lan_ip=<…>
unset CI_RUNNER_TOKEN
# 5. confirm: runner "dc1-ci-tw-1", labels self-hosted,linux,x64,local-dc-ci,
#    status Idle, in the TrueWealth repository ONLY:
gh api repos/meetyaks/truewealth/actions/runners --jq '.runners[] | {name,status,labels:[.labels[].name]}'
gh api repos/meetyaks/keel/actions/runners --jq '.runners[].name'   # unchanged: dc1-ci-1
```

Where the token travels (tasks/token-input.yml, tasks/register.yml): the
controller's environment or a hidden prompt (`-e ci_runner_token` is refused)
→ a module argument on a task that forces pipelining (a runtime probe refuses
the run if modules would be written to the host's disk) → stdin of
`lxc exec -T` → `ACTIONS_RUNNER_INPUT_TOKEN` for the one `config.sh` call
(never `--token`). `no_log` hides Ansible's output; it does not hide process
arguments, which is why the value is never one. Section 9 of the test suite
samples every process's argv and Ansible's temp files during synthetic
registrations to prove it.

Removal: `--tags unregister` with `CI_RUNNER_REMOVAL_TOKEN` exported the same way (or the prompt); rebuild:
`--tags rebuild -e ci_rebuild_confirm=dc1-ci-tw-1`.

### Old checkouts and the second VM

Merging this role into `main` does **not** update any existing checkout or
worktree on the administration plane: a checkout at #2 (`934ca20`) or older
stays at that code until it is deliberately moved. Once `dc1-ci-tw-1` exists,
every **provisioning** run of Keel's runner (`playbooks/ci-runner.yml` without
`--tags`) must use a revision that recognises the marked sibling — `455c088`
or a later `main` — because the preflight of earlier revisions refuses any
other LXD instance on the host. Keel's `--tags register|unregister|rebuild`
do not run preflight and are unaffected. Record the SHA of every
administration run (below).

### Shared-host checks before and after provisioning (read-only)

Record the infrastructure revision of every administration operation. On
dc1-arm-1, in the worktree used:

```bash
INFRA_SHA=$(git rev-parse HEAD); [ -z "$(git status --porcelain)" ] && echo "infrastructure $INFRA_SHA (clean)"
```

Put `$INFRA_SHA` in each log's name and first line. Then take the same
snapshot on dc1-x86 BEFORE provisioning and AFTER it (and after
registration), with `PHASE=before|after-provision|after-register`:

```bash
PHASE=before; SHA=PASTE_THE_40_CHARACTER_INFRA_SHA
if [ ${#SHA} -ne 40 ]; then echo "set SHA to the infrastructure commit first"; else
D=~/ci-shared-check/$PHASE-$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$D/stable" "$D/volatile"; chmod -R go-rwx ~/ci-shared-check
echo "$SHA" > "$D/INFRA_SHA"
# STABLE — must be byte-identical before and after (no counters, no timings)
sudo nft -s list table inet ci_egress                            > "$D/stable/keel-nft.txt"
sudo iptables-save   | sed -E 's/\[[0-9]+:[0-9]+\]//' | grep -v '^#' | grep -v -- 'citwbr0' > "$D/stable/iptables.txt"
sudo iptables-save -t nat | sed -E 's/\[[0-9]+:[0-9]+\]//' | grep -v '^#' | grep -v -- 'citwbr0' > "$D/stable/iptables-nat.txt"
sudo nft -s list ruleset | grep -v '^# Warning' \
  | awk '/^table (ip|ip6) (filter|nat|mangle|raw|security) \{|^table inet (ci_egress|ci_egress_tw|lxd) \{/{s=1} s&&/^\}/{s=0; next} !s' > "$D/stable/nft-other.txt"
sudo nft -s list table inet lxd 2>/dev/null | grep -- 'lxdbr0'  > "$D/stable/lxd-lxdbr0.txt"
for u in ci-egress docker snap.lxd.daemon caddy; do echo "$u $(systemctl is-enabled $u 2>&1) $(systemctl is-active $u 2>&1)"; done > "$D/stable/units.txt"
sudo lxc config show dc1-ci-1 --expanded | grep -vE '^\s*volatile\.' > "$D/stable/dc1-ci-1.txt"
sudo lxc network show lxdbr0                                     > "$D/stable/lxdbr0.txt"
docker ps -a --filter name=keel-lab --format '{{.Names}} {{.Image}} {{.Label "com.docker.compose.project"}}' | sort > "$D/stable/keel-containers.txt"
for c in $(docker ps -a --filter name=keel-lab --format '{{.Names}}' | sort); do
  docker inspect --format '{{.Name}} restarts={{.RestartCount}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' "$c"
done > "$D/stable/keel-state.txt"
# Keel's own health contract (roles/keel/tasks/verify.yml): all 200
for u in http://127.0.0.1:3000/healthz http://127.0.0.1:3000/readyz http://127.0.0.1:8080/ \
         https://keel.dc1.lan/ https://keel.dc1.lan/__keel/healthz; do
  echo "$u $(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$u")"
done > "$D/stable/keel-health.txt"
# VOLATILE — recorded for context, expected to differ
free -m > "$D/volatile/memory.txt"; sudo vgs ubuntu-vg > "$D/volatile/vgs.txt"; sudo lvs ubuntu-vg > "$D/volatile/lvs.txt"
docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}' > "$D/volatile/docker-stats.txt"
sudo nft list table inet ci_egress > "$D/volatile/keel-nft-counters.txt"; sudo lxc list --format csv -c ns4 > "$D/volatile/lxc-list.txt"
sudo iptables -S DOCKER-USER > "$D/volatile/docker-user.txt"; echo "snapshot: $D"
fi
```

Compare: `diff -r ~/ci-shared-check/<before>/stable ~/ci-shared-check/<after>/stable`
must print **nothing**. On dc1-arm-1, also compare
`gh api repos/meetyaks/keel/actions/runners --jq '.runners[] | {name,status}'`
(`dc1-ci-1` must stay `online`; `busy` may change with jobs).

**Expected to change (not regressions):** nft and iptables counters (hence
`-s` and the stripped `[n:m]`); `docker stats`, container uptime; free/available
memory (lower by what dc1-ci-tw-1 uses); VG free −50 GiB and the new
`ci-tw-lxd` LV; new objects: bridge `citwbr0`, table `inet ci_egress_tw`,
`DOCKER-USER` rules `-i citwbr0`/`-o citwbr0` (exactly once each), units
`ci-egress-tw` / `ci-egress-tw-early`, LXD's own `citwbr0` rules, pool
`ci-tw-pool`, instance `dc1-ci-tw-1`; the Keel runner's `busy` flag.

**Regressions (stop before registration):** any line of `stable/` differing —
Keel's table, any non-`citwbr0` iptables rule (Docker's, Tailscale's, Keel's
`lxdbr0` rules), any other nft table, LXD's `lxdbr0` rules, a unit's enabled
or active state, `dc1-ci-1`'s configuration or limits, `lxdbr0`, the Keel
container set, images, a **higher restart count** or non-running/unhealthy
state, or any Keel health endpoint not `200`; `dc1-ci-1` offline; and in
`volatile/docker-user.txt` a `citwbr0` rule present twice or a `lxdbr0` rule
missing.

`tests/run-ci-runner-truewealth.sh` §12 loads both rendered policies and both
appliers together in network namespaces (both orders, re-application) and
checks exactly these invariants with real packets. What it proves is limited
to the policies **rendered from the tested revision** against a **simulated**
host: Docker's and Tailscale's chains are stand-ins (no dockerd, tailscaled
or LXD runs), so their own later rule rewrites are not exercised. It does
**not** prove what dc1-x86 is running: that Keel's policy renders the same
at an earlier revision says nothing about the files, tables or rules actually
loaded there. Live equality is established only by the before/after
snapshots above, taken on the host.
