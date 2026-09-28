#!/bin/bash
# TrueWealth CI runner — PROVISIONING (not check mode) from dc1-arm-1, run from an exact-commit checkout.
# Builds dc1-ci-tw-1 on dc1-x86: LV ci-tw-lxd, pool ci-tw-pool, bridge citwbr0, table inet ci_egress_tw,
# units ci-egress-tw(-early), the VM and the runner binaries. Does NOT register a runner (no token).
#
#   /bin/bash tools/ci-activation/provision-truewealth.sh <40-character commit SHA of this checkout>
#
# Runbook: roles/ci_runner/README.md, "Activation from dc1-arm-1". Run it in Terminal on dc1-arm-1,
# never `source` it. Everything it uses comes from the checkout it lives in; it refuses unless:
#   - it is the intended controller and account (macOS, dc1-arm-1, 10.0.0.22, a terminal);
#   - the checkout's HEAD is exactly the SHA given, the tree is clean (untracked files included) and
#     holds no vault file;
#   - the provisioning implementation is byte-identical to CHECKED_SHA, the revision whose live check
#     mode the owner ran (everything the playbook loads; only the role's README may differ);
#   - labadmin@dc1-x86 is reachable with the inventory key and an ALREADY-TRUSTED host key;
#   - ~/ci-shared-check/hostcheck.sh on dc1-x86 is byte-identical to tools/ci-activation/hostcheck.sh
#     here, and it verifies the newest before snapshot's completion record at this SHA;
#   - you type the confirmation.
set -euo pipefail
CHECKED_SHA="455c088bd750791faccb1e94ff2af52c8fe78ac2"   # live check mode: ok=42 changed=5 unreachable=0 failed=0
# Everything `ansible-playbook playbooks/ci-runner-truewealth.yml` loads.
IMPL_PATHS=(ansible.cfg requirements.yml inventory playbooks/ci-runner-truewealth.yml
            playbooks/vars/ci-runner-truewealth.yml roles/ci_runner ':(exclude)roles/ci_runner/README.md')
EXPECT_USER="dc1-arm-1"
EXPECT_HOME="/Users/dc1-arm-1"
EXPECT_LAN_IP="10.0.0.22"
KEY="$HOME/.ssh/home_datacenter_admin"
LOGDIR="$HOME/ci-preflight"
SSH_STRICT="-o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o IdentitiesOnly=yes"
MAX_BEFORE_AGE_MIN=120
die() { echo "STOP: $*" >&2; exit 1; }
sha_ok() { [ "${#1}" -eq 40 ] && case "$1" in *[!0-9a-f]*) false;; *) true;; esac; }
file_sha256() { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }
# shellcheck disable=SC2086
rsh() { ssh $SSH_STRICT -i "$KEY" -o BatchMode=yes -o ConnectTimeout=10 labadmin@dc1-x86 "$@"; }

