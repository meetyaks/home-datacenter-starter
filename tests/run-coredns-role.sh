#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# THE CoreDNS ROLE, EXECUTED END TO END ON LINUX, IN A DISPOSABLE CONTAINER.
#
#   tests/run-coredns-role.sh            GREEN run (default)
#   tests/run-coredns-role.sh --red      RED run: prove the flush is needed
#
# ═══ WHY THIS EXISTS ════════════════════════════════════════════════════════
#
# Until now every CoreDNS suite was controller-only: they rendered templates
# and parsed YAML. Nothing EXECUTED the role, and four of the six defects that
# reached a production node lived in files no test ran — including
# verify.yml, which produced two of them.
#
# This runs the real role, with its real templates, against a throwaway Linux
# host with a real PID 1, and then asks the running process questions.
#
# ⚠️ THE IMAGE DELIBERATELY DOES NOT CONTAIN dig. verify.yml shells out to it,
# and the role never declared that prerequisite — it worked on dc1-x86 purely
# because dig happened to be installed. Preinstalling it here would hide the
# very dependency this suite exists to prove the role now owns. The image
# ships without it; roles/coredns/tasks/verifier-prereq.yml installs it; and
# check 0 below asserts the image really is clean so that cannot rot into a
# false positive.
#
# ⚠️ IT BINDS REAL PORT 53. The image's systemd-resolved unit is trimmed, so
# 53 is free, and using it keeps the test honest about the production
# configuration rather than exercising a port production never uses.
#
# Does not touch dc1-x86, dc1-arm-1 or any live resolver.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || { echo "cannot reach the repository root" >&2; exit 1; }

MODE=${1:-}
IMAGE=keel-coredns-test:local
CNAME=keel-coredns-role-test

pass=0
fail=0
ok()   { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }

MAIN=roles/coredns/tasks/main.yml
WORK=$(mktemp -d -t coredns-role.XXXXXX)
RED_APPLIED=no

cleanup() {
  if [ "$RED_APPLIED" = yes ] && [ -f "$WORK/main.yml.orig" ]; then
    cp "$WORK/main.yml.orig" "$MAIN"
    grep -q 'flush_handlers' "$MAIN" \
      && echo "  restored the flush in $MAIN" \
      || echo "  WARNING: $MAIN lacks the flush after restore — CHECK git status"
  fi
  docker rm -f "$CNAME" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

if ! docker info >/dev/null 2>&1; then
  skip "Docker is unavailable, and this needs a disposable Linux host with systemd."
  echo; echo "SKIPPED — a skipped run is not a passing one."
  exit 0
fi

# ⚠️ THIS SUITE NEEDS A NATIVE amd64 HOST, AND SAYS SO RATHER THAN PRETENDING.
# The role pins linux_amd64 only, so the container must be amd64. On an Apple
# Silicon workstation that means qemu emulation, and `dig` — which verify.yml
# shells out to — segfaults under it:
#
#   qemu: uncaught target signal 11 (Segmentation fault) - core dumped
#
# Everything else runs correctly there: the role converged to ok=43
# changed=14, installed dig, started the service, bound :53, and the handler
# flush demonstrably ran the restart BEFORE verification. Only the dig calls
# die, and they die in the emulator rather than in the role.
#
# GitHub's runners are native amd64, so this executes for real in CI. Skipping
# loudly here beats a green tick that proved nothing.
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
  x86_64|amd64) : ;;
  *)
    skip "host is $HOST_ARCH; the amd64 container would be emulated and dig segfaults under qemu."
    echo
    echo "SKIPPED — runs natively on the amd64 CI runner. A skipped run is not a passing one."
    exit 0
    ;;
esac

