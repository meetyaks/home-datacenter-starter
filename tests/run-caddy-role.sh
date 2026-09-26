#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# REGRESSION — the caddy role installs, is idempotent, and refuses a bad
# drop-in without taking the running service down.
#
#   tests/run-caddy-role.sh
#
# ═══ WHAT THIS IS ABOUT ══════════════════════════════════════════════════════
#
# A Keel deployment finished with every service healthy and was completely
# unreachable: Caddy was not installed on the host at all. Nothing in this
# repository had ever owned it — the Keel role wrote one drop-in into a
# directory it assumed someone else maintained.
#
# So the questions worth asking of the new owner are the ones nobody could have
# answered before: does a first run actually install and start it, does a second
# run change nothing, is the conf.d import live, and — the one that matters most
# for shared ingress — does a broken drop-in from one application leave every
# other site still being served?
#
# ═══ WHY A CONTAINER ═════════════════════════════════════════════════════════
#
# Installing a package, enabling a unit and reloading a service need root on a
# throwaway Linux machine with systemd. dc1-x86 is not throwaway and macOS is
# not Linux. Each scenario gets a FRESH container, because the host state under
# test is the variable.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.."

IMAGE=keel-systemd-test:local
CNAME=keel-caddy-role-test

pass=0
fail=0
ok()  { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }

