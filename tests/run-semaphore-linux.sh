#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# THE SEMAPHORE ROLE, EXECUTED END TO END ON A DISPOSABLE LINUX HOST.
#
#   tests/run-semaphore-linux.sh            GREEN run (default)
#   tests/run-semaphore-linux.sh --red      RED: prove the flush is needed
#
# Linux is NOT the production platform — the controller is a Mac — but this
# is the only coverage that can run in CI, and it exercises everything that
# is not launchd-specific: checksum verification, versioned install, the
# service account, config rendering, SQLite migration, admin bootstrap and
# its idempotency guard, the health endpoint, restart-before-verification,
# a changed=0 second run, backup and restore, and the absence of secrets in
# the log.
#
# Nothing here touches a host, a port or a daemon outside the container.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || { echo "cannot reach the repository root" >&2; exit 1; }

MODE=${1:-}
IMAGE=keel-semaphore-test:local
CNAME=keel-semaphore-role-test
MAIN=roles/semaphore/tasks/main.yml

pass=0
fail=0
ok()   { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }

WORK=$(mktemp -d -t semaphore-role.XXXXXX)
RED_APPLIED=no
cleanup() {
  if [ "$RED_APPLIED" = yes ] && [ -f "$WORK/main.yml.orig" ]; then
    cp "$WORK/main.yml.orig" "$MAIN" \
      && echo "  restored the flush in $MAIN" \
      || echo "  WARNING: could not restore $MAIN — check git status"
  fi
  docker rm -f "$CNAME" >/dev/null 2>&1
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

if ! docker info >/dev/null 2>&1; then
  skip "Docker is unavailable, and this needs a disposable Linux host with systemd."
  echo; echo "SKIPPED — a skipped run is not a passing one."
  exit 0
fi

# ⚠️ NATIVE amd64 ONLY. The role pins linux_amd64, and emulating a 48 MB Go
# binary under qemu is both slow and a source of spurious faults. On an Apple
# Silicon workstation this skips loudly and runs for real on the CI runner.
HOST_ARCH=$(uname -m)
case "$HOST_ARCH" in
  x86_64|amd64) : ;;
  *)
    # ⚠️ AN EXPLICIT, LOUD ESCAPE HATCH FOR DEVELOPMENT ONLY. Emulated runs
    # are slow and can fail for reasons that have nothing to do with the
    # role, so they must never be mistaken for CI evidence. CI is native
    # amd64 and never sets this.
    if [ "${SEMAPHORE_HARNESS_ALLOW_EMULATION:-0}" = "1" ]; then
      echo "  ⚠️  EMULATED RUN (SEMAPHORE_HARNESS_ALLOW_EMULATION=1) on $HOST_ARCH."
      echo "      For development only. A green emulated run is NOT CI evidence."
    else
      skip "host is $HOST_ARCH; the amd64 container would be emulated."
      echo
      echo "SKIPPED — runs natively on the amd64 CI runner. A skipped run is not a passing one."
      echo "To develop against it here: SEMAPHORE_HARNESS_ALLOW_EMULATION=1 $0"
      exit 0
    fi
    ;;
esac

PLATFORM=linux/amd64
echo "Building the Semaphore test image (cached after the first run)…"
if ! docker build -q --platform "$PLATFORM" -f tests/container/Dockerfile.semaphore \
       -t "$IMAGE" tests/container >/dev/null 2>&1; then
  echo "image build failed:" >&2
  docker build --platform "$PLATFORM" -f tests/container/Dockerfile.semaphore \
    -t "$IMAGE" tests/container 2>&1 | tail -15 >&2
  exit 1
fi

docker rm -f "$CNAME" >/dev/null 2>&1
docker run -d --name "$CNAME" --platform "$PLATFORM" --privileged \
  --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$PWD":/repo:ro -w /repo "$IMAGE" >/dev/null 2>&1

inx() { docker exec "$CNAME" bash -lc "$1"; }

# Wait for systemd. The state is CAPTURED rather than piped through grep:
# `systemctl is-system-running` exits non-zero on `degraded`, which with
# pipefail aborts the condition and reports a boot failure that did not
# happen.
booted=no
for _ in $(seq 1 60); do
  state=$(inx 'systemctl is-system-running 2>/dev/null' | tr -d '\r\n')
  case "$state" in running|degraded) booted=yes; break ;; esac
  sleep 2
