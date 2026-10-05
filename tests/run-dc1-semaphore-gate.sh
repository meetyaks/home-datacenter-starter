#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# SEMAPHORE PRE-MERGE GATE — disposable macOS launchd harness on dc1-arm-1.
#
#   tests/run-dc1-semaphore-gate.sh <full-40-character-pr-head-sha>
#
# Runs the canonical harness from an isolated detached worktree at the exact
# reviewed commit, beside the live CoreDNS resolver, and proves that resolver
# is bit-for-bit unchanged afterwards.
#
# Every refusal below was paid for by the CoreDNS gate: a stale disposable
# daemon silently recorded as live state, a teardown defeated by an expired
# sudo ticket, an ownership check that spared a process that was in fact
# ours, and a port probe that reported open ports as closed.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

PR_HEAD="${1:-}"
[ -n "$PR_HEAD" ] || { echo "usage: $0 <full-40-character-pr-head-sha>" >&2; exit 2; }
[ "${#PR_HEAD}" -eq 40 ] || { echo "the PR head must be a full 40-character SHA, got '${PR_HEAD}'" >&2; exit 2; }
case "$PR_HEAD" in
  *[!0-9a-f]*) echo "the PR head must be lowercase hexadecimal" >&2; exit 2 ;;
esac

BRANCH=feat/semaphore-controller
CANON="$HOME/Projects/home-datacenter-starter"
PROTECTED="inventory/group_vars/linux_servers/vault.yml.backup-20261001T091734Z"
STAMP=$(date +%Y%m%dT%H%M%SZ)-$$
WT="$HOME/dc1-sema-worktree-$STAMP"
EVID="$HOME/dc1-sema-evidence-$STAMP"

WT_CREATED=no
die() {
  echo; echo "BLOCKED: $*" >&2
  if [ "$WT_CREATED" = yes ] && [ -e "$WT" ]; then
    git -C "$CANON" worktree remove --force "$WT" >/dev/null 2>&1 \
      && { git -C "$CANON" worktree prune; echo "Removed the worktree $WT." >&2; } \
      || echo "NOTE: could not remove the worktree $WT — remove it yourself." >&2
  fi
  echo "The live resolver was not touched." >&2
  exit 2
}
hdr() { echo; echo "═══ $* ═══"; }

hdr "PHASE 1  preconditions"
[ "$(hostname -s)" = "dc1-arm-1" ] || die "hostname is $(hostname -s), expected dc1-arm-1"
echo "  hostname        dc1-arm-1"
[ "$(id -un)" = "dc1-arm-1" ] || die "user is $(id -un), expected dc1-arm-1"
echo "  user            dc1-arm-1"
[ "$(uname -s)" = "Darwin" ] || die "not macOS; the launchd path cannot be exercised"
echo "  platform        Darwin $(uname -r)"
[ -d "$CANON/.git" ] || die "canonical repo not found at $CANON"
cd "$CANON" || die "cannot enter $CANON"

# -uno: untracked paths are neither inspected nor listed, so the protected
# backup is never named, let alone read.
DIRTY=$(git status --porcelain -uno)
[ -z "$DIRTY" ] || { echo "$DIRTY" | sed 's/^/    /'; die "canonical repo has tracked or staged changes"; }
echo "  canonical state clean (tracked + staged)"
CANON_BRANCH_BEFORE=$(git rev-parse --abbrev-ref HEAD)
CANON_HEAD_BEFORE=$(git rev-parse HEAD)
echo "  canonical branch $CANON_BRANCH_BEFORE"
echo "  canonical HEAD   $CANON_HEAD_BEFORE"

# Existence only. Never read, print, move, rename, delete, stage or commit.
[ -e "$CANON/$PROTECTED" ] || die "the protected backup is missing BEFORE the test"
echo "  protected backup present (existence tested only)"

for t in ansible-playbook curl lsof python3 openssl; do
  command -v "$t" >/dev/null || die "$t not on PATH"
done
echo "  tooling         ansible-playbook, curl, lsof, python3, openssl present"

hdr "PHASE 1  fetch the exact reviewed commit"
git fetch --quiet origin "$BRANCH" || die "fetch failed"
FETCHED=$(git rev-parse FETCH_HEAD)
echo "  fetched         $FETCHED"
echo "  expected        $PR_HEAD"
[ "$FETCHED" = "$PR_HEAD" ] || die "fetched commit does not equal the recorded PR head"
echo "  MATCH — proceeding with the exact reviewed commit"

