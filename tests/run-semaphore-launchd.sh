#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# THE SEMAPHORE ROLE, EXECUTED ON macOS launchd, DISPOSABLY.
#
#   tests/run-semaphore-launchd.sh                 GREEN, no account
#   tests/run-semaphore-launchd.sh --with-account  GREEN, real disposable account
#   tests/run-semaphore-launchd.sh --red           RED: prove the flush is needed
#
# ⚠️ WHAT THIS PROVES. It exercises the Darwin artifact, the bsdtar
# extraction path, launchd bootstrap, the health endpoint, restart-before-
# verification and idempotence — the half of the role the Linux container
# cannot reach.
#
# ⚠️ TWO IDENTITY MODES, AND THE DIFFERENCE MATTERS.
#
#   default          runs as the invoking user, creates NO account. This is
#                    what a workstation should do: creating and deleting a
#                    real hidden dscl account there is a permanent change a
#                    disposable test must not make.
#
#   --with-account   creates a REAL macOS account `_semt<8 hex>` and its
#                    group, runs the production account-management tasks
#                    against it, measures the result from Directory
#                    Services, and removes both records exactly. This is
#                    what the controller gate runs, because the dscl path
#                    IS production's path and cannot be proved any other
#                    way.
#
# `_semaphore` — production's identity — is never created, modified or
# deleted by either mode, and both assert its absence.
#
# Everything else is disposable: a mktemp prefix, a unique launchd label, a
# free high port, throwaway secrets and its own database. The live CoreDNS
# resolver's PID, files and answers are recorded before and compared after.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || { echo "cannot reach the repository root" >&2; exit 1; }

MODE=${1:-}
PROMPTS=0

pass=0
fail=0
ok()   { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }

if [ "$(uname -s)" != "Darwin" ]; then
  skip "not macOS — the launchd path cannot be exercised here."
  echo; echo "SKIPPED — this suite is macOS-only and is proved on the management node."
  exit 0
fi

STAMP=$$-$(date +%s)
ROOT=$(mktemp -d -t semaphore-disposable.XXXXXX)
LABEL="org.dc1.semaphoredisposable${STAMP}"

# ── THE DISPOSABLE SERVICE IDENTITY ────────────────────────────────────────
#
# ⚠️ WITH --with-account THIS CREATES AND DESTROYS A REAL macOS ACCOUNT.
# Without it the harness runs as the invoking user and creates nothing —
# which is what a workstation should do. The controller gate uses
# --with-account, because the dscl path is production's path and cannot be
# proved any other way.
#
# The name is `_semt<8 hex>`: 13 characters, underscore-prefixed like every
# macOS service account, well inside the short-name limit, and unique per
# run so two gates cannot collide. It is NEVER `_semaphore` — production's
# identity is not created, modified or deleted by any test.
WITH_ACCOUNT=no
[ "$MODE" = "--with-account" ] && { WITH_ACCOUNT=yes; MODE=""; }

TEST_USER=""
TEST_GROUP=""
if [ "$WITH_ACCOUNT" = yes ]; then
  TEST_USER="_semt$(openssl rand -hex 4)"
  TEST_GROUP="$TEST_USER"
  # Validity, checked rather than assumed: lowercase, underscore-led, short.
  case "$TEST_USER" in
    _semt[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) : ;;
    *) echo "generated an invalid test account name: $TEST_USER" >&2; exit 1 ;;
  esac
  [ "${#TEST_USER}" -le 20 ] || { echo "test account name too long" >&2; exit 1; }
  [ "$TEST_USER" = "_semaphore" ] && { echo "refusing: generated the PRODUCTION name" >&2; exit 1; }
fi
PLIST="$ROOT/${LABEL}.plist"

