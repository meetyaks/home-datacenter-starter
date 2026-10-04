#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════
# PR #18 PRE-MERGE GATE — disposable macOS launchd harness on dc1-arm-1.
#
# Runs the canonical harness from an isolated detached worktree at the exact
# PR head, beside the live resolver, and proves the live resolver is
# bit-for-bit unchanged afterwards.
#
# Touches: a new worktree under $HOME, and whatever the harness creates in its
# own mktemp prefix. Nothing else. The canonical checkout is never switched,
# reset, cleaned or committed to.
# ═══════════════════════════════════════════════════════════════════════════
set -uo pipefail

# ⚠️ THE REVIEWED COMMIT IS AN ARGUMENT, NOT A CONSTANT. Baking a SHA into a
# file that lives in the repository is self-defeating: committing the file
# changes the head, so the constant is stale the moment it exists. The caller
# passes the SHA they reviewed, and this script refuses to run unless the
# commit it actually checks out equals that value exactly.
PR_HEAD="${1:-}"
[ -n "$PR_HEAD" ] || { echo "usage: $0 <full-40-character-pr-head-sha>" >&2; exit 2; }
[ "${#PR_HEAD}" -eq 40 ] || { echo "the PR head must be a full 40-character SHA, got '${PR_HEAD}'" >&2; exit 2; }
case "$PR_HEAD" in
  *[!0-9a-f]*) echo "the PR head must be lowercase hexadecimal" >&2; exit 2 ;;
esac
CANON="$HOME/Projects/home-datacenter-starter"
PROTECTED="inventory/group_vars/linux_servers/vault.yml.backup-20261001T091734Z"
STAMP=$(date +%Y%m%dT%H%M%SZ)-$$
WT="$HOME/dc1-gate-worktree-$STAMP"
EVID="$HOME/dc1-gate-evidence-$STAMP"

die() { echo; echo "BLOCKED: $*" >&2; echo "Nothing was changed." >&2; exit 2; }
hdr() { echo; echo "═══ $* ═══"; }


# ── PHASE 1: refuse unless this is exactly the right machine and state ─────
hdr "PHASE 1  preconditions"

[ "$(hostname -s)" = "dc1-arm-1" ] || die "hostname is $(hostname -s), expected dc1-arm-1"
echo "  hostname        dc1-arm-1"

[ "$(id -un)" = "dc1-arm-1" ] || die "user is $(id -un), expected dc1-arm-1"
echo "  user            dc1-arm-1"

[ "$(uname -s)" = "Darwin" ] || die "not macOS; the launchd path cannot be exercised"
echo "  platform        Darwin $(uname -r)"

[ -d "$CANON/.git" ] || die "canonical repo not found at $CANON"
echo "  canonical repo  $CANON"

cd "$CANON" || die "cannot enter $CANON"

# -uno: untracked files are neither inspected nor listed, so the protected
# backup is never named, let alone read.
DIRTY=$(git status --porcelain -uno)
[ -z "$DIRTY" ] || { echo "$DIRTY" | sed 's/^/    /'; die "canonical repo has tracked or staged changes; refusing"; }
echo "  canonical state clean (tracked + staged)"

CANON_BRANCH_BEFORE=$(git rev-parse --abbrev-ref HEAD)
CANON_HEAD_BEFORE=$(git rev-parse HEAD)
echo "  canonical branch $CANON_BRANCH_BEFORE"
echo "  canonical HEAD   $CANON_HEAD_BEFORE"

# Existence only. Never read, print, move, rename, delete, stage or commit.
if [ -e "$CANON/$PROTECTED" ]; then
  echo "  protected backup present (existence tested only)"
  PROTECTED_BEFORE=present
else
  die "the protected backup is missing BEFORE the test; refusing to proceed"
fi

command -v ansible-playbook >/dev/null || die "ansible-playbook not on PATH"
command -v dig >/dev/null             || die "dig not on PATH"
command -v lsof >/dev/null            || die "lsof not on PATH"
echo "  tooling         ansible-playbook, dig, lsof present"

# ── Fetch the exact PR head, and prove it is the exact PR head ─────────────
hdr "PHASE 1  fetch the exact PR head"