hdr "PHASE 1  isolated detached worktree"
# ⚠️ UNDER \$HOME, NOT /tmp. Ansible ignores an ansible.cfg in a
# world-writable directory, which would silently drop roles_path and fail
# the run for a reason unrelated to the role.
git worktree add --quiet --detach "$WT" "$PR_HEAD" || die "could not create the worktree"
WT_CREATED=yes
[ "$(git -C "$WT" rev-parse HEAD)" = "$PR_HEAD" ] || die "worktree HEAD mismatch"
echo "  worktree        $WT"
echo "  worktree HEAD   $PR_HEAD (detached)"

hdr "sudo"
echo "The baseline reads root-owned listeners and the harness installs a"
echo "launchd system daemon. Expect this prompt, three BECOME prompts, and"
echo "possibly one more during teardown."
sudo -v || die "sudo was refused; the gate cannot run"

# ── Refuse to build a baseline on top of someone else's leftovers ──────────
#
# ⚠️ NOT HOUSEKEEPING. A stray disposable daemon from an interrupted run gets
# captured into the "live" baseline, compared against itself, and reported
# unchanged — and afterwards there is no way to tell this run's leak from the
# previous one's. The CoreDNS gate did exactly that before it was fixed.
hdr "PHASE 2  no disposable state may exist before the baseline"
pre_lbl=$(sudo launchctl list 2>/dev/null | awk '/org\.dc1\.semaphoredisposable/{print $3}')
pre_proc=$(pgrep -fl 'semaphore-disposable' 2>/dev/null)
pre_dir=$(find "${TMPDIR:-/tmp}" /tmp -maxdepth 1 -name 'semaphore-disposable.*' 2>/dev/null)
if [ -n "$pre_lbl" ] || [ -n "$pre_proc" ] || [ -n "$pre_dir" ]; then
  echo "  PRE-EXISTING DISPOSABLE STATE FOUND — refusing to run."
  [ -n "$pre_lbl" ]  && printf '%s\n' "$pre_lbl"  | sed 's/^/    label:   /'
  [ -n "$pre_proc" ] && printf '%s\n' "$pre_proc" | sed 's/^/    process: /'
  [ -n "$pre_dir" ]  && printf '%s\n' "$pre_dir"  | sed 's/^/    prefix:  /'
  echo
  echo "  Remove them, then re-run. For each label and prefix above:"
  [ -n "$pre_lbl" ] && printf '%s\n' "$pre_lbl" | sed 's|^|    sudo launchctl bootout system/|'
  [ -n "$pre_dir" ] && printf '%s\n' "$pre_dir" | sed "s|^\\(.*\\)\$|    sudo pkill -f '\\1/sbin/semaphore'|"
  [ -n "$pre_dir" ] && printf '%s\n' "$pre_dir" | sed "s|^\\(.*\\)\$|    sudo rm -rf '\\1'|"
  echo
  echo "  Nothing in the live resolver is involved; do not restart it."
  die "disposable leftovers would contaminate the baseline"
fi
echo "  clean — no disposable label, process or prefix exists"

hdr "PHASE 3  baseline"
mkdir -p "$EVID" || die "cannot create $EVID"

LIVE_LABEL=org.coredns.coredns
LIVE_PLIST=/Library/LaunchDaemons/$LIVE_LABEL.plist
b_pid=$(pgrep -f '[c]oredns -conf /usr/local/etc/coredns/Corefile' | head -1)
[ -n "$b_pid" ] || die "no live CoreDNS process found; the non-interference proof would be vacuous"
b_start=$(ps -p "$b_pid" -o lstart= | sed 's/  */ /g')
b_bin=$(shasum -a 256 /usr/local/sbin/coredns | awk '{print $1}')
b_core=$(shasum -a 256 /usr/local/etc/coredns/Corefile | awk '{print $1}')
b_plist=$(shasum -a 256 "$LIVE_PLIST" | awk '{print $1}')
b_lsn=$(sudo lsof -nP -iTCP -sTCP:LISTEN -iUDP 2>/dev/null \
        | awk '$1 ~ /^coredns/ {print $8, $9}' | sort -u | tr '\n' ';')