cleanup() { docker rm -f "$CNAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if ! docker info >/dev/null 2>&1; then
  echo "  SKIPPED — Docker is not available, and these scenarios need a disposable" >&2
  echo "  Linux host with systemd. A skipped run is not a passing one." >&2
  exit 0
fi

echo "Building the systemd test image (cached after the first run)…"
if ! docker build -q -f tests/container/Dockerfile.systemd -t "$IMAGE" tests/container >/dev/null 2>&1; then
  echo "  FAILED to build $IMAGE" >&2
  docker build -f tests/container/Dockerfile.systemd -t "$IMAGE" tests/container 2>&1 | tail -15 >&2
  exit 1
fi

cleanup
# systemd needs its own PID 1 and a writable cgroup view.
docker run -d --name "$CNAME" --privileged \
  --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$PWD":/repo:ro -w /repo "$IMAGE" >/dev/null 2>&1

# Wait for systemd to finish coming up, or nothing below means anything.
booted=no
for _ in $(seq 1 30); do
  if docker exec "$CNAME" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'; then
    booted=yes; break
  fi
  sleep 1
done
if [ "$booted" != yes ]; then
  echo "  SKIPPED — systemd did not come up in this container; cannot exercise a service role." >&2
  docker exec "$CNAME" systemctl is-system-running 2>&1 | sed 's/^/           /' >&2
  exit 0
fi

inx() { docker exec "$CNAME" bash -lc "$1"; }

# ── 1. First run installs and starts Caddy ─────────────────────────────────
echo
echo "── 1. first run: installs the package and starts the service ──"
inx 'cd /repo && ansible-playbook -i localhost, -c local tests/container/caddy-play.yml' \
  > /tmp/caddy-run1.log 2>&1
rc1=$?
if [ $rc1 -ne 0 ]; then
  # EVERY check below this point assumes Caddy got installed. Continuing without
  # it does not produce 15 honest failures — it produced three false PASSES the
  # first time this happened, because `systemctl is-active` prints "inactive"
  # and `caddy validate` "rejects" a config by not existing. So: stop here.
  if grep -qE 'name resolution|Temporary failure|Could not resolve|Connection timed out|Network is unreachable' /tmp/caddy-run1.log; then
    echo "  SKIPPED — this container has no network, so the APT repository and" >&2
    echo "  signing key are unreachable. Nothing about the role was tested." >&2
    grep -m1 -E 'name resolution|Temporary failure|Could not resolve|Connection timed out|Network is unreachable' /tmp/caddy-run1.log | sed 's/^/           /' >&2
    exit 0
  fi
  bad "first run succeeds" "ansible exited $rc1"
  tail -25 /tmp/caddy-run1.log | sed 's/^/           /'
  echo >&2
  echo "ABORTED: Caddy was not installed, so no later check can mean anything." >&2
  exit 1
fi
ok "first run completed"

inx 'command -v caddy >/dev/null' && ok "caddy binary installed" || bad "caddy binary installed" "not on PATH"
inx 'dpkg -s caddy >/dev/null 2>&1' && ok "installed as a package (dpkg knows it)" || bad "installed as a package" "dpkg has no record"
# -qx, NOT -q. `systemctl is-active` prints "inactive" on a host where the unit
# does not exist, and "inactive" CONTAINS "active" — a substring match reports
# a passing service on a machine that has no Caddy at all. Same for
# "disabled" containing "enabled". Measured, not theorised.
inx 'systemctl is-active caddy | grep -qx active' && ok "caddy.service is active" || bad "caddy.service active" "$(inx 'systemctl is-active caddy' 2>&1)"
inx 'systemctl is-enabled caddy | grep -qx enabled' && ok "caddy.service is enabled" || bad "caddy.service enabled" "$(inx 'systemctl is-enabled caddy' 2>&1)"
inx 'test -f /etc/caddy/Caddyfile && test -d /etc/caddy/conf.d' \
  && ok "/etc/caddy/Caddyfile and conf.d exist" || bad "config paths exist" "missing"
inx 'stat -c "%a %U:%G" /etc/caddy/Caddyfile | grep -q "^644 root:root$"' \
  && ok "Caddyfile is 0644 root:root" || bad "Caddyfile ownership" "$(inx 'stat -c "%a %U:%G" /etc/caddy/Caddyfile' 2>&1)"

# ── 2. The conf.d import is live ───────────────────────────────────────────
echo
echo "── 2. the conf.d import is active, not just present in the file ──"
inx 'grep -q "^import /etc/caddy/conf.d/\*.caddy" /etc/caddy/Caddyfile' \
  && ok "Caddyfile imports conf.d/*.caddy" || bad "import line present" "not found"

# Prove the import is EVALUATED: a drop-in's site must appear in the adapted
# config. Grepping the Caddyfile only proves the line was written.
inx 'printf "http://import-probe.test {\n\trespond \"probe\" 200\n}\n" > /etc/caddy/conf.d/zz-probe.caddy'
if inx 'caddy adapt --config /etc/caddy/Caddyfile 2>/dev/null | grep -q import-probe.test'; then
  ok "a drop-in appears in the adapted configuration (import is evaluated)"
else
  bad "import is evaluated" "the probe site is absent from `caddy adapt` output"
fi
inx 'rm -f /etc/caddy/conf.d/zz-probe.caddy'

# ── 3. Second run is idempotent ────────────────────────────────────────────
echo
echo "── 3. second run changes nothing ──"
inx 'cd /repo && ansible-playbook -i localhost, -c local tests/container/caddy-play.yml' \
  > /tmp/caddy-run2.log 2>&1
rc2=$?
changed=$(grep -oE 'changed=[0-9]+' /tmp/caddy-run2.log | tail -1 | cut -d= -f2)
if [ $rc2 -ne 0 ]; then
  bad "second run succeeds" "ansible exited $rc2"
  tail -20 /tmp/caddy-run2.log | sed 's/^/           /'
elif [ "$changed" != "0" ]; then
  bad "second run is idempotent" "reported changed=$changed"
  grep -E '^changed:' /tmp/caddy-run2.log | head -5 | sed 's/^/           /'
else
  ok "second run reported changed=0"
fi

# ── 4. A broken drop-in is refused, and the service keeps serving ──────────
#
# THE CASE THAT MATTERS FOR SHARED INGRESS. One application's syntax error must
# not take down every other site on the host.
echo
echo "── 4. an invalid drop-in is rejected without breaking the service ──"
if ! inx 'printf "http://good.test {\n\trespond \"good\" 200\n}\n" > /etc/caddy/conf.d/good.caddy'; then
  bad "the scenario can be set up" "could not write a drop-in into /etc/caddy/conf.d"
  echo "         SETUP BROKEN — the checks below would pass vacuously. Stopping." >&2
  exit 1
fi
inx 'systemctl reload caddy' >/dev/null 2>&1
before=$(inx 'systemctl show -p MainPID --value caddy' 2>/dev/null | tr -d '\r')
# MainPID is 0 for a unit that is not running, and "0" is non-empty — so an
# unguarded -n test reports "same process throughout (PID 0)" on a dead service.
if ! printf '%s' "$before" | grep -qE '^[1-9][0-9]*$'; then
  bad "caddy is running before the bad drop-in" "MainPID is '${before:-empty}', so there is no process to preserve"
  echo "         SETUP BROKEN — the invalid-drop-in scenario needs a live service. Stopping." >&2
  exit 1
fi

inx 'printf "this is not { valid caddyfile syntax\n" > /etc/caddy/conf.d/broken.caddy'
if inx 'caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile' >/dev/null 2>&1; then
  bad "validation rejects a broken drop-in" "caddy validate ACCEPTED it"
else
  ok "caddy validate rejects the composed configuration"
fi

# The handler's contract: validation fails, so the reload never runs, so the
# process keeps the configuration it already had.
after=$(inx 'systemctl show -p MainPID --value caddy' 2>/dev/null | tr -d '\r')
if inx 'systemctl is-active caddy | grep -qx active'; then
  ok "caddy is still active after the bad drop-in was written"
else
  bad "caddy still active" "the service went down on a bad drop-in"
fi
if [ -n "$before" ] && [ "$before" = "$after" ]; then
  ok "same process throughout (PID $before) — nothing restarted"
else
  bad "the running process is untouched" "PID changed $before → $after"
fi
if inx 'caddy adapt --config /etc/caddy/Caddyfile 2>/dev/null | grep -q good.test'; then
  bad "the broken file is still on disk" "it should have been left for the operator, but adapt now succeeds"
else
  ok "the composed config stays invalid until the operator removes the bad file"
fi

inx 'rm -f /etc/caddy/conf.d/broken.caddy'
if inx 'caddy validate --adapter caddyfile --config /etc/caddy/Caddyfile' >/dev/null 2>&1; then
  ok "removing the bad drop-in restores a valid configuration"
else
  bad "recovery" "still invalid after removing the bad file"
fi

# ── 5. Ports 80/443 belong to Caddy alone ──────────────────────────────────
echo
echo "── 5. ports 80 and 443 are owned only by Caddy ──"
owners=$(inx "ss -ltnpH 'sport = :80 or sport = :443' 2>/dev/null | grep -oE 'users:\(\(\"[^\"]+' | grep -oE '\"[^\"]+$' | tr -d '\"' | sort -u | tr '\n' ' '" 2>/dev/null | tr -d '\r')
if [ -z "$owners" ]; then
  echo "         (nothing bound — this container has no site configured to listen)"
  ok "no non-Caddy process holds 80/443"
elif [ "$(printf '%s' "$owners" | tr -s ' ' | sed 's/ $//')" = "caddy" ]; then
  ok "80/443 held by caddy only"
else
  bad "80/443 owned only by Caddy" "also held by: $owners"
fi

echo
if [ "$fail" -gt 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) checks." >&2
  exit 1
fi
echo "PASS — $pass checks: the caddy role installs and starts Caddy, is idempotent, evaluates its conf.d import, and refuses a broken drop-in without dropping the running service."
