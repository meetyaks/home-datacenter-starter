#!/usr/bin/env bash
# The runtime-group suite only proves anything under `--check`: the defect it
# covers exists *because* the group module creates nothing in check mode.
#
# `ansible_check_mode` is true only when the PLAY was started with `--check`. A
# task- or block-level `check_mode: true` makes that task behave as a dry run
# but does NOT flip the fact, so a suite that set it internally would exercise a
# different code path from the one `--check` actually takes, pass, and prove
# nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "── check mode (the chgrp cases + the static checks) ──"
ansible-playbook tests/check-mode-runtime-group.yml --check

echo
echo "── normal mode (static checks only; the chgrp cases are skipped) ──"
ansible-playbook tests/check-mode-runtime-group.yml