# Exits that happen before the teardown trap is armed must still take the
# prefix with them.
early_abort() {
  case "$ROOT" in
    /*/semaphore-disposable.*) rm -rf "$ROOT" && echo "  removed $ROOT" ;;
    *) echo "  REFUSING to remove unexpected path: $ROOT" ;;
  esac
  echo "Nothing disposable was created. No host state was changed." >&2
  exit 1
}

free_port() {
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}
PORT1=$(free_port); PORT2=$(free_port)
# ⚠️ DISTINCTNESS IS NOT GUARANTEED BY THE KERNEL. Each free_port is a
# separate process; nothing stops the ephemeral cursor handing out the same
# number twice, and two equal ports would fail the run for a reason that has
# nothing to do with the role. This gate gets one operator run.
if [ "$PORT1" = "$PORT2" ]; then
  bad "the two disposable ports are distinct" "both came back as $PORT1 — re-run"
  early_abort
fi

echo "Disposable identity for this run:"
echo "  root   $ROOT"
echo "  label  $LABEL"
echo "  ports  $PORT1 then $PORT2"
if [ "$WITH_ACCOUNT" = yes ]; then
  echo "  user   $TEST_USER  (a REAL disposable account will be created and removed)"
  echo "  group  $TEST_GROUP"
else
  echo "  user   $(id -un)  (no service account is created — see the header)"
fi

# ── PRE-FLIGHT: THE DISPOSABLE IDENTITY MUST NOT ALREADY EXIST ─────────────
#
# ⚠️ MEASURED FROM DIRECTORY SERVICES, NOT INFERRED. `dscl . -read` exits 56
# when a record is absent and 0 when it is present — verified on macOS, as
# is `id`, which exits 1. Those exact codes are what these checks rely on.
if [ "$WITH_ACCOUNT" = yes ]; then
  # Production's identity must be absent, and stays absent: this milestone
  # does not create it.
  if dscl . -read /Users/_semaphore >/dev/null 2>&1; then
    bad "_semaphore is absent before the test" "the production account already exists"
    early_abort
  fi
  ok "_semaphore is absent (production identity untouched)"

  for _rec in "/Users/$TEST_USER" "/Groups/$TEST_GROUP"; do
    if dscl . -read "$_rec" >/dev/null 2>&1; then
      bad "the disposable identity is free" "$_rec already exists"
      early_abort
    fi
  done
  ok "neither $TEST_USER nor group $TEST_GROUP exists yet"

  # Every UID and GID currently in use, so a collision can be proved absent
  # afterwards rather than assumed.
  UIDS_BEFORE=$(dscl . -list /Users UniqueID | awk '{print $NF}' | sort -n | tr '\n' ' ')
  GIDS_BEFORE=$(dscl . -list /Groups PrimaryGroupID | awk '{print $NF}' | sort -n | tr '\n' ' ')
  [ -n "$UIDS_BEFORE" ] && [ -n "$GIDS_BEFORE" ] \
    && ok "recorded the UID and GID sets in use ($(printf '%s' "$UIDS_BEFORE" | wc -w | tr -d ' ') users, $(printf '%s' "$GIDS_BEFORE" | wc -w | tr -d ' ') groups)" \
    || { bad "UID/GID sets recorded" "directory services returned nothing"; early_abort; }

  # Production Semaphore must not exist either — this test must never be
  # mistaken for, or interfere with, a real installation.
  for _p in /usr/local/etc/semaphore /usr/local/var/lib/semaphore \
            /Library/LaunchDaemons/org.dc1.semaphore.plist; do
    if [ -e "$_p" ]; then
      bad "no production Semaphore state exists" "$_p is present"
      early_abort
    fi
  done
  ok "no production Semaphore paths, and no production launchd plist"

  if sudo -n launchctl print system/org.dc1.semaphore >/dev/null 2>&1; then
    bad "no production Semaphore service is loaded" "org.dc1.semaphore exists"
    early_abort
  fi
  ok "no production Semaphore service is loaded"
fi

# ── Record the LIVE resolver, so non-interference is proved, not hoped ─────
LIVE_LABEL=org.coredns.coredns
LIVE_PLIST=/Library/LaunchDaemons/${LIVE_LABEL}.plist
live_pid() { pgrep -f '[c]oredns -conf /usr/local/etc/coredns/Corefile' | head -1; }
live_fp()  { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

LIVE_PID_BEFORE=$(live_pid)
LIVE_COREFILE_BEFORE=$(live_fp /usr/local/etc/coredns/Corefile)
LIVE_BIN_BEFORE=$(live_fp /usr/local/sbin/coredns)
LIVE_PLIST_BEFORE=$(live_fp "$LIVE_PLIST")
LIVE_ANSWER_BEFORE=$(dig +short +time=3 +tries=1 @127.0.0.1 keel-dev.dc1.lan A 2>/dev/null | tr '\n' ' ')

# ⚠️ AN EMPTY BASELINE PROVES NOTHING. Every "unchanged" check below is an
# equality test; if these came back empty, "" = "" would hold afterwards and
# the harness would report passes having measured nothing.
for _probe in "LIVE_PID_BEFORE:$LIVE_PID_BEFORE" \
              "LIVE_COREFILE_BEFORE:$LIVE_COREFILE_BEFORE" \
              "LIVE_BIN_BEFORE:$LIVE_BIN_BEFORE" \
              "LIVE_PLIST_BEFORE:$LIVE_PLIST_BEFORE" \
              "LIVE_ANSWER_BEFORE:$LIVE_ANSWER_BEFORE"; do
  if [ -z "${_probe#*:}" ]; then
    bad "the live baseline is non-empty before anything disposable starts" \
        "${_probe%%:*} is empty — every non-interference check below would compare '' with '' and pass without measuring anything. Is the live CoreDNS running?"
    echo "REFUSING TO RUN — the non-interference baseline could not be established." >&2
    early_abort
  fi
done
ok "the live baseline is non-empty (pid, binary, Corefile, plist, answer)"

DISPOSABLE_PID=""
MAIN=roles/semaphore/tasks/main.yml
MAIN_BACKUP="$ROOT/main.yml.orig"
RED_APPLIED=no

apply_red() {
  cp "$MAIN" "$MAIN_BACKUP"
  # Remove the WHOLE task, spanning its comment block. Deleting only the
  # `meta:` line leaves an orphaned `- name:`, Ansible dies parsing, and the
  # RED checks then pass trivially against a run that never started.
  perl -0pi -e 's{- name: Apply every pending restart[^\n]*\n(?:  \#[^\n]*\n|\n)*  ansible\.builtin\.meta: flush_handlers\n}{}' "$MAIN"
  RED_APPLIED=yes
  grep -q 'flush_handlers' "$MAIN" && { bad "RED: the flush was removed" "still present"; return 1; }
  grep -q 'Apply every pending restart' "$MAIN" && {
    bad "RED: no orphaned task left behind" "the name survived without its module"; return 1; }
  echo "  (flush removed from $MAIN for this run; restored in teardown)"
}

restore_red() {
  [ "$RED_APPLIED" = yes ] || return 0
  [ -f "$MAIN_BACKUP" ] || { echo "  WARNING: no backup to restore $MAIN from"; return 1; }
  cp "$MAIN_BACKUP" "$MAIN"
  grep -q 'flush_handlers' "$MAIN" \
    && echo "  restored the flush in $MAIN" \
    || echo "  WARNING: $MAIN lacks the flush after restore — CHECK git status"
}

# Teardown needs root. Re-authenticate rather than fail silently once the
# sudo grace period lapses, or a root-owned daemon and prefix are left behind
# while the harness prints a clean teardown.
tsudo() {
  if sudo -n true 2>/dev/null; then sudo -n "$@"; else
    echo "  (sudo timestamp expired — re-authenticating to finish teardown)" >&2
    sudo "$@"
  fi
}

teardown() {
  restore_red
  echo
  echo "── teardown (runs on success, failure and interrupt) ──"
  if tsudo launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    tsudo launchctl bootout "system/${LABEL}" >/dev/null 2>&1 \
      && echo "  booted out ${LABEL}" || echo "  bootout of ${LABEL} returned non-zero"
  else
    echo "  ${LABEL} was not loaded"
  fi

  # Identify by PREFIX, never by a PID captured minutes ago: between a
  # `kill -0` and a `ps` the process can exit, and a process that WAS ours
  # then reads as somebody else's and is spared.
  for _p in $(pgrep -f "$ROOT/sbin/semaphore" 2>/dev/null); do
    tsudo kill "$_p" 2>/dev/null && echo "  killed disposable pid $_p"
  done
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -f "$ROOT/sbin/semaphore" >/dev/null 2>&1 || break
    sleep 1
  done
  _still=$(pgrep -f "$ROOT/sbin/semaphore" 2>/dev/null | tr '\n' ' ')
  [ -n "$_still" ] && tsudo kill -9 $_still 2>/dev/null && echo "  force-killed $_still"

  # ── STEP 4: FILES FIRST, WHILE THE IDENTITY STILL RESOLVES ──────────────
  #
  # ⚠️ ORDER MATTERS AND THIS IS THE REASON. Removing the account before its
  # files leaves them owned by a uid that no longer resolves — orphaned
  # ownership that a later account could silently inherit. Files go while
  # the identity is still there to own them.
  case "$ROOT" in
    /*/semaphore-disposable.*) tsudo rm -rf "$ROOT" && echo "  removed $ROOT" ;;
    *) echo "  REFUSING to remove unexpected path: $ROOT" ;;
  esac

  # ── STEPS 5-8: THE EXACT ACCOUNT AND GROUP RECORDS ──────────────────────
  if [ "$WITH_ACCOUNT" = yes ] && [ -n "$TEST_USER" ]; then
    # ⚠️ EXACT RECORD PATHS, NEVER A PARTIAL NAME. `dscl . -delete` takes a
    # full record path; there is no pattern matching and no prefix deletion
    # anywhere in this teardown.
    case "$TEST_USER" in
      _semt[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) : ;;
      *) echo "  REFUSING to delete an unexpected account name: $TEST_USER"; TEST_USER="" ;;
    esac
  fi
  if [ "$WITH_ACCOUNT" = yes ] && [ -n "$TEST_USER" ]; then
    if [ "$TEST_USER" = "_semaphore" ]; then
      echo "  REFUSING: that is the PRODUCTION account"
    else
      tsudo dscl . -delete "/Users/$TEST_USER" >/dev/null 2>&1 \
        && echo "  deleted user record /Users/$TEST_USER" \
        || echo "  user record /Users/$TEST_USER was not present"
      tsudo dscl . -delete "/Groups/$TEST_GROUP" >/dev/null 2>&1 \
        && echo "  deleted group record /Groups/$TEST_GROUP" \
        || echo "  group record /Groups/$TEST_GROUP was not present"
      tsudo dscacheutil -flushcache >/dev/null 2>&1
      tsudo killall -HUP opendirectoryd >/dev/null 2>&1

      # Steps 8-9: prove they no longer resolve, and that nothing is left
      # owned by the freed uid inside the disposable roots.
      if dscl . -read "/Users/$TEST_USER" >/dev/null 2>&1; then
        bad "the disposable user record is gone" "/Users/$TEST_USER still resolves"
      else ok "the disposable user record is gone"; fi
      if dscl . -read "/Groups/$TEST_GROUP" >/dev/null 2>&1; then
        bad "the disposable group record is gone" "/Groups/$TEST_GROUP still resolves"
      else ok "the disposable group record is gone"; fi
      if id "$TEST_USER" >/dev/null 2>&1; then
        bad "the disposable identity no longer resolves" "id $TEST_USER still succeeds"
      else ok "id $TEST_USER no longer resolves"; fi
      if [ -n "${T_UID:-}" ] && dscl . -search /Users UniqueID "$T_UID" 2>/dev/null | grep -q .; then
        bad "the freed uid resolves to nothing" "uid $T_UID is still claimed"
      else ok "uid ${T_UID:-?} is no longer claimed"; fi
      if [ -e "$ROOT" ]; then
        bad "no file remains in the disposable root" "$ROOT still exists"
      else ok "no file remains owned by the removed identity (its root is gone)"; fi
      # ⚠️ _semaphore MUST STILL BE ABSENT. If this test ever created or
      # removed production's identity, that is the thing to find out about.
      if dscl . -read /Users/_semaphore >/dev/null 2>&1; then
        bad "_semaphore remains absent" "the PRODUCTION account now exists"
      else ok "_semaphore remains absent"; fi
    fi
  fi

  echo "── live-resolver non-interference ──"
  local a_pid a_core a_bin a_plist a_ans
  a_pid=$(live_pid); a_core=$(live_fp /usr/local/etc/coredns/Corefile)
  a_bin=$(live_fp /usr/local/sbin/coredns); a_plist=$(live_fp "$LIVE_PLIST")
  a_ans=$(dig +short +time=3 +tries=1 @127.0.0.1 keel-dev.dc1.lan A 2>/dev/null | tr '\n' ' ')

  [ "$a_pid" = "$LIVE_PID_BEFORE" ] && ok "live CoreDNS PID unchanged (${a_pid:-none})" \
    || bad "live PID unchanged" "was ${LIVE_PID_BEFORE:-none}, now ${a_pid:-none}"
  [ "$a_core" = "$LIVE_COREFILE_BEFORE" ] && ok "live Corefile fingerprint unchanged" \
    || bad "live Corefile unchanged" "changed"
  [ "$a_bin" = "$LIVE_BIN_BEFORE" ] && ok "live CoreDNS binary unchanged" \
    || bad "live binary unchanged" "changed"
  [ "$a_plist" = "$LIVE_PLIST_BEFORE" ] && ok "live CoreDNS plist unchanged" \
    || bad "live plist unchanged" "changed"
  [ "$a_ans" = "$LIVE_ANSWER_BEFORE" ] && ok "live resolver still answers identically" \
    || bad "live answers unchanged" "was '$LIVE_ANSWER_BEFORE' now '$a_ans'"

  [ -e "$PLIST" ] && bad "no disposable plist survives" "$PLIST still exists" \
    || ok "no disposable plist survives"
  [ -e "$ROOT" ] && bad "no disposable prefix survives" "$ROOT still exists" \
    || ok "no disposable prefix survives"
  if tsudo launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    bad "no disposable launchd label survives" "system/${LABEL} is still loaded"
  else ok "no disposable launchd label survives"; fi

  # ⚠️ RESIDUE INCLUDES THE IDENTITY, NOT JUST FILES. An account left behind
  # is the worst outcome of this test, so it is checked here too and the
  # recovery commands name the exact records.
  _residue=no
  [ -e "$ROOT" ] && _residue=yes
  pgrep -f "$ROOT/sbin/semaphore" >/dev/null 2>&1 && _residue=yes
  tsudo launchctl print "system/${LABEL}" >/dev/null 2>&1 && _residue=yes
  if [ "$WITH_ACCOUNT" = yes ] && [ -n "$TEST_USER" ]; then
    dscl . -read "/Users/$TEST_USER" >/dev/null 2>&1 && _residue=yes
    dscl . -read "/Groups/$TEST_GROUP" >/dev/null 2>&1 && _residue=yes
  fi
  if [ "$_residue" = yes ]; then
    echo
    echo "  ╭─ TEARDOWN DID NOT COMPLETE ─────────────────────────────────"
    echo "  │ Run exactly these, in this order. They name only this run's"
    echo "  │ own label, prefix and records — nothing is matched by prefix"
    echo "  │ or pattern:"
    echo "  │"
    echo "  │   sudo launchctl bootout system/${LABEL}"
    echo "  │   sudo pkill -f '${ROOT}/sbin/semaphore'"
    echo "  │   sudo rm -rf '${ROOT}'"
    if [ "$WITH_ACCOUNT" = yes ] && [ -n "$TEST_USER" ]; then
      echo "  │   sudo dscl . -delete '/Users/${TEST_USER}'"
      echo "  │   sudo dscl . -delete '/Groups/${TEST_GROUP}'"
      echo "  │   sudo dscacheutil -flushcache"
      echo "  │"
      echo "  │ Do NOT delete any account whose name is not exactly"
      echo "  │ ${TEST_USER}. In particular _semaphore is production's"
      echo "  │ identity and is not created or removed by this test."
    fi
    echo "  ╰──────────────────────────────────────────────────────────────"
    bad "teardown completed without residue" "see the recovery commands above"
  fi

  echo
  if [ "$fail" -gt 0 ]; then
    echo "FAILED: $fail of $((pass + fail)) checks." >&2
    exit 1
  fi
  echo "PASS — $pass checks."
}
trap teardown EXIT INT TERM

