#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# REGRESSION — the caddy role never consumes an artifact that check mode only
# PREDICTED, and a real run proves what it installed.
#
#   tests/run-caddy-check-mode.sh
#
# ═══ WHAT THIS IS ABOUT ══════════════════════════════════════════════════════
#
# `ansible-playbook --check` against dc1-x86 aborted here:
#
#   TASK [caddy : Install Caddy]
#     The following NEW packages will be installed: caddy
#     changed: [dc1-x86]
#   TASK [caddy : Record the installed version]
#     fatal: [dc1-x86]: FAILED! => {"cmd": "caddy version",
#       "msg": "[Errno 2] No such file or directory: b'caddy'", "rc": 2}
#
# The apt task's `changed: true` under --check means "would install", not
# "did". The version task carried `check_mode: false`, so it ran anyway and
# called a binary that a predicted installation had not created.
#
# Two more of the same kind were found by running the role rather than reading
# it: `systemd_service` fails on a unit that does not exist EVEN in check mode
# ("Could not find the requested service caddy: host"), and on a genuinely
# fresh host apt cannot resolve the package at all, because under --check the
# repository file was reported rather than written ("No package matching
# 'caddy' is available").
#
# So the role now decides everything from `stat` — what is on the host right
# now — and never from a package task's report.
#
# ═══ WHY A CONTAINER ═════════════════════════════════════════════════════════
#
# The only honest test of "fresh host" is a host that is actually fresh, and of
# "the package left nothing usable behind" is a host where that is true.
# dc1-x86 is not disposable and macOS is not Debian. Scenario 1 runs FIRST,
# against a container nothing has touched.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.."

IMAGE=keel-systemd-test:local
CNAME=keel-caddy-checkmode-test
PLAY="cd /repo && ansible-playbook -i localhost, -c local tests/container/caddy-play.yml"

pass=0
fail=0
ok()  { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }
die() { printf '\n\033[31mABORTED\033[0m — %s\n' "$1" >&2; exit 1; }

# Every scenario runs the role, and the role fetches a signing key. If the
# container's DNS drops — which it does, intermittently, under Docker Desktop —
# each remaining scenario fails identically and for a reason that has nothing to
# do with the code. Scenarios 5 and 6 EXPECT a failure, so a dead network is
# exactly the shape of the thing they are looking for. Catch it explicitly:
# a run that proved nothing must not read as a run that proved something.
guard_net() {
  grep -qE 'name resolution|Temporary failure|Could not resolve|Connection timed out|Network is unreachable' "$1" || return 0
  echo >&2
  echo "  SKIPPED — the container lost network partway through ($2), so the" >&2
  echo "  remaining scenarios cannot be distinguished from a real failure." >&2
  grep -m1 -oE '"msg": "[^"]*(name resolution|Temporary failure)[^"]*"' "$1" | sed 's/^/           /' >&2
  echo >&2
  echo "  $pass check(s) had passed before that point; none of them are in doubt," >&2
  echo "  but this run is NOT a pass. Re-run it." >&2
  exit 0
}

