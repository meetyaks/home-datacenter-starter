#!/bin/bash
# Runs INSIDE a throwaway privileged container (tests/tools image).
#
#   policy-listing.sh <truewealth render dir> <path to tools/ci-activation/hostcheck.sh>
#
# hostcheck.sh probe compares the LIVE `nft list table inet ci_egress_tw` on dc1-x86, counters
# removed, with the text it embeds (tw_table_expected). This keeps that text honest: it loads the
# policy freshly rendered from playbooks/vars/ci-runner-truewealth.yml into a real nft and fails
# if the listing and the embedded text differ, so a policy change cannot leave the probe checking
# for a stale table.
set -uo pipefail
nft -f "$1/ci-egress.nft" || { echo "FAIL the rendered policy does not load"; exit 2; }
# shellcheck disable=SC1090
HOSTCHECK_LIB=1 . "$2"
listed=$(nft list table inet ci_egress_tw) || { echo "FAIL nft list"; exit 2; }
live=$(printf '%s\n' "$listed" | normalize_nft)
if [ "$live" = "$(tw_table_expected)" ] && [ "$(printf '%s\n' "$listed" | normalize_nft | policy_verdict)" = PASS ]; then
  echo "PASS the rendered policy lists exactly as hostcheck.sh expects ($(nft --version))"
  exit 0
fi
echo "FAIL the rendered policy's listing differs from hostcheck.sh's tw_table_expected:"
diff <(tw_table_expected) <(printf '%s\n' "$live")
exit 1
