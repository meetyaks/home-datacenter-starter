#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# REGRESSION — the runtime group, across every host state that matters.
#
#   tests/run-runtime-group-scenarios.sh
#
# ═══ WHY A CONTAINER ═════════════════════════════════════════════════════════
#
# Six scenarios, and not one of them can be exercised on the control node.
# Creating a system group, colliding a GID, and proving a real run is idempotent
# all need root on a throwaway Linux machine. dc1-x86 is not a throwaway
# machine, and macOS is not Linux. A disposable container is both.
#
# Each scenario gets a FRESH container: the host state under test IS the
# variable, so reusing one would leak the previous scenario's group into the
# next.
#
# ═══ THE SCENARIOS ═══════════════════════════════════════════════════════════
#
#   1  fresh host, group absent     --check   PASSES, and changes NOTHING
#   2  group present, GID 10001     --check   PASSES
#   3  group present, wrong GID     --check   FAILS, naming the GID conflict
#   4  GID 10001 held by another    --check   FAILS, naming the holder
#   5  fresh host                   real      creates the group and directories
#   6  immediately again            real      idempotent — nothing changes
#
# Scenario 1 is the one that failed on dc1-x86, and its assertion is the strong
# form: not merely "the play exited 0" but "the account database and /srv are
# untouched afterwards".
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.."

IMAGE=keel-ansible-test:local
PLAY=tests/container/runtime-group-play.yml

pass=0
fail=0

ok()   { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }

if ! docker info >/dev/null 2>&1; then
  echo "  SKIPPED — Docker is not available, and these scenarios need a disposable Linux host." >&2
  echo "  They are the only coverage for real group creation and idempotence; do not treat" >&2
  echo "  a skipped run as a passing one." >&2
  exit 0
fi

echo "Building the disposable test image (cached after the first run)…"
if ! docker build -q -f tests/container/Dockerfile -t "$IMAGE" tests/container >/dev/null 2>&1; then
  echo "  FAILED to build $IMAGE" >&2
  docker build -f tests/container/Dockerfile -t "$IMAGE" tests/container 2>&1 | tail -15 >&2
  exit 1
fi
echo

