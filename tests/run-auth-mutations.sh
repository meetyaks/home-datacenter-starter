#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# BREAK THE SCHEDULER AND THE CREDENTIAL HANDLING, PROVE THE SUITES NOTICE.
#
#   tests/run-auth-mutations.sh
#
# ⚠️ A GUARD THAT HAS NEVER FAILED IS NOT A GUARD. These guards decide
# whether a read-only token ends up in a process table, whether a failed
# deployment leaves a credential on the host, and whether an unattended
# controller accepts a release document from whatever answered on port 22.
# Each mutation below removes or inverts exactly one of them and asserts the
# suites go red FOR THAT REASON — a failure for the wrong reason is not a
# pass, because a suite that failed on everything would look identical.
#
# ⚠️ IT STARTS FROM A GREEN BASELINE, AND NOT AS A FORMALITY. Without it,
# every case below is satisfied by a suite that is broken.
#
# Operates on COPIES: every file is restored on exit, including on interrupt.
# Controller-only; touches nothing outside this checkout and /tmp.
#
# ⚠️ DO NOT EDIT THE MUTATED FILES WHILE THIS IS RUNNING. It restores each
# from a copy taken at startup, so an edit made mid-run is silently reverted.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

TMP="$(mktemp -d)"

PLIST=roles/keel_reconcile/files/launchd/com.meetyaks.keel-reconcile-dev.plist
SERVICE=roles/keel_reconcile/files/systemd/keel-reconcile-dev.service
WRAPPER=bin/keel-reconcile-dev
DEFAULTS=roles/keel_reconcile/defaults/main.yml
CREDS=roles/keel_reconcile/tasks/credentials.yml
REGISTRY=roles/keel/tasks/registry.yml
BUNDLE=roles/keel/tasks/release-bundle.yml
VAULT_EXAMPLE=inventory/group_vars/linux_servers/vault.yml.example

FILES="$PLIST $SERVICE $WRAPPER $DEFAULTS $CREDS $REGISTRY $BUNDLE $VAULT_EXAMPLE"

restore() {
  for f in $FILES; do
    cp "$TMP/$(echo "$f" | tr / _)" "$f" 2>/dev/null
  done
}
trap 'restore; rm -rf "$TMP"' EXIT INT TERM
for f in $FILES; do cp "$f" "$TMP/$(echo "$f" | tr / _)"; done

pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; fail=$((fail + 1)); }

echo "── the shipped tree passes its own suites ──────────────────────────────"
base_green=1
for s in controller-scheduler credential-contract; do
  if ansible-playbook "tests/${s}.yml" >/dev/null 2>&1; then
    ok "tests/${s}.yml is green"
  else
    bad "tests/${s}.yml FAILS on the shipped tree"; base_green=0
  fi
done
if tests/run-wrapper-behaviour.sh >/dev/null 2>&1; then
  ok "tests/run-wrapper-behaviour.sh is green"
else
  bad "tests/run-wrapper-behaviour.sh FAILS on the shipped tree"; base_green=0
fi
[ "$base_green" -eq 1 ] || { echo "FAILED early — the baseline is not green."; exit 1; }

echo
echo "── each mutation is caught, for its own reason ─────────────────────────"

mutate() {  # mutate <label> <file> <perl-expr> <suite-or-script> <expected-substring>
  local label="$1" file="$2" expr="$3" suite="$4" want="$5"
  restore
  perl -0pi -e "$expr" "$file"

  if diff -q "$file" "$TMP/$(echo "$file" | tr / _)" >/dev/null; then
    bad "$label" "the mutation changed nothing — it is not a real mutation"
    return
  fi

  # ⚠️ ONE RUN, NOT TWO. Running the suite once for its output and again for
  # its status doubles a slow suite and lets the two disagree.
  local out rc
  case "$suite" in
    *.sh) out=$("$suite" 2>&1); rc=$? ;;
    *)    out=$(ansible-playbook "tests/${suite}.yml" 2>&1); rc=$? ;;
  esac

  if [ "$rc" -eq 0 ]; then
    bad "$label" "${suite} still PASSED"
    return
  fi
  if grep -qF -- "$want" <<<"$out"; then
    ok "$label"
  else
    bad "$label" "red, but not for '${want}'" \
      && echo "        actual: $(grep -oE '"msg": "[^"]{0,200}|  FAIL  .{0,120}' <<<"$out" | tail -2 | tr '\n' ' ')"
  fi
}

# ── THE SCHEDULER ───────────────────────────────────────────────────────────

