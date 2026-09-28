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
# 2. provision the VM, volume, bridge, egress policy and runner binaries — ONLY through
#    "Activation from dc1-arm-1" below: exact-commit checkout, verified before snapshot,
#    explicit confirmation, then tools/ci-activation/provision-truewealth.sh <commit>
# 3. after snapshot, compare and live checks from inside the VM — the same runbook, step 5
#    (tools/ci-activation/hostcheck.sh; probes run again before every job). The generic
#    `CI_RUNNER_LIVE=… tests/run-ci-runner-isolation.sh` probes Keel's target set and needs
#    passwordless sudo, so it is not the acceptance check for dc1-ci-tw-1.
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

### Activation from dc1-arm-1 (operator runbook)

Everything comes from **this repository at one exact commit**, checked out
fresh on dc1-arm-1. Nothing is copied from another machine, no checksum
manifest is carried by hand, and the same full commit SHA `C` is recorded by
every step, in every log and snapshot. Use the commit that carries
`tools/ci-activation/`: PR #3's head, or the merge commit on `main` once it
is merged. Its provisioning implementation must equal `455c088`, the
revision whose live check mode was run (`ok=42 changed=5 unreachable=0
failed=0`). The wrapper refuses any other implementation.

Each numbered step is a separate authorisation. Paste the steps into Terminal
on **dc1-arm-1** (zsh or bash). Passwords are only ever typed at prompts.

```bash
# 0. once per Terminal window
C=<the 40-character commit>; W="$HOME/preflight/hds-$C"; K="$HOME/.ssh/home_datacenter_admin"; H=labadmin@dc1-x86
S=(-o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o IdentitiesOnly=yes -i "$K")

# 1. exact-commit checkout in a NEW directory (existing checkouts are not touched)
git clone --quiet --no-checkout https://github.com/meetyaks/home-datacenter-starter.git "$W" \
  && git -C "$W" fetch --quiet origin "$C" && git -C "$W" checkout --quiet --detach "$C" \
  && [ "$(git -C "$W" rev-parse HEAD)" = "$C" ] \
  && [ -z "$(git -C "$W" status --porcelain --untracked-files=all)" ] && echo "checkout $C: exact and clean"

# 2. stage this checkout's hostcheck.sh on dc1-x86 (files only); the two hashes must be equal
ssh "${S[@]}" $H 'mkdir -p ~/ci-shared-check && chmod 700 ~/ci-shared-check' \
  && scp "${S[@]}" "$W/tools/ci-activation/hostcheck.sh" $H:ci-shared-check/hostcheck.sh \
  && ssh "${S[@]}" $H 'sha256sum ~/ci-shared-check/hostcheck.sh' && shasum -a 256 "$W/tools/ci-activation/hostcheck.sh"

# 3. before snapshot (sudo on dc1-x86 asks for labadmin's password)
ssh -t "${S[@]}" $H "bash ~/ci-shared-check/hostcheck.sh snapshot before $C"
#    required: exit 0 and "RESULT: OK — completion record …/COMPLETE"

# 4. provision (within 120 minutes of step 3): confirmation, then labadmin's BECOME password
/bin/bash "$W/tools/ci-activation/provision-truewealth.sh" "$C"
#    required: recap failed=0 unreachable=0 and "wrapper exits 0"

# 5. after snapshot, comparison, live checks
ssh -t "${S[@]}" $H "bash ~/ci-shared-check/hostcheck.sh snapshot after-provision $C"   # RESULT: OK — completion record
ssh -t "${S[@]}" $H "bash ~/ci-shared-check/hostcheck.sh compare $C"                     # RESULT: OK — no regression
ssh -t "${S[@]}" $H "bash ~/ci-shared-check/hostcheck.sh probe $C"; echo "probe exit: $?"  # RESULT: OK, exit 0
gh api repos/meetyaks/keel/actions/runners --jq '.runners[] | {name,status}'   # dc1-ci-1 online (needs gh)
```

If `$W` already exists from an earlier attempt, reuse it. The wrapper
re-verifies it, and a directory that is not exactly `C` and clean is refused.
Registration (step 4 of "Provisioning and registration" above) is **not** part
of this runbook and needs its own authorisation and a one-time token.

