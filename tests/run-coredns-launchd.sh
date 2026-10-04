#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# THE CoreDNS ROLE, EXECUTED END TO END ON macOS, BESIDE A LIVE RESOLVER.
#
#   tests/run-coredns-launchd.sh            GREEN run (default)
#   tests/run-coredns-launchd.sh --red      RED run: prove the flush is needed
#
# ═══ WHY THIS EXISTS ════════════════════════════════════════════════════════
#
# Six defects reached a production node in this rollout. Four of them lived in
# files no test executed, and three were specific to the macOS path:
#
#   1  ansible.builtin.unarchive rejects bsdtar          (macOS install)
#   2  /usr/local/sbin does not exist on a stock Mac     (macOS install)
#   3  a `that:` item parsed as a YAML mapping           (verify.yml)
#   4  a conditional whose \b escape Python consumed     (verify.yml)
#   5  the health port collided with Keel's console      (Linux bind)
#   6  handlers not flushed before verification          (both platforms)
#
# Every static guard added since was a narrower substitute for running the
# thing. This runs the thing.
#
# ═══ WHY IT IS SAFE BESIDE THE LIVE DAEMON ══════════════════════════════════
#
# Everything is overridden to a disposable identity: a temporary prefix, a
# unique launchd label, and three dynamically chosen free high ports on
# 127.0.0.1. Nothing it touches is a production path.
#
# ⚠️ IT CANNOT USE ANOTHER LOOPBACK ADDRESS. macOS refuses to bind 127.0.0.2
# without an explicit `ifconfig lo0 alias` —
#
#   listen tcp 127.0.0.2:18653: bind: can't assign requested address
#
# — and changing host networking for a test is not acceptable. That is why
# coredns_dns_port exists: the disposable instance shares 127.0.0.1 with the
# live daemon and differs by PORT.
#
# The live daemon's PID, label, files, fingerprints, listeners and answers are
# recorded before and compared after. Teardown runs on success, failure and
# interrupt, and touches only the unique label, the recorded disposable PID
# and the exact temporary directory.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || { echo "cannot reach the repository root" >&2; exit 1; }

MODE=${1:-}

# Counts the BECOME prompts so the operator knows how many are still coming.
# Initialised because `set -u` makes $((++PROMPTS)) an error on an unset name.
PROMPTS=0

pass=0
fail=0
ok()   { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }

if [ "$(uname -s)" != "Darwin" ]; then
  skip "not macOS — the launchd path cannot be exercised here."
  echo
  echo "SKIPPED — this suite is macOS-only and is proved on the management node."
  exit 0
fi

# ── A disposable identity, chosen fresh every run ──────────────────────────
STAMP=$$-$(date +%s)
ROOT=$(mktemp -d -t coredns-disposable.XXXXXX)
LABEL="org.dc1.corednsdisposable${STAMP}"
PLIST="$ROOT/${LABEL}.plist"

# ⚠️ THE PLIST LIVES IN THE TEMPORARY ROOT, NOT /Library/LaunchDaemons.
# `launchctl bootstrap system <path>` accepts any path; only persistence
# across reboots needs the system directory, and a disposable service must
# NOT persist. Nothing permanent is created.