git fetch --quiet origin fix/coredns-end-to-end-lifecycle || die "fetch failed"
FETCHED=$(git rev-parse FETCH_HEAD)
echo "  fetched         $FETCHED"
echo "  expected        $PR_HEAD"
[ "$FETCHED" = "$PR_HEAD" ] || die "fetched commit does not equal the recorded PR head; refusing"
echo "  MATCH — proceeding with the exact reviewed commit"

# ── Isolated detached worktree. The canonical checkout is NOT switched. ────
hdr "PHASE 1  isolated detached worktree"
git worktree add --quiet --detach "$WT" "$PR_HEAD" || die "could not create the worktree"
WT_HEAD=$(git -C "$WT" rev-parse HEAD)
[ "$WT_HEAD" = "$PR_HEAD" ] || die "worktree HEAD $WT_HEAD != $PR_HEAD"
echo "  worktree        $WT"
echo "  worktree HEAD   $WT_HEAD (detached)"

# ── sudo, primed once, interactively ───────────────────────────────────────
hdr "sudo"
echo "The baseline reads root-owned listeners and the harness installs a"
echo "launchd system daemon. You will be prompted now, and possibly again."
sudo -v || die "sudo was refused; the gate cannot run"

# ── PHASE 4: live baseline ─────────────────────────────────────────────────
hdr "PHASE 4  live CoreDNS baseline"

# Created only now, after every precondition has passed: a refused run leaves
# nothing behind at all, not even an empty evidence directory.
mkdir -p "$EVID" || die "cannot create $EVID"

LIVE_LABEL=org.coredns.coredns
LIVE_PLIST=/Library/LaunchDaemons/$LIVE_LABEL.plist

b_pid=$(pgrep -f '[c]oredns -conf /usr/local/etc/coredns/Corefile' | head -1)
[ -n "$b_pid" ] || die "no live CoreDNS process found; the non-interference proof would be vacuous"
b_start=$(ps -p "$b_pid" -o lstart= | sed 's/  */ /g')
b_bin=$(shasum -a 256 /usr/local/sbin/coredns        | awk '{print $1}')
b_core=$(shasum -a 256 /usr/local/etc/coredns/Corefile | awk '{print $1}')
b_zone=$(shasum -a 256 /usr/local/etc/coredns/db.dc1.lan | awk '{print $1}')
b_plist=$(shasum -a 256 "$LIVE_PLIST"                | awk '{print $1}')
b_state=$(sudo launchctl print "system/$LIVE_LABEL" 2>/dev/null | awk '/state = /{print $3; exit}')
b_lsn=$(sudo lsof -nP -iTCP -sTCP:LISTEN -iUDP 2>/dev/null \
        | awk '$1 ~ /^coredns/ {print $8, $9}' | sort -u | tr '\n' ';')
ports_listen() {
  for p in 53 8080 8181 8653 8654; do
    if sudo lsof -nP -iTCP:"$p" -sTCP:LISTEN -iUDP:"$p" >/dev/null 2>&1; then
      printf '%s=open ' "$p"; else printf '%s=closed ' "$p"; fi
  done
}
b_ports=$(ports_listen)
answer() { dig +short +time=3 +tries=1 @127.0.0.1 "$1" A 2>/dev/null | tr '\n' ' '; }
rcode()  { dig +time=3 +tries=1 @127.0.0.1 "$1" A 2>/dev/null | awk '/status:/{print $6; exit}' | tr -d ','; }
b_a1=$(answer dc1-arm-1.dc1.lan); b_a2=$(answer dc1-x86.dc1.lan)
b_a3=$(answer keel-dev.dc1.lan);  b_a4=$(rcode  keel.dc1.lan)

{
  echo "label      $LIVE_LABEL"
  echo "pid        $b_pid"
  echo "started    $b_start"
  echo "state      ${b_state:-unknown}"
  echo "binary     $b_bin"
  echo "corefile   $b_core"
  echo "zone       $b_zone"
  echo "plist      $b_plist"
  echo "listeners  $b_lsn"
  echo "ports      $b_ports"
  echo "dc1-arm-1  $b_a1"
  echo "dc1-x86    $b_a2"
  echo "keel-dev   $b_a3"
  echo "keel       $b_a4"
} | tee "$EVID/baseline.txt" | sed 's/^/  /'

