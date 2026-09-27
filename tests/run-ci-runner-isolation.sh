#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# THE CI RUNNER CANNOT REACH PRODUCTION.
#
#   tests/run-ci-runner-isolation.sh              static, controller-only
#   CI_RUNNER_LIVE=dc1-x86 tests/run-ci-runner-isolation.sh   + the real VM
#
# ═══ WHAT THIS IS ABOUT ══════════════════════════════════════════════════════
#
# A self-hosted runner executes repository code, on the machine that holds every
# secret in the lab: the RS256 JWT signing key, the credential-vault and MFA
# master keys, ten database and object-store passwords, and Caddy's internal CA
# private key — which could mint a certificate trusted for keel.dc1.lan.
#
# So "the runner is isolated" is not a design intention, it is a set of
# properties that have to keep being true. Every check below fails closed: it
# asserts the presence of a control, never the absence of an accident.
#
# The STATIC half runs anywhere and proves the role cannot build an unsafe
# machine. The LIVE half runs the probes from inside the VM, because a policy
# that was once applied and a policy that is in force are different claims.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.."

R="${TMPDIR:-/tmp}/ci-runner-isolation.$$"
mkdir -p "$R"
trap 'rm -rf "$R"' EXIT

pass=0
fail=0
ok()  { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }
skip() { printf '  \033[33mskip\033[0m  %s\n         %s\n' "$1" "$2"; }

ROLE=roles/ci_runner

# ── 1. Every entry point parses ────────────────────────────────────────────
#
# ⚠️ NOT A PIPELINE. `ansible-playbook … | tail` returns tail's status, so a
# failing parse reads as rc=0. That mistake has already made one check in this
# repository certify a play it never successfully ran.
echo "── 1. every entry point parses ──"
if ansible-playbook --syntax-check tests/ci-runner-parse.yml > "$R/parse.log" 2>&1; then
  ok "register, unregister, rebuild and main all parse"
else
  bad "every task file parses" "$(tail -3 "$R/parse.log")"
fi

if ansible-playbook --syntax-check playbooks/ci-runner.yml > "$R/pb.log" 2>&1; then
  ok "playbooks/ci-runner.yml parses"
else
  bad "playbooks/ci-runner.yml parses" "$(tail -3 "$R/pb.log")"
fi

# ── 2. The templates render, and render to valid shell ─────────────────────
echo
echo "── 2. the guest scripts render ──"
if ansible-playbook tests/ci-runner-render.yml -e render_dir="$R" > "$R/render.log" 2>&1; then
  ok "all templates render and pass bash -n"
else
  bad "all templates render" "$(tail -5 "$R/render.log")"
fi

# ── 3. No path from the guest to the host ──────────────────────────────────
echo
echo "── 3. the VM is built with no path to the host ──"

# The assertion in vm.yml is the control. Its ABSENCE is the defect, so this
# checks the control exists rather than checking the current config is clean.
if grep -q "'/srv' not in ci_devices.stdout" "$ROLE/tasks/vm.yml" \
   && grep -q "'docker.sock' not in ci_devices.stdout" "$ROLE/tasks/vm.yml"; then
  ok "vm.yml asserts no host-path device"
else
  bad "vm.yml asserts no host-path device" "the device assertion is missing or was reworded"
fi

if grep -qE "search\('source:" "$ROLE/tasks/vm.yml"; then
  ok "vm.yml rejects any disk device with a host source"
else
  bad "vm.yml rejects a host source" "no source: check in the device assertion"
fi

if grep -q 'security\\.privileged' "$ROLE/tasks/vm.yml"; then
  ok "vm.yml refuses a privileged instance"
else
  bad "vm.yml refuses a privileged instance" "no security.privileged assertion"
fi

# A VM, not a container: the host kernel is not shared, so a container escape
# is not a host compromise.
if grep -qE '^\s+- --vm$' "$ROLE/tasks/vm.yml"; then
  ok "the instance is a virtual machine, not a container"