echo
echo "This test needs sudo (the role installs a launchd system daemon)."
# ⚠️ DENIED SUDO IS A FAILURE, NOT A SKIP. A run that could not reach
# launchd has not passed, and must not be reportable as one.
if ! sudo -v; then
  bad "sudo was granted, so the launchd path can be exercised" \
      "sudo was refused — nothing was installed, started or verified"
  exit 1
fi

# Throwaway secrets, in a 0600 file — never on a command line.
cat > "$ROOT/secrets.json" <<JSON
{
  "vault_semaphore_cookie_hash": "$(openssl rand -base64 32)",
  "vault_semaphore_cookie_encryption": "$(openssl rand -base64 32)",
  "vault_semaphore_access_key_encryption": "$(openssl rand -base64 32)",
  "vault_semaphore_admin_password": "Disposable-$(openssl rand -hex 12)"
}
JSON
chmod 600 "$ROOT/secrets.json"

run_role() {   # run_role <port> <logfile>
  # ⚠️ --ask-become-pass: macOS sudo tickets are TTY-scoped, and Ansible's
  # become runs `sudo -n` in a pipe-wired subprocess that cannot see the
  # ticket `sudo -v` just cached. getpass prompts on /dev/tty, so the
  # password reaches neither this log nor the process table.
  echo "  (Ansible will ask for your BECOME password — prompt $((++PROMPTS)) of 3)" >&2
  ansible-playbook --ask-become-pass -i localhost, -c local \
    tests/container/semaphore-disposable-play.yml \
    -e @"$ROOT/secrets.json" \
    -e semaphore_libexec_dir="$ROOT/libexec" \
    -e semaphore_bin_link="$ROOT/sbin/semaphore" \
    -e semaphore_conf_dir="$ROOT/etc" \
    -e semaphore_state_dir="$ROOT/state" \
    -e semaphore_log_dir="$ROOT/log" \
    -e semaphore_launchd_label="$LABEL" \
    -e semaphore_launchd_plist="$PLIST" \
    -e semaphore_manage_account="$([ "$WITH_ACCOUNT" = yes ] && echo true || echo false)" \
    -e semaphore_user="$([ "$WITH_ACCOUNT" = yes ] && echo "$TEST_USER" || id -un)" \
    -e semaphore_group="$([ "$WITH_ACCOUNT" = yes ] && echo "$TEST_GROUP" || id -gn)" \
    -e semaphore_port="$1" \
    > "$2" 2>&1
}

