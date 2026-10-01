#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# BREAK THE PROVENANCE POLICY, PROVE THE SUITES NOTICE.
#
#   tests/run-provenance-mutations.sh
#
# ⚠️ A GUARD THAT HAS NEVER FAILED IS NOT A GUARD. The policy decides whether
# this site will deploy a release nothing has signed. Each mutation below
# removes or inverts exactly one part of that decision and asserts the suites
# go red FOR THAT REASON — a failure for the wrong reason is not a pass,
# because a suite that failed on everything would look identical.
#
# Operates on COPIES: every file is restored on exit, including on interrupt.
# Controller-only; touches nothing outside this checkout and /tmp.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# ⚠️ DO NOT EDIT THE FOUR FILES BELOW WHILE THIS IS RUNNING. It restores each
# one from a copy taken at startup, so an edit made mid-run is silently
# reverted when the next mutation restores.

TMP="$(mktemp -d)"
DEFAULTS=roles/keel/defaults/main.yml
RELEASE=roles/keel/tasks/release.yml
DEVINV=inventory/group_vars/keel_dev/environment.yml
RECONCILE=roles/keel_reconcile/tasks/main.yml

restore() {
  cp "$TMP/defaults.yml"  "$DEFAULTS"  2>/dev/null
  cp "$TMP/release.yml"   "$RELEASE"   2>/dev/null
  cp "$TMP/devinv.yml"    "$DEVINV"    2>/dev/null
  cp "$TMP/reconcile.yml" "$RECONCILE" 2>/dev/null
}
trap 'restore; rm -rf "$TMP"' EXIT INT TERM

cp "$DEFAULTS"  "$TMP/defaults.yml"
cp "$RELEASE"   "$TMP/release.yml"
cp "$DEVINV"    "$TMP/devinv.yml"
cp "$RECONCILE" "$TMP/reconcile.yml"

pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; fail=$((fail + 1)); }

# ── 0. BASELINE ─────────────────────────────────────────────────────────────
#
# First, and not a formality: without it every case below is satisfied by a
# suite that fails on everything, including the correct code.
echo "── the shipped tree passes its own suites ──────────────────────────────"
base_green=1
for s in release-contract dev-environment-identity reconcile-boundaries; do
  if ansible-playbook "tests/${s}.yml" >/dev/null 2>&1; then
    ok "tests/${s}.yml is green"
  else
    bad "tests/${s}.yml FAILS on the shipped tree"; base_green=0
  fi
done
[ "$base_green" -eq 1 ] || { echo "FAILED early — the baseline is not green."; exit 1; }

echo
echo "── each mutation is caught, for its own reason ─────────────────────────"

mutate() {  # mutate <label> <file> <perl-expr> <suite> <expected-substring>
  local label="$1" file="$2" expr="$3" suite="$4" want="$5"
  restore
  perl -0pi -e "$expr" "$file"

  local orig
  case "$file" in
    "$DEFAULTS")  orig="$TMP/defaults.yml" ;;
    "$RELEASE")   orig="$TMP/release.yml" ;;
    "$DEVINV")    orig="$TMP/devinv.yml" ;;
    "$RECONCILE") orig="$TMP/reconcile.yml" ;;
  esac
  if diff -q "$file" "$orig" >/dev/null; then
    bad "$label" "the mutation changed nothing — it is not a real mutation"
    return
  fi

  # ⚠️ ONE RUN, NOT TWO. Running the suite once for its output and again for
  # its exit status doubles a slow suite and, worse, lets the two disagree.
  local out rc
  out="$(ansible-playbook "tests/${suite}.yml" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "$label" "tests/${suite}.yml still PASSED"
    return
  fi
  if grep -qF -- "$want" <<<"$out"; then
    ok "$label"
  else
    bad "$label" "red, but not for '${want}'" \
      && echo "        actual: $(grep -oE '"(msg|assertion)": "[^"]{0,200}' <<<"$out" | tail -2 | tr '\n' ' ')"
  fi
}

# 1. THE SHIPPED DEFAULT FLIPPED — every environment silently permissive.
mutate "default changed to allow_unavailable is caught" \
  "$DEFAULTS" 's{^keel_release_provenance_policy: require_persisted}{keel_release_provenance_policy: allow_unavailable}m' \
  release-contract 'must be `require_persisted`'

# 2. DEV'S EXPLICIT OPT-IN REMOVED — DEV would refuse the real release, and
#    more importantly the exception would stop being written down.
mutate "removing DEV's explicit policy is caught" \
  "$DEVINV" 's{^keel_release_provenance_policy: allow_unavailable}{}m' \
  dev-environment-identity 'It must be exactly `allow_unavailable`'