cleanup() { docker rm -f "$CNAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

if ! docker info >/dev/null 2>&1; then
  echo "  SKIPPED — Docker is not available, and 'fresh host' cannot be faked." >&2
  echo "  A skipped run is not a passing one." >&2
  exit 0
fi

echo "Building the systemd test image (cached after the first run)…"
docker build -q -f tests/container/Dockerfile.systemd -t "$IMAGE" tests/container >/dev/null 2>&1 \
  || die "could not build $IMAGE"

cleanup
docker run -d --name "$CNAME" --privileged \
  --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$PWD":/repo:ro -w /repo "$IMAGE" >/dev/null 2>&1

booted=no
for _ in $(seq 1 30); do
  if docker exec "$CNAME" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'; then
    booted=yes; break
  fi
  sleep 1
done
[ "$booted" = yes ] || { echo "  SKIPPED — systemd did not come up in this container." >&2; exit 0; }

inx() { docker exec "$CNAME" bash -lc "$1"; }
recap_field() { grep -oE "$2=[0-9]+" "$1" | tail -1 | cut -d= -f2; }

# The host must be untouched before scenario 1, or "check mode changed nothing"
# proves nothing.
if inx 'test -e /usr/bin/caddy -o -e /etc/caddy -o -e /etc/apt/sources.list.d/caddy-stable.sources'; then
  die "the container is not fresh; scenario 1 would be meaningless"
fi

# ── 1. Fresh host + check mode ─────────────────────────────────────────────
echo
echo "── 1. fresh host, --check: reports, changes nothing, fails nothing ──"
inx "$PLAY --check" > /tmp/cm-1.log 2>&1
guard_net /tmp/cm-1.log "scenario 1"
failed=$(recap_field /tmp/cm-1.log failed)
if [ "${failed:-x}" = "0" ]; then
  ok "check mode completed with failed=0"
else
  bad "check mode completes on a fresh host" "failed=${failed:-<no PLAY RECAP>}"
  grep -A4 'fatal:' /tmp/cm-1.log | head -8 | sed 's/^/           /'
fi

# The specific regression: the version task must not have run.
if grep -qF "No such file or directory: b'caddy'" /tmp/cm-1.log; then
  bad "caddy version is not executed" "the original ENOENT is back"
elif grep -qE '^TASK \[caddy : Record the installed version\]' /tmp/cm-1.log \
     && grep -A1 'Record the installed version' /tmp/cm-1.log | grep -qE '^skipping:'; then
  ok "'Record the installed version' was skipped, not executed"
else
  bad "the version task is skipped on a fresh host" "it neither skipped nor is absent"
  grep -A2 'Record the installed version' /tmp/cm-1.log | head -4 | sed 's/^/           /'
fi

# …and neither did anything else that needs the binary or the unit.
for t in 'Enable and start Caddy' 'Wait for Caddy'"'"'s internal CA to exist' \
         'Publish the internal root certificate' 'Trust the internal root on this host'; do
  if grep -A1 -F "$t" /tmp/cm-1.log | grep -qE '^skipping:'; then
    ok "skipped: $t"
  else
    bad "skipped: $t" "it ran against an artifact that does not exist"
  fi
done

if grep -qF 'CHECK MODE: Caddy is not installed on this host' /tmp/cm-1.log; then
  ok "it still REPORTS that a real run would install Caddy"
else
  bad "check mode reports the intended installation" "silence is not a dry run"
fi

# Nothing on disk, no package, no user, no service.
for path in /usr/bin/caddy /etc/caddy /etc/apt/sources.list.d/caddy-stable.sources \
            /etc/apt/keyrings/caddy-stable.asc /var/log/caddy; do
  inx "test -e $path" && bad "check mode created nothing: $path" "it exists" \
                      || ok "not created: $path"
done
inx 'dpkg -s caddy >/dev/null 2>&1' && bad "no package installed" "dpkg has a record" \
                                    || ok "no caddy package installed"
inx 'id caddy >/dev/null 2>&1' && bad "no service account created" "the caddy user exists" \
                               || ok "no caddy user created"

# ── 2. Fresh host + real mode ──────────────────────────────────────────────
echo
echo "── 2. real mode: installs the exact version and starts it ──"
inx "$PLAY" > /tmp/cm-2.log 2>&1
guard_net /tmp/cm-2.log "scenario 2"
failed=$(recap_field /tmp/cm-2.log failed)
[ "${failed:-x}" = "0" ] || { tail -20 /tmp/cm-2.log | sed 's/^/           /'; die "the real run failed; nothing below can mean anything"; }
ok "real run completed with failed=0"

# `-f="${Version}"` would be expanded by the shell `docker exec … -lc` starts,
# not by dpkg-query, and would arrive empty. Two fields, take the second.
dpkg_ver=$(inx 'dpkg-query -W caddy' 2>/dev/null | awk '{print $2}' | tr -d '\r')
bin_ver=$(inx '/usr/bin/caddy version' 2>/dev/null | head -1 | awk '{print $1}' | sed 's/^v//' | tr -d '\r')
if [ -n "$dpkg_ver" ] && [ "$dpkg_ver" = "$bin_ver" ]; then
  ok "dpkg and the binary agree on the version ($bin_ver)"
else
  bad "the installed version is consistent" "dpkg says '$dpkg_ver', the binary says '$bin_ver'"
fi
inx 'systemctl is-active caddy | grep -qx active' \
  && ok "caddy.service is active" || bad "caddy.service active" "$(inx 'systemctl is-active caddy' 2>&1)"

# Re-run REAL mode with the version pinned to what is installed. The role must
# accept it — a pin that fails against the version it names is a broken check.
inx "$PLAY -e caddy_version=$bin_ver" > /tmp/cm-2b.log 2>&1
guard_net /tmp/cm-2b.log "scenario 2b"
if [ "$(recap_field /tmp/cm-2b.log failed)" = "0" ]; then
  ok "a pin matching the installed version is accepted (caddy_version=$bin_ver)"
else
  bad "a correct pin is accepted" "the run failed with caddy_version=$bin_ver"
  grep -A4 'fatal:' /tmp/cm-2b.log | head -6 | sed 's/^/           /'
fi

# ── 3. Second real run ─────────────────────────────────────────────────────
echo
echo "── 3. second real run changes nothing ──"
inx "$PLAY" > /tmp/cm-3.log 2>&1
guard_net /tmp/cm-3.log "scenario 3"
changed=$(recap_field /tmp/cm-3.log changed)
if [ "${changed:-x}" = "0" ]; then
  ok "second real run reported changed=0"
else
  bad "the role is idempotent" "reported changed=${changed:-<no PLAY RECAP>}"
  grep -B6 'changed: \[' /tmp/cm-3.log | grep -E '^TASK' | head -5 | sed 's/^/           /'
fi

# ── 4. Installed host + check mode ─────────────────────────────────────────
echo
echo "── 4. --check on an installed host reads the real version safely ──"
inx "$PLAY --check" > /tmp/cm-4.log 2>&1
guard_net /tmp/cm-4.log "scenario 4"
failed=$(recap_field /tmp/cm-4.log failed)
[ "${failed:-x}" = "0" ] && ok "check mode on an installed host: failed=0" \
  || bad "check mode on an installed host" "failed=${failed:-<no PLAY RECAP>}"

if grep -qF "Caddy v${bin_ver}" /tmp/cm-4.log; then
  ok "it reports the version actually installed (v${bin_ver})"
else
  bad "the version is read in check mode" "no 'Caddy v${bin_ver}' in the output"
fi
# Requirement: it must not claim this run installed it.
if grep -qF 'already installed before this run' /tmp/cm-4.log; then
  ok "it says the version pre-dated this run, not that this run installed it"
else
  bad "presence is not attributed to this run" "the report does not distinguish the two"
fi
if grep -qF 'CHECK MODE: Caddy is not installed' /tmp/cm-4.log; then
  bad "no stale 'would install' claim" "it says Caddy is absent on a host that has it"
else
  ok "no 'would install' claim on a host that already has Caddy"
fi

# ── 5. Wrong installed version ─────────────────────────────────────────────
#
# dpkg and the binary disagreeing is a real state: a diverted path, a
# half-configured package, something installed over the top. The role reads the
# BINARY, so it catches what `dpkg -s` would wave through.
echo
echo "── 5. an installed version that is not the pinned one fails explicitly ──"
inx 'mv /usr/bin/caddy /usr/bin/caddy.real && printf "#!/bin/sh\necho \"v2.8.4 h1:fake=\"\n" > /usr/bin/caddy && chmod 755 /usr/bin/caddy' >/dev/null 2>&1
if [ "$(inx '/usr/bin/caddy version' 2>/dev/null | awk '{print $1}' | tr -d '\r')" != "v2.8.4" ]; then
  inx 'test -e /usr/bin/caddy.real && mv -f /usr/bin/caddy.real /usr/bin/caddy' >/dev/null 2>&1
  die "could not stage a version mismatch; scenario 5 would pass vacuously"
fi
inx "$PLAY -e caddy_version=$bin_ver" > /tmp/cm-5.log 2>&1
guard_net /tmp/cm-5.log "scenario 5"
if [ "$(recap_field /tmp/cm-5.log failed)" = "0" ]; then
  bad "a version mismatch fails the run" "the run SUCCEEDED against a host running 2.8.4"
elif grep -qF "pinned to ${bin_ver} but this host is running 2.8.4" /tmp/cm-5.log; then
  ok "it fails naming both versions, not just 'assertion failed'"
else
  bad "the failure is explicit" "it failed, but not with the version-mismatch message"
  grep -A3 'fatal:' /tmp/cm-5.log | head -5 | sed 's/^/           /'
fi
inx 'mv -f /usr/bin/caddy.real /usr/bin/caddy' >/dev/null 2>&1
inx "/usr/bin/caddy version | grep -qF v${bin_ver}" \
  || die "could not restore the real binary; scenario 6 would test the wrong thing"

# ── 6. Package present, binary absent ──────────────────────────────────────
echo
echo "── 6. a package that left no usable binary fails explicitly ──"
inx 'mv /usr/bin/caddy /root/caddy.stashed' >/dev/null 2>&1
inx 'dpkg -s caddy >/dev/null 2>&1' || die "dpkg lost its record; scenario 6 needs apt to report success"
inx "$PLAY" > /tmp/cm-6.log 2>&1
guard_net /tmp/cm-6.log "scenario 6"
if [ "$(recap_field /tmp/cm-6.log failed)" = "0" ]; then
  bad "a missing binary fails the run" "the run SUCCEEDED with no /usr/bin/caddy"
elif grep -qF 'apt reported Caddy installed, but /usr/bin/caddy does not exist' /tmp/cm-6.log; then
  ok "it fails saying apt reported success and the binary is absent"
else
  bad "the failure is explicit" "it failed, but not with the missing-binary message"
  grep -A3 'fatal:' /tmp/cm-6.log | head -5 | sed 's/^/           /'
fi
inx 'mv /root/caddy.stashed /usr/bin/caddy' >/dev/null 2>&1

# ── 7. The handover to an application role ─────────────────────────────────
#
# roles/caddy OWNS /etc/caddy/conf.d and the CA; roles/keel CONSUMES both. Under
# --check on a fresh host roles/caddy only PREDICTS them, so the pair is where
# the predicted-artifact defect actually bites — and running either role alone
# cannot show it. A FRESH container, because scenarios 5 and 6 left this one
# converged.
echo
echo "── 7. caddy → keel handover: dry run, first deploy, second run ──"
PAIR=keel-caddy-pair-test
PAIRPLAY="cd /repo && ansible-playbook -i localhost, -c local tests/container/caddy-keel-dropin-play.yml"
docker rm -f "$PAIR" >/dev/null 2>&1
docker run -d --name "$PAIR" --privileged \
  --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v "$PWD":/repo:ro -w /repo "$IMAGE" >/dev/null 2>&1
trap 'cleanup; docker rm -f "$PAIR" >/dev/null 2>&1 || true' EXIT

pbooted=no
for _ in $(seq 1 30); do
  if docker exec "$PAIR" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'; then
    pbooted=yes; break
  fi
  sleep 1
done
[ "$pbooted" = yes ] || die "systemd did not come up in the pair container; scenario 7 cannot run"

pinx() { docker exec "$PAIR" bash -lc "$1"; }

pinx 'test -e /usr/bin/caddy -o -e /etc/caddy' \
  && die "the pair container is not fresh; scenario 7a would be meaningless"

# 7a. Dry run on a fresh host must not assert on the predicted conf.d.
pinx "$PAIRPLAY --check" > /tmp/cm-7a.log 2>&1
guard_net /tmp/cm-7a.log "scenario 7a"
if [ "$(recap_field /tmp/cm-7a.log failed)" = "0" ]; then
  ok "dry run of the pair completes on a fresh host (failed=0)"
else
  bad "the pair survives --check on a fresh host" "failed=$(recap_field /tmp/cm-7a.log failed)"
  grep -A4 'fatal:' /tmp/cm-7a.log | head -6 | sed 's/^/           /'
fi
pinx 'test -e /etc/caddy -o -e /usr/bin/caddy' \
  && bad "the dry run changed nothing" "it created /etc/caddy or the binary" \
  || ok "the dry run created neither /etc/caddy nor the binary"

# 7b. FIRST real deploy. The reload must succeed — `caddy validate` runs as
# root and creates a missing site log 0600 root:root, after which the service
# account cannot open it and the reload fails with "permission denied" while
# validate still reports "Valid configuration".
pinx "$PAIRPLAY" > /tmp/cm-7b.log 2>&1
guard_net /tmp/cm-7b.log "scenario 7b"
if [ "$(recap_field /tmp/cm-7b.log failed)" = "0" ]; then
  ok "first deploy of the pair completes (failed=0)"
else
  bad "the first deploy succeeds" "failed=$(recap_field /tmp/cm-7b.log failed)"
  grep -A4 'fatal:' /tmp/cm-7b.log | head -6 | sed 's/^/           /'
fi
# THE JOURNAL, not Ansible's output. systemd reports only "Job for
# caddy.service failed" to the caller; the actual cause lives in the unit's
# log. An earlier version of this check grepped /tmp/cm-7b.log and PASSED
# against a host where the reload had failed for exactly this reason.
if pinx 'journalctl -u caddy --no-pager 2>/dev/null | grep -q "opening log writer.*permission denied"'; then
  bad "the reload succeeds on a first deploy" "the site log is not writable by the service account"
  pinx 'journalctl -u caddy --no-pager 2>/dev/null | grep -o "open /var/log/caddy/[^\"]*permission denied" | tail -1' \
    | sed 's/^/           /'
else
  ok "no permission-denied reload in caddy's journal"
fi
logown=$(pinx 'stat -c "%U:%G" /var/log/caddy/keel.dc1.lan.log' 2>/dev/null | tr -d '\r')
if [ "$logown" = "caddy:caddy" ]; then
  ok "the site log is owned by the service account ($logown)"
else
  bad "the site log is writable by Caddy" "owned by '${logown:-absent}', not caddy:caddy"
fi
pinx 'systemctl is-active caddy | grep -qx active' \
  && ok "caddy is active after the pair deployed" \
  || bad "caddy active after the pair" "$(pinx 'systemctl is-active caddy' 2>&1)"

# 7c. The root CA must be published by the FIRST deploy, because the README
# tells the operator to scp exactly this path. Caddy creates its local CA
# lazily; without the `pki` block in the main Caddyfile the file did not exist
# until some later run.
if pinx 'test -s /usr/local/share/ca-certificates/caddy-lan-root.crt'; then
  ok "the internal root CA is published on the FIRST deploy"
else
  bad "the root CA is published on run 1" "the path the README hands operators is empty or absent"
fi
if pinx 'openssl x509 -in /usr/local/share/ca-certificates/caddy-lan-root.crt -noout -subject 2>/dev/null | grep -qi "caddy local authority"'; then
  ok "it is a parsable certificate from Caddy's local authority"
else
  bad "the published file is a real certificate" "it does not parse as Caddy's local root"
fi

# 7d. Second run of the pair changes nothing.
pinx "$PAIRPLAY" > /tmp/cm-7d.log 2>&1
guard_net /tmp/cm-7d.log "scenario 7d"
pchanged=$(recap_field /tmp/cm-7d.log changed)
if [ "${pchanged:-x}" = "0" ]; then
  ok "second run of the pair reported changed=0"
else
  bad "the pair is idempotent" "reported changed=${pchanged:-<no PLAY RECAP>}"
  awk '/^TASK \[|^RUNNING HANDLER \[/{t=$0} /^changed: \[localhost\]/{print "           "t}' /tmp/cm-7d.log | head -4
fi

echo
if [ "$fail" -gt 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) checks." >&2
  exit 1
fi
echo "PASS — $pass checks: check mode on a fresh host reports without executing anything it only predicted, a real run installs and proves the exact version, a second run changes nothing, and a host whose package left nothing usable fails by saying so."
