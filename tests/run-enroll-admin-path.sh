#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# REGRESSION — the enrollment operator path EXECUTES, for real addresses.
#
#   tests/run-enroll-admin-path.sh
#
# ═══ WHY THIS EXISTS ═════════════════════════════════════════════════════════
#
# `playbooks/enroll-admin.yml` shipped with an email validator that rejected
# EVERY valid address:
#
#   keel_admin_email is match('^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
#
# Jinja's `match` is Python `re`, which has no POSIX classes — and the unescaped
# `]` closed the character class early, leaving a literal `]` that an address had
# to contain. admin@example.com, you@company.com and bob@x.io were all refused.
# The documented path to the first administrator could not enroll anybody.
#
# It passed `--syntax-check`, because a syntax check does not evaluate a template.
# So this suite RUNS THE PLAY — against a local stand-in host, never dc1-x86 —
# and asserts on what the tasks actually do.
#
# ═══ WHAT IT DOES NOT NEED ═══════════════════════════════════════════════════
#
# A gateway. The last task fails on a stand-in container with no Keel in it, and
# that is fine: everything under test here happens BEFORE it — validation, the
# container check, and `no_log`. The enrollment command itself is covered by
# Keel's own suites, which run it as a real process against a real database.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0
fail=0
ok()  { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }
die() { printf '\n\033[31mABORTED\033[0m — %s\n' "$1" >&2; exit 1; }

# ⚠️ THE INVENTORY MUST END IN `.yml`. `mktemp -t foo.yml` appends random
# characters AFTER the template, so the file ends in neither `.yml` nor anything
# Ansible recognises — it falls back to the INI plugin, fails to parse, matches no
# hosts, and EXITS 0 HAVING RUN NOTHING. That silent no-op is what the
# positive-evidence helpers below exist to catch; the first version of this script
# hit it and reported "proved nothing" rather than a row of false passes.
TMPDIR_RUN=$(mktemp -d -t enroll-path.XXXXXX)
INV="${TMPDIR_RUN}/inventory.yml"
LOG="${TMPDIR_RUN}/run.log"
CNAME=keel-enroll-path-standin
SENTINEL='Zx3-PathTest-Qv7!m'

