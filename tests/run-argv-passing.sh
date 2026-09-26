#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# REGRESSION — image references reach the checker as DATA, and PASS is earned.
#
#   tests/run-argv-passing.sh
#
# ═══ WHAT BROKE ══════════════════════════════════════════════════════════════
#
# Preflight interpolated a newline-separated image list into a command string
# handed to `ansible.builtin.script`, which runs it through a shell. The list
# arrived as a PROGRAM:
#
#     /bin/sh: 2: ghcr.io/meetyaks/minio...: not found
#     /bin/sh: 3: nats...: not found
#     /bin/sh: 4: pgvector/pgvector...: not found
#     /bin/sh: 5: temporalio/auto-setup...: not found
#
# Two independent defects, either of which alone was enough:
#
#   1. `.split('\n')` inside a YAML FOLDED (`>-`) scalar splits on a literal
#      backslash-n, so a five-line string stayed ONE element.
#   2. `script` passes `cmd` to a shell, so lines 2..5 became commands.
#
# And the part that matters most: the checker examined its single argument,
# found it good, and printed PASS. A green check over a fifth of its input.
#
# ═══ WHAT THIS PROVES ════════════════════════════════════════════════════════
#
#   - five newline-originated references arrive as five opaque argv values
#   - tag+digest syntax survives intact
#   - a registry host WITH A PORT survives intact
#   - spaces and shell metacharacters are REJECTED, never executed
#   - a failure in the second, middle or final position fails the aggregate
#   - PASS is impossible unless verified == input count
#   - the five references compose actually renders are each reported
#
# Most cases use a local argv-echoing stub rather than the network, so what is
# being tested is the PASSING MECHANISM, deterministically. The cases that must
# reach a registry say so.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.."

CHECK=roles/keel/files/check-anonymous-pull.sh
TMP="${TMPDIR:-/tmp}/keel-argv-tests.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }

# A stub that reports exactly what argv it received, one per line, delimited so
# an embedded space or newline would be visible rather than silently merged.
cat > "$TMP/echo-argv.sh" <<'STUB'
#!/usr/bin/env bash
printf 'ARGC=%d\n' "$#"
i=0
for a in "$@"; do i=$((i+1)); printf 'ARG%d=[%s]\n' "$i" "$a"; done
STUB
chmod +x "$TMP/echo-argv.sh"

# The five references, exactly as the compose file renders them.
FIVE=(
  'ghcr.io/meetyaks/minio-mc:RELEASE.2024-09-16T17-43-14Z@sha256:f1f0a5d12276a1abb127a6ae394e4ff598900b971fb22ae27c7d42461984f7ff'
  'ghcr.io/meetyaks/minio:RELEASE.2024-09-22T00-33-43Z@sha256:19d1d6bee97df4d34c3d6e62a1dc9bf3593db9ae6d19abc94883e1e4f2040008'
  'nats:2-alpine@sha256:ac8f88a6494bffc2c2a5289a0ca61cb28a9145c11ba5677cf24265d07f46d8d4'
  'pgvector/pgvector:pg16@sha256:ccc6e83d6e35e931dc7c5def2022729d5a6c370318d099181995567ff1fb4d6b'
  'temporalio/auto-setup:1.25.2@sha256:b1edc1e20002d958c8182f2ae08dee877a125083683a627a44917683419ba6a8'
)

echo "── 1. newline-originated list → five opaque argv values ──"
#
# The list starts life exactly as it does in preflight: newline-separated text
# from a command's stdout. Ansible's `stdout_lines` turns that into a real list;
# this reproduces that with mapfile and asserts the count survives.
printf '%s\n' "${FIVE[@]}" > "$TMP/refs.txt"
mapfile -t from_lines < "$TMP/refs.txt"
out=$("$TMP/echo-argv.sh" "${from_lines[@]}")
argc=$(printf '%s' "$out" | sed -n 's/^ARGC=//p')
if [ "$argc" = 5 ]; then
  ok "five newline-originated references arrive as ARGC=5"
else
  bad "five references arrive as five arguments" "ARGC=$argc"
  printf '%s\n' "$out" | sed 's/^/           /'
fi

# And each one arrives byte-identical — no splitting, no truncation at the
# colon or the @, which is where a naive splitter would break them.
mismatch=0
for i in "${!FIVE[@]}"; do
  n=$((i + 1))
  got=$(printf '%s' "$out" | sed -n "s/^ARG${n}=\[\(.*\)\]$/\1/p")
  [ "$got" = "${FIVE[$i]}" ] || { mismatch=$((mismatch+1)); echo "           ARG$n differs"; }
done
[ "$mismatch" -eq 0 ] && ok "each reference arrives byte-identical (tag + @sha256 intact)" \
                      || bad "references arrive intact" "$mismatch of 5 differ"

echo
echo "── 2. registry host with a port ──"
PORTED='localhost:5000/team/app:v1.2.3@sha256:1111111111111111111111111111111111111111111111111111111111111111'
out=$("$TMP/echo-argv.sh" "$PORTED")
got=$(printf '%s' "$out" | sed -n 's/^ARG1=\[\(.*\)\]$/\1/p')
[ "$got" = "$PORTED" ] && ok "host:port reference passes through as one argument" \
                       || bad "host:port survives" "got [$got]"

# The checker must also PARSE it as host:port rather than mistaking the colon
# for a tag. It will fail to resolve (nothing is listening), but the failure
# must name localhost:5000 — proving the split was right.
out=$("$CHECK" "$PORTED" 2>&1) || true
if printf '%s' "$out" | grep -q 'localhost:5000'; then
  ok "host:port is parsed as a registry, not as a tag"