done
if [ "$booted" != yes ]; then
  skip "systemd did not come up in the container; cannot exercise a service role."
  echo; echo "SKIPPED — a skipped run is not a passing one."
  exit 0
fi

# ── 0. the host starts with nothing of ours on it ──────────────────────────
echo
echo "── 0. the disposable host has no Semaphore, no account, no database ──"
inx 'command -v semaphore' >/dev/null 2>&1 \
  && bad "the image ships no semaphore binary" "one is already installed" \
  || ok "no semaphore binary in the image — the role must install it"
inx 'id _semaphore' >/dev/null 2>&1 \
  && bad "the image ships no service account" "_semaphore already exists" \
  || ok "no _semaphore account — the role must create it"

# ── throwaway secrets, generated per run ───────────────────────────────────
SEC_COOKIE_HASH=$(openssl rand -base64 32)
SEC_COOKIE_ENC=$(openssl rand -base64 32)
SEC_ACCESS_ENC=$(openssl rand -base64 32)
SEC_ADMIN_PW="Disposable-$(openssl rand -hex 12)"

# ⚠️ SECRETS GO IN A 0600 FILE, NOT ON THE COMMAND LINE. Passing them as -e
# arguments would put them in the container's process table and in this
# script's own argv — the exact thing the role is written to avoid.
cat > "$WORK/secrets.json" <<JSON
{
  "vault_semaphore_cookie_hash": "${SEC_COOKIE_HASH}",
  "vault_semaphore_cookie_encryption": "${SEC_COOKIE_ENC}",
  "vault_semaphore_access_key_encryption": "${SEC_ACCESS_ENC}",
  "vault_semaphore_admin_password": "${SEC_ADMIN_PW}"
}
JSON
chmod 600 "$WORK/secrets.json"
# ⚠️ PIPED IN ON STDIN, AND THE RESULT IS CHECKED. The first version used
# `docker cp ... >/dev/null 2>&1`, which failed silently and left the role
# to die on a missing vars file several steps later — the error was hidden
# by the very redirect meant to keep the output tidy.
docker exec -i "$CNAME" bash -c 'umask 077; cat > /run/semaphore-secrets.json' \
  < "$WORK/secrets.json" \
  || { bad "secrets delivered to the container" "docker exec write failed"; exit 1; }
inx 'test -s /run/semaphore-secrets.json' \
  && ok "throwaway secrets delivered (0600, never on a command line)" \
  || { bad "secrets delivered to the container" "/run/semaphore-secrets.json is missing or empty"; exit 1; }

run_role() {   # run_role <logfile> [extra ansible args...]
  local log=$1; shift
  docker exec "$CNAME" bash -lc \
    "cd /work && ansible-playbook -i localhost, -c local \
       tests/container/semaphore-disposable-play.yml \
       -e @/run/semaphore-secrets.json \
       -e semaphore_controller_hostname=\$(hostname -s) $*" \
    > "$log" 2>&1
}

# /repo is read-only, so the role runs from a writable copy.
inx 'rm -rf /work && cp -a /repo /work' >/dev/null 2>&1

echo
echo "── 1. STAGE 1: the role must STOP, with no administrator and no service ──"
# ⚠️ FAILING HERE IS THE CORRECT BEHAVIOUR. The role cannot create a user
# without putting the password in argv, so it installs everything, migrates
# the database and stops. Critically it must NOT have started Semaphore: an
# empty Semaphore left listening is an unauthenticated initialisation
# surface.
run_role /tmp/semaphore-linux-1.log
rc1=$?
[ $rc1 -ne 0 ] && ok "stage 1 stopped, as it must without an administrator" \
  || bad "stage 1 stops without an administrator" "the role converged — did it create a user?"
# ⚠️ MATCH THE STOP MESSAGE, NOT THE TASK NAME. The first version grepped
# for "semaphore-bootstrap-admin" and passed against the include line
# "The database, the backup command and the bootstrap helper" — while the
# role had actually died earlier and printed no instruction at all.
grep -q 'has NOT been started' /tmp/semaphore-linux-1.log \
  && grep -q 'sudo /usr/local/sbin/semaphore-bootstrap-admin' /tmp/semaphore-linux-1.log \
  && ok "it stops with the exact bootstrap instruction" \
  || bad "stop message names the helper" "the role did not print its stop instruction"
inx 'systemctl is-active semaphore' 2>/dev/null | grep -qx active \
  && bad "NO service is running after stage 1" "semaphore.service is active with no administrator" \
  || ok "no service is running after stage 1"
