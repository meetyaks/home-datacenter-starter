#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# REGRESSION — the anonymous image check runs ON THE MANAGED HOST, takes its
# input as structured data, and cannot report a pass it did not earn.
#
#   tests/run-remote-image-check.sh
#
# ═══ THE TWO FAILURES THIS COVERS ════════════════════════════════════════════
#
# 1. SHELL INTERPOLATION. Preflight once built a command string from a
#    newline-separated image list and handed it to `ansible.builtin.script`,
#    which runs it through a shell. The list arrived as a PROGRAM:
#
#        /bin/sh: 2: ghcr.io/meetyaks/minio...: not found
#        /bin/sh: 3: nats...: not found
#
#    The checker examined its single argument, found it good, and printed PASS.
#
# 2. DELEGATION. The fix for (1) moved execution to the controller, which
#    quietly removed the protection the check exists for: the original incident
#    was HOST-PATH-SPECIFIC — another machine could resolve an image while
#    dc1-x86 received 401. A green result from the wrong machine is worse than
#    no result.
#
# So this suite asserts both: the task is not delegated, and the module refuses
# to pass when it ran somewhere other than the host it was asked about.
#
# Module cases run the module through its own JSON protocol — the standalone
# contract every Ansible module honours — so they test the real code with no
# playbook in the way.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.."

MOD=roles/keel/library/anonymous_image_check.py
PREFLIGHT=roles/keel/tasks/preflight.yml
TMP="${TMPDIR:-/tmp}/keel-remote-check.$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP" /tmp/keel-modcheck-canary' EXIT

# Modules import ansible.module_utils, so they need the interpreter Ansible
# itself runs on — not necessarily the default python3.
PY=$(head -1 "$(command -v ansible)" 2>/dev/null | sed 's|^#!||')
[ -x "$PY" ] || PY=python3

pass=0
fail=0
ok()  { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }

# invoke <json-args> → prints the module's JSON on stdout
invoke() {
  printf '%s' "$1" > "$TMP/args.json"
  "$PY" "$MOD" "$TMP/args.json" 2>&1
}

jget() { printf '%s' "$1" | "$PY" -c "import json,sys; print(json.loads(sys.stdin.read()).get('$2'))" 2>/dev/null; }

FIVE_JSON='"ghcr.io/meetyaks/minio-mc:RELEASE.2024-09-16T17-43-14Z@sha256:f1f0a5d12276a1abb127a6ae394e4ff598900b971fb22ae27c7d42461984f7ff","ghcr.io/meetyaks/minio:RELEASE.2024-09-22T00-33-43Z@sha256:19d1d6bee97df4d34c3d6e62a1dc9bf3593db9ae6d19abc94883e1e4f2040008","nats:2-alpine@sha256:ac8f88a6494bffc2c2a5289a0ca61cb28a9145c11ba5677cf24265d07f46d8d4","pgvector/pgvector:pg16@sha256:ccc6e83d6e35e931dc7c5def2022729d5a6c370318d099181995567ff1fb4d6b","temporalio/auto-setup:1.25.2@sha256:b1edc1e20002d958c8182f2ae08dee877a125083683a627a44917683419ba6a8"'
HERE=$(hostname)

# ── 1. The task must not be delegated ───────────────────────────────────────
#
# Static, because this is a property of the playbook rather than of a run, and
# because a delegated task would otherwise LOOK correct in every other test.
echo "── 1. the check is not delegated away from the managed host ──"

block=$("$PY" - "$PREFLIGHT" <<'PY'
import io, re, sys
text = io.open(sys.argv[1], encoding="utf-8").read()
# The task that invokes the module, up to the next top-level task.
m = re.search(r"\n- name: [^\n]*anonymous[^\n]*\n(.*?)(?=\n- name: )", text, re.S | re.I)
print(m.group(0) if m else "")
PY
)

if [ -z "$block" ]; then
  bad "the invoking task is present" "could not locate it in $PREFLIGHT"
else
  if printf '%s' "$block" | grep -qE '^\s*delegate_to:'; then
    bad "not delegated" "the task carries delegate_to — the check would run on the wrong machine"
    printf '%s\n' "$block" | grep -nE 'delegate_to:|ansible_connection:' | sed 's/^/           /'
  else
    ok "no delegate_to on the invoking task"
  fi
  if printf '%s' "$block" | grep -qE '^\s*ansible_connection:\s*local'; then
    bad "not forced local" "ansible_connection: local would run it on the controller"
  else
    ok "no ansible_connection: local"
  fi
  if printf '%s' "$block" | grep -q 'anonymous_image_check:'; then
    ok "invokes the anonymous_image_check module"
  else
    bad "invokes the module" "the task does not call anonymous_image_check"
  fi
  # And it must pass expected_host, or the module cannot refuse a wrong host.
  if printf '%s' "$block" | grep -q 'expected_host:'; then
    ok "passes expected_host so a wrong machine can be detected"
  else
    bad "passes expected_host" "without it the module cannot tell where it ran"
  fi
