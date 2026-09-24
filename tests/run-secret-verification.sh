#!/usr/bin/env bash
# Regression runner for roles/keel/tasks/verify-secret-files.yml.
#
# Runs the suite TWICE — once with --check, once without — because
# `ansible_check_mode` is true only when the PLAY was started with --check. A
# task- or block-level `check_mode: true` behaves as a dry run without flipping
# that fact, so a single invocation cannot cover both halves.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "── check mode (cases 1, 2) ─────────────────────────────────────────"
ansible-playbook tests/secret-verification.yml --check

echo
echo "── normal mode (cases 3, 4) ────────────────────────────────────────"
ansible-playbook tests/secret-verification.yml

echo
echo "All four cases passed."