# 1. THE MAC CONTROLLER LEFT WITHOUT A SCHEDULER IT CAN START — the original
#    mistake, re-committed. There is no systemctl here, so a plist that will
#    not load means nothing is scheduled at all.
#
#    ⚠️ BREAKING THE XML, NOT RENAMING A KEY. A renamed key still lints and
#    still exists, so the suite would pass; `launchctl bootstrap` is what
#    would have failed, weeks later. Removing the closing tag is the
#    realistic regression — a hand edit, invisible in a diff.
mutate "a launchd plist a Mac cannot load is caught" \
  "$PLIST" 's{</dict>\n</plist>}{</plist>}' \
  controller-scheduler 'no valid launchd plist'

# 2. KeepAlive — an uncontrolled retry loop, in launchd's dialect.
mutate "enabling KeepAlive is caught" \
  "$PLIST" 's{<key>RunAtLoad</key>}{<key>KeepAlive</key>\n  <true/>\n  <key>RunAtLoad</key>}' \
  controller-scheduler 'plist sets KeepAlive'

# 3. THE SCHEDULER GROWING ITS OWN COPY OF THE POLICY.
#
#    ⚠️ ADDED BESIDE THE WRAPPER, NOT INSTEAD OF IT. Replacing ExecStart
#    outright is caught by the earlier "executes the wrapper" assertion,
#    which leaves the duplication check itself untested. The realistic
#    regression is somebody keeping the wrapper and adding a step — and it
#    is the one that would actually ship.
mutate "a scheduler running Ansible beside the wrapper is caught" \
  "$SERVICE" 's{ExecStart=/opt/home-datacenter-starter/bin/keel-reconcile-dev}{ExecStartPre=/usr/bin/ansible-playbook playbooks/keel-reconcile.yml --vault-password-file /etc/keel/vault-pass\nExecStart=/opt/home-datacenter-starter/bin/keel-reconcile-dev}' \
  controller-scheduler 'runs Ansible directly'

# 4. A CREDENTIAL IN A WORLD-READABLE PLIST.
mutate "a token committed into the plist is caught" \
  "$PLIST" 's{<key>KEEL_CHECKOUT</key>}{<key>REGISTRY_TOKEN</key>\n    <string>ghp_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA</string>\n    <key>KEEL_CHECKOUT</key>}' \
  controller-scheduler 'credential, or something shaped like one'

# 5. THE WRAPPER'S CONCURRENCY LOCK REMOVED — two reconciliations starting at
#    once, both cloning, both deciding, both logging in.
#    ⚠️ `mkdir -p`, NOT `if false`. Removing the branch outright means the
#    lock directory is never created at all, and the suite fails on "the
#    first run never took the lock" — a true failure, but about the fixture
#    rather than about concurrency. `mkdir -p` is the realistic regression:
#    it looks like a lock, it creates the directory, and it never refuses.
#
#    ⚠️ `\$` IN THE REPLACEMENT TOO. perl interpolates the replacement side,
#    so an unescaped `$KEEL_RECONCILE_RUNLOCK` becomes the empty string —
#    producing `mkdir -p ""`, which FAILS, which makes every run report
#    "already running". The mutation then tests the opposite of what it
#    claims to, and the suite is red for a reason nobody intended.
mutate "removing the wrapper's refusal to run twice is caught" \
  "$WRAPPER" 's{if ! mkdir "\$KEEL_RECONCILE_RUNLOCK" 2>/dev/null; then}{if ! mkdir -p "\$KEEL_RECONCILE_RUNLOCK" 2>/dev/null; then}' \
  tests/run-wrapper-behaviour.sh 'the second run exited 0, not 100'

# ── THE DEPLOY KEY ──────────────────────────────────────────────────────────

# 6. THE PREFLIGHT SKIPPED ENTIRELY — the scheduler discovers it has no
#    credential at 3am instead of here. Gating the whole block off is the
#    shape this takes in practice: one `when:` edited while debugging.
mutate "skipping the deploy-key preflight is caught" \
  "$CREDS" 's{- name: The deploy-key contract\n  when: keel_channel_is_remote \| bool}{- name: The deploy-key contract\n  when: false}' \
  credential-contract 'the credential preflight ACCEPTED this'