fi

# ── 2. No shell anywhere in the module ──────────────────────────────────────
echo
echo "── 2. the module contains no shell execution path at all ──"
# CODE ONLY. The first version of this check grepped the whole file and matched
# the module's own comment explaining that it contains no subprocess call — a
# test failing on its own documentation. Comment and blank lines are stripped
# before the search.
code_only=$("$PY" - "$MOD" <<'PY'
import io, sys
for line in io.open(sys.argv[1], encoding="utf-8"):
    stripped = line.strip()
    if stripped and not stripped.startswith("#"):
        sys.stdout.write(line)
PY
)
if printf '%s' "$code_only" | grep -nE '\b(subprocess|os\.system|os\.popen|shell=True|run_command)\b' >/dev/null; then
  bad "no shell execution in the module" "found a process-spawning call in CODE:"
  printf '%s' "$code_only" | grep -nE '\b(subprocess|os\.system|os\.popen|shell=True|run_command)\b' | sed 's/^/           /'
else
  ok "no subprocess, os.system, shell=True or run_command in code"
fi

# ── 3. Five references stay five structured elements ────────────────────────
#
# ⚠️ THIS CASE DELIBERATELY DOES NOT FETCH ANYTHING. The claim under test is
# that a five-element list arrives as five separate values — which `input_count`
# and five distinct result entries establish on their own. Verifying them for
# real is a separate case, run ONCE, at the end.
#
# That split matters: an earlier version re-verified all five in four different
# cases and exhausted Docker Hub's anonymous rate limit, so the suite started
# reporting 429 on public images. A test that fails because it ran too often is
# worse than no test — it teaches you to ignore it.
echo
echo "── 3. five references arrive as five structured list elements ──"
# Well-formed, unmistakably absent, and one cheap request each.
FIVE_ABSENT='"a.invalid/x/one@sha256:0000000000000000000000000000000000000000000000000000000000000001","a.invalid/x/two@sha256:0000000000000000000000000000000000000000000000000000000000000002","a.invalid/x/three@sha256:0000000000000000000000000000000000000000000000000000000000000003","a.invalid/x/four@sha256:0000000000000000000000000000000000000000000000000000000000000004","a.invalid/x/five@sha256:0000000000000000000000000000000000000000000000000000000000000005"'
out=$(invoke "{\"ANSIBLE_MODULE_ARGS\":{\"images\":[$FIVE_ABSENT],\"expected_host\":\"$HERE\",\"retries\":1,\"timeout\":5}}")
ic=$(jget "$out" input_count)
eh=$(jget "$out" execution_host)
[ "$ic" = 5 ] && ok "input_count is 5 — the list arrived as five values" \
              || bad "input_count is 5" "got $ic"
[ -n "$eh" ] && ok "reports execution_host ($eh)" || bad "reports execution_host" "empty"

missing=0
for n in one two three four five; do
  printf '%s' "$out" | grep -qF "a.invalid/x/$n@" || { missing=$((missing+1)); echo "           not reported: $n"; }
done
[ "$missing" -eq 0 ] && ok "all five appear as separate result entries" \
                     || bad "five separate result entries" "$missing missing"

# ── 4. Metacharacters are rejected as data, never executed ──────────────────
echo
echo "── 4. metacharacters are rejected as DATA ──"
CANARY=/tmp/keel-modcheck-canary
rm -f "$CANARY"
evil_json="\"foo@sha256:x; touch $CANARY\",\"foo@sha256:x\$(touch $CANARY)\",\"foo@sha256:x | touch $CANARY\",\"pgvector/pgvector@sha256:aaa bbb\""
out=$(invoke "{\"ANSIBLE_MODULE_ARGS\":{\"images\":[$evil_json]}}")
if [ "$(jget "$out" verified_count)" = 0 ] && [ "$(jget "$out" failed)" = True ]; then
  ok "all four malicious references refused"
else
  bad "malicious references refused" "verified=$(jget "$out" verified_count) failed=$(jget "$out" failed)"
fi
if printf '%s' "$out" | grep -q 'invalid reference'; then
  ok "refused specifically as invalid references"
else
  bad "refused as invalid references" "the reason does not say so"