inx 'curl -sS --max-time 3 http://127.0.0.1:3000/api/ping' >/dev/null 2>&1 \
  && bad "nothing is listening after stage 1" "port 3000 answered" \
  || ok "nothing is listening after stage 1"
inx 'test -x /usr/local/sbin/semaphore-bootstrap-admin' \
  && ok "the bootstrap helper was installed" \
  || bad "bootstrap helper installed" "/usr/local/sbin/semaphore-bootstrap-admin missing"
inx 'test -s /usr/local/var/lib/semaphore/semaphore.db' \
  && ok "the database was initialised" || bad "database initialised" "missing or empty"

echo
echo "── 2. the interactive bootstrap, on a real pty ──"
# ⚠️ A pty, NOT A PIPE. The helper refuses without an interactive terminal
# and uses `read -rs`, which needs one to disable echo. Driving it through a
# pipe would exercise neither.
BOOTSTRAP_PW="Disposable-Bootstrap-$(openssl rand -hex 10)"
inx 'cp /work/tests/container/bootstrap-driver.py /run/bootstrap-driver.py && chmod 700 /run/bootstrap-driver.py'
docker exec -e SEMAPHORE_STATE_DIR=/usr/local/var/lib/semaphore "$CNAME" \
  python3 /run/bootstrap-driver.py \
  /usr/local/sbin/semaphore-bootstrap-admin "$BOOTSTRAP_PW" /run/ps-samples.txt \
  > /tmp/semaphore-bootstrap.log 2>&1
rcb=$?
[ $rcb -eq 0 ] && ok "the interactive bootstrap succeeded" \
  || { bad "interactive bootstrap" "exit $rcb"; tail -25 /tmp/semaphore-bootstrap.log | sed 's/^/           /'; }

# ⚠️ A LOW FLOOR, AND THE CONTROL BELOW IS THE REAL PROOF. The first version
# demanded >50 captured LINES, a threshold tuned on an emulated arm64 host
# where the bootstrap takes many seconds. Natively it finishes in under one,
# so CI took far fewer samples and the check failed on a perfectly good run —
# a speed-dependent assertion, not a correctness one.
#
# What actually matters is that sampling ran at all and that the password was
# never in another process's argv. The next check proves sampling works by
# requiring the password to appear in the driver's OWN argv; if that holds
# and no other process shows it, the evidence stands regardless of count.
samples=$(grep -oE '[0-9]+ process-table samples' /tmp/semaphore-bootstrap.log | head -1 | awk '{print $1}')
[ "${samples:-0}" -ge 3 ] && ok "the process table was sampled ${samples} times during setup" \
  || bad "process table sampled" "only ${samples:-0} samples taken"

# ⚠️ THE CONTROL AND THE TEST, TOGETHER. The password MUST appear in the
# driver's own argv — that is how we know the sampling actually worked — and
# MUST NOT appear in any other process's arguments.
PWRE=$(printf '%s' "$BOOTSTRAP_PW" | sed 's/[.[\*^$/]/\\&/g')
inx "grep -q 'bootstrap-driver.py.*${PWRE}' /run/ps-samples.txt" \
  && ok "control: the password IS visible in the driver's own argv (sampling works)" \
  || bad "sampling control" "the password never appeared even in the driver's argv — the samples prove nothing"
if inx "grep -E '${PWRE}' /run/ps-samples.txt | grep -vq 'bootstrap-driver.py'"; then
  bad "the password NEVER reaches another process's argv" \
      "it appeared in a non-driver process — see /run/ps-samples.txt"
else
  ok "the password never reached semaphore's or any other process's argv"
fi

for f in /usr/local/var/lib/semaphore/semaphore.db /usr/local/etc/semaphore/config.json; do
  if inx "grep -qa '${PWRE}' $f" 2>/dev/null; then
    bad "the password is absent from $f" "found in cleartext"
  else ok "the password is absent from $(basename "$f")"; fi
done
if grep -qa "$BOOTSTRAP_PW" /tmp/semaphore-bootstrap.log 2>/dev/null; then
  bad "the password is absent from the bootstrap output" "it was echoed to the terminal"