disposable_pid() { pgrep -f "$ROOT/sbin/semaphore" | head -1; }

echo
echo "── 1. first run: the whole role against a disposable prefix ──"
run_role "$PORT1" /tmp/semaphore-disp-1.log
rc1=$?
if [ $rc1 -ne 0 ]; then
  bad "the role converges on a clean disposable prefix" "exit $rc1; see /tmp/semaphore-disp-1.log"
  tail -30 /tmp/semaphore-disp-1.log | sed 's/^/           /'
  exit 1
fi
ok "the role converged (exit 0)"
DISPOSABLE_PID=$(disposable_pid)
[ -n "$DISPOSABLE_PID" ] && ok "a disposable Semaphore is running (pid $DISPOSABLE_PID)" \
  || bad "a disposable Semaphore is running" "no process under $ROOT"
grep -q 'Unpack it (macOS' /tmp/semaphore-disp-1.log \
  && ok "the macOS bsdtar extraction path executed" \
  || bad "macOS extraction path" "not present in the run log"
[ -x "$ROOT/libexec/2.19.12/semaphore" ] && ok "the versioned binary is installed" \
  || bad "versioned binary" "missing under $ROOT/libexec/2.19.12"
[ -L "$ROOT/sbin/semaphore" ] && ok "the stable link points at the version" \
  || bad "stable link" "$ROOT/sbin/semaphore is not a symlink"
