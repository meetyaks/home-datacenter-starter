#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# REGRESSION — an ingress change is ACTIVE before anything verifies it.
#
#   tests/run-caddy-handler-order.sh
#
# ═══ WHAT THIS IS ABOUT ══════════════════════════════════════════════════════
#
# dc1-x86, after a deploy that reported an ingress failure:
#
#   · Caddy v2.11.4 installed, enabled, active
#   · /etc/caddy/conf.d/keel.caddy present
#   · `caddy validate` on those files: Valid configuration, HTTPS on :443
#   · the RUNNING process's journal:
#       No files matching import glob pattern /etc/caddy/conf.d/*.caddy
#   · nothing listening on :80 or :443
#   · Keel itself healthy: 127.0.0.1:8080 → 200, 127.0.0.1:3000/healthz → 200
#
# Every file was correct. Ansible runs handlers at the END of a play, so the
# `Reload Caddy` notification from the route template was still PENDING when
# verification ran. Verification tested the configuration Caddy had loaded
# before the drop-in existed, failed — and because the play failed, the
# pending handler never ran at all. The route never became active.
#
# The lesson generalises past Caddy: a check that reads FILES cannot tell you
# what a running process has LOADED. Every check below that matters asks the
# process.
#
# ═══ WHY A CONTAINER ═════════════════════════════════════════════════════════
#
# The precondition is "Caddy is already running, with an empty conf.d". That
# needs a real service on a throwaway machine, and each scenario needs it
# fresh, because the whole question is what was loaded when.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.."

IMAGE=keel-systemd-test:local
PLAYFILE=tests/container/handler-order-play.yml

pass=0
fail=0
ok()  { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }
die() { printf '\n\033[31mABORTED\033[0m — %s\n' "$1" >&2; exit 1; }

CONTAINERS=""
cleanup() { for c in $CONTAINERS; do docker rm -f "$c" >/dev/null 2>&1 || true; done; }
trap cleanup EXIT

guard_net() {
  grep -qE 'name resolution|Temporary failure|Could not resolve|Connection timed out|Network is unreachable' "$1" || return 0
  echo >&2
  echo "  SKIPPED — the container lost network during $2, so the role could not" >&2
  echo "  install Caddy. Nothing about handler ordering was tested. Re-run." >&2
  exit 0
}

if ! docker info >/dev/null 2>&1; then
  echo "  SKIPPED — Docker is not available, and this needs a real running service." >&2
  echo "  A skipped run is not a passing one." >&2
  exit 0
fi

echo "Building the systemd test image (cached after the first run)…"
docker build -q -f tests/container/Dockerfile.systemd -t "$IMAGE" tests/container >/dev/null 2>&1 \
  || die "could not build $IMAGE"

# Bring up a disposable host with the repo copied to a WRITABLE path, so a
# scenario can mutate the roles without touching the working tree.
boot() {
  local name=$1
  docker rm -f "$name" >/dev/null 2>&1
  CONTAINERS="$CONTAINERS $name"
  docker run -d --name "$name" --privileged \
    --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
    -v "$PWD":/repo:ro -w /repo "$IMAGE" >/dev/null 2>&1
  local up=no
  for _ in $(seq 1 30); do
    if docker exec "$name" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'; then
      up=yes; break
    fi
    sleep 1
  done
  [ "$up" = yes ] || die "systemd did not come up in $name"
  # The route's hostname must resolve for an HTTPS check to mean anything.
  # Test-fixture only: the real deployment needs an A record on the LAN
  # resolver, which roles/caddy/README.md documents.
  docker exec "$name" bash -lc 'echo "127.0.0.1 keel.dc1.lan" >> /etc/hosts; cp -r /repo /work' >/dev/null 2>&1
}

# ── 1. The precondition: Caddy running with an empty conf.d ────────────────
echo
echo "── 1. the starting state: Caddy up, conf.d empty, nothing on 80/443 ──"
A=keel-handler-order-a
boot "$A"
ax() { docker exec "$A" bash -lc "$1"; }

ax 'cd /work && ansible-playbook -i localhost, -c local tests/container/caddy-play.yml' > /tmp/ho-1.log 2>&1
guard_net /tmp/ho-1.log "scenario 1"
[ "$(grep -oE 'failed=[0-9]+' /tmp/ho-1.log | tail -1 | cut -d= -f2)" = "0" ] \
  || { tail -15 /tmp/ho-1.log | sed 's/^/           /'; die "roles/caddy alone failed; the precondition cannot be set up"; }

ax 'systemctl is-active caddy | grep -qx active' \
  && ok "Caddy is active" || bad "Caddy is active" "$(ax 'systemctl is-active caddy' 2>&1)"
[ "$(ax 'ls /etc/caddy/conf.d | wc -l' 2>/dev/null | tr -d ' \r')" = "0" ] \
  && ok "conf.d is empty" || bad "conf.d is empty" "it already has drop-ins"