else
  bad "the instance is a virtual machine" "--vm is absent from the launch"
fi

# ⚠️ EXECUTABLE CONTENT ONLY, AND argv IS LINE-SPLIT. The defaults file explains
# at length what must not be mounted, and an earlier version of this check
# failed on its own prose. The first version of THIS check then failed on the
# role's own root disk, because `- -d` and its `root,size=…` value are two
# separate entries in an argv list: a line-at-a-time grep sees a device flag
# with nothing after it. So the value is read from the FOLLOWING line.
#
# Two further traps this check fell into, both worth naming: an unset `want`
# compares equal to FNR-1 on line 1 of every file, so without the `want > 0`
# guard it reported the `---` at the top of all ten task files; and `lxc config
# device add` written as an argv LIST is comma-separated, so a space-separated
# pattern silently matched nothing — it passed the mutation test by not seeing
# the mount that was deliberately planted.
mounts=$(awk '
  FNR == 1 { want = 0 }
  /^[[:space:]]*-[[:space:]]*(-d|--device)[[:space:]]*$/ { want = FNR; next }
  want > 0 && want == FNR - 1 && $0 !~ /root,size=/ { print FILENAME ":" FNR ": " $0 }
  /lxc[,"[:space:]]+config[,"[:space:]]+device[,"[:space:]]+add/ { print FILENAME ":" FNR ": " $0 }
' "$ROLE"/tasks/*.yml || true)
if [ -z "$mounts" ]; then
  ok "the role adds no device beyond the root disk"
else
  bad "the role adds no extra device" "found: $mounts"
fi

srv=$(grep -rn '/srv/data' "$ROLE/tasks/" "$ROLE/templates/" 2>/dev/null \
      | grep -v 'job-hook-started' | grep -vE '^\S+:[0-9]+:\s*#' || true)
if [ -z "$srv" ]; then
  ok "no task or template references /srv/data (except the hook that forbids it)"
else
  bad "no reference to /srv/data" "found: $srv"
fi

# ── 4. The egress policy ───────────────────────────────────────────────────
echo
echo "── 4. the host egress policy ──"
nft="$R/ci-egress.nft"

if [ -f "$nft" ]; then
  # Its own table. Writing into Tailscale's `ip filter` is how one of the two
  # gets flushed by the other's next reload.
  if grep -q '^table inet ci_egress {' "$nft" && ! grep -qE '^table ip filter' "$nft"; then
    ok "the policy lives in its own table, not Tailscale's"
  else
    bad "the policy has its own table" "it writes into a table it does not own"
  fi

  # ⚠️ THE INPUT CHAIN IS THE ONE THAT NEARLY WENT MISSING. Traffic to the
  # host's OWN addresses is delivered through INPUT and never reaches the
  # forward chain — so without this, the CI VM reaches production Caddy on the
  # bridge address and every forward-chain drop is beside the point.
  if grep -q 'hook input' "$nft"; then
    ok "traffic to the host itself is policed (input chain present)"
  else
    bad "traffic to the host itself is policed" \
        "no input chain: the VM can reach any host service on the bridge address"
  fi

  if grep -qE 'ip saddr 10\.71\.0\.0/24 counter drop' "$nft"; then
    ok "host services are denied to the CI subnet by default"
  else
    bad "host services are denied by default" "no catch-all drop in the input chain"
  fi

  # Every denied range the defaults declare must appear as a drop. Read from
  # the role, not restated here — a suite carrying its own copy of the list
  # passes while the role's list quietly shrinks.
  missing=""
  while read -r cidr; do
    [ -n "$cidr" ] || continue
    grep -qE "ip daddr ${cidr//./\\.} counter drop" "$nft" || missing="$missing $cidr"
  done < <(awk '/^ci_egress_denied_cidrs:/{f=1;next} f&&/^ *- /{print $2} f&&!/^ *[-#]/&&NF{exit}' \
           "$ROLE/defaults/main.yml")
  if [ -z "$missing" ]; then
    ok "every declared private range is dropped"
  else
    bad "every declared private range is dropped" "not dropped:$missing"
  fi

  # The final rule must be a drop, so the accepts above are the whole policy.
  last=$(awk '/counter/{l=$0} END{print l}' "$nft")
  case "$last" in
    *drop*) ok "the last rule from the CI bridge is a drop" ;;
    *)      bad "the last rule is a drop" "it is: $last" ;;
  esac

  # ⚠️ THE POLICY IS TWO FIREWALLS, AND THE SECOND ONE IS EASY TO FORGET.
  # Docker sets the iptables FORWARD policy to DROP. Our chain at priority -10
  # decides first — so its drops are authoritative — but an ACCEPT there is not
  # terminal across tables, and the packet then dies in Docker's chain. The CI
  # VM resolved DNS, our accept counter climbed past 400, every drop counter
  # read zero, and not one connection completed.
  if grep -q 'DOCKER-USER' "$ROLE/templates/ci-egress-apply.sh.j2"; then
    ok "the applier permits the CI bridge in DOCKER-USER"
  else
    bad "DOCKER-USER carries the matching accept" \
        "nftables would permit traffic that Docker's FORWARD DROP then discards"
  fi

  if grep -q 'PartOf=docker.service' "$ROLE/tasks/egress.yml"; then
    ok "a Docker restart re-applies the policy (PartOf=docker.service)"
  else
    bad "the policy survives a Docker restart" \
        "Docker recreates DOCKER-USER empty; the CI VM would lose its network"
  fi

  # The convergence check must test BOTH halves, or it reports green through
  # exactly the failure above.
  if grep -q 'iptables -C DOCKER-USER' "$ROLE/tasks/egress.yml"; then
    ok "the in-force check tests both halves of the policy"
  else
    bad "the in-force check tests both halves" \
        "it would pass on a host where the CI VM has no egress at all"
  fi

  if command -v nft >/dev/null 2>&1; then
    if nft -c -f "$nft" > "$R/nft.log" 2>&1; then
      ok "nft accepts the ruleset"
    else
      bad "nft accepts the ruleset" "$(tail -3 "$R/nft.log")"
    fi
  else
    skip "nft accepts the ruleset" "no nft on this controller; the role validates on the host"
  fi