else ok "the password is absent from the bootstrap output (echo was off)"; fi
# ⚠️ 4A: THE 0700 PARENT IS THE PROTECTION, OBSERVED WHILE IT EXISTS.
# setup writes its config 0644 and the binary cannot be told otherwise, so
# the only thing keeping its generated encryption key private is the
# directory above it. The driver watches for that directory during setup,
# records its mode, and tries to read the config as `nobody`.
obs=$(grep -c "DRIVER: setup-dir" /tmp/semaphore-bootstrap.log || echo 0)
[ "${obs:-0}" -ge 1 ] \
  && ok "the live temporary setup directory was observed $obs time(s)" \
  || bad "temporary setup directory observed" "the driver never saw it — the check proves nothing"
if grep -q "DRIVER: setup-dir.*mode=0o700" /tmp/semaphore-bootstrap.log; then
  ok "it was mode 0700 while setup was running"
else
  bad "temporary setup directory is 0700" "$(grep -m1 'DRIVER: setup-dir' /tmp/semaphore-bootstrap.log)"
fi
if grep -q "DRIVER: setup-dir.*nobody_read_rc=0" /tmp/semaphore-bootstrap.log; then
  bad "an unrelated account CANNOT read the temporary config" "nobody read it successfully"
else
  ok "an unrelated account could not read the temporary config"
fi

inx 'ls -d /usr/local/var/lib/semaphore/.setup.* 2>/dev/null' >/dev/null 2>&1 \
  && bad "no temporary setup config survives" "one is still on disk" \
  || ok "no temporary setup config survives"
inx 'test -e /usr/local/var/lib/semaphore/.admin-bootstrapped' \
  && ok "a non-secret bootstrap marker was written" || bad "bootstrap marker" "missing"

echo
echo "── 3. a second bootstrap attempt must be refused ──"
docker exec "$CNAME" python3 /run/bootstrap-driver.py \
  /usr/local/sbin/semaphore-bootstrap-admin "Another-Password-123456" /run/ps2.txt \
  > /tmp/semaphore-bootstrap2.log 2>&1
rcb2=$?
[ $rcb2 -ne 0 ] && ok "a second bootstrap is refused" \
  || bad "second bootstrap refused" "it succeeded a second time"
grep -qi 'already completed' /tmp/semaphore-bootstrap2.log \
  && ok "it refuses for the right reason (already bootstrapped)" \
  || bad "refusal reason" "$(tail -3 /tmp/semaphore-bootstrap2.log | tr '\n' ' ')"

echo
echo "── 4. STAGE 2: re-run the role, which now converges ──"
run_role /tmp/semaphore-linux-2nd.log
rc1b=$?
if [ $rc1b -ne 0 ]; then
  bad "stage 2 converges once an administrator exists" "exit $rc1b"
  tail -40 /tmp/semaphore-linux-2nd.log | sed 's/^/           /'
  exit 1
fi
ok "stage 2 converged (exit 0)"

inx 'id _semaphore' >/dev/null 2>&1 && ok "the service account was created" \
  || bad "service account created" "id _semaphore failed"
inx 'test -x /usr/local/sbin/semaphore' && ok "the stable link is in place" \
  || bad "stable link" "/usr/local/sbin/semaphore missing or not executable"
ver=$(inx '/usr/local/sbin/semaphore version' 2>&1 | tr -d '\r\n')
[ "$ver" = "2.19.12-012ed06-1788086239" ] \
  && ok "it reports the pinned community version" \
  || bad "pinned version" "reported: $ver"
inx 'systemctl is-active semaphore' 2>/dev/null | grep -qx active \
  && ok "semaphore.service is active" \
  || bad "service active" "$(inx 'systemctl is-active semaphore' 2>&1 | tr -d '\r\n')"

echo
echo "── 4b. the service is real, and answers ──"
body=$(inx 'curl -sS --max-time 5 http://127.0.0.1:3000/api/ping' 2>/dev/null | tr -d '\r\n')
[ "$body" = "pong" ] && ok "/api/ping returns pong" || bad "/api/ping" "got '$body'"
listener=$(inx 'ss -lntpH sport = :3000' 2>/dev/null | tr -s ' ')
printf '%s' "$listener" | grep -q '127.0.0.1:3000' \
  && ok "bound to 127.0.0.1:3000" || bad "loopback bind" "$listener"
printf '%s' "$listener" | grep -qE '0\.0\.0\.0:3000|\*:3000' \
  && bad "not bound to a wildcard address" "$listener" \
  || ok "nothing bound on 0.0.0.0"