[ -f "$PLIST" ] && ok "the launchd plist rendered into the prefix" \
  || bad "plist rendered" "$PLIST missing"

if [ "$WITH_ACCOUNT" = yes ]; then
  echo
  echo "── 1b. the disposable account, measured from Directory Services ──"
  dscl . -read "/Users/$TEST_USER" >/dev/null 2>&1 \
    && ok "user $TEST_USER was created" || bad "user created" "dscl cannot read /Users/$TEST_USER"
  dscl . -read "/Groups/$TEST_GROUP" >/dev/null 2>&1 \
    && ok "group $TEST_GROUP was created" || bad "group created" "dscl cannot read /Groups/$TEST_GROUP"

  T_UID=$(dscl . -read "/Users/$TEST_USER" UniqueID 2>/dev/null | awk '{print $NF}')
  T_GID=$(dscl . -read "/Groups/$TEST_GROUP" PrimaryGroupID 2>/dev/null | awk '{print $NF}')
  T_PRIMARY=$(dscl . -read "/Users/$TEST_USER" PrimaryGroupID 2>/dev/null | awk '{print $NF}')
  echo "  allocated uid=$T_UID gid=$T_GID primary=$T_PRIMARY"

  # ⚠️ NO COLLISION, PROVED AGAINST THE RECORDED SET — not assumed from the
  # fact that creation succeeded. A hardcoded uid would eventually land on
  # another service's files.
  case " $UIDS_BEFORE " in
    *" $T_UID "*) bad "the allocated UID was free" "uid $T_UID was already in use" ;;
    *) ok "uid $T_UID was not previously in use" ;;
  esac
  case " $GIDS_BEFORE " in
    *" $T_GID "*) bad "the allocated GID was free" "gid $T_GID was already in use" ;;
    *) ok "gid $T_GID was not previously in use" ;;
  esac
  [ "$T_PRIMARY" = "$T_GID" ] && ok "the account's primary group is its own group" \
    || bad "primary group" "primary=$T_PRIMARY but group gid=$T_GID"
  [ -n "$T_UID" ] && [ "$T_UID" -lt 500 ] \
    && ok "uid $T_UID is in the macOS service range (<500)" \
    || bad "service uid range" "uid=$T_UID"

  # ⚠️ HIDDEN MEANS EITHER IsHidden=1 OR uid<500 — and that is not pedantry.
  # `_www`, a real macOS service account, has NO IsHidden key at all and is
  # still hidden from the login window, because macOS hides sub-500 uids.
  # Asserting IsHidden=1 alone would reject a correctly hidden account.
  T_HIDDEN=$(dscl . -read "/Users/$TEST_USER" IsHidden 2>/dev/null | awk '{print $NF}')
  if [ "$T_HIDDEN" = "1" ] || { [ -n "$T_UID" ] && [ "$T_UID" -lt 500 ]; }; then
    ok "hidden from the login window (IsHidden=${T_HIDDEN:-unset}, uid=$T_UID)"
  else
    bad "hidden from the login window" "IsHidden=${T_HIDDEN:-unset} and uid=$T_UID"
  fi

  # Non-member reads "user is not a member of the group"; member reads
  # "user is a member of the group". Verified on macOS against _www and a
  # real admin account.
  T_ADMIN=$(dsmemberutil checkmembership -U "$TEST_USER" -G admin 2>&1)
  case "$T_ADMIN" in
    *"is not a member"*) ok "not a member of admin" ;;
    *) bad "not a member of admin" "dsmemberutil said: $T_ADMIN" ;;
  esac
  T_WHEEL=$(dsmemberutil checkmembership -U "$TEST_USER" -G wheel 2>&1)
  case "$T_WHEEL" in
    *"is not a member"*) ok "not a member of wheel" ;;
    *) bad "not a member of wheel" "dsmemberutil said: $T_WHEEL" ;;
  esac

  T_SHELL=$(dscl . -read "/Users/$TEST_USER" UserShell 2>/dev/null | awk '{print $NF}')
  case "$T_SHELL" in
    /usr/bin/false|/sbin/nologin|/usr/sbin/nologin) ok "no interactive shell ($T_SHELL)" ;;
    *) bad "no interactive shell" "UserShell=$T_SHELL" ;;
  esac

  # No usable password: a service account must not be able to authenticate.
  if dscl . -read "/Users/$TEST_USER" AuthenticationAuthority >/dev/null 2>&1; then
    T_AUTH=$(dscl . -read "/Users/$TEST_USER" AuthenticationAuthority 2>/dev/null | tr -d '\n')
    case "$T_AUTH" in
      *ShadowHash*) bad "no usable password" "the account has a ShadowHash" ;;
      *) ok "no password hash on the account" ;;
    esac
  else
    ok "no AuthenticationAuthority at all (cannot authenticate)"
  fi

  # ⚠️ ACCESS RESULTS ONLY — the contents of protected locations are never
  # read or printed, only whether this identity can reach them.
  if sudo -n -u "$TEST_USER" test -r "/Users/$(id -un)/.ssh" 2>/dev/null; then
    bad "cannot read the operator's ~/.ssh" "the disposable account can read it"
  else ok "cannot read the operator's ~/.ssh"; fi
  PROT="$HOME/Projects/home-datacenter-starter/inventory/group_vars/linux_servers/vault.yml.backup-20261001T091734Z"
  if [ -e "$PROT" ]; then
    if sudo -n -u "$TEST_USER" test -r "$PROT" 2>/dev/null; then
      bad "cannot read the protected vault backup" "the disposable account can read it"
    else ok "cannot read the protected vault backup (existence tested only)"; fi
  fi
  if sudo -n -u "$TEST_USER" test -w "$HOME/Projects/home-datacenter-starter/.git" 2>/dev/null; then
    bad "cannot modify the canonical repository" "the disposable account can write .git"
  else ok "cannot modify the canonical repository"; fi

  # The running service must actually be this identity.
  SVC_PID=$(pgrep -f "$ROOT/sbin/semaphore" | head -1)
  if [ -n "$SVC_PID" ]; then
    SVC_OWNER=$(ps -o user= -p "$SVC_PID" | tr -d ' ')
    SVC_UID=$(ps -o uid= -p "$SVC_PID" | tr -d ' ')
    [ "$SVC_OWNER" = "$TEST_USER" ] && ok "the service runs as $TEST_USER (pid $SVC_PID)" \
      || bad "service runs as the disposable identity" "owner=$SVC_OWNER"
    [ "$SVC_UID" = "$T_UID" ] && ok "its effective uid is $T_UID" \
      || bad "effective uid matches" "process uid=$SVC_UID, account uid=$T_UID"
  else
    bad "the service is running under the disposable prefix" "no process found"
  fi