# ⚠️ THE EXITS THAT HAPPEN BEFORE THE TEARDOWN TRAP IS ARMED. $ROOT already
# exists by this point — mktemp created it — so an early refusal must take it
# with it, or the run leaves a stray prefix behind while reporting that it
# changed nothing. Nothing privileged has been created yet, so no sudo is
# needed and none is used; the path is still checked against the mktemp
# pattern before anything is removed.
early_abort() {
  case "$ROOT" in
    /*/coredns-disposable.*) rm -rf "$ROOT" && echo "  removed $ROOT" ;;
    *) echo "  REFUSING to remove unexpected path: $ROOT" ;;
  esac
  echo "Nothing disposable was created. No host state was changed." >&2
  exit 1
}

free_port() {
  # Ask the kernel for an unused port by binding one and releasing it.
  python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
}
DNS_PORT=$(free_port); HEALTH_PORT=$(free_port); READY_PORT=$(free_port)
DNS_PORT2=$(free_port); HEALTH_PORT2=$(free_port); READY_PORT2=$(free_port)

# ⚠️ DISTINCTNESS IS NOT GUARANTEED BY THE KERNEL, so it is checked. Each
# free_port is a SEPARATE python3 process that binds a port and immediately
# releases it; nothing stops the ephemeral cursor handing the same number to
# two of them. Two equal ports would put DNS and health — or the old and new
# health — on one socket, CoreDNS would refuse to start, and the run would
# fail for a reason that has nothing to do with the role. This test gets ONE
# operator run; it does not get to fail confusingly.
# (enforced: tests/dns-harness-integrity.yml "the six disposable ports are
#  proved distinct", mutation "allowing two disposable ports to collide")
if [ "$(printf '%s\n' "$DNS_PORT" "$HEALTH_PORT" "$READY_PORT" \
                      "$DNS_PORT2" "$HEALTH_PORT2" "$READY_PORT2" \
        | sort -u | wc -l | tr -d ' ')" != 6 ]; then
  bad "the six disposable ports are distinct" \
      "got $DNS_PORT $HEALTH_PORT $READY_PORT / $DNS_PORT2 $HEALTH_PORT2 $READY_PORT2 — re-run"
  early_abort
fi

echo "Disposable identity for this run:"
echo "  root   $ROOT"
echo "  label  $LABEL"
echo "  ports  dns=$DNS_PORT health=$HEALTH_PORT ready=$READY_PORT"
echo "  phase-2 ports dns=$DNS_PORT2 health=$HEALTH_PORT2 ready=$READY_PORT2"

# ── Record the LIVE daemon, so non-interference is proved rather than hoped ─
LIVE_LABEL=org.coredns.coredns
LIVE_PLIST=/Library/LaunchDaemons/${LIVE_LABEL}.plist
live_pid()  { pgrep -f '[c]oredns -conf /usr/local/etc/coredns/Corefile' | head -1; }
live_fp()   { shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; }

LIVE_PID_BEFORE=$(live_pid)
LIVE_COREFILE_BEFORE=$(live_fp /usr/local/etc/coredns/Corefile)
LIVE_ZONE_BEFORE=$(live_fp /usr/local/etc/coredns/db.dc1.lan)
LIVE_BIN_BEFORE=$(live_fp /usr/local/sbin/coredns)
LIVE_PLIST_BEFORE=$(live_fp "$LIVE_PLIST")
LIVE_ANSWER_BEFORE=$(dig +short +time=3 +tries=1 @127.0.0.1 keel-dev.dc1.lan A 2>/dev/null | tr '\n' ' ')

echo "Live daemon recorded: pid=${LIVE_PID_BEFORE:-none} corefile=${LIVE_COREFILE_BEFORE:0:12}…"

# ⚠️ AN EMPTY BASELINE PROVES NOTHING, AND THIS IS THE SAME TRAP AS THE
# VACUOUS RED. Every non-interference check below is an equality test against
# these values. If pgrep matched nothing and the fingerprints came back empty,
# "" = "" would hold after the run and the harness would report six passes
# while having measured precisely nothing — including on a machine where the
# live resolver had been stopped, or where it runs under a command line this
# pattern does not match.
#
# So the baseline must be non-empty before anything disposable is created. If
# the live daemon genuinely is not running, that is a state to report and have
# the operator resolve, not one to silently call "unchanged".
# (enforced: tests/dns-harness-integrity.yml "the live baseline is non-empty
#  before anything disposable starts", mutation "accepting an empty baseline")
for _probe in "LIVE_PID_BEFORE:$LIVE_PID_BEFORE" \
              "LIVE_COREFILE_BEFORE:$LIVE_COREFILE_BEFORE" \
              "LIVE_ZONE_BEFORE:$LIVE_ZONE_BEFORE" \
              "LIVE_BIN_BEFORE:$LIVE_BIN_BEFORE" \
              "LIVE_PLIST_BEFORE:$LIVE_PLIST_BEFORE" \
              "LIVE_ANSWER_BEFORE:$LIVE_ANSWER_BEFORE"; do
  if [ -z "${_probe#*:}" ]; then
    bad "the live baseline is non-empty before anything disposable starts" \
        "${_probe%%:*} is empty — every non-interference check below would compare '' with '' and pass without measuring anything. Is the live CoreDNS running?"
    echo
    echo "REFUSING TO RUN — the non-interference baseline could not be established." >&2
    early_abort
  fi
done
ok "the live baseline is non-empty (pid, binary, Corefile, zone, plist, answer)"

DISPOSABLE_PID=""

# ── RED mode removes the flush from the REAL role, and puts it back ────────
#
# ⚠️ THE REGRESSION MUST RUN AGAINST THE ACTUAL ROLE, not a copy. A harness
# that reproduced the defect in its own restated tasks would prove nothing
# about roles/coredns. So --red edits tasks/main.yml in place, exactly as
# tests/run-dns-mutations.sh edits the files it mutates, and restores it from
# a byte-for-byte backup in teardown — including on interrupt.
MAIN=roles/coredns/tasks/main.yml
MAIN_BACKUP="$ROOT/main.yml.orig"
RED_APPLIED=no

apply_red() {
  cp "$MAIN" "$MAIN_BACKUP"
  # ⚠️ REMOVE THE WHOLE TASK, NAME AND ALL, SPANNING ITS COMMENT BLOCK.
  # Deleting only the `ansible.builtin.meta: flush_handlers` line leaves an
  # orphaned `- name:` with no module; Ansible then dies on "no module/action
  # detected in task" in a fraction of a second, before installing or
  # reconfiguring anything. The run still "fails" and the old pid is still
  # alive, so the RED checks below pass TRIVIALLY — a proof that would hold
  # equally well against a typo. The Linux harness shipped exactly that bug
  # and CI caught it; this is the same fix.
  perl -0pi -e 's{- name: Apply every pending restart[^\n]*\n(?:  \#[^\n]*\n|\n)*  ansible\.builtin\.meta: flush_handlers\n}{}' "$MAIN"
  RED_APPLIED=yes
  if grep -q 'flush_handlers' "$MAIN"; then
    bad "RED: the flush was removed" "it is still present in $MAIN"
    return 1
  fi
  if grep -q 'Apply every pending restart' "$MAIN"; then
    bad "RED: no orphaned task left behind" \
        "the name survived without its module — the run would die parsing, not verifying"
    return 1
  fi
  echo "  (flush removed from $MAIN for this run; restored in teardown)"
}

restore_red() {
  [ "$RED_APPLIED" = yes ] || return 0
  [ -f "$MAIN_BACKUP" ] || { echo "  WARNING: no backup to restore $MAIN from"; return 1; }
  cp "$MAIN_BACKUP" "$MAIN"
  if grep -q 'flush_handlers' "$MAIN"; then
    echo "  restored the flush in $MAIN"
  else
    echo "  WARNING: $MAIN does not contain the flush after restore — CHECK git status"
  fi
}

# ⚠️ TEARDOWN MUST NOT BE DEFEATED BY AN EXPIRED SUDO TIMESTAMP. The run can
# take longer than the sudo grace period, and teardown is where a root-owned
# launchd daemon and a root-owned prefix get removed. With bare `sudo -n`,
# every removal would fail silently the moment the timestamp lapsed, and the
# harness would leave a live disposable daemon behind while printing that it
# had cleaned up. So: try non-interactively, and if that fails, PROMPT — the
# operator is at an interactive terminal precisely because this needs sudo.
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
  # 1. Bootout ONLY the unique disposable label.
  if tsudo launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    tsudo launchctl bootout "system/${LABEL}" >/dev/null 2>&1 \
      && echo "  booted out ${LABEL}" || echo "  bootout of ${LABEL} returned non-zero"
  else
    echo "  ${LABEL} was not loaded"
  fi
  # 2. Kill ONLY the recorded disposable PID, and only if it is still ours.
  if [ -n "$DISPOSABLE_PID" ] && kill -0 "$DISPOSABLE_PID" 2>/dev/null; then
    if ps -p "$DISPOSABLE_PID" -o command= | grep -q "$ROOT"; then
      tsudo kill "$DISPOSABLE_PID" 2>/dev/null && echo "  killed disposable pid $DISPOSABLE_PID"
    else
      echo "  pid $DISPOSABLE_PID is no longer ours — NOT killing it"
    fi
  fi
  # 3. Remove ONLY the exact temporary root.
  case "$ROOT" in
    /*/coredns-disposable.*) tsudo rm -rf "$ROOT" && echo "  removed $ROOT" ;;
    *) echo "  REFUSING to remove unexpected path: $ROOT" ;;
  esac

  # 4. Prove the live daemon is untouched.
  echo "── live-daemon non-interference ──"
  local after_pid after_core after_zone after_bin after_plist after_ans
  after_pid=$(live_pid)
  after_core=$(live_fp /usr/local/etc/coredns/Corefile)
  after_zone=$(live_fp /usr/local/etc/coredns/db.dc1.lan)
  after_bin=$(live_fp /usr/local/sbin/coredns)
  after_plist=$(live_fp "$LIVE_PLIST")
  after_ans=$(dig +short +time=3 +tries=1 @127.0.0.1 keel-dev.dc1.lan A 2>/dev/null | tr '\n' ' ')

  [ "$after_pid"   = "$LIVE_PID_BEFORE" ]      && ok "live PID unchanged (${after_pid:-none})" \
     || bad "live PID unchanged" "was ${LIVE_PID_BEFORE:-none}, now ${after_pid:-none}"
  [ "$after_core"  = "$LIVE_COREFILE_BEFORE" ] && ok "live Corefile fingerprint unchanged" \
     || bad "live Corefile unchanged" "was $LIVE_COREFILE_BEFORE now $after_core"
  [ "$after_zone"  = "$LIVE_ZONE_BEFORE" ]     && ok "live zone fingerprint unchanged" \
     || bad "live zone unchanged" "was $LIVE_ZONE_BEFORE now $after_zone"
  [ "$after_bin"   = "$LIVE_BIN_BEFORE" ]      && ok "live binary fingerprint unchanged" \
     || bad "live binary unchanged" "was $LIVE_BIN_BEFORE now $after_bin"
  [ "$after_plist" = "$LIVE_PLIST_BEFORE" ]    && ok "live plist unchanged" \
     || bad "live plist unchanged" "was $LIVE_PLIST_BEFORE now $after_plist"
  [ "$after_ans"   = "$LIVE_ANSWER_BEFORE" ]   && ok "live daemon still answers identically" \
     || bad "live answers unchanged" "was '$LIVE_ANSWER_BEFORE' now '$after_ans'"

  # 5. Nothing permanent survived.
  if [ -e "$PLIST" ]; then bad "no disposable plist survives" "$PLIST still exists"
  else ok "no disposable plist survives"; fi
  if [ -e "$ROOT" ]; then bad "no disposable prefix survives" "$ROOT still exists"
  else ok "no disposable prefix survives"; fi
  if tsudo launchctl print "system/${LABEL}" >/dev/null 2>&1; then
    bad "no disposable launchd label survives" "system/${LABEL} is still loaded"
  else ok "no disposable launchd label survives"; fi

  echo
  if [ "$fail" -gt 0 ]; then
    echo "FAILED: $fail of $((pass + fail)) checks." >&2
    exit 1
  fi
  echo "PASS — $pass checks."
}
trap teardown EXIT INT TERM