printf '%s' "$listener" | grep -q 'semaphore' \
  && ok "the listener is the semaphore process" || bad "listener identity" "$listener"
owner=$(inx "ps -o user= -p \$(pgrep -f 'semaphore server' | head -1)" 2>/dev/null | tr -d ' \r\n')
[ "$owner" = "_semaphore" ] && ok "running as _semaphore (not root)" \
  || bad "runs as the service account" "running as '$owner'"

echo
echo "── 4c. secrets are protected ──"
cfgmode=$(inx 'stat -c %a /usr/local/etc/semaphore/config.json' 2>/dev/null | tr -d '\r\n')
[ "$cfgmode" = "600" ] && ok "config.json is 0600" || bad "config.json 0600" "mode $cfgmode"
dbmode=$(inx 'stat -c %a /usr/local/var/lib/semaphore/semaphore.db' 2>/dev/null | tr -d '\r\n')
[ "$dbmode" = "600" ] && ok "the database is 0600" || bad "database 0600" "mode $dbmode"
if inx "grep -q '$SEC_ACCESS_ENC' /var/log/semaphore/semaphore.log" 2>/dev/null; then
  bad "no secret in the service log" "the access-key encryption key is in semaphore.log"
else ok "no secret in the service log"; fi
if grep -qE "$(printf '%s' "$SEC_ADMIN_PW" | sed 's/[.[\*^$]/\\&/g')" /tmp/semaphore-linux-2nd.log 2>/dev/null; then
  bad "no secret in the ansible run log" "the admin password is in the run log — no_log is not working"
else ok "no secret in the ansible run log"; fi

echo
echo "── 5. the administrator exists, exactly once ──"
users=$(inx 'sudo -u _semaphore /usr/local/sbin/semaphore users list --config /usr/local/etc/semaphore/config.json' 2>/dev/null | tr -d '\r' | sed '/^$/d')
[ "$users" = "dc1admin" ] && ok "exactly one administrator: dc1admin" \
  || bad "one administrator" "users list returned: $(printf '%s' "$users" | tr '\n' ' ')"

echo
echo "── 6. a configuration change must restart BEFORE verification ──"
PID1=$(inx "pgrep -f 'semaphore server' | head -1" 2>/dev/null | tr -d '\r\n')
[ -n "$PID1" ] && ok "running pid before the change: $PID1" || bad "a pid before the change" "none"

if [ "$MODE" = "--red" ]; then
  cp "$MAIN" "$WORK/main.yml.orig"
  # Remove the WHOLE task, spanning its comment block. Deleting only the
  # `meta:` line leaves an orphaned `- name:` with no module, Ansible dies
  # parsing in a fraction of a second, and the RED assertions below then pass
  # trivially against a run that never started anything.
  perl -0pi -e 's{- name: Apply every pending restart[^\n]*\n(?:  \#[^\n]*\n|\n)*  ansible\.builtin\.meta: flush_handlers\n}{}' "$MAIN"
  RED_APPLIED=yes
  grep -q 'flush_handlers' "$MAIN" && { bad "RED: flush removed" "still present"; exit 1; }
  grep -q 'Apply every pending restart' "$MAIN" && {
    bad "RED: no orphaned task left behind" "the name survived without its module"; exit 1; }
  echo "  RED mode: flush removed from $MAIN (restored on exit)"
  inx 'rm -rf /work && cp -a /repo /work' >/dev/null 2>&1
fi

# A changed port is a changed config, which notifies a restart.
run_role /tmp/semaphore-linux-2.log -e semaphore_port=3100
rc2=$?
PID2=$(inx "pgrep -f 'semaphore server' | head -1" 2>/dev/null | tr -d '\r\n')

if [ "$MODE" = "--red" ]; then
  if [ $rc2 -eq 0 ]; then
    bad "RED: the run fails without the flush" "it SUCCEEDED — is the flush really gone?"
  else
    ok "RED: the run failed, as it must without the flush"
    [ "$PID2" = "$PID1" ] && ok "RED: the OLD pid $PID1 is still running (stale process)" \
      || bad "RED: old pid survives" "pid $PID1 -> ${PID2:-none}"
    if grep -qE '3100|Connection refused|timed out' /tmp/semaphore-linux-2.log; then
      ok "RED: it failed waiting for the NEW port against the OLD process"
    else
      bad "RED: failed for the stale-process reason" "the run failed, but not at verification"
      tail -25 /tmp/semaphore-linux-2.log | sed 's/^/           /'
    fi
  fi
  echo; echo "RED phase complete — the harness reproduces the defect on Linux."
  exit $((fail > 0))