fi
if [ -e "$CANARY" ]; then
  bad "nothing was executed" "the canary file EXISTS — a reference reached a shell"
else
  ok "canary absent — no reference was executed"
fi

# ── 5. A failure in any position fails the aggregate ────────────────────────
echo
echo "── 5. first / middle / last failures all fail the aggregate ──"
# GHCR rather than Docker Hub for the good reference: it is our own registry
# and its anonymous limits are generous, whereas repeating a Docker Hub image
# across cases is what exhausted the rate limit and made this suite flake.
GOOD='ghcr.io/meetyaks/minio-mc:RELEASE.2024-09-16T17-43-14Z@sha256:f1f0a5d12276a1abb127a6ae394e4ff598900b971fb22ae27c7d42461984f7ff'
BAD='ghcr.io/meetyaks/definitely-not-real@sha256:0000000000000000000000000000000000000000000000000000000000000001'

position() {
  local label="$1" a="$2" b="$3" c="$4"
  local out ic vc fl
  out=$(invoke "{\"ANSIBLE_MODULE_ARGS\":{\"images\":[\"$a\",\"$b\",\"$c\"]}}")
  ic=$(jget "$out" input_count); vc=$(jget "$out" verified_count); fl=$(jget "$out" failed)
  if [ "$fl" != True ]; then
    bad "$label" "the module did not fail"
  elif [ "$ic" != 3 ]; then
    bad "$label" "input_count=$ic, expected 3"
  elif [ "$vc" = "$ic" ]; then
    bad "$label" "verified==input despite a bad reference"
  else
    ok "$label (verified $vc of $ic, failed)"
  fi
}
position "failure in FIRST position"  "$BAD"  "$GOOD" "$GOOD"
position "failure in MIDDLE position" "$GOOD" "$BAD"  "$GOOD"
position "failure in LAST position"   "$GOOD" "$GOOD" "$BAD"

# ── 6. Execution-host mismatch cannot produce a pass ────────────────────────
echo
echo "── 6. a result from the wrong machine cannot pass ──"
# One good image is enough: the claim is that a wrong host fails EVEN WHEN
# every image verified, so what matters is that verified == input and it still
# fails.
out=$(invoke "{\"ANSIBLE_MODULE_ARGS\":{\"images\":[\"$GOOD\"],\"expected_host\":\"some-other-host\"}}")
if [ "$(jget "$out" failed)" = True ] \
   && [ "$(jget "$out" host_matches)" = False ] \
   && [ "$(jget "$out" verified_count)" = "$(jget "$out" input_count)" ]; then
  ok "host mismatch fails even though every image verified"
else
  bad "host mismatch fails" "failed=$(jget "$out" failed) host_matches=$(jget "$out" host_matches) verified=$(jget "$out" verified_count)/$(jget "$out" input_count)"
fi

out=$(invoke '{"ANSIBLE_MODULE_ARGS":{"images":[]}}')
if [ "$(jget "$out" failed)" = True ]; then
  ok "an empty image list fails rather than passing vacuously"
else
  bad "empty list fails" "failed=$(jget "$out" failed)"
fi

# And the direct controller guard: `expected_host` alone only catches
# delegation when the inventory name and the real hostname differ. Naming this
# machine as forbidden reproduces "it ran on the controller" exactly.
out=$(invoke "{\"ANSIBLE_MODULE_ARGS\":{\"images\":[\"$GOOD\"],\"expected_host\":\"$HERE\",\"forbidden_host\":\"$HERE\"}}")
if [ "$(jget "$out" failed)" = True ] \
   && [ "$(jget "$out" ran_on_forbidden_host)" = True ] \
   && printf '%s' "$out" | grep -q 'which is the controller'; then
  ok "running on the controller fails even when expected_host matches"
else
  bad "controller guard" "failed=$(jget "$out" failed) ran_on_forbidden_host=$(jget "$out" ran_on_forbidden_host)"
fi

# The task must actually supply it, or the guard is dead code.
if printf '%s' "$block" | grep -q 'forbidden_host:'; then
  ok "preflight passes forbidden_host (the controller's own name)"
else
  bad "preflight passes forbidden_host" "the guard would never fire"
fi

# ── 7. Read-only: check mode makes no durable change ───────────────────────
echo
echo "── 7. read-only, so check mode changes nothing ──"
out=$(invoke "{\"ANSIBLE_MODULE_ARGS\":{\"images\":[\"$GOOD\"],\"expected_host\":\"$HERE\",\"_ansible_check_mode\":true}}")
if [ "$(jget "$out" changed)" = False ]; then
  ok "reports changed=false"