**What `provision-truewealth.sh <C>` checks before it changes anything:**
- the controller: macOS, account `dc1-arm-1`, the address 10.0.0.22, and a terminal;
- no token and no `ANSIBLE_*` override in the environment;
- the checkout it lives in:
  - HEAD is exactly `C`;
  - the tree is clean, untracked files included, and holds no vault file;
  - `C` descends from `455c088`;
  - `git diff 455c088 C` is empty over everything the play loads: `ansible.cfg`, `requirements.yml`, `inventory/`, the TrueWealth playbook and vars, and `roles/ci_runner` (only its README may differ);
- SSH to `labadmin@dc1-x86` with the inventory key and an **already-trusted** host key. Ansible gets the same `StrictHostKeyChecking=yes`, `UpdateHostKeys=no` and `IdentitiesOnly=yes`;
- the staged `~/ci-shared-check/hostcheck.sh` is byte-identical to the checkout's;
- `hostcheck.sh verify before C 120` accepts the newest before snapshot's completion record;
- you type `PROVISION dc1-ci-tw-1`.

It then runs `ansible-playbook playbooks/ci-runner-truewealth.yml --limit
dc1-x86 --diff --ask-become-pass -e ci_tw_host_lan_ip=10.0.0.3` from the
checkout (no `--check`, no registration). The log goes to
`~/ci-preflight/provisioning-apply-C-<UTC>.log` (0600). The wrapper exits with
Ansible's status, or tee's if Ansible succeeded.

**`tools/ci-activation/hostcheck.sh`** runs on dc1-x86 as labadmin. It only
reads the host, and writes nothing outside `~/ci-shared-check` (0700).

- **`snapshot`** is fail-closed:
  - each required collector's own exit status and output structure are checked, and stderr is kept in `errors/`;
  - it requires Keel's DOCKER-USER rules each exactly once, readable unit states with docker, LXD and Caddy active, every Keel container to satisfy the **container contract** (below), and Keel's five health endpoints (below) at 200;
  - only then does it write `COMPLETE` (format `hostcheck-snapshot v3`), which binds the phase, `C`, the snapshot identity, the creation time and the SHA-256 of all 22 required evidence files, including the deployed Compose file and the inventory derived from it, with an end count;
  - otherwise it prints `RESULT: INCOMPLETE`, exits 1 and writes no record.
- **`verify`** checks the **newest** snapshot of a phase, and re-applies the container contract to its bound evidence. An older valid snapshot is never used instead.
- **`compare`** verifies both records, requires `stable/` to be byte-identical and each `citwbr0` and `lxdbr0` DOCKER-USER rule exactly once. It exits 1 on anything else.
- **`probe`** judges three sections separately:
  - **infrastructure readiness:** the instance is a VM and answers; its expanded configuration has no host-path disk, passthrough device or raw override (configuration evidence only); the live `inet ci_egress_tw` equals the reviewed rendering; the DOCKER-USER rules, the units and `citwbr0`;
  - **Keel preservation:** Keel's table, unit and DOCKER-USER rules, `dc1-ci-1`, the five health endpoints, and the containers under the same container contract;
  - **TrueWealth isolation coverage:** positive controls, denied targets, IPv6 and guest contents.

**Keel container contract** — the same in `snapshot`, `verify`, `compare` (both records) and `probe`:
- **The expected inventory comes from Keel's own deployment definition, not from a list here.** `roles/keel` installs `infra/lab/compose.lab.yml` of the built Keel commit, as a plain copy, at `/srv/data/services/keel/compose.lab.yml`. `hostcheck.sh` reads that file and accepts it only if its SHA-256 equals the reviewed file at the pinned `keel_commit` (`9b0d36f0…`, `73a4ac34…`). Every `container_name` under `services:` is then an expected container, required **exactly once**: today postgres, nats, temporal, minio, minio-bucket, bootstrap, gateway, runtime-worker and web.
  - If the file is unreadable or differs from the reviewed definition, the snapshot is INCOMPLETE and the probe reports INCONCLUSIVE or FAIL.
  - The copy and the derived `stable/keel-inventory.txt` are bound by the record. `verify` re-derives the inventory and re-checks the hash.
  - `tests/ci-activation` binds the commit, path and copy task to `roles/keel`. Where the Keel source is available, it re-derives the hash and the inventory from `git show <keel_commit>:infra/lab/compose.lab.yml`.