else
  bad "the egress policy renders" "no ci-egress.nft produced"
fi

# ── 5. The service account ─────────────────────────────────────────────────
echo
echo "── 5. the runner runs unprivileged ──"
prov="$R/provision.sh"

if [ -f "$prov" ]; then
  if grep -q 'FATAL: .* is in an administrative group' "$prov"; then
    ok "provisioning refuses a runner user with sudo"
  else
    bad "provisioning refuses a sudo runner" "the administrative-group guard is gone"
  fi

  if ! grep -qE 'usermod -aG (sudo|admin|root)|adduser .* sudo' "$prov"; then
    ok "nothing grants the runner user sudo"
  else
    bad "nothing grants sudo" "$(grep -nE 'usermod -aG (sudo|admin)' "$prov")"
  fi

  # The tarball is pinned AND verified. "curl | tar" trusts whatever the release
  # page serves at download time; a withdrawn artefact has already stopped one
  # deployment in this lab.
  if grep -q 'sha256sum -c' "$prov" && grep -qE "^RUNNER_SHA256='[0-9a-f]{64}'" "$prov"; then
    ok "the runner tarball is pinned and its SHA-256 verified"
  else
    bad "the tarball is verified" "no 64-hex digest or no sha256sum -c"
  fi

  if grep -q 'rm -f "$tarball"' "$prov"; then
    ok "a digest mismatch discards the download"
  else
    bad "a mismatch discards the download" "a failed check could leave the artefact in place"
  fi

  # ⚠️ AND THE PIN MUST BE THE PUBLISHED DIGEST, NOT A PLAUSIBLE ONE. The first
  # value in this role was neither copied nor verified: provisioning failed with
  # a computed hash whose first SIXTEEN BYTES matched the pin and whose tail did
  # not — which no real mismatch produces. It was a fabricated value, and it
  # would have failed every honest download while catching no tampering at all.
  #
  # Network-dependent, like the remote image check: "is this the digest upstream
  # publishes" is only answerable by asking upstream.
  ver=$(awk '/^ci_runner_version:/{gsub(/"/,"",$2); print $2; exit}' "$ROLE/defaults/main.yml")
  pin=$(awk '/^ci_runner_sha256:/{gsub(/"/,"",$2); print $2; exit}' "$ROLE/defaults/main.yml")
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    published=$(gh api "repos/actions/runner/releases/tags/v${ver}" --jq '.body' 2>/dev/null \
                | grep -oE 'BEGIN SHA linux-x64 -->[0-9a-f]{64}' | sed 's/.*-->//')
    if [ -z "$published" ]; then
      bad "the pinned digest matches the release" \
          "could not read a linux-x64 digest from the v${ver} release notes"
    elif [ "$published" = "$pin" ]; then
      ok "the pinned digest is the one actions/runner publishes for v${ver}"
    else
      bad "the pinned digest matches the release" \
          "pinned $pin, published $published"
    fi
  else
    skip "the pinned digest matches the release" \
         "needs an authenticated gh; the provisioning script verifies on the host"
  fi

  # No sshd in the guest: nothing to attack, no host key to rotate.
  if ! grep -qE 'openssh-server|systemctl (enable|start) ssh' "$prov"; then
    ok "the guest installs no sshd"
  else
    bad "the guest installs no sshd" "$(grep -nE 'openssh-server' "$prov")"
  fi