else
  bad "reports changed=false" "changed=$(jget "$out" changed)"
fi
if [ "$(jget "$out" verified_count)" = 1 ]; then
  ok "check mode returns a real answer, not a skip (1 of 1)"
else
  bad "check mode answers identically" "verified=$(jget "$out" verified_count) — $(jget "$out" msg)"
fi
# Nothing it could have written. The module never opens a file for writing, and
# a grep is the durable way to say so.
if grep -nE "open\([^)]*['\"][wax]" "$MOD" >/dev/null; then
  bad "the module writes no files" "found a write-mode open()"
  grep -nE "open\([^)]*['\"][wax]" "$MOD" | sed 's/^/           /'
else
  ok "no write-mode open() anywhere in the module"
fi

# ── 8. A withdrawn image is refused, even when it is cached locally ────────
#
# The case the whole preflight exists for, and the one no cache-based check can
# make. `quay.io/minio/minio` was pullable, was verified, ran in production —
# and then upstream withdrew it. A local copy still satisfies `docker pull` and
# `docker image inspect`, which is exactly how an image becomes unpullable with
# nothing noticing.
echo
echo "── 8. a withdrawn image is refused, cached or not ──"
WITHDRAWN='quay.io/minio/minio@sha256:7d80fd232a2f7108aa6f133fcfe5fade3f1626d92d31ae1318076e7aa61928a2'
out=$(invoke "{\"ANSIBLE_MODULE_ARGS\":{\"images\":[\"$WITHDRAWN\"]}}")
if [ "$(jget "$out" failed)" = True ] && printf '%s' "$out" | grep -q 'refuses this repository'; then
  ok "withdrawn image refused, citing the registry's refusal"
else
  bad "withdrawn image refused" "failed=$(jget "$out" failed) — $(jget "$out" msg)"
fi

if command -v docker >/dev/null 2>&1 && docker image inspect "$WITHDRAWN" >/dev/null 2>&1; then
  ok "…and it IS in this machine's local image store, so a cache-based check would pass it"
else
  echo "         (not cached here, so the contrast cannot be shown on this run;"
  echo "          the module speaks HTTP and has no image store to consult at all)"
fi

# Well-formed but never published, and an unpinned tag: both refused.
out=$(invoke '{"ANSIBLE_MODULE_ARGS":{"images":["pgvector/pgvector:pg16"]}}')
if [ "$(jget "$out" failed)" = True ] && printf '%s' "$out" | grep -q 'not pinned by digest'; then
  ok "an unpinned tag is refused"
else
  bad "an unpinned tag is refused" "$(jget "$out" msg)"
fi

# ── 9. The real five, verified for real — ONCE ─────────────────────────────
#
# Deliberately the only case that fetches all five. Three of them live on
# Docker Hub, whose anonymous rate limit is per-IP and unforgiving; repeating
# this across cases is what made an earlier version of this suite report 429 on
# public images.
#
# A 429 here is NOT a verification failure — it means this machine has asked
# Docker Hub too often recently — so it is reported distinctly rather than
# counted as "the image is unavailable". That is the same distinction the
# module draws, and the reason it draws it.
echo
echo "── 9. the five rendered references, verified end to end (once) ──"
out=$(invoke "{\"ANSIBLE_MODULE_ARGS\":{\"images\":[$FIVE_JSON],\"expected_host\":\"$HERE\"}}")
vc=$(jget "$out" verified_count); ic=$(jget "$out" input_count)
rate_limited=$(printf '%s' "$out" | grep -c 'rate limited' || true)

if [ "$vc" = "$ic" ] && [ "$ic" = 5 ]; then
  ok "verified $vc of $ic from $(jget "$out" execution_host)"
  "$PY" -c '
import json,sys
d=json.load(open(sys.argv[1]))
for r in d["results"]:
    print("         ok   %s" % r["image"])
' <(printf '%s' "$out") 2>/dev/null || true
elif [ "$rate_limited" -gt 0 ]; then
  printf "  \033[33mSKIPPED\033[0m  this machine is currently rate limited by Docker Hub\n"
  echo "           $(jget "$out" verified_count) of $(jget "$out" input_count) verified; the rest returned 429."
  echo "           429 is not a refusal — it is 'ask again later'. Not counted as a"
  echo "           pass OR a failure, because it says nothing about the images."
else
  bad "the five rendered references" "verified=$vc of $ic — $(jget "$out" msg)"
fi

echo
if [ "$fail" -gt 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) cases." >&2
  exit 1
fi
echo "PASS — $pass cases: the check runs on the managed host, takes a list as data, never lets a reference reach a shell, and cannot report a pass it did not earn."