# ── sudo, cached once; the role uses become for every privileged task ──────
echo
echo "This test needs sudo (the role installs a launchd system daemon)."
# ⚠️ DENIED SUDO IS A FAILURE, NOT A SKIP. This used to `skip` and `exit 0`,
# which meant teardown found fail=0 and printed "PASS — N checks" after
# exercising nothing at all. The launchd path is the half of this role that no
# test has ever executed and where three of the six defects lived; a run that
# could not reach it has not passed, and must not be reportable as a pass.
# (enforced: tests/dns-harness-integrity.yml "a run that cannot reach launchd
#  is a failure, not a pass", mutation "turning denied sudo back into a skip")
if ! sudo -v; then
  bad "sudo was granted, so the launchd path can be exercised" \
      "sudo was refused — nothing was installed, started or verified, and this run proves nothing"
  exit 1
fi
need_sudo() {
  sudo -n true 2>/dev/null && return 0
  # Re-prompt rather than abandon the run: the operator is at an interactive
  # terminal, the sudo grace period is shorter than three role runs, and
  # throwing away a run that has already installed a disposable daemon just
  # because a timestamp lapsed wastes the one window this gate gets.
  echo "  (sudo timestamp expired — re-authenticating to continue)"
  sudo -v && return 0
  bad "sudo credential still valid" "sudo could not be renewed mid-run; re-run the test"
  return 1
}

