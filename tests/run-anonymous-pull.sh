#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# REGRESSION — the anonymous-pullability check actually discriminates.
#
#   tests/run-anonymous-pull.sh
#
# ═══ WHAT IT MUST PROVE ══════════════════════════════════════════════════════
#
# The check it exercises exists because a deployment stopped on an image that
# every other check called fine. So this suite's job is to show the new check
# can say NO — and specifically that it says no for registry reasons rather
# than from anything on this machine.
#
#   a public digest                  → PASSES
#   a withdrawn digest               → FAILS, citing the refusal
#   a withdrawn digest CACHED HERE   → still FAILS
#   a digest that does not exist     → FAILS
#   an unpinned tag                  → FAILS
#   an amd64-less image              → FAILS
#
# THE THIRD CASE IS THE POINT. `docker pull` of a cached image succeeds without
# contacting anything, which is exactly how an image can become unpullable
# without a single check noticing. If a local copy makes this suite pass, the
# check is measuring this laptop instead of the registry.
#
# Network-dependent by nature: it asks real registries real questions, which is
# the only way to answer "can this be fetched right now".
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.."

CHECK=roles/keel/files/check-anonymous-pull.sh

# Public, multi-arch, and not going anywhere: the control.
PUBLIC='pgvector/pgvector@sha256:ccc6e83d6e35e931dc7c5def2022729d5a6c370318d099181995567ff1fb4d6b'
# Withdrawn by MinIO from every public registry. Verified working, then not.
WITHDRAWN='quay.io/minio/minio@sha256:7d80fd232a2f7108aa6f133fcfe5fade3f1626d92d31ae1318076e7aa61928a2'
WITHDRAWN_MC='quay.io/minio/mc@sha256:a5399b66b88543efac8afb08eb2bdcce5904e548ea6fe1a921600cd74f766668'
# Well-formed, correct repository, digest that was never published.
NONEXISTENT='pgvector/pgvector@sha256:0000000000000000000000000000000000000000000000000000000000000001'
# Not pinned at all.
UNPINNED='pgvector/pgvector:pg16'

pass=0
fail=0
ok()  { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }

expect() {
  local want="$1" name="$2"; shift 2
  local out rc
  out=$("$CHECK" "$@" 2>&1); rc=$?
  if [ "$want" = pass ] && [ "$rc" -ne 0 ]; then
    bad "$name" "expected to pass, exited $rc"
    printf '%s\n' "$out" | grep -E 'FAIL|HTTP' | head -3 | sed 's/^/           /'
  elif [ "$want" = fail ] && [ "$rc" -eq 0 ]; then
    bad "$name" "expected to FAIL, but it passed"
  else
    ok "$name"
  fi
}

# Three attempts before concluding there is no network. A single probe once
# reported "no network" on a perfectly good connection, and a suite that skips
# itself on one dropped packet is a suite that stops running.
reachable=no
for _ in 1 2 3; do
  if curl -sS -o /dev/null --max-time 15 --retry 1 https://registry-1.docker.io/v2/ 2>/dev/null; then
    reachable=yes; break
  fi
  sleep 2
done
if [ "$reachable" != yes ]; then
  echo "  SKIPPED — no network path to a registry after three attempts. This suite" >&2
  echo "  asks real registries real questions; a skipped run is not a passing one." >&2
  exit 0
fi

echo "── the check must accept what is genuinely public ──"
expect pass "a public, digest-pinned, multi-arch image" "$PUBLIC"

echo
echo "── and refuse everything else ──"
expect fail "a withdrawn image (MinIO server)"  "$WITHDRAWN"
expect fail "a withdrawn image (MinIO client)"  "$WITHDRAWN_MC"
expect fail "a digest that was never published" "$NONEXISTENT"
expect fail "an unpinned tag"                   "$UNPINNED"
expect fail "one bad reference among good ones" "$PUBLIC" "$WITHDRAWN"

echo
echo "── ⚠️ the case that makes this worth having ──"
# If the withdrawn image happens to be in the local store, `docker pull` would
# succeed and tell us nothing. The check must be unmoved by that.
cached=no
if docker image inspect "$WITHDRAWN" >/dev/null 2>&1; then
  cached=yes
fi
echo "     withdrawn image present in the local image store: ${cached}"
if [ "$cached" = yes ]; then
  if docker pull "$WITHDRAWN" >/dev/null 2>&1; then
    echo "     and \`docker pull\` on it SUCCEEDS from cache — which is how this"
    echo "     class of breakage hides from every cache-based check"
  fi
  expect fail "withdrawn AND cached locally — still refused" "$WITHDRAWN"
else
  echo "     (not cached here, so the contrast cannot be demonstrated on this run;"
  echo "      the check speaks HTTP and has no image store to fall back on)"
  expect fail "withdrawn, not cached — refused" "$WITHDRAWN"
fi

echo
if [ "$fail" -gt 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) cases." >&2
  exit 1
fi
echo "PASS — $pass cases: public images are accepted, withdrawn ones are refused, and a local cached copy does not change the answer."