else
  bad "provision.sh renders" "not produced"
fi

# ── 6. Per-job hygiene is wired up, not merely present ─────────────────────
echo
echo "── 6. the per-job hooks are wired to the runner ──"
envf="$R/runner.env"

# ⚠️ THE HOOKS EXISTING ON DISK PROVES NOTHING. The runner only runs them if
# these two variables name them, so the .env is the load-bearing artefact.
if grep -q '^ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/ci-hooks/job-started.sh' "$envf" \
   && grep -q '^ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/ci-hooks/job-completed.sh' "$envf"; then
  ok "both hooks are named in the runner environment"
else
  bad "both hooks are wired" "the runner would never execute them"
fi

# The hooks are root's. A runner user who could edit them could disable both the
# cleanup and the isolation self-check on its way past.
if grep -q 'install -d -o root -g root -m 0755 "$HOOK_DIR"' "$prov"; then
  ok "the hook directory is owned by root, not the runner"
else
  bad "the hooks are root-owned" "the runner user could rewrite its own cleanup"
fi

started="$R/job-started.sh"
if grep -q '\[ -e /srv/data \]' "$started"; then
  ok "the started hook refuses to run if /srv/data is visible"
else
  bad "the started hook checks /srv/data" "the runtime half of the isolation claim is gone"
fi

if grep -qE 'keel-gateway|keel-postgres' "$started"; then
  ok "the started hook refuses if production containers are visible"
else
  bad "the started hook checks the Docker socket" "a host socket would go unnoticed"
fi

if grep -q '/dev/tcp/' "$started"; then
  ok "the started hook probes that the egress policy is in force"
else
  bad "the started hook probes egress" "the policy would be assumed, not proven"
fi

# ⚠️ AND THE PROBES MUST BE ADDRESSES. `/dev/tcp` to a name that does not
# resolve fails exactly like a dropped packet — so a probe list rendered from an
# inventory NAME would report every target unreachable while testing nothing.
# The controller's own `ansible_host` for this lab IS such a name.
if grep -q 'is not an IP address' "$started"; then
  ok "a probe target that is not an address fails the job instead of passing"
else
  bad "unresolvable probe targets are rejected" \
      "a probe that cannot resolve would report success without testing anything"