echo "Building the CoreDNS test image (cached after the first run)…"
# ⚠️ linux/amd64 EXPLICITLY. On an Apple Silicon workstation the default
# platform is arm64, for which this role has no pinned checksum and which it
# therefore refuses — correctly. Production dc1-x86 is amd64, so the test
# must exercise the artifact production actually installs, emulated if need
# be. The first run of this harness discovered exactly that.
PLATFORM=linux/amd64
if ! docker build -q --platform "$PLATFORM" -f tests/container/Dockerfile.coredns -t "$IMAGE" tests/container >/dev/null 2>&1; then
  echo "  FAILED to build $IMAGE" >&2
  docker build --platform "$PLATFORM" -f tests/container/Dockerfile.coredns -t "$IMAGE" tests/container 2>&1 | tail -15 >&2
  exit 1
fi

docker rm -f "$CNAME" >/dev/null 2>&1 || true
docker run -d --name "$CNAME" --platform "$PLATFORM" --privileged \
  --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$PWD":/repo:ro -w /repo "$IMAGE" >/dev/null 2>&1

booted=no
# ⚠️ 120s, NOT 30s. Under linux/amd64 emulation on an Apple Silicon host
# systemd takes far longer to reach a steady state, and a 30s wait reported
# "systemd did not come up" while the container was still booting — a SKIP
# that looked like an environment limitation rather than an impatient test.
# ⚠️ THE STATE IS CAPTURED, NOT PIPED THROUGH grep. `systemctl
# is-system-running` EXITS 1 when the state is `degraded`, and under
# `set -o pipefail` that non-zero status propagates even though grep matched
# — so the condition was never true and the suite reported "systemd did not
# come up" while printing "degraded" one line later. A container with a
# trimmed unit set is degraded by design, so this is the normal case, not an
# edge one.
for _ in $(seq 1 120); do
  state=$(docker exec "$CNAME" systemctl is-system-running 2>/dev/null || true)
  case "$state" in
    running|degraded) booted=yes; break ;;
  esac
  sleep 1
done
if [ "$booted" != yes ]; then
  skip "systemd did not come up in the container; cannot exercise a service role."
  docker exec "$CNAME" systemctl is-system-running 2>&1 | sed 's/^/           /' >&2
  exit 0
fi

inx() { docker exec "$CNAME" bash -lc "$1"; }

# ── 0. THE IMAGE MUST NOT ALREADY PROVIDE dig ─────────────────────────────
echo
echo "── 0. the disposable host starts WITHOUT dig ──"
if inx 'command -v dig' >/dev/null 2>&1; then
  bad "the image ships no ambient dig" \
      "dig is already present, so this suite cannot prove the role installs it"
else
  ok "no dig in the image — the role must supply it"
fi

# ⚠️ /repo IS READ-ONLY, so the role runs from a writable copy. The copy is of
# the real repository, not a curated subset.
inx 'rm -rf /work && cp -a /repo /work' >/dev/null 2>&1

run_role() {  # run_role <logfile> [extra ansible args...]
  local log=$1; shift
  # ⚠️ bind 127.0.0.1 ONLY. The role refuses an empty or wildcard bind list,
  # which is the behaviour we want in production; inside the container the
  # only meaningful address is loopback.
  docker exec "$CNAME" bash -lc \
    "cd /work && ansible-playbook -i localhost, -c local tests/container/coredns-disposable-play.yml \
       -e '{\"coredns_bind_addresses\": [\"127.0.0.1\"]}' $*" \
    > "$log" 2>&1
}

echo
echo "── 1. first run: the whole role on a clean Linux host ──"
run_role /tmp/coredns-linux-1.log
rc1=$?
if [ $rc1 -ne 0 ]; then
  bad "the role converges on a clean host" "exit $rc1"
  tail -30 /tmp/coredns-linux-1.log | sed 's/^/           /'
  exit 1
fi
ok "the role converged (exit 0)"

inx 'command -v dig' >/dev/null 2>&1 \
  && ok "the role installed dig before verification" \
  || bad "the role installed dig" "still absent after a successful run"