run_role() {   # run_role <dns> <health> <ready> <logfile>
  # ⚠️ --ask-become-pass, AND `sudo -v` IS NOT A SUBSTITUTE. The first real
  # run of this harness on dc1-arm-1 died here:
  #
  #   TASK [coredns : Create the directories this role installs into]
  #   Task failed: Premature end of stream waiting for become success.
  #   >>> Standard Error
  #   sudo: a password is required
  #
  # The harness had already run `sudo -v` and the timestamp was valid — in
  # THIS shell. macOS sudo defaults to timestamp_type=tty, so the ticket is
  # scoped to the controlling terminal. Ansible's local connection runs
  # `sudo -n ...` in a subprocess wired to pipes, with no controlling tty, so
  # it looks up a different timestamp record, finds none, and `-n` makes it
  # fail rather than prompt.
  #
  # The fix is the one every documented invocation of this role already uses
  # (roles/coredns/README.md, docs/dc1-lan-dns.md): let Ansible collect the
  # password itself. It costs one prompt per run, three per GREEN pass, and
  # the password never reaches a command line, an environment variable, a
  # file or this log.
  # (enforced: tests/dns-harness-integrity.yml "the role is run with
  #  --ask-become-pass, never a cached ticket", mutation "relying on a cached
  #  sudo ticket instead of --ask-become-pass")
  echo "  (Ansible will now ask for your BECOME password — this is prompt $((++PROMPTS)) of 3)" >&2
  ansible-playbook --ask-become-pass -i localhost, -c local \
    tests/container/coredns-disposable-play.yml \
    -e coredns_bin_dir_darwin="$ROOT/sbin" \
    -e coredns_conf_dir_darwin="$ROOT/etc" \
    -e coredns_log_dir_darwin="$ROOT/log" \
    -e coredns_launchd_label="$LABEL" \
    -e coredns_launchd_plist="$PLIST" \
    -e coredns_dns_port="$1" \
    -e coredns_health_address="127.0.0.1:$2" \
    -e coredns_ready_address="127.0.0.1:$3" \
    -e '{"coredns_bind_addresses": ["127.0.0.1"]}' \
    > "$4" 2>&1
}

