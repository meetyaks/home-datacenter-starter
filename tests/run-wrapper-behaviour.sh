#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# THE WRAPPER, EXECUTED — NOT READ.
#
#   tests/run-wrapper-behaviour.sh
#
# tests/controller-scheduler.yml reads bin/keel-reconcile-dev and checks its
# shape. Shape is not behaviour. Two of its guarantees are the kind that look
# right in a diff and are wrong at runtime:
#
#   · IT REFUSES A SECOND CONCURRENT RUN. A `[ -e lock ]` test followed by a
#     `touch` reads exactly like an atomic lock and races with a window as
#     wide as the two commands. Only running two at once proves it.
#   · IT RETURNS ANSIBLE'S EXIT STATUS UNCHANGED. A wrapper that normalises
#     every failure to 1 — or worse, swallows one to 0 — makes a scheduler
#     report success for a deployment that did not happen. `set -e`, a
#     trailing `echo`, or a pipeline is enough to do that by accident.
#
# ⚠️ ansible-playbook IS REPLACED BY A STUB, AND NOTHING IS DEPLOYED. The
# subject is the wrapper, not Ansible: the stub exits with whatever status the
# case asks for and, for the concurrency case, sleeps. No inventory is read,
# no host is contacted, no playbook runs.
#
# Controller-only. Everything it creates is under /tmp, named exactly, and
# removed at the end.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

WRAPPER="$PWD/bin/keel-reconcile-dev"
ROOT=/tmp/keel-wrapper-behaviour
CONF="$ROOT/reconcile.conf"
STUB="$ROOT/bin/ansible-playbook"

cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT INT TERM
rm -rf "$ROOT"
mkdir -p "$ROOT/bin" "$ROOT/checkout/playbooks" "$ROOT/checkout/inventory"

# ── A CHECKOUT-SHAPED DIRECTORY, AND A VAULT FILE WITH NO SECRET IN IT ──────
#
# The wrapper refuses to start without these. They are empty placeholders:
# the stub never reads them, and this file must never contain a credential —
# not even a fake one, because "fake" is a property of the value and not of
# the file it lives in.
: > "$ROOT/checkout/playbooks/keel-reconcile.yml"
: > "$ROOT/checkout/inventory/hosts.yml"
: > "$ROOT/checkout/ansible.cfg"
: > "$ROOT/vault-pass"
chmod 0400 "$ROOT/vault-pass"

cat > "$CONF" <<'CONF_EOF'
KEEL_CHECKOUT=/tmp/keel-wrapper-behaviour/checkout
KEEL_VAULT_PASSWORD_FILE=/tmp/keel-wrapper-behaviour/vault-pass
KEEL_ANSIBLE_PLAYBOOK=/tmp/keel-wrapper-behaviour/bin/ansible-playbook
KEEL_RECONCILE_RUNLOCK=/tmp/keel-wrapper-behaviour/run.lock
KEEL_RECONCILE_TIMEOUT=60
CONF_EOF

# ⚠️ THE ONE HEREDOC THAT IS NOT CONFIGURATION: the stub itself. It prints a
# release id and a decision so the wrapper's summary line can be checked, then
# exits with STUB_RC and optionally sleeps for STUB_SLEEP.
cat > "$STUB" <<'STUB_EOF'
#!/bin/sh
echo "TASK [Say where this host stands] ****"
echo "channel wants  keel-20261001T010103Z-5bb120c97b56 (5bb120c97b56)"
echo "DECISION deploy — the channel names a newer release"
[ "${STUB_SLEEP:-0}" -gt 0 ] && sleep "${STUB_SLEEP}"
exit "${STUB_RC:-0}"
STUB_EOF
chmod +x "$STUB"

export KEEL_RECONCILE_CONF="$CONF"

pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; fail=$((fail + 1)); }

# ── 1. ANSIBLE'S EXIT STATUS, UNCHANGED ─────────────────────────────────────
#
# ⚠️ NOT JUST "NON-ZERO STAYS NON-ZERO". The specific number matters: Ansible
# uses 2 for a failed task, 4 for unreachable hosts and 99 for a user
# interrupt, and an operator reading a scheduler log distinguishes them.
echo "── the wrapper returns ansible's exit status, exactly ──────────────"
for rc in 0 1 2 4 99; do
  out=$(STUB_RC="$rc" "$WRAPPER" 2>&1); got=$?
  if [ "$got" -eq "$rc" ]; then
    ok "ansible exited $rc, the wrapper exited $got"
  else
    bad "ansible exited $rc but the wrapper exited $got" "$(echo "$out" | tail -2)"
  fi
done

# ── 2. IT SAYS WHAT HAPPENED, WITHOUT SAYING ANYTHING SECRET ────────────────
echo
echo "── it logs the release and the decision ────────────────────────────"
out=$(STUB_RC=0 "$WRAPPER" 2>&1)
case "$out" in
  *"keel-20261001T010103Z-5bb120c97b56"*) ok "the summary names the release" ;;
  *) bad "the summary does not name the release" "$(echo "$out" | tail -2)" ;;
esac
case "$out" in
  *"DECISION deploy"*) ok "the summary names the decision" ;;
  *) bad "the summary does not name the decision" "$(echo "$out" | tail -2)" ;;