for v in b_pid b_start b_bin b_core b_zone b_plist b_a1 b_a2 b_a3 b_a4; do
  eval "val=\$$v"
  [ -n "$val" ] || die "baseline field $v is empty; the comparison would be vacuous"
done
echo "  baseline complete and non-empty"

# ── PHASE 5: run the canonical harness from the worktree ───────────────────
hdr "PHASE 5  execute tests/run-coredns-launchd.sh from the worktree"
echo "  (this runs the role three times; expect a few minutes and maybe a sudo re-prompt)"
echo

cd "$WT" || die "cannot enter the worktree"
tests/run-coredns-launchd.sh 2>&1 | tee "$EVID/harness.log"
HARNESS_RC=${PIPESTATUS[0]}
cd "$CANON" || die "cannot return to $CANON"

echo
echo "  harness exit status: $HARNESS_RC"
for f in /tmp/coredns-disp-1.log /tmp/coredns-disp-2.log /tmp/coredns-disp-3.log; do
  [ -f "$f" ] && cp "$f" "$EVID/" 2>/dev/null
done

# ── PHASE 6: live non-interference, independent of the harness's own claim ─
hdr "PHASE 6  live CoreDNS non-interference (independent re-measurement)"

a_pid=$(pgrep -f '[c]oredns -conf /usr/local/etc/coredns/Corefile' | head -1)
a_start=$([ -n "$a_pid" ] && ps -p "$a_pid" -o lstart= | sed 's/  */ /g')
a_bin=$(shasum -a 256 /usr/local/sbin/coredns 2>/dev/null | awk '{print $1}')
a_core=$(shasum -a 256 /usr/local/etc/coredns/Corefile 2>/dev/null | awk '{print $1}')
a_zone=$(shasum -a 256 /usr/local/etc/coredns/db.dc1.lan 2>/dev/null | awk '{print $1}')
a_plist=$(shasum -a 256 "$LIVE_PLIST" 2>/dev/null | awk '{print $1}')
a_state=$(sudo launchctl print "system/$LIVE_LABEL" 2>/dev/null | awk '/state = /{print $3; exit}')
a_lsn=$(sudo lsof -nP -iTCP -sTCP:LISTEN -iUDP 2>/dev/null \
        | awk '$1 ~ /^coredns/ {print $8, $9}' | sort -u | tr '\n' ';')
a_ports=$(ports_listen)
a_a1=$(answer dc1-arm-1.dc1.lan); a_a2=$(answer dc1-x86.dc1.lan)
a_a3=$(answer keel-dev.dc1.lan);  a_a4=$(rcode  keel.dc1.lan)

drift=0
cmp_f() {
  if [ "$2" = "$3" ]; then printf '  same      %-12s %s\n' "$1" "$2"
  else printf '  DIFFERENT %-12s before=%s after=%s\n' "$1" "$2" "$3"; drift=$((drift+1)); fi
}
cmp_f pid       "$b_pid"    "$a_pid"
cmp_f started   "$b_start"  "$a_start"
cmp_f state     "$b_state"  "$a_state"
cmp_f binary    "$b_bin"    "$a_bin"
cmp_f corefile  "$b_core"   "$a_core"
cmp_f zone      "$b_zone"   "$a_zone"
cmp_f plist     "$b_plist"  "$a_plist"
cmp_f listeners "$b_lsn"    "$a_lsn"
cmp_f ports     "$b_ports"  "$a_ports"
cmp_f dc1-arm-1 "$b_a1"     "$a_a1"
cmp_f dc1-x86   "$b_a2"     "$a_a2"
cmp_f keel-dev  "$b_a3"     "$a_a3"
cmp_f keel      "$b_a4"     "$a_a4"

echo
echo "  — nothing disposable survived —"
leftover=0
stray_lbl=$(sudo launchctl list 2>/dev/null | awk '/org\.dc1\.corednsdisposable/{print $3}')
if [ -z "$stray_lbl" ]; then echo "  clean     no disposable launchd label loaded"
else echo "  LEFTOVER  disposable label(s): $stray_lbl"; leftover=$((leftover+1)); fi