# ⚠️ THE EXPECTED STRING IS THE FAILURE MESSAGE, NOT THE CASE NAME. A case name
# is printed in the TASK header of every run, passing or failing, so grepping
# for it would accept a suite that went red for an unrelated reason — the exact
# thing this file exists to rule out. `<case>: expected the contract to …` is
# emitted only by that case's own verdict.
ACCEPTED=': expected the contract to refuse this manifest, but it was accepted'

# 3. THE STATUS CHECK REMOVED — an unknown status read as acceptable.
mutate "removing the attestation-status check is caught" \
  "$RELEASE" "s{      - keel_release.provenance.attestation.status in \\['persisted', 'unavailable'\\]}{      - true}" \
  release-contract "an unknown attestation status is refused${ACCEPTED}"

# 4. STATUS/MECHANISM AGREEMENT REMOVED — the forgery becomes possible.
mutate "removing the status/mechanism agreement is caught" \
  "$RELEASE" 's{      - keel_release.provenance.mechanism ==\n        \(.*?\)\n}{      - true\n}s' \
  release-contract "unavailable claiming the attestation mechanism is refused${ACCEPTED}"

# 5. THE REASON REQUIREMENT REMOVED.
#    ⚠️ BOTH LINES. Removing only the length check leaves `is defined`, which
#    still catches the fixture — the mutation would appear caught while the
#    guard it targets was never exercised.
#
#    ⚠️ AND IT IS CAUGHT AS A WRONG REASON, NOT AS AN ACCEPTANCE — which is the
#    more interesting result. Without the guard the release is STILL refused,
#    but only because a debug task downstream dereferences `.reason` and
#    raises "object of type 'dict' has no attribute 'reason'". A suite that
#    checked only the verdict would have called that a pass and left the
#    contract resting on an accidental template error. The per-case `because`
#    check is what distinguishes a deliberate refusal from a lucky one.
mutate "removing the reason requirement is caught" \
  "$RELEASE" 's{      - keel_release.provenance.attestation.reason is defined\n      - \(keel_release.provenance.attestation.reason \| trim\) \| length > 0}{      - true}s' \
  release-contract 'unavailable without a reason is refused: refused, but for the wrong reason'

# 6. THE SBOM REQUIREMENT REMOVED.
mutate "removing the SBOM digest check is caught" \
  "$RELEASE" "s{      - keel_release.provenance.sbom.sha256 is match\\('\\^\\[0-9a-f\\]\\{64\\}\\\$'\\)}{      - true}" \
  release-contract "a malformed SBOM sha256 is refused${ACCEPTED}"

# 7. UNAVAILABLE ACCEPTED UNDER require_persisted — the policy made cosmetic.
mutate "accepting unavailable under require_persisted is caught" \
  "$RELEASE" "s{    - keel_release_provenance_policy != 'allow_unavailable'}{    - false}" \
  release-contract "UNAVAILABLE UNDER require_persisted IS REFUSED${ACCEPTED}"

# 8. ATTESTATION VERIFICATION REMOVED FROM THE PERSISTED PATH — accepted and
#    unverified, the worst of both outcomes.
mutate "removing attestation verification from persisted is caught" \
  "$RELEASE" "s{  when: keel_release.provenance.attestation.status == 'persisted'}{  when: false}g" \
  release-contract 'attestation verify` never ran'

# 9. VERIFICATION RUN FOR AN UNAVAILABLE RELEASE — there is nothing to verify,
#    so this either breaks DEV or appears to succeed against something else.
mutate "running attestation verification for unavailable is caught" \
  "$RELEASE" "s{  when: keel_release.provenance.attestation.status == 'persisted'}{  when: true}g" \
  release-contract 'was invoked. There is nothing to verify'

# 10. THE RECORD OF REDUCED ASSURANCE DROPPED — current.json would no longer
#     say what assurance the running release had.
mutate "dropping the assurance record from current.json is caught" \
  "$RECONCILE" "s{,\n\\s+'assurance': keel_release_assurance \\| default\\('\\(unrecorded\\)'\\)}{}s" \
  reconcile-boundaries 'does not record the full provenance state'

# 11. THE RETIRED BOOLEAN RESTORED AS A BYPASS.
mutate "restoring the boolean as a second authority is caught" \
  "$DEFAULTS" 's{^keel_release_provenance_policy: require_persisted}{keel_release_provenance_policy: require_persisted\nkeel_release_require_provenance: false}m' \
  release-contract "still exists in the role's defaults"

restore
echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: ${fail} of $((fail + pass)) mutation(s) not caught."
  exit 1
fi
echo "provenance mutations: ${pass} checks, every mutation caught for its own reason."
