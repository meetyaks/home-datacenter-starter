#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# THE SEMAPHORE ROLE, EXECUTED ON macOS launchd, DISPOSABLY.
#
#   tests/run-semaphore-launchd.sh           GREEN run (default)
#   tests/run-semaphore-launchd.sh --red     RED: prove the flush is needed
#
# ⚠️ WHAT THIS DOES AND DOES NOT PROVE. It exercises the Darwin artifact, the
# bsdtar extraction path, launchd bootstrap, the health endpoint, restart-
# before-verification and idempotence — the half of the role that the Linux
# container cannot reach.
#
# It deliberately does NOT create a service account. `semaphore_user` is
# overridden to the invoking user, because creating and deleting a real
# hidden dscl account on a workstation is exactly the permanent change a
# disposable test must not make. The account path is therefore proved on
# Linux (where the container is thrown away) and on the real controller
# during the watched deployment — never here. That gap is stated in
# docs/dc1-semaphore.md rather than papered over.
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
echo "  user   $(id -un)  (no service account is created — see the header)"

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

  case "$ROOT" in
    /*/semaphore-disposable.*) tsudo rm -rf "$ROOT" && echo "  removed $ROOT" ;;
    *) echo "  REFUSING to remove unexpected path: $ROOT" ;;
  esac

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

  if [ -e "$ROOT" ] || pgrep -f "$ROOT/sbin/semaphore" >/dev/null 2>&1 \
     || tsudo launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    echo
    echo "  ╭─ TEARDOWN DID NOT COMPLETE ─────────────────────────────────"
    echo "  │   sudo launchctl bootout system/${LABEL}"
    echo "  │   sudo pkill -f '${ROOT}/sbin/semaphore'"
    echo "  │   sudo rm -rf '${ROOT}'"
    echo "  ╰──────────────────────────────────────────────────────────────"
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
    -e semaphore_user="$(id -un)" \
    -e semaphore_group="$(id -gn)" \
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

echo
echo "── 5. teardown and live-resolver non-interference follow ──"