esac
case "$out" in
  *"START mode=deploy"*) ok "it records what mode it ran in" ;;
  *) bad "it does not record the mode" ;;
esac

out=$(STUB_RC=0 "$WRAPPER" --check 2>&1)
case "$out" in
  *"START mode=check"*) ok "--check is recorded as a check run" ;;
  *) bad "--check is not recorded as a check run" ;;
esac

# ── 3. IT REFUSES A SECOND CONCURRENT RUN ───────────────────────────────────
#
# ⚠️ EXERCISED, NOT GREPPED. That the SECOND acquisition fails is the only
# property that matters, and it is exactly the one a careless rewrite loses.
echo
echo "── two at once: the second is refused, the first is unharmed ───────"

STUB_SLEEP=8 STUB_RC=0 "$WRAPPER" > "$ROOT/first.out" 2>&1 &
first=$!

# Wait for the first run to actually hold the lock before racing it —
# otherwise this tests nothing but which process the shell scheduled first.
waited=0
while [ ! -d "$ROOT/run.lock" ] && [ "$waited" -lt 50 ]; do
  sleep 0.1
  waited=$((waited + 1))
done

if [ ! -d "$ROOT/run.lock" ]; then
  bad "the first run never took the lock" "nothing to contend with"
else
  ok "the first run holds the lock"

  second_out=$(STUB_RC=0 "$WRAPPER" 2>&1); second_rc=$?
  if [ "$second_rc" -eq 100 ]; then
    ok "the second run refused, with its own status (100)"
  else
    bad "the second run exited $second_rc, not 100" "$(echo "$second_out" | tail -2)"
  fi
  case "$second_out" in
    *"ALREADY RUNNING"*) ok "and said why" ;;
    *) bad "the refusal does not say why" "$(echo "$second_out" | tail -2)" ;;
  esac
  # ⚠️ IT MUST NOT HAVE RUN ANSIBLE. A "refusal" that started the playbook and
  # then complained would be worse than no lock at all.
  case "$second_out" in
    *"DECISION"*) bad "the refused run executed the playbook anyway" ;;
    *) ok "and it never started a reconciliation" ;;
  esac
fi

wait "$first"; first_rc=$?
if [ "$first_rc" -eq 0 ]; then
  ok "the first run finished normally, unaffected by the contention"
else
  bad "the first run exited $first_rc" "$(tail -3 "$ROOT/first.out")"
fi

# ── 4. THE LOCK IS GIVEN BACK ───────────────────────────────────────────────
#
# A lock left behind would decline every subsequent tick, silently, until
# somebody read the log.
echo
echo "── the lock does not outlive the run ───────────────────────────────"
if [ -d "$ROOT/run.lock" ]; then
  bad "the lock survived a completed run"
else
  ok "released after success"
fi

STUB_RC=2 "$WRAPPER" >/dev/null 2>&1
if [ -d "$ROOT/run.lock" ]; then
  bad "the lock survived a FAILED run"
else
  ok "released after failure too"
fi

# ── 5. MISCONFIGURATION IS REFUSED, DISTINCTLY ──────────────────────────────
#
# ⚠️ A DIFFERENT STATUS FROM A DEPLOYMENT FAILURE. "The vault file is missing"
# and "the deployment failed" need different responses from whoever is paged,
# so they must not arrive as the same number.
echo
echo "── a missing prerequisite is refused before anything runs ──────────"
# ⚠️ REMOVE AND RECREATE, NOT `mv` AND `mv` BACK. A `mv` that fails because
# the fixture is not where it was expected leaves the rest of the section
# testing something else entirely — which is how this check first reported
# "the refusal does not name the vault file" when the real problem was that
# the whole fixture had been deleted by a leftover process.
[ -f "$ROOT/vault-pass" ] || { bad "the fixture vanished before the misconfiguration case"; exit 1; }
rm -f "$ROOT/vault-pass"
out=$("$WRAPPER" 2>&1); rc=$?
: > "$ROOT/vault-pass"
chmod 0400 "$ROOT/vault-pass"
if [ "$rc" -eq 101 ]; then
  ok "a missing vault password file exits 101, not a deployment status"
else
  bad "a missing vault password file exited $rc" "$(echo "$out" | tail -2)"
fi
case "$out" in
  *"vault password file"*) ok "and names the file it could not read" ;;
  *) bad "the refusal does not name the vault file" "$(echo "$out" | tail -2)" ;;
esac
case "$out" in
  *"DECISION"*) bad "it ran the playbook despite the missing prerequisite" ;;
  *) ok "and it ran nothing" ;;
esac

# ── 6. IT NEVER PRINTS A SECRET ─────────────────────────────────────────────
#
# The vault file here is empty on purpose, so this proves the shape rather
# than the contents: the wrapper must name the PATH and never cat the file.
echo
echo "── the wrapper logs paths, never values ────────────────────────────"
out=$(STUB_RC=0 "$WRAPPER" 2>&1)
if printf '%s' "$out" | grep -qE 'gh[pousr]_[A-Za-z0-9]{16,}|BEGIN [A-Z ]*PRIVATE KEY'; then
  bad "the wrapper printed something credential-shaped"
else
  ok "no credential-shaped output"
fi

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: ${fail} of $((fail + pass)) check(s)."
  exit 1
fi
echo "wrapper behaviour: ${pass} checks — status preserved, concurrency refused, lock released."