# ⚠️ TCP AND UDP ASKED SEPARATELY. Combining them in one lsof selection makes
# every TCP-only port report closed — the CoreDNS gate printed `8653=closed`
# while its own listener list showed 8653 open.
ports_listen() {
  for p in 53 3000; do
    if sudo lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 \
       || sudo lsof -nP -iUDP:"$p" >/dev/null 2>&1; then
      printf '%s=open ' "$p"; else printf '%s=closed ' "$p"; fi
  done
}
b_ports=$(ports_listen)
answer() { dig +short +time=3 +tries=1 @127.0.0.1 "$1" A 2>/dev/null | tr '\n' ' '; }
b_a1=$(answer dc1-arm-1.dc1.lan); b_a2=$(answer dc1-x86.dc1.lan); b_a3=$(answer keel-dev.dc1.lan)

{
  echo "coredns pid   $b_pid"
  echo "started       $b_start"
  echo "binary        $b_bin"
  echo "corefile      $b_core"
  echo "plist         $b_plist"
  echo "listeners     $b_lsn"
  echo "ports         $b_ports"
  echo "dc1-arm-1     $b_a1"
  echo "dc1-x86       $b_a2"
  echo "keel-dev      $b_a3"
} | tee "$EVID/baseline.txt" | sed 's/^/  /'

for v in b_pid b_start b_bin b_core b_plist b_a1 b_a2 b_a3; do
  eval "val=\$$v"
  [ -n "$val" ] || die "baseline field $v is empty; the comparison would be vacuous"
done
echo "  baseline complete and non-empty"

hdr "PHASE 4  execute tests/run-semaphore-launchd.sh from the worktree"
echo "  (three role runs; expect three BECOME prompts)"
echo
cd "$WT" || die "cannot enter the worktree"
# ⚠️ --with-account: THE GATE EXERCISES THE REAL PRODUCTION ACCOUNT PATH.
# A disposable `_semt<hex>` identity is created, measured from Directory
# Services and removed exactly. Running the gate WITHOUT this flag would
# skip the one thing the controller run exists to prove.
tests/run-semaphore-launchd.sh --with-account 2>&1 | tee "$EVID/harness.log"
HARNESS_RC=${PIPESTATUS[0]}
cd "$CANON" || die "cannot return to $CANON"
echo
echo "  harness exit status: $HARNESS_RC"
for f in /tmp/semaphore-disp-1.log /tmp/semaphore-disp-2.log /tmp/semaphore-disp-3.log; do
  [ -f "$f" ] && cp "$f" "$EVID/" 2>/dev/null
done

hdr "PHASE 5  live CoreDNS non-interference (independent re-measurement)"
a_pid=$(pgrep -f '[c]oredns -conf /usr/local/etc/coredns/Corefile' | head -1)
a_start=$([ -n "$a_pid" ] && ps -p "$a_pid" -o lstart= | sed 's/  */ /g')
a_bin=$(shasum -a 256 /usr/local/sbin/coredns 2>/dev/null | awk '{print $1}')
a_core=$(shasum -a 256 /usr/local/etc/coredns/Corefile 2>/dev/null | awk '{print $1}')
a_plist=$(shasum -a 256 "$LIVE_PLIST" 2>/dev/null | awk '{print $1}')
a_lsn=$(sudo lsof -nP -iTCP -sTCP:LISTEN -iUDP 2>/dev/null \
        | awk '$1 ~ /^coredns/ {print $8, $9}' | sort -u | tr '\n' ';')
a_ports=$(ports_listen)
a_a1=$(answer dc1-arm-1.dc1.lan); a_a2=$(answer dc1-x86.dc1.lan); a_a3=$(answer keel-dev.dc1.lan)

drift=0
cmp_f() {
  if [ "$2" = "$3" ]; then printf '  same      %-12s %s\n' "$1" "$2"
  else printf '  DIFFERENT %-12s before=%s after=%s\n' "$1" "$2" "$3"; drift=$((drift+1)); fi
}
cmp_f pid "$b_pid" "$a_pid"
cmp_f started "$b_start" "$a_start"
cmp_f binary "$b_bin" "$a_bin"
cmp_f corefile "$b_core" "$a_core"
cmp_f plist "$b_plist" "$a_plist"
cmp_f listeners "$b_lsn" "$a_lsn"
cmp_f ports "$b_ports" "$a_ports"
cmp_f dc1-arm-1 "$b_a1" "$a_a1"
cmp_f dc1-x86 "$b_a2" "$a_a2"
cmp_f keel-dev "$b_a3" "$a_a3"