fi

# ⚠️ AND IT MUST NOT DELETE THE DIRECTORY THE JOB IS ABOUT TO RUN IN. The runner
# creates the job's working directory BEFORE invoking this hook. The first
# version removed everything under _work, so every step died with "No such file
# or directory" and two jobs failed in under 20 seconds having executed no
# product code. The current workspace is the completed hook's to clear.
if grep -q 'RUNNER_WORKSPACE' "$started"; then
  ok "the started hook spares the current job's workspace"
else
  bad "the started hook spares the current workspace" \
      "it would delete the directory the job is about to run in"
fi

completed="$R/job-completed.sh"

if grep -q 'GITHUB_WORKSPACE' "$completed"; then
  ok "the completed hook clears the workspace the job used"
else
  bad "the completed hook clears the workspace" "the next job would inherit this job's files"
fi
if grep -q 'docker ps -aq' "$completed" && grep -q 'docker volume ls -q' "$completed"; then
  ok "the completed hook destroys containers and volumes"
else
  bad "the completed hook destroys job resources" "test databases would survive the job"
fi

if grep -q 'redacted' "$completed"; then
  ok "preserved logs are passed through redaction"
else
  bad "preserved logs are redacted" "job output is kept verbatim"
fi

# ── 7. The token discipline ────────────────────────────────────────────────
echo
echo "── 7. the registration token is never written down ──"

# Nothing in the role may hold a token value. This is the check that would have
# caught a "temporary" default.
tok=$(grep -rnE '^\s*ci_runner_(token|removal_token)\s*:' "$ROLE/defaults/" 2>/dev/null || true)
if [ -z "$tok" ]; then
  ok "no token is defaulted anywhere in the role"
else
  bad "no token is defaulted" "found: $tok"
fi

if grep -q 'no_log: true' "$ROLE/tasks/register.yml" \
   && grep -q 'no_log: true' "$ROLE/tasks/unregister.yml"; then
  ok "both token-bearing tasks are no_log"
else
  bad "the token-bearing tasks are no_log" "the token would appear in -v output and callbacks"
fi

# stdin, not argv: absent from `ps` on the host and from Ansible's task args.
if grep -q 'stdin: "{{ ci_runner_token }}"' "$ROLE/tasks/register.yml"; then
  ok "the token reaches the guest on stdin, not in an argument"
else
  bad "the token is delivered on stdin" "it would be visible in ps on dc1-x86"
fi

if ! grep -rnE 'ci_runner_token' "$ROLE/templates/" 2>/dev/null | grep -qv '^\s*#'; then
  ok "no template interpolates a token"
else
  bad "no template holds a token" "$(grep -rn 'ci_runner_token' "$ROLE/templates/")"
fi

# Registration must not ride along with ordinary provisioning: the token is
# single-use and expires within the hour, so a role that needed one could never
# be re-run unattended.
if ! grep -q 'register' "$ROLE/tasks/main.yml"; then
  bad "main.yml mentions registration" "it should explain the separation"
else
  if grep -qE 'include_tasks:\s*register\.yml' "$ROLE/tasks/main.yml"; then
    bad "registration is out of the provisioning flow" "main.yml includes register.yml"
  else
    ok "registration is a separate, operator-initiated entry point"
  fi
fi

if grep -qE '^\s+tags: \[register, never\]' playbooks/ci-runner.yml \
   && grep -qE '^\s+tags: \[unregister, never\]' playbooks/ci-runner.yml \
   && grep -qE '^\s+tags: \[rebuild, never\]' playbooks/ci-runner.yml; then
  ok "register, unregister and rebuild are never-tagged"
else
  bad "the dangerous entry points are never-tagged" "one could run as a side effect of a deploy"
fi