# 7. THE MODE CHECK REMOVED — a world-readable key is not a dedicated one.
#
#    ⚠️ CAUGHT AS A WRONG REASON, NOT AS AN ACCEPTANCE, AND THAT IS THE MORE
#    INTERESTING RESULT. The fixture key is not real, so `git ls-remote`
#    fails and the case is STILL refused — just for the wrong thing. A suite
#    that checked only the verdict would have called that a pass and left
#    the mode check resting on an unrelated failure. The per-case `because`
#    is what distinguishes a deliberate refusal from a lucky one.
mutate "removing the deploy-key mode check is caught" \
  "$CREDS" 's{    - name: It is readable only by its owner}{    - name: It is readable only by its owner\n      when: false}' \
  credential-contract 'A WORLD-READABLE DEPLOY KEY IS REFUSED: refused, but for the wrong reason'

# 8. STRICT HOST-KEY CHECKING DISABLED — the path by which a site deploys a
#    manifest handed to it by the wrong server.
mutate "disabling StrictHostKeyChecking is caught" \
  "$DEFAULTS" 's{-o StrictHostKeyChecking=yes}{-o StrictHostKeyChecking=no}' \
  credential-contract 'does not pin an explicit key'

# 9. FALLING BACK TO THE OPERATOR'S INTERACTIVE CREDENTIAL — the check would
#    then pass on a developer's Mac and prove nothing about the scheduler.
mutate "falling back to an interactive credential is caught" \
  "$DEFAULTS" 's{keel_reconcile_channel_repo: git\@github.com:meetyaks/keel.git}{keel_reconcile_channel_repo: https://github.com/meetyaks/keel}' \
  credential-contract 'It must be the SSH form'

# 10. THE ssh-agent ESCAPE HATCH REOPENED.
mutate "re-enabling the ssh-agent fallback is caught" \
  "$DEFAULTS" 's{-o IdentityAgent=none\n  }{  }' \
  credential-contract 'IdentityAgent=none'

# ── THE REGISTRY TOKEN ──────────────────────────────────────────────────────

# 11. THE TOKEN MOVED INTO AN ARGUMENT — visible in the host's process table.
mutate "moving the token into a command argument is caught" \
  "$REGISTRY" 's{      - --password-stdin\n    stdin: "\{\{ keel_vault_registry_token \}\}"\n    stdin_add_newline: false}{      - --password\n      - "{{ keel_vault_registry_token }}"}' \
  credential-contract 'passed as a command-line argument'

# 12. no_log REMOVED — a failed task prints its own arguments.
mutate "removing no_log from the login is caught" \
  "$REGISTRY" 's{  no_log: true\n  changed_when: false\n  register: keel_registry_login}{  changed_when: false\n  register: keel_registry_login}' \
  credential-contract 'missing `no_log: true`'

# 13. THE CREDENTIAL CHECK REMOVED — discovered after compose stopped the stack.
mutate "removing the registry credential check is caught" \
  "$REGISTRY" 's{      - keel_vault_registry_token is defined}{      - true}' \
  credential-contract 'does not require both'

# 14. LOGOUT TAKEN OUT OF `always` — a failed deployment leaves the token on
#     the host, in exactly the case where somebody goes poking around.
mutate "moving logout out of the always block is caught" \
  "$BUNDLE" 's{  always:\n    - name: Give the registry credential back, whatever happened\n      ansible.builtin.include_tasks: registry-logout.yml}{    - name: Give the registry credential back, usually\n      ansible.builtin.include_tasks: registry-logout.yml}' \
  credential-contract 'not in an `always:` block'

# 15. PULL BY TAG INSTEAD OF DIGEST — the image that runs need not be the
#     image that was gated.
mutate "pulling a tag instead of a digest is caught" \
  "$BUNDLE" 's{          - "\{\{ item.repository \}\}\@\{\{ item.digest \}\}"\n      register: keel_release_pull}{          - "{{ item.repository }}:latest"\n      register: keel_release_pull}' \
  credential-contract 'not a digest reference'

# 16. DIGEST VERIFICATION REMOVED — `docker pull` exiting 0 is not the same
#     statement as "the daemon holds this digest".
mutate "removing the pulled-digest verification is caught" \
  "$BUNDLE" 's{          - item.item.digest in item.stdout}{          - true}' \
  credential-contract 'Nothing confirms'

# 17. A REAL CREDENTIAL VALUE COMMITTED.
mutate "committing a credential value is caught" \
  "$VAULT_EXAMPLE" 's{keel_vault_registry_token: ""}{keel_vault_registry_token: "ghp_BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"}' \
  credential-contract 'shaped like a real credential'

restore
echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: ${fail} of $((fail + pass)) mutation(s) not caught."
  exit 1
fi
echo "auth mutations: ${pass} checks, every mutation caught for its own reason."