# The checkout this script lives in must be exactly <commit>, clean, vault-free, and carry the
# provisioning implementation of CHECKED_SHA unchanged.
verify_checkout() { # root commit
  local root=$1 c=$2 head r=0 changed
  sha_ok "$c" || die "usage: provision-truewealth.sh <40-character commit SHA of this checkout>"
  head=$(git -C "$root" rev-parse HEAD 2>/dev/null) || die "$root is not a git checkout"
  [ "$(git -C "$root" rev-parse --show-toplevel)" = "$root" ] || die "$root is not the top of its checkout"
  [ "$head" = "$c" ] || die "checkout HEAD is $head, not $c"
  [ -z "$(git -C "$root" status --porcelain --untracked-files=all)" ] || die "checkout is not clean (git status in $root)"
  if [ -e "$root/inventory/group_vars/linux_servers/vault.yml" ] || [ -e "$root/inventory/group_vars/vault.yml" ]; then
    die "a vault file is present in the checkout"; fi
  git -C "$root" cat-file -e "$CHECKED_SHA^{commit}" 2>/dev/null || die "the checked revision $CHECKED_SHA is not in this checkout"
  git -C "$root" merge-base --is-ancestor "$CHECKED_SHA" "$c" || die "$c does not descend from the checked revision $CHECKED_SHA"
  git -C "$root" diff --quiet "$CHECKED_SHA" "$c" -- "${IMPL_PATHS[@]}" || r=$?
  if [ "$r" -eq 1 ]; then
    changed=$(git -C "$root" diff --name-only "$CHECKED_SHA" "$c" -- "${IMPL_PATHS[@]}" | tr '\n' ' ')
    die "the provisioning implementation differs from the checked revision $CHECKED_SHA: $changed"
  elif [ "$r" -ne 0 ]; then die "git diff against $CHECKED_SHA failed (exit $r)"; fi
  grep -q 'ansible_ssh_private_key_file: ~/.ssh/home_datacenter_admin' "$root/inventory/hosts.yml" || die "inventory key differs from $KEY"
}

# The gate before provisioning: the staged hostcheck.sh is this checkout's, and it VERIFIES the newest
# before snapshot's completion record (SHA, phase, identity, evidence hashes, 5/5 health, age). A
# snapshot without a valid record — however fresh, however many HTTP 200s it holds — does not pass.
# Sets BEFORE_DIR.
require_before_record() { # path-to-reviewed-hostcheck.sh commit
  local ref=$1 c=$2 exp out rc=0 line
  exp=$(file_sha256 "$ref"); [ "${#exp}" -eq 64 ] || die "cannot hash $ref"
  out=$(rsh 'sha256sum ~/ci-shared-check/hostcheck.sh') || die "cannot read ~/ci-shared-check/hostcheck.sh on dc1-x86 (stage it first)"
  [ "${out%% *}" = "$exp" ] || die "hostcheck.sh on dc1-x86 is not this checkout's (${out%% *} != $exp); stage it again"
  out=$(rsh "bash ~/ci-shared-check/hostcheck.sh verify before $c $MAX_BEFORE_AGE_MIN") || rc=$?
  printf '%s\n' "$out" | sed 's/^/   /'
  [ "$rc" -eq 0 ] || die "the before snapshot has no valid completion record at $c (verify exit $rc); take: hostcheck.sh snapshot before $c"
  line=$(printf '%s\n' "$out" | sed -n 's/^VERIFIED //p')
  [ -n "$line" ] || die "verify did not confirm a snapshot"
  BEFORE_DIR=$line
}
if [ "${PROVISION_LIB:-0}" = 1 ]; then return 0; fi   # sourced by tests/ci-activation only

C="${1:-}"
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
echo "== 0. intended controller and account (before any connection)"
[ "$(uname -s)" = "Darwin" ] || die "not macOS (uname -s is $(uname -s))"
[ "$(id -un)" = "$EXPECT_USER" ] || die "account is $(id -un), expected $EXPECT_USER"
[ "$HOME" = "$EXPECT_HOME" ] || die "HOME is $HOME, expected $EXPECT_HOME"
ifconfig 2>/dev/null | grep "inet $EXPECT_LAN_IP " >/dev/null || die "this Mac does not hold $EXPECT_LAN_IP (not dc1-arm-1?)"
{ : </dev/tty; } 2>/dev/null || die "no terminal: confirmation and the become password must be typed at a prompt"
echo "controller: $(hostname) ($EXPECT_LAN_IP), account $(id -un), $(sw_vers -productVersion 2>/dev/null || uname -r)"
for t in git ssh ansible-playbook python3 tee shasum; do command -v "$t" >/dev/null 2>&1 || die "missing $t"; done
ansible --version 2>/dev/null | sed -n 1p
for v in ANSIBLE_KEEP_REMOTE_FILES ANSIBLE_CONFIG ANSIBLE_INVENTORY ANSIBLE_SSH_ARGS ANSIBLE_SSH_EXTRA_ARGS \
         ANSIBLE_SSH_COMMON_ARGS ANSIBLE_HOST_KEY_CHECKING ANSIBLE_PRIVATE_KEY_FILE ANSIBLE_REMOTE_USER \
         CI_RUNNER_TOKEN CI_RUNNER_REMOVAL_TOKEN; do
  eval "val=\${$v:-}"; [ -z "$val" ] || die "$v is set in the environment; unset it first (no token is used in this phase)"