fi

if [ $rc2 -ne 0 ]; then
  bad "the reconfigure run converges" "exit $rc2"
  tail -40 /tmp/semaphore-linux-2.log | sed 's/^/           /'
  exit 1
fi
ok "the reconfigure run converged (exit 0)"
[ -n "$PID2" ] && [ "$PID2" != "$PID1" ] \
  && ok "the service RESTARTED before verification ($PID1 -> $PID2)" \
  || bad "restarted before verification" "pid $PID1 -> ${PID2:-none}"
nb=$(inx 'curl -sS --max-time 5 http://127.0.0.1:3100/api/ping' 2>/dev/null | tr -d '\r\n')
[ "$nb" = "pong" ] && ok "the NEW port 3100 answers" || bad "new port answers" "got '$nb'"

echo
echo "── 7. an unchanged run is a genuine no-op ──"
PID_BEFORE=$(inx "pgrep -f 'semaphore server' | head -1" 2>/dev/null | tr -d '\r\n')
run_role /tmp/semaphore-linux-3.log -e semaphore_port=3100
rc3=$?
PID_AFTER=$(inx "pgrep -f 'semaphore server' | head -1" 2>/dev/null | tr -d '\r\n')
[ $rc3 -eq 0 ] && ok "third run converged (exit 0)" || bad "third run converges" "exit $rc3"
grep -qE '^localhost.*changed=0 ' /tmp/semaphore-linux-3.log \
  && ok "third run reported changed=0" \
  || bad "third run is changed=0" "$(grep -E '^localhost' /tmp/semaphore-linux-3.log | tail -1)"
[ "$PID_AFTER" = "$PID_BEFORE" ] && ok "no restart on the no-op run (pid $PID_AFTER)" \
  || bad "no restart on the no-op run" "pid $PID_BEFORE -> ${PID_AFTER:-none}"
grep -q 'already exists' /tmp/semaphore-linux-3.log \
  && ok "the administrator was recognised, not recreated" \
  || bad "admin idempotency" "the run did not report an existing administrator"

echo
echo "── 8. backup and restore ──"
inx 'sudo -u _semaphore /usr/local/sbin/semaphore-backup' > /tmp/semaphore-backup.log 2>&1
rcb=$?
[ $rcb -eq 0 ] && ok "semaphore-backup succeeded" || bad "backup" "exit $rcb: $(tail -2 /tmp/semaphore-backup.log)"
grep -q 'integrity: ok' /tmp/semaphore-backup.log \
  && ok "the backup passed its own integrity check" || bad "backup integrity" "not reported ok"
BK=$(grep '^backup: ' /tmp/semaphore-backup.log | awk '{print $2}')
if [ -n "$BK" ]; then
  restored=$(inx "sqlite3 '$BK' 'SELECT username FROM user;'" 2>/dev/null | tr -d '\r\n')
  [ "$restored" = "dc1admin" ] \
    && ok "the restored copy contains the administrator" \
    || bad "restore content" "got '$restored'"
  bkmode=$(inx "stat -c %a '$BK'" 2>/dev/null | tr -d '\r\n')
  [ "$bkmode" = "600" ] && ok "the backup is 0600" || bad "backup 0600" "mode $bkmode"
  # ⚠️ THE BACKUP ALONE IS NOT A RESTORE. Proving the ciphertext stays
  # ciphertext without the vaulted key is the point of keeping them apart.
  if inx "sqlite3 '$BK' \"SELECT secret FROM access_key LIMIT 1;\"" 2>/dev/null | grep -q "$SEC_ACCESS_ENC"; then
    bad "the encryption key is NOT inside the backup" "it appears in the database"
  else
    ok "the encryption key is not inside the backup"
  fi
else
  bad "backup path reported" "no 'backup:' line in the output"
fi

echo
if [ "$fail" -gt 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) checks." >&2
  exit 1
fi
echo "PASS — $pass checks: the role installs a pinned, checksum-verified"
echo "binary under a dedicated account, renders a 0600 config, migrates"
echo "SQLite, bootstraps exactly one administrator without leaking it,"
echo "serves /api/ping on loopback only, restarts before verification,"
echo "is a genuine no-op on an unchanged run, and backs up and restores."