disposable_pid() { pgrep -f "$ROOT/sbin/coredns" | head -1; }

echo
echo "── 1. first run: the whole role, against a disposable prefix ──"
need_sudo || exit 1
run_role "$DNS_PORT" "$HEALTH_PORT" "$READY_PORT" /tmp/coredns-disp-1.log
rc1=$?
if [ $rc1 -ne 0 ]; then
  bad "the role converges on a clean disposable prefix" "exit $rc1; see /tmp/coredns-disp-1.log"
  tail -25 /tmp/coredns-disp-1.log | sed 's/^/           /'
  exit 1
fi
ok "the role converged (exit 0)"
DISPOSABLE_PID=$(disposable_pid)
[ -n "$DISPOSABLE_PID" ] && ok "a disposable CoreDNS is running (pid $DISPOSABLE_PID)" \
   || bad "a disposable CoreDNS is running" "no process matching $ROOT/sbin/coredns"

# The install path really ran, rather than being skipped.
grep -q 'Unpack it (macOS' /tmp/coredns-disp-1.log && ok "the macOS bsdtar extraction path executed" \
   || bad "the macOS extraction path executed" "not present in the run log"
[ -x "$ROOT/sbin/coredns" ] && ok "the binary was installed into the disposable prefix" \
   || bad "binary installed into the prefix" "$ROOT/sbin/coredns missing"