else
  bad "host:port parsed correctly" "the failure never mentions localhost:5000"
  printf '%s\n' "$out" | grep -iE 'fail|http' | head -3 | sed 's/^/           /'
fi

echo
echo "── 3. spaces and metacharacters are rejected, never executed ──"
#
# The canary file must not exist afterwards. If the reference were ever handed
# to a shell, `touch` would run and create it.
CANARY="$TMP/canary-executed"
for evil in \
  "pgvector/pgvector@sha256:aaa bbb" \
  "foo@sha256:x; touch $CANARY" \
  "foo@sha256:x\$(touch $CANARY)" \
  "foo@sha256:x\`touch $CANARY\`" \
  "foo@sha256:x | touch $CANARY"
do
  out=$("$CHECK" "$evil" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "rejects: ${evil:0:40}" "checker exited 0"
  elif ! printf '%s' "$out" | grep -qi 'invalid reference'; then
    bad "rejects: ${evil:0:40}" "failed, but not as an invalid reference"
    printf '%s\n' "$out" | grep -i fail | head -2 | sed 's/^/           /'
  else
    ok "rejected as invalid: ${evil:0:40}"
  fi
done
if [ -e "$CANARY" ]; then
  bad "no metacharacter was executed" "the canary file EXISTS — something ran a reference as shell"
else
  ok "no metacharacter was executed (canary absent)"
fi

echo
echo "── 4. a failure anywhere makes the aggregate fail ──"
#
# A well-formed reference to a repository that does not exist. Position is what
# is under test: an early exit would let later failures pass unnoticed, and a
# loop that forgot to record would let earlier ones vanish.
GOOD='pgvector/pgvector:pg16@sha256:ccc6e83d6e35e931dc7c5def2022729d5a6c370318d099181995567ff1fb4d6b'
BAD='ghcr.io/meetyaks/definitely-not-real@sha256:0000000000000000000000000000000000000000000000000000000000000001'

check_position() {
  local label="$1"; shift
  local out rc
  out=$("$CHECK" "$@" 2>&1); rc=$?
  local v t
  v=$(printf '%s' "$out" | sed -n 's/^verified \([0-9]*\) of \([0-9]*\).*/\1/p')
  t=$(printf '%s' "$out" | sed -n 's/^verified \([0-9]*\) of \([0-9]*\).*/\2/p')
  if [ "$rc" -eq 0 ]; then
    bad "$label" "aggregate exited 0 despite a bad reference"
  elif printf '%s' "$out" | grep -q '^PASS'; then
    bad "$label" "printed PASS with a bad reference present"
  elif [ "$t" != "$#" ]; then
    bad "$label" "reported a total of $t for $# references"
  elif [ "$v" = "$t" ]; then
    bad "$label" "claimed verified==total ($v/$t) with a bad reference present"
  else
    ok "$label (verified $v of $t, exit $rc)"
  fi
}

check_position "failure in FIRST position"  "$BAD"  "$GOOD" "$GOOD"
check_position "failure in MIDDLE position" "$GOOD" "$BAD"  "$GOOD"
check_position "failure in LAST position"   "$GOOD" "$GOOD" "$BAD"

echo
echo "── 5. PASS requires verified == input count ──"
out=$("$CHECK" "$GOOD" "$GOOD" 2>&1); rc=$?
v=$(printf '%s' "$out" | sed -n 's/^verified \([0-9]*\) of \([0-9]*\).*/\1/p')
t=$(printf '%s' "$out" | sed -n 's/^verified \([0-9]*\) of \([0-9]*\).*/\2/p')
if [ "$rc" -eq 0 ] && [ "$v" = 2 ] && [ "$t" = 2 ] && printf '%s' "$out" | grep -q '^PASS'; then
  ok "two good references → verified 2 of 2, PASS, exit 0"
else
  bad "two good references pass cleanly" "rc=$rc verified=$v total=$t"
fi

# No arguments at all must not be a silent success.
out=$("$CHECK" 2>&1); rc=$?
if [ "$rc" -eq 0 ] || printf '%s' "$out" | grep -q '^PASS'; then
  bad "an empty invocation is not a pass" "rc=$rc — PASS over zero images is how a broken caller hides"
else
  ok "an empty invocation fails rather than passing vacuously"
fi

echo
echo "── 6. the five references compose actually renders ──"
out=$("$CHECK" "${FIVE[@]}" 2>&1); rc=$?
v=$(printf '%s' "$out" | sed -n 's/^verified \([0-9]*\) of \([0-9]*\).*/\1/p')
t=$(printf '%s' "$out" | sed -n 's/^verified \([0-9]*\) of \([0-9]*\).*/\2/p')
missing=0
for r in "${FIVE[@]}"; do
  printf '%s' "$out" | grep -qF "$r" || { missing=$((missing+1)); echo "           not reported: $r"; }
done
if [ "$rc" -eq 0 ] && [ "$v" = 5 ] && [ "$t" = 5 ] && [ "$missing" -eq 0 ]; then
  ok "all five rendered references verified and individually reported"
else
  bad "the five rendered references" "rc=$rc verified=$v total=$t unreported=$missing"
fi

echo
if [ "$fail" -gt 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) cases." >&2
  exit 1
fi
echo "PASS — $pass cases: references travel as opaque argv, metacharacters are refused rather than run, and PASS is only printed when every input verified."