cleanup() {
  rm -rf "$TMPDIR_RUN"
  docker rm -f "$CNAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v ansible-playbook >/dev/null 2>&1 || die "ansible-playbook is not installed"

# A LOCAL stand-in for the managed host. `linux_servers` is the group the play
# targets; pointing it at a local connection is what keeps dc1-x86 out of this.
cat > "$INV" <<'YAML'
all:
  children:
    linux_servers:
      hosts:
        enroll-path-standin:
          ansible_connection: local
YAML

# A container by the name the task looks for, so the gateway check passes and the
# run reaches the password-bearing task. It deliberately contains no Keel.
if docker info >/dev/null 2>&1; then
  docker rm -f "$CNAME" >/dev/null 2>&1
  docker run -d --name "$CNAME" alpine:3 sleep 900 >/dev/null 2>&1
  HAVE_DOCKER=yes
else
  HAVE_DOCKER=no
  echo "  (no Docker — the container-dependent cases will be skipped loudly)" >&2
fi

# Run the play for one address. `become: false` so no sudo prompt; the stand-in is
# local and nothing here needs root.
run_for() {
  local email=$1
  ansible-playbook -i "$INV" playbooks/enroll-admin.yml \
    -e "keel_admin_email=${email}" \
    -e "keel_admin_password=${SENTINEL}" \
    -e ansible_become=false \
    -e "keel_gateway_container=${CNAME}" \
    -vvv > "$LOG" 2>&1
  return $?
}

# ═══ POSITIVE EVIDENCE, IN BOTH DIRECTIONS ═══════════════════════════════════
#
# The first version of these helpers inferred from ABSENCE — "the assertion text
# is not in the log, so validation passed" — and was wrong both ways: it reported
# every invalid address as accepted while the play was correctly refusing them.
# An unsound detector is worse than none, because it reads as evidence.
#
# So each helper now looks for something that can only be true in one case:
# the email task's own `fatal:`, or the arrival of the NEXT task.

# Did the run stop AT the email assertion? Looks for the fatal belonging to that
# task, not merely for the pattern text appearing somewhere.
refused_by_email_assert() {
  awk '/^TASK \[keel : Require an email to enroll\]/{seen=1; next}
       /^TASK \[/{seen=0}
       seen && /^fatal:/{found=1}
       END{exit !found}' "$LOG"
}

# Did the run get PAST the email assertion? Proven by the next task appearing.
passed_email_assert() {
  grep -qF 'TASK [keel : Require the password that was prompted for]' "$LOG"
}

# Was a named task's output censored by `no_log`?
#
# Scoped to the block BETWEEN that task's header and the next one — not a fixed
# `-A<n>` window. At -vvv the connection chatter between a task header and its
# result is ten lines for a `command` and three for an `assert`, so a fixed window
# reported the shorter task as censored and the longer one as not.
censored_for() {
  awk -v want="TASK [keel : $1]" '
    index($0, "TASK [") == 1 { inblock = (index($0, want) == 1); next }
    inblock && /no_log: true/ { found = 1 }
    END { exit !found }' "$LOG"
}

# ── 0. The harness itself must work ────────────────────────────────────────
#
# Asserted before anything else, because an inventory Ansible cannot parse yields
# exit 0 with no tasks — indistinguishable from success unless someone checks.
echo
echo "── 0. the stand-in inventory parses and matches the target group ──"
if ansible-inventory -i "$INV" --list >/dev/null 2>&1 \
   && ansible-inventory -i "$INV" --list 2>/dev/null | grep -q 'enroll-path-standin'; then
  ok "the inventory parses and contains the stand-in host"
else
  die "the stand-in inventory does not parse; every case below would prove nothing"
fi

# ── 1. Valid addresses reach past validation ───────────────────────────────
echo
echo "── 1. valid addresses pass validation (the old regex rejected all of these) ──"
for email in \
  admin@example.com \
  you@company.com \
  bob@x.io \
  first.last@sub.domain.test \
  ops+keel@example.co.uk \
  a@b.cd
do
  run_for "$email"
  if refused_by_email_assert; then
    bad "accepted: $email" "the email assertion refused a valid address"
  elif passed_email_assert; then
    ok "accepted: $email"
  else
    bad "accepted: $email" "the run never reached validation — this case proved nothing"
  fi
done

# ── 2. Invalid addresses are still refused ────────────────────────────────
#
# The fix must not be "accept everything". Each of these must be stopped BY the
# email assertion, not by something later.
echo
echo "── 2. invalid addresses are refused, by the email assertion itself ──"
for email in \
  'notanemail' \
  'missing@tld' \
  '@nolocalpart.test' \
  'two@@at.test' \
  'has space@example.com' \
  'trailing@dot.'
do
  run_for "$email"
  if refused_by_email_assert; then
    ok "refused: '$email'"
  elif passed_email_assert; then
    bad "refused: '$email'" "validation let it through to the next task"
  else
    bad "refused: '$email'" "the run failed somewhere else — this case proved nothing"
  fi
done

# ── 3. An absent address is refused, not defaulted ────────────────────────
echo
echo "── 3. no address at all ──"
ansible-playbook -i "$INV" playbooks/enroll-admin.yml \
  -e "keel_admin_password=${SENTINEL}" -e ansible_become=false \
  -e "keel_gateway_container=${CNAME}" > "$LOG" 2>&1
if refused_by_email_assert; then
  ok "a missing address stops the run at the email assertion"
else
  bad "a missing address is refused" "the run did not stop at the email assertion"
  failed_task=$(grep -E '^TASK \[' "$LOG" | tail -1)
  printf '           last task: %s\n' "$failed_task"
fi

# ── 4. no_log, on the tasks that hold the password ────────────────────────
echo
echo "── 4. the password never reaches the log, even at -vvv ──"
if [ "$HAVE_DOCKER" != yes ]; then
  echo "  SKIPPED — needs Docker for the stand-in container. A skip is not a pass." >&2
else
  run_for 'admin@example.com'
  if grep -q "$SENTINEL" "$LOG"; then
    bad "the password is absent from the -vvv log" "it appears in the output"
    grep -n "$SENTINEL" "$LOG" | head -2 | sed 's/^/           /'
  else
    ok "zero occurrences of the password in the full -vvv log"
  fi

  # Both sensitive tasks must be censored — asserted by name, so a task losing
  # `no_log` is caught even while the sentinel happens not to appear.
  for t in 'Require the password that was prompted for' 'Enroll the first administrator'; do
    if censored_for "$t"; then
      ok "censored: $t"
    else
      bad "censored: $t" "the task output was not hidden by no_log"
    fi
  done

  # And the play must actually have REACHED the enrollment task, or the check
  # above proved nothing.
  if grep -qF 'Enroll the first administrator' "$LOG"; then
    ok "the run reached the password-bearing task"
  else
    bad "the run reaches the enrollment task" "it stopped earlier; the no_log checks are vacuous"
  fi

  # The password is delivered on STDIN, never as an argument. Ansible logs the
  # module invocation at -vvv, so an argv leak would be visible here.
  if grep -E '^<.*> EXEC' "$LOG" | grep -q "$SENTINEL"; then
    bad "the password is not in any exec line" "it appears in a command invocation"
  else
    ok "no exec line carries the password (stdin delivery, not argv)"
  fi
fi

echo
if [ "$fail" -gt 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) checks." >&2
  exit 1
fi
echo "PASS — $pass checks: the enrollment play validates real addresses correctly, still refuses malformed ones, stops when none is given, and keeps the password out of a -vvv log."