[ -f "$ROOT/etc/Corefile" ] && [ -f "$ROOT/etc/db.dc1.lan" ] \
   && ok "Corefile and zone rendered into the prefix" \
   || bad "Corefile and zone rendered" "missing under $ROOT/etc"
[ -f "$PLIST" ] && ok "the launchd plist rendered into the prefix" \
   || bad "plist rendered" "$PLIST missing"

echo
echo "── 2. it actually answers, on the disposable ports ──"
dq() { dig +short +time=3 +tries=1 -p "$DNS_PORT" @127.0.0.1 "$1" A 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
[ "$(dq dc1-arm-1.dc1.lan)" = "10.0.0.22" ] && ok "dc1-arm-1.dc1.lan -> 10.0.0.22 (UDP)" \
   || bad "dc1-arm-1.dc1.lan -> 10.0.0.22" "got '$(dq dc1-arm-1.dc1.lan)'"
[ "$(dq keel-dev.dc1.lan)" = "10.0.0.3" ] && ok "keel-dev.dc1.lan -> 10.0.0.3 (UDP)" \
   || bad "keel-dev.dc1.lan -> 10.0.0.3" "got '$(dq keel-dev.dc1.lan)'"
tcpans=$(dig +short +tcp +time=3 +tries=1 -p "$DNS_PORT" @127.0.0.1 keel-dev.dc1.lan A 2>/dev/null | tr -d '\n')
[ "$tcpans" = "10.0.0.3" ] && ok "keel-dev.dc1.lan -> 10.0.0.3 (TCP)" \
   || bad "TCP query works" "got '$tcpans'"
resv=$(dig +time=3 +tries=1 -p "$DNS_PORT" @127.0.0.1 keel.dc1.lan A 2>/dev/null)
printf '%s' "$resv" | grep -q 'status: NXDOMAIN' && printf '%s' "$resv" | grep -qE 'flags:[^;]* aa[ ;]' \
   && ok "keel.dc1.lan -> authoritative NXDOMAIN" \
   || bad "keel.dc1.lan authoritative NXDOMAIN" "$(printf '%s' "$resv" | grep -E 'status|flags' | tr '\n' ' ')"
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$HEALTH_PORT/health" || echo 000)
[ "$code" = 200 ] && ok "health endpoint 200 on $HEALTH_PORT" || bad "health 200" "got $code"
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:$READY_PORT/ready" || echo 000)
[ "$code" = 200 ] && ok "ready endpoint 200 on $READY_PORT" || bad "ready 200" "got $code"

echo
echo "── 3. a CONFIGURATION CHANGE must restart the daemon BEFORE verification ──"
# ⚠️ THE SIXTH DEFECT, AS AN EXECUTABLE TEST. New ports mean a new Corefile,
# which notifies `Restart CoreDNS`. Without `meta: flush_handlers` the handler
# is still pending when verify.yml runs, so verification interrogates the OLD
# process — which still holds the OLD ports — and fails on the new ones.
PID_BEFORE_CHANGE=$DISPOSABLE_PID
need_sudo || exit 1
if [ "$MODE" = "--red" ]; then
  echo "  RED mode: removing the flush so the defect can reproduce"
  apply_red || exit 1
fi
run_role "$DNS_PORT2" "$HEALTH_PORT2" "$READY_PORT2" /tmp/coredns-disp-2.log
rc2=$?
PID_AFTER_CHANGE=$(disposable_pid)
DISPOSABLE_PID=${PID_AFTER_CHANGE:-$DISPOSABLE_PID}

if [ "$MODE" = "--red" ]; then
  # RED: the flush has been removed; the run MUST fail, and fail because the
  # stale process is still serving.
  if [ $rc2 -eq 0 ]; then
    bad "RED: the run fails without the flush" "it SUCCEEDED — the flush may still be present"
  else
    ok "RED: the run failed, as it must without the flush"
    [ "$PID_AFTER_CHANGE" = "$PID_BEFORE_CHANGE" ] \
      && ok "RED: the OLD pid $PID_BEFORE_CHANGE is still running (stale process)" \
      || bad "RED: the old pid survives" "pid changed $PID_BEFORE_CHANGE -> ${PID_AFTER_CHANGE:-none}"
    if nc -z 127.0.0.1 "$HEALTH_PORT" 2>/dev/null; then
      ok "RED: the OLD health port $HEALTH_PORT is still live"
    else bad "RED: old health port still live" "$HEALTH_PORT is closed"; fi
    if nc -z 127.0.0.1 "$HEALTH_PORT2" 2>/dev/null; then
      bad "RED: the NEW health port is absent" "$HEALTH_PORT2 is already listening"
    else ok "RED: the NEW health port $HEALTH_PORT2 is absent"; fi
    grep -qE "Connection refused|127\.0\.0\.1:$READY_PORT2" /tmp/coredns-disp-2.log \
      && ok "RED: it failed polling the NEW ready port against the OLD process" \
      || bad "RED: failed for the stale-process reason" "see /tmp/coredns-disp-2.log"
  fi
  echo
  echo "RED phase complete — the harness reproduces the defect."
  exit 0
fi

# GREEN
if [ $rc2 -ne 0 ]; then
  bad "the reconfigure run converges" "exit $rc2; see /tmp/coredns-disp-2.log"
  tail -25 /tmp/coredns-disp-2.log | sed 's/^/           /'
  exit 1
fi
ok "the reconfigure run converged (exit 0)"
[ -n "$PID_AFTER_CHANGE" ] && [ "$PID_AFTER_CHANGE" != "$PID_BEFORE_CHANGE" ] \
  && ok "the daemon was RESTARTED before verification ($PID_BEFORE_CHANGE -> $PID_AFTER_CHANGE)" \
  || bad "the daemon restarted before verification" \
         "pid $PID_BEFORE_CHANGE -> ${PID_AFTER_CHANGE:-none}; the handler did not run in time"
if nc -z 127.0.0.1 "$HEALTH_PORT2" 2>/dev/null; then ok "the NEW health port $HEALTH_PORT2 is live"
else bad "new health port live" "$HEALTH_PORT2 is not listening"; fi
if nc -z 127.0.0.1 "$HEALTH_PORT" 2>/dev/null; then bad "the OLD health port is closed" "$HEALTH_PORT still listening"
else ok "the OLD health port $HEALTH_PORT is closed"; fi
ans=$(dig +short +time=3 +tries=1 -p "$DNS_PORT2" @127.0.0.1 keel-dev.dc1.lan A 2>/dev/null | tr -d '\n')
[ "$ans" = "10.0.0.3" ] && ok "DNS still correct on the new port $DNS_PORT2" \
  || bad "DNS correct on the new port" "got '$ans'"

echo
echo "── 4. a third, unchanged run must be a genuine no-op ──"
need_sudo || exit 1
PID_BEFORE_NOOP=$(disposable_pid)
run_role "$DNS_PORT2" "$HEALTH_PORT2" "$READY_PORT2" /tmp/coredns-disp-3.log
rc3=$?
PID_AFTER_NOOP=$(disposable_pid)
DISPOSABLE_PID=${PID_AFTER_NOOP:-$DISPOSABLE_PID}
[ $rc3 -eq 0 ] && ok "the third run converged (exit 0)" || bad "third run converges" "exit $rc3"
if grep -qE '^localhost.*changed=0 ' /tmp/coredns-disp-3.log; then
  ok "third run reported changed=0"
else
  bad "third run is changed=0" "$(grep -E '^localhost' /tmp/coredns-disp-3.log | tail -1)"
fi
[ "$PID_AFTER_NOOP" = "$PID_BEFORE_NOOP" ] \
  && ok "no restart on the no-op run (pid $PID_AFTER_NOOP)" \
  || bad "no restart on the no-op run" "pid $PID_BEFORE_NOOP -> ${PID_AFTER_NOOP:-none}"

echo
echo "── 5. teardown and live-daemon non-interference follow ──"