done

echo "== 1. the checkout: $ROOT"
verify_checkout "$ROOT" "$C"
echo "ok: HEAD $C, clean, no vault; provisioning implementation identical to the checked revision $CHECKED_SHA"

echo "== 2. existing SSH trust to dc1-x86 (known_hosts is read, never updated)"
[ -f "$KEY" ] || die "inventory key $KEY not found"
rsh true || die "labadmin@dc1-x86 refused: host key not already trusted, or the inventory key was not accepted (nothing changed)"
echo "ok: already-known host key, inventory key accepted"

echo "== 3. the before snapshot on dc1-x86 must have a valid completion record at this SHA"
require_before_record "$ROOT/tools/ci-activation/hostcheck.sh" "$C"
echo "ok: before snapshot $BEFORE_DIR verified (record, SHA, identity, evidence hashes, 5/5 health, < $MAX_BEFORE_AGE_MIN min)"

echo "== 4. confirmation"
echo "This will CREATE dc1-ci-tw-1 and its volume, pool, bridge, egress table and units on dc1-x86."
echo "It will NOT register a runner. Type exactly:  PROVISION dc1-ci-tw-1"
IFS= read -r answer </dev/tty
[ "$answer" = "PROVISION dc1-ci-tw-1" ] || die "not confirmed; nothing was run"

echo "== 5. provisioning (Ansible prompts for labadmin's BECOME password)"
cd "$ROOT"
mkdir -p "$LOGDIR"; chmod 0700 "$LOGDIR"
LOG="$LOGDIR/provisioning-apply-$C-$(date -u +%Y%m%dT%H%M%SZ).log"
( umask 077; echo "infrastructure $C (implementation of $CHECKED_SHA)  PROVISION  $(date -u +%Y-%m-%dT%H:%M:%SZ)  controller $(hostname) $(id -un)  before $BEFORE_DIR" > "$LOG" )
set +e
ANSIBLE_CONFIG="$ROOT/ansible.cfg" ansible-playbook -i inventory/hosts.yml playbooks/ci-runner-truewealth.yml \
  --limit dc1-x86 \
  --diff --ask-become-pass \
  --ssh-extra-args="$SSH_STRICT" \
  -e ci_tw_host_lan_ip=10.0.0.3 </dev/tty 2>&1 | tee -a "$LOG"
PS=("${PIPESTATUS[@]}")
set -e
ansible_rc=${PS[0]}; tee_rc=${PS[1]:-1}
if [ "$ansible_rc" -ne 0 ]; then rc=$ansible_rc; else rc=$tee_rc; fi
chmod 0600 "$LOG" 2>/dev/null || true
echo "== ansible-playbook exit status: $ansible_rc; tee exit status: $tee_rc; wrapper exits $rc"
echo "== private log: $LOG"
if [ "$rc" -ne 0 ]; then
  echo "== FAILED. Do NOT re-run, roll back or delete anything. Preserve the log and take:"
  echo "   ssh -t $SSH_STRICT -i $KEY labadmin@dc1-x86 'bash ~/ci-shared-check/hostcheck.sh snapshot after-failure $C'"
else
  echo "== Ansible finished. This is not yet evidence of a healthy, isolated runner. Next (runbook step 5):"
  echo "   after-provision snapshot, compare, live probes. Registration is a separate authorization."
fi
exit "$rc"