# ⚠️ ASKED OF dpkg, NOT OF THE RUN LOG. The first version grepped the log for
# "bind9-dnsutils" — and that string is only in the log when the install
# FAILS and Ansible quotes the package in its error. A successful run names
# the task, not the package, so the check went red on the run where the
# install finally worked. A test that passes only while the thing is broken
# is worse than no test.
# ⚠️ `dpkg-query -s`, NOT `-W -f=${Status}` — inx runs its argument through
# `bash -lc`, which would expand ${Status} to nothing before dpkg ever saw it.
inx 'dpkg-query -s bind9-dnsutils' 2>/dev/null | grep -q 'Status: install ok installed' \
  && ok "it installed the canonical Debian package (bind9-dnsutils)" \
  || bad "bind9-dnsutils is installed" "dpkg does not report it as installed"
grep -q 'Unpack it (Linux)' /tmp/coredns-linux-1.log \
  && ok "the Linux unarchive path executed (not the Darwin tar path)" \
  || bad "the Linux extraction path executed" "not present in the run log"

echo
echo "── 2. the service is real, and answers ──"
# ⚠️ CAPTURE ONCE, THEN TEST — DO NOT RUN THE COMMAND TWICE. These two
# checks used to execute the container command once for the test and AGAIN
# to build the failure message, with different stderr handling each time
# (`2>/dev/null` for the test, `2>&1` for the message). CI then produced the
# contradiction that makes the pattern indefensible:
#
#   FAIL  version 1.14.7
#         CoreDNS-1.14.7
#
# — the failure message printed the exact string the test had just claimed
# was absent, because the two invocations did not see the same output. A
# check whose pass and fail paths run different commands is not a check; it
# cannot be trusted in either direction, and it wastes a CI run to say so.
svc_state=$(inx 'systemctl is-active coredns' 2>&1 | tr -d '\r' | head -1)
[ "$svc_state" = active ] && ok "coredns.service is active" \
  || bad "coredns.service is active" "systemctl is-active said '$svc_state'"
inx 'id coredns' >/dev/null 2>&1 && ok "the coredns service account exists" \
  || bad "service account exists" "id coredns failed"
inx 'test -x /usr/local/sbin/coredns' && ok "the binary is installed" \
  || bad "binary installed" "/usr/local/sbin/coredns missing"
ver_out=$(inx '/usr/local/sbin/coredns --version' 2>&1 | tr -d '\r')
printf '%s' "$ver_out" | grep -q 'CoreDNS-1.14.7' \
  && ok "it reports CoreDNS-1.14.7" \
  || bad "version 1.14.7" "reported: $(printf '%s' "$ver_out" | head -1)"