if ax 'journalctl -u caddy --no-pager 2>/dev/null | grep -q "No files matching import glob pattern"'; then
  ok "the journal shows the dc1-x86 line: 'No files matching import glob pattern'"
else
  bad "the reported precondition is reproduced" "that journal line is absent"
fi
[ "$(ax "ss -ltnH 'sport = :80 or sport = :443'" 2>/dev/null | grep -c . | tr -d ' \r')" = "0" ] \
  && ok "nothing is listening on :80 or :443 yet" \
  || bad "no listeners yet" "something is already bound"

# ── 2. First deploy: the route is live AT verification time ────────────────
#
# THE REGRESSION. The play's MIDPLAY VERIFICATION task sits exactly where
# verify.yml sits in the real deployment — before Ansible would flush handlers.
echo
echo "── 2. first deploy: the route is already live when verification runs ──"
ax "cd /work && ansible-playbook -i localhost, -c local $PLAYFILE" > /tmp/ho-2.log 2>&1
rc2=$?
guard_net /tmp/ho-2.log "scenario 2"
if [ "$(grep -oE 'failed=[0-9]+' /tmp/ho-2.log | tail -1 | cut -d= -f2)" = "0" ] && [ $rc2 -eq 0 ]; then
  ok "the first-deploy play completes, mid-play verification included"
else
  bad "the first deploy verifies successfully" "the play failed"
  grep -A4 'fatal:' /tmp/ho-2.log | head -8 | sed 's/^/           /'
fi
if grep -qF 'MIDPLAY OK:' /tmp/ho-2.log; then
  ok "the mid-play HTTPS check reached the console over verified TLS"
else
  bad "mid-play HTTPS verification succeeded" "no MIDPLAY OK in the output"
fi

# ORDER, not just outcome: the reload must be proved applied BEFORE the check.
loaded_line=$(grep -n 'The Keel route must be in the configuration Caddy has LOADED' /tmp/ho-2.log | head -1 | cut -d: -f1)
midplay_line=$(grep -n 'MIDPLAY VERIFICATION — the console over HTTPS' /tmp/ho-2.log | head -1 | cut -d: -f1)
flush_line=$(grep -n 'Apply the pending ingress change now' /tmp/ho-2.log | head -1 | cut -d: -f1)
if [ -n "$flush_line" ] && [ -n "$loaded_line" ] && [ -n "$midplay_line" ] \
   && [ "$flush_line" -lt "$loaded_line" ] && [ "$loaded_line" -lt "$midplay_line" ]; then
  ok "order held: flush ($flush_line) → loaded-config assert ($loaded_line) → verification ($midplay_line)"
else
  bad "the reload is applied before verification" \
      "flush=${flush_line:-absent} loaded=${loaded_line:-absent} midplay=${midplay_line:-absent}"
fi

# And the ACTIVE state, asked of the process rather than of the files.
if ax 'curl -fsS http://localhost:2019/config/ 2>/dev/null | grep -q keel.dc1.lan'; then
  ok "keel.dc1.lan is in the configuration Caddy has LOADED (admin API)"
else
  bad "the route is in the loaded configuration" "the admin API does not mention it"
fi
if ax 'journalctl -u caddy --no-pager 2>/dev/null | tail -40 | grep -q "No files matching import glob pattern"'; then
  bad "the running process has re-read conf.d" "the glob warning is still the latest state"
else
  ok "the running process re-read conf.d after the drop-in landed"
fi
owners=$(ax "ss -ltnpH 'sport = :80 or sport = :443'" 2>/dev/null | grep -oE '"[a-z]+"' | tr -d '"' | sort -u | tr '\n' ' ' | sed 's/ $//')
if [ "$owners" = "caddy" ]; then
  ok "ports 80 and 443 are held, and only by caddy"
else
  bad "80/443 exist and belong to Caddy" "owners: '${owners:-nothing listening}'"
fi