fi

echo
echo "── 2. it answers, on the disposable port ──"
body=$(curl -sS --max-time 5 "http://127.0.0.1:$PORT1/api/ping" 2>/dev/null | tr -d '\r\n')
[ "$body" = "pong" ] && ok "/api/ping returns pong on $PORT1" || bad "/api/ping" "got '$body'"
lsn=$(lsof -nP -iTCP:"$PORT1" -sTCP:LISTEN 2>/dev/null | tail -1)
printf '%s' "$lsn" | grep -q '127.0.0.1' && ok "bound to loopback" || bad "loopback bind" "$lsn"
cfgmode=$(stat -f '%Lp' "$ROOT/etc/config.json" 2>/dev/null)
[ "$cfgmode" = "600" ] && ok "config.json is 0600" || bad "config.json 0600" "mode $cfgmode"

echo
echo "── 3. a configuration change must restart BEFORE verification ──"
PID_BEFORE=$DISPOSABLE_PID
if [ "$MODE" = "--red" ]; then
  echo "  RED mode: removing the flush so the defect can reproduce"
  apply_red || exit 1
fi
run_role "$PORT2" /tmp/semaphore-disp-2.log
rc2=$?
PID_AFTER=$(disposable_pid)
DISPOSABLE_PID=${PID_AFTER:-$DISPOSABLE_PID}