# ⚠️ AND EVERY TAGGED INCLUDE MUST CARRY `apply:`. A tag on a dynamic
# `include_role` applies to the include task alone; the tasks it pulls in
# inherit nothing and are filtered out under `--tags`. `--tags rebuild`
# reported "ok=2 changed=0" against a VM it never touched. On `--tags register`
# the same defect would consume a one-time GitHub token, report success, and
# leave no runner registered — a failure whose cost is a trip back to the
# repository settings for another token.
includes=$(grep -c 'include_role:' playbooks/ci-runner.yml)
applies=$(grep -c '^\s*apply:' playbooks/ci-runner.yml)
if [ "$includes" -eq "$applies" ] && [ "$includes" -gt 0 ]; then
  ok "every include_role applies its tag to the tasks it includes ($applies/$includes)"
else
  bad "every tagged include carries apply:" \
      "$applies of $includes includes — the others run nothing under --tags"
fi

# ── 8. Reversibility ───────────────────────────────────────────────────────
echo
echo "── 8. the runner can be removed and the VM rebuilt ──"

if grep -q 'config.sh remove' "$R/unregister.sh"; then
  ok "removal uses the runner's own de-registration"
else
  bad "removal de-registers properly" "an orphan would be left in the repository's runner list"
fi

if grep -q 'ci_rebuild_confirm == ci_vm_name' "$ROLE/tasks/rebuild.yml"; then
  ok "rebuild requires the VM to be named explicitly"
else
  bad "rebuild requires confirmation" "a --tags rebuild on the wrong host would proceed"
fi

if grep -q "devices.root.pool | default('') == ci_lxd_pool" "$ROLE/tasks/rebuild.yml"; then
  ok "rebuild refuses an instance outside this role's storage pool"
else
  bad "rebuild checks ownership" "a name collision could delete someone else's instance"
fi

if grep -q 'ci_rebuild_registered.rc != 0' "$ROLE/tasks/rebuild.yml"; then
  ok "rebuild refuses while a runner is still registered"
else
  bad "rebuild refuses a registered runner" \
      "deleting the VM would strand a runner GitHub can never remove"
fi

if grep -q 'include_tasks: main.yml' "$ROLE/tasks/rebuild.yml"; then
  ok "rebuild replays the ordinary provisioning path"
else
  bad "rebuild reuses main.yml" "a bespoke rebuild path proves nothing about the real one"
fi

# ── 9. The ephemeral option is real ────────────────────────────────────────
echo
echo "── 9. the ephemeral opt-in actually changes the registration ──"
if grep -q -- '--ephemeral' "$R/register-ephemeral.sh" && ! grep -q -- '--ephemeral' "$R/register.sh"; then
  ok "ci_runner_ephemeral=true adds --ephemeral, and the default does not"
else
  bad "the ephemeral flag is honoured" \
      "both renders are the same — the opt-in is documentation, not behaviour"
fi

if grep -q -- '--disableupdate' "$R/register.sh"; then
  ok "the runner will not replace its verified binaries by self-update"
else
  bad "self-update is disabled" "the pinned, digest-checked install could be silently replaced"
fi

# ── 10. Live: the properties, from inside the VM ───────────────────────────
echo
echo "── 10. live checks inside the VM ──"
if [ -z "${CI_RUNNER_LIVE:-}" ]; then
  skip "in-guest isolation probes" \
       "set CI_RUNNER_LIVE=1 to run them against the real dc1-ci-1"