- **One-shot jobs** are exactly `bootstrap` and `minio-bucket`: the set `roles/keel/tasks/verify.yml` exempts from "running". In the bound Compose file, they are exactly the services with `restart: 'no'`. They run one command, exit, and gate the gateway through `service_completed_successfully`. If the two sources disagree, the inventory is refused.
  - Each must have **completed successfully**: `status=exited`, `exit=0`, `oom=false`.
  - A nonzero exit, an OOM kill, or a `created` or `running` one-shot blocks.
- **Every other expected container is long-running**: it must be `running`, and `healthy` where it has a health check.
  - An exited long-running service blocks, even with exit 0.
  - So does `restarting`, or a health state of `starting` or `unhealthy`.
- **Also blocking, even when all five HTTP endpoints return 200:**
  - a missing expected container (a missing worker, postgres or web, for example);
  - an expected container listed twice;
  - a `keel-lab-*` container that is not in the inventory.
- **Also blocking:** a failed `docker inspect` (INCONCLUSIVE in the probe) and any unrecognised state line.
- **Evidence:** each container's line is kept in the snapshot's `stable/keel-state.txt` as `/<name> restarts=N status=S exit=E oom=B health=H`, and in the probe directory's `keel-state.txt`. It is hash-bound by the record, and compared byte-for-byte before and after, so a one-shot rerun or a changed exit code shows as a regression.
- HTTP health alone never satisfies the contract.
- **Keeping the contract honest:** `tests/ci-activation` checks that the one-shot list equals `verify.yml`'s, and that the inventory binding matches `roles/keel`.
  - Changing the one-shot list needs a matching change to Keel's Compose file and to `verify.yml`.
  - Moving `keel_commit` needs the new file's hash in `hostcheck.sh`. The drift test fails until it is updated.

**Probe verdicts.**
- **PASS for a denied target** is an *observed* outcome: the guest got no connection, and the host reached the same address and port. Drop-counter changes are printed as supporting evidence only.
- **INCONCLUSIVE:** a failed query, a missing tool or address, or a target that does not answer even from the host. It is never a pass.
- **EXPECTED_UNAVAILABLE:** only for PostgreSQL on 10.0.0.3:5432, which is documented absent because Keel binds it to 127.0.0.1. It is not evidence.
- **Exit codes:** 0 OK, 1 FAIL, 2 INCONCLUSIVE, 3 evidence-log failure.
- **Not covered live:** spoofed-source traffic and unsolicited inbound. Those rest on the namespace test (§12 below).

**Every denied target must leave the guest through its external interface.** The probe reads the guest's default route (its external interface, `enp5s0`) and runs `ip -4 route get` in the guest for each destination before probing it.
- **Rejected as INCONCLUSIVE, never evidence:**
  - a destination local to the guest (for example `local 172.17.0.1 dev lo`: the guest's own `docker0` holds the host's docker0 address);
  - one routed via another guest interface (an overlapping network);
  - one with no route;
  - a failed route query.
- **Recorded** with each result: the guest's route, the host control and the guest outcome.

**Host Docker bridge target: discovered, not assumed.** The probe no longer uses a fixed `172.17.0.1`. It reads the host's bridge networks from Docker's metadata (`docker network ls --filter driver=bridge`, `docker network inspect`; read-only), falling back to the bridge interface's own address when IPAM has no gateway. It then tries candidates in order, default bridge first:
1. The address must belong to the host.
2. The guest must route it through its external interface.
3. It must answer a host-side control on `:443`.

The first address that passes all three is probed, and every candidate's identity, route, control and disposition is recorded. With none, this coverage stays INCONCLUSIVE. Nothing is created: no listener, no address and no Docker or firewall change.