if [ "$MODE" = "--red" ]; then
  if [ $rc2 -eq 0 ]; then
    bad "RED: the run fails without the flush" "it SUCCEEDED — is the flush really gone?"
  else
    ok "RED: the run failed, as it must without the flush"
    [ "$PID_AFTER" = "$PID_BEFORE" ] \
      && ok "RED: the OLD pid $PID_BEFORE is still running (stale process)" \
      || bad "RED: the old pid survives" "pid $PID_BEFORE -> ${PID_AFTER:-none}"
    if grep -qE "$PORT2|Connection refused|timed out" /tmp/semaphore-disp-2.log; then
      ok "RED: it failed waiting for the NEW port against the OLD process"
    else
      bad "RED: failed for the stale-process reason" "the run failed, but not at verification"
      tail -25 /tmp/semaphore-disp-2.log | sed 's/^/           /'
    fi
  fi
  echo; echo "RED phase complete — the harness reproduces the defect on launchd."
  exit 0
fi

if [ $rc2 -ne 0 ]; then
  bad "the reconfigure run converges" "exit $rc2; see /tmp/semaphore-disp-2.log"
  tail -30 /tmp/semaphore-disp-2.log | sed 's/^/           /'
  exit 1
fi
ok "the reconfigure run converged (exit 0)"
[ -n "$PID_AFTER" ] && [ "$PID_AFTER" != "$PID_BEFORE" ] \
  && ok "the daemon was RESTARTED before verification ($PID_BEFORE -> $PID_AFTER)" \
  || bad "restarted before verification" "pid $PID_BEFORE -> ${PID_AFTER:-none}"