else
  # ⚠️ THROUGH ANSIBLE, NOT `ssh`. The inventory already knows the host's
  # address, user and key, and an earlier version of this section invented its
  # own ssh invocation — which meant the suite could only run from a controller
  # whose ssh config happened to match. CI_RUNNER_HOST overrides the address for
  # a controller that cannot resolve the inventory name.
  vm=$(awk '/^ci_vm_name:/{print $2; exit}' "$ROLE/defaults/main.yml")
  AOPT=(-i inventory/hosts.yml linux_servers -b)
  [ -n "${CI_RUNNER_HOST:-}" ] && AOPT+=(-e "ansible_host=${CI_RUNNER_HOST}")

  # Returns the guest's stdout, and a non-zero status when the command failed
  # inside the guest — `ansible -m command` propagates the remote exit code.
  live() {
    ansible "${AOPT[@]}" -m command -a "lxc exec $vm -T -- $*" 2>/dev/null \
      | sed '1d'
  }
  live_rc() {
    ansible "${AOPT[@]}" -m command -a "lxc exec $vm -T -- $*" > "$R/live.log" 2>&1
  }

  if live_rc /bin/true; then
    ok "the guest answers over lxc exec"

    # ⚠️ EACH OF THESE IS A NEGATIVE CLAIM, so read the direction carefully: the
    # check PASSES when the command inside the guest FAILS.
    if live_rc test -e /srv/data; then
      bad "/srv/data is not visible in the guest" "a host path is mounted in"
    else
      ok "/srv/data is not visible in the guest"
    fi

    names=$(live docker ps -a --format '{{.Names}}')
    case "$names" in
      *keel-*) bad "no production container is visible" "saw: $names" ;;
      *)       ok "no production container is visible from the guest" ;;
    esac

    # The probes the started hook uses, run here so a misconfiguration is
    # diagnosed now rather than as a mysteriously failing job later. The host's
    # own LAN address is read from the host, not assumed.
    hostip=$(ansible "${AOPT[@]}" -m shell \
               -a "ip -4 -o addr show scope global | awk '{print \$4}' | cut -d/ -f1 | head -1" \
               2>/dev/null | sed '1d' | tr -d '[:space:]')
    if [ -z "$hostip" ]; then
      bad "the host's own address is known" "could not read it; the probes below would prove nothing"
    else
      for port in 443 5432; do
        # Quoted so the command module passes `exec 3<>…` to bash as one
        # argument instead of the controller's shell trying to redirect it.
        if live_rc "timeout 4 bash -c 'exec 3<>/dev/tcp/$hostip/$port'"; then
          bad "the host's $port is unreachable from the guest" \
              "$hostip:$port answered — the egress policy is not in force"
        else
          ok "the host's $port is unreachable from the guest ($hostip)"
        fi
      done
    fi

    # ⚠️ A THIRD PARTY ON THE LAN, NOT JUST THE HOST. The host is denied by the
    # INPUT chain; this is the only check that exercises the FORWARD chain's
    # drops — and those are the ones a broad `ACCEPT` in DOCKER-USER would
    # undermine if the priority ordering were ever wrong. The router is used
    # because it is guaranteed to be up, so a timeout means dropped rather than
    # absent.
    gw=$(ansible "${AOPT[@]}" -m shell -a "ip route show default | awk '{print \$3}' | head -1" \
           2>/dev/null | sed '1d' | tr -d '[:space:]')
    if [ -n "$gw" ]; then
      if live_rc "timeout 4 bash -c 'exec 3<>/dev/tcp/$gw/80'"; then
        bad "the LAN is unreachable from the guest" \
            "the router at $gw answered — the forward-chain drops are not in force"
      else
        ok "the rest of the LAN is unreachable from the guest ($gw)"
      fi
    else
      bad "the default gateway is known" "could not read it; the LAN drop is unproven"
    fi

    if live_rc "curl -sS -m 20 -o /dev/null https://api.github.com/zen"; then
      ok "github.com is reachable from the guest"
    else
      bad "github is reachable" "the runner could not talk to GitHub"
    fi

    groups=$(live id -nG "$(awk '/^ci_runner_user:/{print $2; exit}' "$ROLE/defaults/main.yml")")
    case " $groups " in
      *" sudo "*|*" admin "*|*" root "*)
        bad "the runner user is unprivileged" "it is in an administrative group: $groups" ;;
      *) ok "the runner user is unprivileged (groups:$groups)" ;;
    esac
  else
    bad "the guest answers over lxc exec" "cannot reach $vm — see $R/live.log"
  fi
fi

# ── Result ─────────────────────────────────────────────────────────────────
echo
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ] || exit 1