**Re-probing an existing deployment with a corrected checker.** The provisioning revision and its snapshots stay the record of the deployment: the before and after snapshots, and `compare`, taken by the checker staged at that revision. A later checker correction does **not** create a new before-provisioning baseline, and does not re-run `compare` or `provision`. It only re-runs `probe`, recording itself separately:
```bash
# on dc1-arm-1: an exact, clean checkout of the CHECKER commit K (steps 0-1 above, with C=K and W=$HOME/preflight/hds-$K)
K=<checker commit>; D=<deployment commit, e.g. 1b7eed2d2a8c41d2b4ce6b84a815aaff8f1f270b>
scp "${S[@]}" "$HOME/preflight/hds-$K/tools/ci-activation/hostcheck.sh" $H:ci-shared-check/hostcheck-$K.sh \
  && ssh "${S[@]}" $H "sha256sum ~/ci-shared-check/hostcheck-$K.sh" && shasum -a 256 "$HOME/preflight/hds-$K/tools/ci-activation/hostcheck.sh"
ssh -t "${S[@]}" $H "bash ~/ci-shared-check/hostcheck-$K.sh probe $D $K"; echo "probe exit: $?"
```
- The staged `hostcheck.sh` from the deployment revision stays in place, next to `hostcheck-$K.sh`.
- The new `probe-<UTC>/` records `INFRA_SHA` = `D` (the deployment), and `CHECKER` = the checker's own SHA-256, commit `K` and path.
- Earlier probe directories and all snapshots are left as they are.

**Stop at the first of these, and report:**
- any `STOP:` line;
- a snapshot `RESULT: INCOMPLETE`;
- the wrapper exiting nonzero;
- `compare` or `probe` not ending in `RESULT: OK` with exit 0;
- `dc1-ci-1` offline;
- anything unexpected in production.

**On failure, change nothing:**
- no re-run, rebuild, unregister, `lxc delete`, `lvremove`, `nft delete`, `iptables -D`, `systemctl stop|disable` or rollback of the shared host;
- take `hostcheck.sh snapshot after-failure $C`. It may itself be INCOMPLETE, which is still evidence; do not retry it;
- run `probe` if the VM exists;
- keep the provisioning log and every `~/ci-shared-check/*` directory;
- report the failing step, the recap line and the `RESULT`, `FAIL` and `STOP` lines.

Any remediation is a separate, reviewed change.

`tests/run-ci-runner-truewealth.sh` §13 tests these tools locally with
stand-ins. It covers:
- fail-closed snapshots and damaged or partial records;
- the gate refusing a fresh snapshot with five HTTP 200s but no record;
- failed queries never becoming PASS;
- log failure;
- checkout verification against real clones: wrong SHA, untracked file, vault file, changed allocation, changed policy template, unrelated history;
- the wrapper's exit status.

It also loads the freshly rendered policy into a real nft to keep the probe's
expected table equal to it.

**Shared-host evidence.** The snapshot's `stable/` files hold:
- Keel's `inet ci_egress` (stateless);
- `iptables-save` filter and nat, with counters and `citwbr0` lines removed;
- every other nft table;
- LXD's `lxdbr0` rules;
- the units `ci-egress`, `docker`, `snap.lxd.daemon` and `caddy`;
- `dc1-ci-1`'s expanded configuration without `volatile.*`;
- `lxdbr0`;
- the Keel containers, with restart count, state, exit code, OOM flag and health (one-shots included);
- Keel's health contract from `roles/keel/tasks/verify.yml`:
  - `http://127.0.0.1:3000/healthz`;
  - `http://127.0.0.1:3000/readyz`;
  - `http://127.0.0.1:8080/`;
  - `https://keel.dc1.lan/`;
  - `https://keel.dc1.lan/__keel/healthz`.

Memory, VG, `docker stats`, counters and `lxc list` are volatile context. Also
compare `gh api repos/meetyaks/keel/actions/runners --jq '.runners[] | {name,status}'`:
`dc1-ci-1` must stay `online`, and `busy` may change with jobs.

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
