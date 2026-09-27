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

# register — needs a one-time token you generate in the repository settings
ansible-playbook playbooks/ci-runner.yml --tags register \
  --ask-become-pass -e ci_runner_token=<token>

# remove — needs a one-time removal token from the runner's Remove button
ansible-playbook playbooks/ci-runner.yml --tags unregister \
  --ask-become-pass -e ci_runner_removal_token=<token>

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