nb=$(curl -sS --max-time 5 "http://127.0.0.1:$PORT2/api/ping" 2>/dev/null | tr -d '\r\n')
[ "$nb" = "pong" ] && ok "the NEW port $PORT2 answers" || bad "new port answers" "got '$nb'"

echo
echo "── 4. a third, unchanged run must be a genuine no-op ──"
PID_NOOP_BEFORE=$(disposable_pid)
run_role "$PORT2" /tmp/semaphore-disp-3.log
rc3=$?
PID_NOOP_AFTER=$(disposable_pid)
DISPOSABLE_PID=${PID_NOOP_AFTER:-$DISPOSABLE_PID}
[ $rc3 -eq 0 ] && ok "the third run converged (exit 0)" || bad "third run converges" "exit $rc3"
grep -qE '^localhost.*changed=0 ' /tmp/semaphore-disp-3.log \
  && ok "third run reported changed=0" \
  || bad "third run is changed=0" "$(grep -E '^localhost' /tmp/semaphore-disp-3.log | tail -1)"
[ "$PID_NOOP_AFTER" = "$PID_NOOP_BEFORE" ] \
  && ok "no restart on the no-op run (pid $PID_NOOP_AFTER)" \
  || bad "no restart on the no-op run" "pid $PID_NOOP_BEFORE -> ${PID_NOOP_AFTER:-none}"

if [ "$WITH_ACCOUNT" = yes ]; then
  # ⚠️ NO DIRECTORY-SERVICE CHURN. A role that recreated or re-numbered the
  # account every run would still report changed=0 for the service while
  # quietly rewriting the identity underneath it.
  U2=$(dscl . -read "/Users/$TEST_USER" UniqueID 2>/dev/null | awk '{print $NF}')
  G2=$(dscl . -read "/Groups/$TEST_GROUP" PrimaryGroupID 2>/dev/null | awk '{print $NF}')
  S2=$(dscl . -read "/Users/$TEST_USER" UserShell 2>/dev/null | awk '{print $NF}')
  H2=$(dscl . -read "/Users/$TEST_USER" NFSHomeDirectory 2>/dev/null | awk '{print $NF}')
  [ "$U2" = "$T_UID" ] && ok "uid unchanged on the no-op run ($U2)" \
    || bad "uid unchanged" "$T_UID -> $U2"
  [ "$G2" = "$T_GID" ] && ok "gid unchanged on the no-op run ($G2)" \
    || bad "gid unchanged" "$T_GID -> $G2"
  [ "$S2" = "$T_SHELL" ] && ok "shell unchanged on the no-op run" \
    || bad "shell unchanged" "$T_SHELL -> $S2"
  [ "$H2" = "$ROOT/state" ] && ok "home unchanged on the no-op run" \
    || bad "home unchanged" "expected $ROOT/state, got $H2"
fi

echo
echo "── 5. teardown and live-resolver non-interference follow ──"