# run_scenario <name> <setup-shell> <ansible-args> <expect: pass|fail> <post-shell> [expect-msg]
#
# setup runs before the play, post runs after it and must exit non-zero to fail
# the scenario. Both run inside the same container as root.
#
# `expect-msg` matters for the two failure scenarios: "the play failed" is
# satisfied by ANY error, including a typo in this harness. A failure case that
# does not check WHY it failed proves nothing, so those scenarios also require
# the message to name the specific conflict they set up.
run_scenario() {
  local name="$1" setup="$2" args="$3" expect="$4" post="$5" expect_msg="${6:-}"
  local out rc

  out=$(docker run --rm -v "$PWD":/repo:ro -w /repo "$IMAGE" bash -c "
    set -e
    $setup
    ansible-playbook $PLAY $args > /tmp/play.log 2>&1 || echo \"PLAYRC=\$?\" >> /tmp/play.log
    echo '--- PLAY LOG ---'
    cat /tmp/play.log
    echo '--- POST ---'
    $post
  " 2>&1)
  rc=$?

  local play_failed=no
  printf '%s' "$out" | grep -qE 'PLAYRC=|failed=[1-9]' && play_failed=yes

  if [ "$expect" = pass ] && [ "$play_failed" = yes ]; then
    bad "$name" "the play FAILED but was expected to pass"
    printf '%s\n' "$out" | grep -E 'fatal:|failed=|msg' | head -6 | sed 's/^/           /'
    return
  fi
  if [ "$expect" = fail ] && [ "$play_failed" = no ]; then
    bad "$name" "the play PASSED but was expected to fail"
    return
  fi
  if [ "$expect" = fail ] && [ -n "$expect_msg" ] \
     && ! printf '%s' "$out" | grep -qi -- "$expect_msg"; then
    bad "$name" "it failed, but not for the stated reason (wanted: $expect_msg)"
    printf '%s\n' "$out" | grep -E 'fatal:|msg' | head -4 | sed 's/^/           /'
    return
  fi
  if [ $rc -ne 0 ] && [ "$expect" = pass ]; then
    bad "$name" "post-conditions failed"
    printf '%s\n' "$out" | sed -n '/--- POST ---/,$p' | head -8 | sed 's/^/           /'
    return
  fi
  ok "$name"
}

echo "── check mode ──"

run_scenario \
  "1. fresh host, group absent — check mode passes and mutates nothing" \
  "true" \
  "--check" \
  pass \
  "getent group keel-runtime >/dev/null && { echo 'MUTATION: the group was created'; exit 1; }
   test -e /srv/data && { echo 'MUTATION: /srv/data was created'; exit 1; }
   for d in '' /builds /data /env /pg /secrets /data/postgres /data/nats /data/minio; do
     test -e \"/srv/data/services/keel\$d\" && { echo \"MUTATION: /srv/data/services/keel\$d was created\"; exit 1; }
   done
   echo 'account database untouched; not one of the nine directories exists'"

# ⚠️ THE SCENARIO THAT ACTUALLY REPRODUCES THE dc1-x86 FAILURE.
#
# Scenario 1 does NOT, and believing it did was a false green: on a genuinely
# fresh host the secrets directory does not exist, so `file` predicts creating
# it and never reaches the chgrp. The defect needs a directory that is ALREADY
# THERE — which dc1-x86's was, from the earlier partial runs. Its own error
# output says so: `"mode": "0700", "size": 4096, "state": "directory"`.
#
# Reverting the fix makes THIS case fail and leaves scenario 1 green, which is
# precisely why it is here.
run_scenario \
  "1b. secrets directory ALREADY EXISTS, group absent — check mode passes" \
  "mkdir -p /srv/data/services/keel/secrets && chmod 0700 /srv/data/services/keel/secrets" \
  "--check" \
  pass \
  "getent group keel-runtime >/dev/null && { echo 'MUTATION: the group was created'; exit 1; }
   s=\$(stat -c '%a %U %G' /srv/data/services/keel/secrets)
   [ \"\$s\" = '700 root root' ] || { echo \"MUTATION: the existing directory changed to '\$s'\"; exit 1; }
   echo \"group still absent; existing directory untouched at \$s\""

run_scenario \
  "2. group already present at GID 10001 — check mode passes" \
  "groupadd -r -g 10001 keel-runtime" \
  "--check" \
  pass \
  "test -e /srv/data/services/keel && { echo 'MUTATION: directories were created'; exit 1; }
   echo 'still no directories'"

run_scenario \
  "3. group present at the WRONG GID — check mode fails" \
  "groupadd -r -g 10002 keel-runtime" \
  "--check" \
  fail \
  "true" \
  "already exists with GID 10002"

run_scenario \
  "4. GID 10001 held by a DIFFERENT group — check mode fails" \
  "groupadd -r -g 10001 someone-else" \
  "--check" \
  fail \
  "true" \
  "already belongs to someone-else"

echo
echo "── real runs ──"

run_scenario \
  "5. fresh host, real run — creates the group and the directories" \
  "true" \
  "" \
  pass \
  "getent group keel-runtime | grep -q ':10001:' || { echo 'group missing or wrong GID'; getent group keel-runtime; exit 1; }
   s=\$(stat -c '%a %U %G' /srv/data/services/keel/secrets)
   [ \"\$s\" = '750 root keel-runtime' ] || { echo \"secrets dir is '\$s', expected '750 root keel-runtime'\"; exit 1; }
   for d in builds data env pg data/postgres data/nats data/minio; do
     test -d \"/srv/data/services/keel/\$d\" || { echo \"missing \$d\"; exit 1; }
   done
   echo \"group 10001 ok; secrets \$s; every directory present\""

run_scenario \
  "6. second real run — idempotent, nothing changes" \
  "true" \
  "" \
  pass \
  "ansible-playbook $PLAY > /tmp/second.log 2>&1
   c=\$(grep -oE 'changed=[0-9]+' /tmp/second.log | tail -1 | cut -d= -f2)
   [ \"\$c\" = '0' ] || { echo \"second run reported changed=\$c, expected 0\"; grep -E 'changed:' /tmp/second.log | head; exit 1; }
   s=\$(stat -c '%a %U %G' /srv/data/services/keel/secrets)
   [ \"\$s\" = '750 root keel-runtime' ] || { echo \"secrets dir drifted to '\$s'\"; exit 1; }
   echo \"second run changed=0; secrets still \$s\""

echo
if [ "$fail" -gt 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) scenarios." >&2
  exit 1
fi
echo "PASS — $pass scenarios: check mode is inert on a fresh host, both GID conflicts are refused, and a real run is correct and idempotent."