stray_proc=$(pgrep -fl 'coredns-disposable' 2>/dev/null)
if [ -z "$stray_proc" ]; then echo "  clean     no disposable coredns process"
else echo "  LEFTOVER  $stray_proc"; leftover=$((leftover+1)); fi

# ⚠️ $TMPDIR, NOT a deep walk of /var/folders. `mktemp -t` creates the prefix
# directly inside $TMPDIR — on macOS something like
# /var/folders/zz/_xxx/T/coredns-disposable.AbC123 — which is four levels
# below /var/folders, so a maxdepth-2 search there would find nothing and
# report "clean" without having looked anywhere near the right place.
stray_dir=$(find "${TMPDIR:-/tmp}" /tmp -maxdepth 1 -name 'coredns-disposable.*' 2>/dev/null)
if [ -z "$stray_dir" ]; then echo "  clean     no disposable prefix on disk"
else echo "  LEFTOVER  $stray_dir"; leftover=$((leftover+1)); fi

stray_plist=$(find /Library/LaunchDaemons -maxdepth 1 -name 'org.dc1.corednsdisposable*' 2>/dev/null)
if [ -z "$stray_plist" ]; then echo "  clean     no disposable plist in /Library/LaunchDaemons"
else echo "  LEFTOVER  $stray_plist"; leftover=$((leftover+1)); fi

alias_cnt=$(ifconfig lo0 2>/dev/null | grep -c 'inet 127\.' )
if [ "$alias_cnt" = "1" ]; then echo "  clean     lo0 has exactly one 127/8 address (no alias added)"
else echo "  LEFTOVER  lo0 has $alias_cnt 127/8 addresses"; leftover=$((leftover+1)); fi

# ── PHASE 6: repository and protected-file integrity ───────────────────────
hdr "PHASE 6  repository integrity"
git worktree remove --force "$WT" 2>/dev/null && echo "  removed worktree $WT" \
  || echo "  NOTE: worktree not removed automatically: $WT"
git worktree prune
if [ -e "$WT" ]; then echo "  LEFTOVER  $WT still exists"; leftover=$((leftover+1));
else echo "  clean     worktree path gone"; fi

CANON_BRANCH_AFTER=$(git rev-parse --abbrev-ref HEAD)
CANON_HEAD_AFTER=$(git rev-parse HEAD)
cmp_f branch "$CANON_BRANCH_BEFORE" "$CANON_BRANCH_AFTER"
cmp_f head   "$CANON_HEAD_BEFORE"   "$CANON_HEAD_AFTER"
DIRTY_AFTER=$(git status --porcelain -uno)
if [ -z "$DIRTY_AFTER" ]; then echo "  same      canonical worktree still clean"
else echo "  DIFFERENT canonical worktree is now dirty:"; echo "$DIRTY_AFTER" | sed 's/^/      /'; drift=$((drift+1)); fi

if [ -e "$CANON/$PROTECTED" ]; then echo "  same      protected backup still present ($PROTECTED_BEFORE -> present)"
else echo "  DIFFERENT protected backup is GONE"; drift=$((drift+1)); fi

# ── Verdict ────────────────────────────────────────────────────────────────
hdr "VERDICT"
echo "  harness exit status      $HARNESS_RC"
echo "  live-state differences   $drift"
echo "  leftovers                $leftover"
echo "  evidence                 $EVID"
echo
if [ "$HARNESS_RC" -eq 0 ] && [ "$drift" -eq 0 ] && [ "$leftover" -eq 0 ]; then
  echo "MACOS LAUNCHD END-TO-END: PASS"
  echo "Live CoreDNS is bit-for-bit unchanged; nothing disposable survived."
  FINAL=0
else
  echo "MACOS LAUNCHD END-TO-END: NOT A PASS"
  [ "$HARNESS_RC" -ne 0 ] && echo "  - the harness itself failed (exit $HARNESS_RC)"
  [ "$drift"      -ne 0 ] && echo "  - the live resolver differs from its baseline — DO NOT repair; report it"
  [ "$leftover"   -ne 0 ] && echo "  - disposable state survived teardown"
  FINAL=1
fi
echo
echo "FINAL EXIT CODE: $FINAL"
exit $FINAL