for rec in "dc1-arm-1.dc1.lan 10.0.0.22" "dc1-x86.dc1.lan 10.0.0.3" "keel-dev.dc1.lan 10.0.0.3"; do
  n=${rec%% *}; want=${rec##* }
  got=$(inx "dig +short +time=3 +tries=1 @127.0.0.1 $n A" 2>/dev/null | tr -d '\r\n')
  [ "$got" = "$want" ] && ok "$n -> $want (UDP)" || bad "$n -> $want" "got '$got'"
done
got=$(inx 'dig +short +tcp +time=3 +tries=1 @127.0.0.1 keel-dev.dc1.lan A' 2>/dev/null | tr -d '\r\n')
[ "$got" = "10.0.0.3" ] && ok "keel-dev.dc1.lan -> 10.0.0.3 (TCP)" || bad "TCP query" "got '$got'"

resv=$(inx 'dig +time=3 +tries=1 @127.0.0.1 keel.dc1.lan A' 2>/dev/null)
printf '%s' "$resv" | grep -q 'status: NXDOMAIN' && printf '%s' "$resv" | grep -qE 'flags:[^;]* aa[ ;]' \
  && ok "keel.dc1.lan -> authoritative NXDOMAIN" \
  || bad "keel.dc1.lan authoritative NXDOMAIN" "$(printf '%s' "$resv" | grep -E 'status|flags' | tr '\n' ' ')"
resv=$(inx 'dig +time=3 +tries=1 @127.0.0.1 nothing-here.dc1.lan A' 2>/dev/null)
printf '%s' "$resv" | grep -q 'status: NXDOMAIN' && printf '%s' "$resv" | grep -qE 'flags:[^;]* aa[ ;]' \
  && ok "an unknown dc1.lan name -> authoritative NXDOMAIN" \
  || bad "unknown name authoritative NXDOMAIN" "$(printf '%s' "$resv" | grep -E 'status|flags' | tr '\n' ' ')"

code=$(inx 'curl -sS -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:8653/health' 2>/dev/null)
[ "$code" = 200 ] && ok "health 200 on 8653" || bad "health 200 on 8653" "got '$code'"
code=$(inx 'curl -sS -o /dev/null -w "%{http_code}" --max-time 5 http://127.0.0.1:8654/ready' 2>/dev/null)
[ "$code" = 200 ] && ok "ready 200 on 8654" || bad "ready 200 on 8654" "got '$code'"

# ── 3. the handler-order regression ───────────────────────────────────────
echo
echo "── 3. a configuration change must restart BEFORE verification ──"
PID1=$(inx 'systemctl show coredns -p MainPID --value' 2>/dev/null | tr -d '\r\n')
[ -n "$PID1" ] && [ "$PID1" != 0 ] && ok "running pid before the change: $PID1" \
  || bad "a pid before the change" "got '$PID1'"

if [ "$MODE" = "--red" ]; then
  cp "$MAIN" "$WORK/main.yml.orig"
  # ⚠️ REMOVE THE WHOLE TASK, NAME AND ALL. Deleting only the
  # `ansible.builtin.meta: flush_handlers` line leaves an orphan `- name:`
  # with no module, and Ansible dies on "no module/action detected in task"
  # in a third of a second — before it installs anything, before it
  # reconfigures anything, and nowhere near verification.
  #
  # The run still "fails", the old pid is still alive, the old port is still
  # live and the new one is still absent, so three of the four RED checks
  # below pass TRIVIALLY. That is a vacuous proof: it would hold just as well
  # against a typo. The fourth check — that it failed polling the NEW ready
  # port against the OLD process — is the one that caught this, which is
  # precisely why "red for the right reason" is a rule here.
  # The `(?:  #[^\n]*\n|\n)*` spans the comment block that sits between the
  # task's name and its module — the task is heavily annotated, and a pattern
  # that assumed the two lines were adjacent would match nothing and leave
  # the flush in place, turning the RED run green for no reason at all.
  perl -0pi -e 's{- name: Apply every pending restart[^\n]*\n(?:  \#[^\n]*\n|\n)*  ansible\.builtin\.meta: flush_handlers\n}{}' "$MAIN"
  RED_APPLIED=yes
  grep -q 'flush_handlers' "$MAIN" && { bad "RED: flush removed" "still present"; exit 1; }
  # ⚠️ AND NO ORPHANED NAME MAY REMAIN. This is the actual check, not a YAML
  # parse: a `- name:` with no module is the exact wreckage the first version
  # left behind, and it is what made the run die instantly instead of
  # reaching verification. Checked by absence of the task name, so the
  # harness needs no YAML library on the host.
  grep -q 'Apply every pending restart' "$MAIN" \
    && { bad "RED: no orphaned task left behind" \
              "the name survived without its module — the run would die parsing, not verifying"; exit 1; }
  echo "  RED mode: flush removed from $MAIN (restored in cleanup)"
  inx 'rm -rf /work && cp -a /repo /work' >/dev/null 2>&1
fi

run_role /tmp/coredns-linux-2.log -e coredns_health_address=127.0.0.1:8753 \
                                  -e coredns_ready_address=127.0.0.1:8754
rc2=$?
PID2=$(inx 'systemctl show coredns -p MainPID --value' 2>/dev/null | tr -d '\r\n')

if [ "$MODE" = "--red" ]; then
  if [ $rc2 -eq 0 ]; then
    bad "RED: the run fails without the flush" "it SUCCEEDED — is the flush really gone?"
  else
    ok "RED: the run failed, as it must without the flush"
    [ "$PID2" = "$PID1" ] && ok "RED: the OLD pid $PID1 is still running (stale process)" \
      || bad "RED: old pid survives" "pid $PID1 -> $PID2"
    inx 'curl -sS -o /dev/null --max-time 3 http://127.0.0.1:8653/health' >/dev/null 2>&1 \
      && ok "RED: the OLD health port 8653 is still live" \
      || bad "RED: old port still live" "8653 is closed"
    inx 'curl -sS -o /dev/null --max-time 3 http://127.0.0.1:8753/health' >/dev/null 2>&1 \
      && bad "RED: the NEW health port is absent" "8753 is already listening" \
      || ok "RED: the NEW health port 8753 is absent"
    # ⚠️ THE CHECK THAT CAUGHT A VACUOUS RED. The three above can all pass
    # when the run dies instantly for an unrelated reason — nothing started,
    # so of course the old pid is alive and the new port is absent. This one
    # requires the failure to be ABOUT the new ports, which only happens if
    # the role actually got as far as verifying. It is the difference between
    # reproducing the defect and merely failing.
    if grep -qE 'Connection refused|8753|8754' /tmp/coredns-linux-2.log; then
      ok "RED: it failed polling the NEW ports against the OLD process"
    else
      bad "RED: failed for the stale-process reason" \
          "the run failed, but not at verification — see the tail below"
      tail -25 /tmp/coredns-linux-2.log | sed 's/^/           /'
    fi
  fi
  echo; echo "RED phase complete — the harness reproduces the defect on Linux."
  exit $((fail > 0))
fi

if [ $rc2 -ne 0 ]; then
  bad "the reconfigure run converges" "exit $rc2"
  tail -30 /tmp/coredns-linux-2.log | sed 's/^/           /'
  exit 1
fi
ok "the reconfigure run converged (exit 0)"
[ -n "$PID2" ] && [ "$PID2" != "$PID1" ] \
  && ok "the service RESTARTED before verification ($PID1 -> $PID2)" \
  || bad "restarted before verification" "pid $PID1 -> $PID2; the handler did not run in time"
inx 'curl -sS -o /dev/null --max-time 3 http://127.0.0.1:8753/health' >/dev/null 2>&1 \
  && ok "the NEW health port 8753 is live" || bad "new port live" "8753 not answering"
inx 'curl -sS -o /dev/null --max-time 3 http://127.0.0.1:8653/health' >/dev/null 2>&1 \
  && bad "the OLD health port is closed" "8653 still answering" \
  || ok "the OLD health port 8653 is closed"

# ── 4. idempotence ────────────────────────────────────────────────────────
echo
echo "── 4. an unchanged third run is a genuine no-op ──"
PID_BEFORE=$(inx 'systemctl show coredns -p MainPID --value' 2>/dev/null | tr -d '\r\n')
run_role /tmp/coredns-linux-3.log -e coredns_health_address=127.0.0.1:8753 \
                                  -e coredns_ready_address=127.0.0.1:8754
rc3=$?
PID_AFTER=$(inx 'systemctl show coredns -p MainPID --value' 2>/dev/null | tr -d '\r\n')
[ $rc3 -eq 0 ] && ok "third run converged (exit 0)" || bad "third run converges" "exit $rc3"
grep -qE '^localhost.*changed=0 ' /tmp/coredns-linux-3.log \
  && ok "third run reported changed=0" \
  || bad "third run is changed=0" "$(grep -E '^localhost' /tmp/coredns-linux-3.log | tail -1)"
[ "$PID_AFTER" = "$PID_BEFORE" ] && ok "no restart on the no-op run (pid $PID_AFTER)" \
  || bad "no restart on the no-op run" "pid $PID_BEFORE -> $PID_AFTER"
got=$(inx 'dig +short +time=3 +tries=1 @127.0.0.1 keel-dev.dc1.lan A' 2>/dev/null | tr -d '\r\n')
[ "$got" = "10.0.0.3" ] && ok "records unchanged after the no-op run" || bad "records unchanged" "got '$got'"

echo
if [ "$fail" -gt 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) checks." >&2
  exit 1
fi
echo "PASS — $pass checks: the role installs its own verifier prerequisite,"
echo "converges on a clean Linux host, serves the zone over UDP and TCP,"
echo "restarts before verification when configuration changes, and is a"
echo "genuine no-op on an unchanged run."