echo
echo "  — nothing disposable survived —"
leftover=0
check_clean() {  # check_clean <label> <value>
  if [ -z "$2" ]; then echo "  clean     $1"; else echo "  LEFTOVER  $1: $2"; leftover=$((leftover+1)); fi
}
check_clean "no disposable launchd label" \
  "$(sudo launchctl list 2>/dev/null | awk '/org\.dc1\.semaphoredisposable/{print $3}')"
check_clean "no disposable semaphore process" "$(pgrep -fl 'semaphore-disposable' 2>/dev/null)"
check_clean "no disposable prefix on disk" \
  "$(find "${TMPDIR:-/tmp}" /tmp -maxdepth 1 -name 'semaphore-disposable.*' 2>/dev/null)"
check_clean "no disposable plist in /Library/LaunchDaemons" \
  "$(find /Library/LaunchDaemons -maxdepth 1 -name 'org.dc1.semaphoredisposable*' 2>/dev/null)"
# ⚠️ THE PRODUCTION LABEL MUST NOT HAVE APPEARED. This milestone does not
# deploy Semaphore; if the real daemon exists after a disposable test, the
# harness escaped its overrides.
check_clean "no PRODUCTION semaphore daemon was created" \
  "$(sudo launchctl list 2>/dev/null | awk '$3 == "org.dc1.semaphore" {print $3}')"
check_clean "no production Semaphore paths were created" \
  "$(ls -d /usr/local/etc/semaphore /usr/local/var/lib/semaphore 2>/dev/null)"
check_clean "no _semaphore service account was created" "$(id _semaphore 2>/dev/null)"
# ⚠️ AND NO DISPOSABLE IDENTITY SURVIVED EITHER. The gate runs with
# --with-account, so a real account existed during the run; an orphaned
# `_semt*` record is the worst residue this test can leave.
check_clean "no disposable _semt account survives" \
  "$(dscl . -list /Users 2>/dev/null | grep '^_semt' | tr '\n' ' ')"
check_clean "no disposable _semt group survives" \
  "$(dscl . -list /Groups 2>/dev/null | grep '^_semt' | tr '\n' ' ')"

hdr "PHASE 6  repository integrity"
git worktree remove --force "$WT" 2>/dev/null && echo "  removed worktree $WT" \
  || echo "  NOTE: worktree not removed automatically: $WT"
git worktree prune
[ -e "$WT" ] && { echo "  LEFTOVER  $WT still exists"; leftover=$((leftover+1)); } \
  || echo "  clean     worktree path gone"
cmp_f branch "$CANON_BRANCH_BEFORE" "$(git rev-parse --abbrev-ref HEAD)"
cmp_f head "$CANON_HEAD_BEFORE" "$(git rev-parse HEAD)"
[ -z "$(git status --porcelain -uno)" ] && echo "  same      canonical worktree still clean" \
  || { echo "  DIFFERENT canonical worktree is now dirty"; drift=$((drift+1)); }
[ -e "$CANON/$PROTECTED" ] && echo "  same      protected backup still present" \
  || { echo "  DIFFERENT protected backup is GONE"; drift=$((drift+1)); }

hdr "VERDICT"
echo "  harness exit status      $HARNESS_RC"
echo "  live-state differences   $drift"
echo "  leftovers                $leftover"
echo "  evidence                 $EVID"
echo
if [ "$HARNESS_RC" -eq 0 ] && [ "$drift" -eq 0 ] && [ "$leftover" -eq 0 ]; then
  echo "SEMAPHORE macOS LAUNCHD END-TO-END: PASS"
  echo "Live CoreDNS is bit-for-bit unchanged; nothing disposable survived;"
  echo "no production Semaphore service, path or account was created."
  FINAL=0
else
  echo "SEMAPHORE macOS LAUNCHD END-TO-END: NOT A PASS"
  [ "$HARNESS_RC" -ne 0 ] && echo "  - the harness itself failed (exit $HARNESS_RC)"
  [ "$drift" -ne 0 ] && echo "  - the live resolver differs from its baseline — DO NOT repair; report it"
  [ "$leftover" -ne 0 ] && echo "  - disposable or production state survived"
  FINAL=1
fi
echo
echo "FINAL EXIT CODE: $FINAL"
exit $FINAL