# ── 3. The OLD implementation must fail this ───────────────────────────────
#
# A regression that the broken code also passes is not a regression. This
# reverts roles/keel to notifying and leaving the reload for end-of-play, and
# reproduces every symptom from the incident report.
echo
echo "── 3. the old implementation fails the same play, with the same symptoms ──"
B=keel-handler-order-b
boot "$B"
bx() { docker exec "$B" bash -lc "$1"; }
bx 'python3 -c "
p=\"/work/roles/keel/tasks/caddy.yml\"
s=open(p).read()
i=s.index(\"# ═══ APPLY IT NOW.\")
open(p,\"w\").write(s[:i].rstrip()+chr(10))
"' >/dev/null 2>&1
if bx 'grep -q "APPLY IT NOW" /work/roles/keel/tasks/caddy.yml'; then
  die "could not revert to the old implementation; scenario 3 would prove nothing"
fi
ok "reverted roles/keel to end-of-play handler flush"

bx "cd /work && ansible-playbook -i localhost, -c local $PLAYFILE" > /tmp/ho-3.log 2>&1
guard_net /tmp/ho-3.log "scenario 3"
if [ "$(grep -oE 'failed=[0-9]+' /tmp/ho-3.log | tail -1 | cut -d= -f2)" = "0" ]; then
  bad "the old implementation FAILS this regression" "it passed — the test does not catch the defect"
else
  ok "the old implementation fails the mid-play verification"
fi
# …and it fails the way dc1-x86 did, not some other way.
for sym in \
  'drop-in on disk:/etc/caddy/conf.d/keel.caddy:test -f /etc/caddy/conf.d/keel.caddy' \
  'caddy validate still passes:Valid configuration:/usr/bin/caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile' \
  ; do
  label=${sym%%:*}; rest=${sym#*:}; want=${rest%%:*}; cmd=${rest#*:}
  if bx "$cmd" >/dev/null 2>&1; then ok "old-run symptom — $label"; else bad "old-run symptom — $label" "not reproduced"; fi
done
[ "$(bx "ss -ltnH 'sport = :80 or sport = :443'" 2>/dev/null | grep -c . | tr -d ' \r')" = "0" ] \
  && ok "old-run symptom — nothing listening on :80 or :443" \
  || bad "old-run symptom — no listeners" "something is bound"
if bx 'curl -fsS http://localhost:2019/config/ 2>/dev/null | grep -q keel.dc1.lan'; then
  bad "old-run symptom — the route is NOT in the loaded config" "it somehow is"
else
  ok "old-run symptom — the route is absent from the loaded configuration"
fi
if bx 'journalctl -u caddy --no-pager 2>/dev/null | grep -q "No files matching import glob pattern"'; then
  ok "old-run symptom — the exact journal line from the incident report"
else
  bad "old-run symptom — the journal line" "not reproduced"
fi

# ── 4. A malformed drop-in leaves the live route serving ───────────────────
#
# Back on container A, where the Keel route is live and answering.
echo
echo "── 4. a malformed drop-in is refused, and the live route keeps serving ──"
before_pid=$(ax 'systemctl show -p MainPID --value caddy' 2>/dev/null | tr -d '\r')
if ! printf '%s' "$before_pid" | grep -qE '^[1-9][0-9]*$'; then
  die "no live Caddy process on container A; scenario 4 would prove nothing"
fi
ax 'printf "this is not { valid caddyfile\n" > /etc/caddy/conf.d/zz-broken.caddy'
ax "cd /work && ansible-playbook -i localhost, -c local $PLAYFILE" > /tmp/ho-4.log 2>&1
rc4=$?
if [ $rc4 -eq 0 ] && [ "$(grep -oE 'failed=[0-9]+' /tmp/ho-4.log | tail -1 | cut -d= -f2)" = "0" ]; then
  bad "a malformed drop-in fails the run" "the play SUCCEEDED with a broken composed config"
else
  ok "the run fails on the invalid composed configuration"
fi
# It must fail at VALIDATION, before the service is touched.
if grep -q 'Validate the composed Caddy configuration before reloading' /tmp/ho-4.log \
   && grep -A3 'Validate the composed Caddy configuration before reloading' /tmp/ho-4.log | grep -q 'fatal:'; then
  ok "it fails at the pre-reload validation step, before the flush"
else
  bad "validation is what stops it" "it failed somewhere else"
  grep -B2 -A2 'fatal:' /tmp/ho-4.log | head -8 | sed 's/^/           /'
fi
after_pid=$(ax 'systemctl show -p MainPID --value caddy' 2>/dev/null | tr -d '\r')
[ "$before_pid" = "$after_pid" ] \
  && ok "the running process is untouched (PID $before_pid) — no reload, no restart" \
  || bad "the previous configuration keeps running" "PID changed $before_pid → $after_pid"
if ax 'curl -fsS https://keel.dc1.lan/ >/dev/null 2>&1'; then
  ok "the PREVIOUSLY ACTIVE route is still serving over verified TLS"
else
  bad "the active route survives a bad drop-in" "https://keel.dc1.lan/ stopped answering"
fi

# ── 5. Nothing is silently lost when a task fails ──────────────────────────
#
# The handler is still pending after that failure — which is correct, because
# the configuration it would load is invalid. What must never happen is the
# run REPORTING SUCCESS with an unapplied ingress change.
echo
echo "── 5. a failed run never reports an unapplied ingress change as done ──"
grep -qF 'MIDPLAY OK:' /tmp/ho-4.log \
  && bad "verification does not run after a failed reload" "MIDPLAY OK printed on a failed run" \
  || ok "the mid-play verification did not run against a pending handler"
if grep -qE 'failed=[1-9]' /tmp/ho-4.log; then
  ok "the run is reported as failed, not as a deploy with a footnote"
else
  bad "the failure is visible in the recap" "the PLAY RECAP does not show a failure"
fi
ax 'rm -f /etc/caddy/conf.d/zz-broken.caddy'
ax "cd /work && ansible-playbook -i localhost, -c local $PLAYFILE" > /tmp/ho-5.log 2>&1
guard_net /tmp/ho-5.log "scenario 5"
if [ "$(grep -oE 'failed=[0-9]+' /tmp/ho-5.log | tail -1 | cut -d= -f2)" = "0" ]; then
  ok "removing the bad drop-in and re-running recovers cleanly"
else
  bad "recovery" "the run still fails after the bad file was removed"
  grep -A4 'fatal:' /tmp/ho-5.log | head -6 | sed 's/^/           /'
fi
if [ "$(grep -oE 'changed=[0-9]+' /tmp/ho-5.log | tail -1 | cut -d= -f2)" = "0" ]; then
  ok "…and that recovery run is idempotent (changed=0)"
else
  bad "the recovered run is idempotent" "changed=$(grep -oE 'changed=[0-9]+' /tmp/ho-5.log | tail -1 | cut -d= -f2)"
fi

# ── 6. CA trust: managed by Ansible, not by a privileged Caddy ─────────────
echo
echo "── 6. the CA is trusted without giving the caddy service sudo ──"
if ax 'journalctl -u caddy --no-pager 2>/dev/null | grep -qiE "failed to install root certificate|failed to execute sudo"'; then
  bad "no sudo trust error" "Caddy is still trying to install the root itself"
  ax 'journalctl -u caddy --no-pager 2>/dev/null | grep -iE "install root certificate" | tail -1' | sed 's/^/           /'
else
  ok "no sudo trust error in the journal"
fi
if ax 'curl -fsS http://localhost:2019/config/ 2>/dev/null | grep -q "\"install_trust\": *false"'; then
  ok "the loaded config carries install_trust: false"
else
  bad "Caddy is told not to install trust" "install_trust is not false in the loaded config"
fi
ax 'test -s /usr/local/share/ca-certificates/caddy-lan-root.crt' \
  && ok "the role-published root CA is still present" \
  || bad "the published CA survives" "the file the README hands operators is gone"
ax 'ls /etc/ssl/certs/ | grep -qi caddy' \
  && ok "it is installed in the host trust store by the role" \
  || bad "the CA is trusted on the host" "update-ca-certificates did not install it"
# The proof that trust actually works: HTTPS with verification ON, no -k.
if ax 'curl -fsS https://keel.dc1.lan/ >/dev/null 2>&1'; then
  ok "https://keel.dc1.lan/ verifies without --insecure"
else
  bad "the chain verifies from this host" "curl needs --insecure, so trust is not working"
fi
ax 'id -nG caddy 2>/dev/null | grep -qw sudo' \
  && bad "the caddy service has no sudo" "it was added to the sudo group" \
  || ok "the caddy service account has no sudo access"

# ── 7. Forwarded headers still arrive without header_up ────────────────────
echo
echo "── 7. removing the header_up overrides changed nothing the upstream sees ──"
# CODE ONLY. The template now explains in a comment why those lines are gone,
# quoting the validator warning verbatim — and a naive grep matches its own
# documentation. Comment lines are stripped first, the same way two earlier
# checks in this repository had to be after failing on their own prose.
if grep -vE '^[[:space:]]*#' roles/keel/templates/keel.caddy.j2 | grep -qE 'header_up X-Forwarded'; then
  bad "the redundant overrides are gone" "header_up X-Forwarded-* is still a directive in the template"
  grep -nvE '^[[:space:]]*#' roles/keel/templates/keel.caddy.j2 | grep -E 'header_up X-Forwarded' | sed 's/^/           /'
else
  ok "no header_up X-Forwarded-* directive remains (the comment about it does not count)"
fi
fwd=$(ax 'curl -fsS https://keel.dc1.lan/ 2>/dev/null' | tr -d '\r')
case "$fwd" in
  *"proto=[https]"*"host=[keel.dc1.lan]"*)
    ok "the upstream still receives proto=[https] host=[keel.dc1.lan]" ;;
  *)
    bad "Caddy's defaults supply the forwarded headers" "upstream saw: '${fwd:-nothing}'" ;;
esac

echo
if [ "$fail" -gt 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) checks." >&2
  exit 1
fi
echo "PASS — $pass checks: the reload is applied and PROVED ACTIVE before anything verifies it, the old implementation fails this same play with every symptom from the incident, an invalid drop-in leaves the live route serving on the same process, and the CA is trusted without granting the service sudo."
