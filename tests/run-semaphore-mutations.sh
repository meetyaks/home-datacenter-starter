#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# A GUARD THAT HAS NEVER FAILED IS NOT A GUARD.
#
#   tests/run-semaphore-mutations.sh
#
# tests/semaphore-config.yml and tests/semaphore-task-shape.yml both pass
# against the shipped role. That proves they agree with it — not that they
# would notice if it changed. So this breaks the role one way at a time and
# requires the suites to go RED, and red FOR THAT REASON: a failure for the
# wrong reason is not a pass, because the next person reads the message and
# fixes the thing it names.
#
# Every mutation is reverted from a byte-for-byte backup, including on an
# interrupt. Nothing here touches a host, a port or a daemon.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || { echo "cannot reach the repository root" >&2; exit 1; }

DEFAULTS=roles/semaphore/defaults/main.yml
CONFIG_TPL=roles/semaphore/templates/config.json.j2
PLIST_TPL=roles/semaphore/templates/launchd.plist.j2
BACKUP_TPL=roles/semaphore/templates/semaphore-backup.sh.j2
BOOTSTRAP_TPL=roles/semaphore/templates/semaphore-bootstrap-admin.sh.j2
MAIN=roles/semaphore/tasks/main.yml
PREFLIGHT=roles/semaphore/tasks/preflight-secrets.yml
ACCOUNT=roles/semaphore/tasks/account.yml
CONFIGURE=roles/semaphore/tasks/configure.yml
DATABASE=roles/semaphore/tasks/database.yml
ADMIN=roles/semaphore/tasks/admin.yml
INSTALL=roles/semaphore/tasks/install.yml
VERIFY=roles/semaphore/tasks/verify.yml
LINUX_SH=tests/run-semaphore-linux.sh
MACOS_SH=tests/run-semaphore-launchd.sh
GATE_SH=tests/run-dc1-semaphore-gate.sh

FILES=("$DEFAULTS" "$CONFIG_TPL" "$PLIST_TPL" "$BACKUP_TPL" "$BOOTSTRAP_TPL" "$MAIN" "$PREFLIGHT"
       "$ACCOUNT" "$CONFIGURE" "$DATABASE" "$ADMIN" "$INSTALL" "$VERIFY"
       "$LINUX_SH" "$MACOS_SH" "$GATE_SH")

WORK=$(mktemp -d -t semaphore-mutations.XXXXXX)
restore() {
  local i=0
  for f in "${FILES[@]}"; do
    [ -f "$WORK/$i" ] && cp "$WORK/$i" "$f"
    i=$((i + 1))
  done
  return 0
}
cleanup() { restore; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

i=0
for f in "${FILES[@]}"; do cp "$f" "$WORK/$i"; i=$((i + 1)); done

pass=0
fail=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }

# perl -pi, never `sed -i ''`: the empty-suffix form is BSD-only and silently
# edits nothing on Linux, which once made eight mutations pass by doing
# nothing at all.
edit() { perl -pi -e "$1" "$2"; }

expect_red() {
  local suite=$1 want=$2 label=$3
  if ansible-playbook "tests/${suite}" >"$WORK/out" 2>&1; then
    bad "$label" "tests/${suite} still PASSED — the mutation went unnoticed"
  elif grep -qE "$want" "$WORK/out"; then
    ok "$label"
  else
    bad "$label" "tests/${suite} failed, but not for /${want}/"
    grep -E "fatal|assertion|msg" "$WORK/out" | head -3 | sed 's/^/           /'
  fi
  restore
}

echo "── the suites are green before anything is broken ──"
for s in semaphore-config semaphore-task-shape; do
  if ansible-playbook "tests/${s}.yml" >"$WORK/out" 2>&1; then
    ok "tests/${s}.yml is green"
  else
    bad "tests/${s}.yml is green" "it fails BEFORE any mutation; fix that first"
    tail -5 "$WORK/out" | sed 's/^/           /'
    echo; echo "ABORTED — the baseline is not green." >&2
    exit 1
  fi
done

echo
echo "── the pinned release ──"
edit 's{^semaphore_version: "2\.19\.12"$}{semaphore_version: "latest"}' "$DEFAULTS"
expect_red semaphore-config.yml 'exact semantic version|exact release' \
           "replacing the pinned version with latest is caught"

restore
edit 's{^semaphore_edition: "community"$}{semaphore_edition: "standard"}' "$DEFAULTS"
expect_red semaphore-config.yml 'community|exact release' \
           "switching to the licensed standard edition is caught"

restore
edit 's{^  darwin_arm64: "f99cd2829722c9f4a7074cafa07a43ad7f027055b0b0eb48931059d38c62261e"$}{  darwin_arm64: ""}' "$DEFAULTS"
expect_red semaphore-config.yml 'full 64-character SHA-256|SHA-256' \
           "removing a checksum is caught"

restore
perl -0pi -e 's{        checksum: "sha256:\{\{ semaphore_checksums\[semaphore_platform\] \}\}"\n}{}' "$INSTALL"
expect_red semaphore-task-shape.yml 'checksum|verified' \
           "removing checksum verification from the download is caught" || true

echo
echo "── exposure ──"
restore
edit 's{^semaphore_interface: "127\.0\.0\.1"$}{semaphore_interface: "0.0.0.0"}' "$DEFAULTS"
expect_red semaphore-config.yml 'loopback|0\.0\.0\.0' \
           "binding 0.0.0.0 is caught"

restore
perl -pi -e 's{"interface": "\{\{ semaphore_interface \}\}"}{"interface": "0.0.0.0"}' "$CONFIG_TPL"
expect_red semaphore-config.yml 'loopback|0\.0\.0\.0' \
           "hardcoding a wildcard interface in the template is caught"

echo
echo "── service identity ──"
restore
edit 's{^semaphore_user: "_semaphore"$}{semaphore_user: "root"}' "$DEFAULTS"
expect_red semaphore-config.yml 'dedicated|root' \
           "running as root is caught"

restore
edit 's{^semaphore_user: "_semaphore"$}{semaphore_user: "dc1-arm-1"}' "$DEFAULTS"
expect_red semaphore-config.yml 'dedicated|operator' \
           "running as the human controller account is caught"

restore
perl -pi -e 's{<string>\{\{ semaphore_user \}\}</string>}{<string>root</string>}' "$PLIST_TPL"
expect_red semaphore-config.yml 'dedicated|root' \
           "a plist that runs the daemon as root is caught"

restore
# ⚠️ THE DISPOSABLE-TEST ESCAPE HATCH MUST NOT BECOME THE DEFAULT. As a
# default it would run Semaphore as whoever applied the playbook.
edit 's{^semaphore_manage_account: true$}{semaphore_manage_account: false}' "$DEFAULTS"
expect_red semaphore-config.yml 'manage_account|dedicated service account' \
           "defaulting to not managing the service account is caught"

restore
# ⚠️ getent DOES NOT EXIST ON macOS. The module requires the binary, so a
# getent-based lookup converges in the Linux container and dies on the
# controller — which is exactly what happened on the first real gate run.
perl -0pi -e 's{    - name: Look for an existing service account\n      ansible\.builtin\.command:\n        cmd: "id -u \{\{ semaphore_user \}\}"\n}{    - name: Look for an existing service account\n      ansible.builtin.getent:\n        database: passwd\n        key: "\{\{ semaphore_user \}\}"\n}' "$ACCOUNT"
expect_red semaphore-task-shape.yml 'getent|macOS' \
           "a getent-based account lookup that cannot work on macOS is caught"

echo
echo "── secrets ──"
restore
edit 's{^semaphore_admin_password: .*$}{semaphore_admin_password: "changeme"}' "$DEFAULTS"
expect_red semaphore-config.yml 'non-empty value|usable key material' \
           "a default administrator password is caught"

restore
edit 's{^semaphore_access_key_encryption: .*$}{semaphore_access_key_encryption: "aGVsbG93b3JsZGhlbGxvd29ybGRoZWxsb3dvcmxkMTI="}' "$DEFAULTS"
expect_red semaphore-config.yml 'usable value|key material|empty without the vault' \
           "key material committed in defaults is caught"

restore
edit 's{^semaphore_admin_password_min_length: 16$}{semaphore_admin_password_min_length: 4}' "$DEFAULTS"
expect_red semaphore-config.yml 'at least 16|password floor' \
           "lowering the administrator password floor is caught"

restore
perl -0pi -e 's{^- name: Each required secret must be present and non-empty\n(?:.*?\n)*?  no_log: true\n}{}m' "$PREFLIGHT"
expect_red semaphore-task-shape.yml 'no_log|secret' \
           "removing the missing-secret preflight is caught" || true

restore
perl -0pi -e 's{(    mode: "0600"\n  become: true\n)  no_log: true\n}{$1}' "$CONFIGURE"
expect_red semaphore-task-shape.yml 'no_log' \
           "removing no_log from the config template task is caught"

restore
# ── THE FIRST-ADMINISTRATOR BOOTSTRAP CONTRACT ────────────────────────────
#
# The role must not be able to create a user at all, and the helper must
# accept a password from nowhere but a terminal.
perl -pi -e 's{^  ansible\.builtin\.include_tasks: admin\.yml$}{  ansible.builtin.command: "semaphore users add --admin --password x"}' "$MAIN"
expect_red semaphore-config.yml 'users add|--password|creates no user' \
           "reintroducing argv-based user creation in the role is caught"

restore
perl -pi -e 's{^read -rs PW; echo$}{PW="$1"}; s{^read -rs PW2; echo$}{PW2="$1"}' "$BOOTSTRAP_TPL"
expect_red semaphore-config.yml 'interactive terminal|read -rs' \
           "a helper that takes the password as an argument is caught"

restore
perl -pi -e 's{^read -rs PW2; echo$}{PW2="${SEMAPHORE_ADMIN_PASSWORD}"}' "$BOOTSTRAP_TPL"
expect_red semaphore-config.yml 'interactive terminal|environment' \
           "a helper that takes the password from the environment is caught"

restore
perl -ni -e 'print unless /\[ -t 0 \] && \[ -t 1 \]/' "$BOOTSTRAP_TPL"
expect_red semaphore-config.yml 'interactive terminal|real terminal|no other source' \
           "a helper that can run noninteractively is caught"

restore
perl -ni -e 'print unless /SELECT count\(\*\) FROM user/' "$BOOTSTRAP_TPL"
expect_red semaphore-config.yml 'existing|FROM user|unsafe precondition' \
           "bootstrap that does not check for an existing user is caught"

restore
perl -ni -e 'print unless /SELECT count\(\*\) FROM access_key/' "$BOOTSTRAP_TPL"
expect_red semaphore-config.yml 'access_key|Key Store|unsafe precondition' \
           "bootstrap that ignores existing Key Store credentials is caught"

restore
perl -ni -e 'print unless /the Semaphore service is/' "$BOOTSTRAP_TPL"
expect_red semaphore-config.yml 'service is|unsafe precondition' \
           "bootstrap that runs while the service is live is caught"

restore
perl -ni -e 'print unless /trap cleanup EXIT INT TERM/' "$BOOTSTRAP_TPL"
expect_red semaphore-config.yml 'temporary configuration|unsafe precondition' \
           "a temporary setup config that survives failure is caught"

restore
perl -ni -e 'print unless /bootstrap already completed/' "$BOOTSTRAP_TPL"
expect_red semaphore-config.yml 'already|unsafe precondition' \
           "a helper that can be run twice is caught"

restore
# ⚠️ 4A: setup WRITES ITS CONFIG 0644 AND THE BINARY CANNOT BE TOLD
# OTHERWISE, so the 0700 parent is the only thing keeping its generated
# encryption key out of reach while it exists on disk.
perl -pi -e 's{mkdir -m 0700 "\$SETUPDIR"}{mkdir -m 0755 "\$SETUPDIR"}' "$BOOTSTRAP_TPL"
expect_red semaphore-config.yml '0700|unsafe precondition' \
           "a world-traversable temporary setup directory is caught"

restore
perl -ni -e 'print unless /temporary setup path already exists/' "$BOOTSTRAP_TPL"
expect_red semaphore-config.yml 'already exists|unsafe precondition' \
           "a setup directory that may be pre-planted is caught"

restore
perl -pi -e 's{<key>PATH</key>}{<key>SEMAPHORE_ACCESS_KEY_ENCRYPTION</key>\n    <string>{{ semaphore_access_key_encryption }}</string>\n    <key>PATH</key>}' "$PLIST_TPL"
expect_red semaphore-config.yml 'plist|secret' \
           "a secret embedded in the world-readable plist is caught"

echo
echo "── permissions ──"
restore
perl -pi -e 's{^    mode: "0600"$}{    mode: "0644"}' "$CONFIGURE"
expect_red semaphore-task-shape.yml 'no_log|0600' \
           "a world-readable configuration is caught" || true

echo
echo "── order ──"
restore
perl -0pi -e 's{- name: Apply every pending restart[^\n]*\n(?:  \#[^\n]*\n|\n)*  ansible\.builtin\.meta: flush_handlers\n}{}' "$MAIN"
expect_red semaphore-task-shape.yml 'flush handlers exactly once|Found flush at' \
           "removing the handler flush is caught"

restore
perl -0pi -e 's{(- name: Apply every pending restart[^\n]*\n(?:  \#[^\n]*\n|\n)*  ansible\.builtin\.meta: flush_handlers\n)}{}; s{(- name: Verify it answers\n  ansible\.builtin\.include_tasks: verify\.yml\n)}{$1\n- name: Apply every pending restart BEFORE anything verifies the service\n  ansible.builtin.meta: flush_handlers\n}' "$MAIN"
expect_red semaphore-task-shape.yml 'BEFORE verify|Found flush at' \
           "flushing AFTER verification is caught"

restore
perl -0pi -e 's{(- name: Every secret is present and well-formed before anything is created\n  ansible\.builtin\.include_tasks: preflight-secrets\.yml\n)}{}; s{(- name: Verify it answers\n)}{- name: Every secret is present and well-formed before anything is created\n  ansible.builtin.include_tasks: preflight-secrets.yml\n\n$1}' "$MAIN"
expect_red semaphore-task-shape.yml 'before the service account|before the first mutation|preflight' \
           "checking secrets after the host has been mutated is caught"

echo
echo "── authority: Git stays the source of truth ──"
restore
edit 's{^semaphore_repo_branch: "main"$}{semaphore_repo_branch: "operator-edits"}' "$DEFAULTS"
expect_red semaphore-config.yml 'main|source of truth' \
           "pointing the project at a non-main branch is caught"

restore
edit 's{^semaphore_repo_url: .*$}{semaphore_repo_url: ""}' "$DEFAULTS"
expect_red semaphore-config.yml 'repository|source of truth' \
           "removing the Git repository entirely is caught"

echo
echo "── the harnesses must stay harnesses ──"
restore
perl -pi -e 's{\btsudo }{sudo -n }g' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'expired sudo|tsudo' \
           "teardown that fails silently on an expired sudo timestamp is caught"

restore
perl -ni -e 'print unless /^trap teardown EXIT INT TERM$/' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'trap|teardown' \
           "omitting the macOS teardown trap is caught"

restore
perl -pi -e 's{^LABEL="org\.dc1\.semaphoredisposable\$\{STAMP\}"$}{LABEL="org.dc1.semaphore"}' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'unique|production label' \
           "a macOS harness reusing the PRODUCTION label is caught"

restore
perl -0pi -e 's{  for _p in \$\(pgrep -f "\$ROOT/sbin/semaphore" 2>/dev/null\); do\n.*?\n  done\n}{  kill "\$DISPOSABLE_PID" 2>/dev/null\n}s' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'by prefix|stale PID' \
           "teardown identifying its process by a stale PID is caught"

restore
perl -ni -e 'print unless /the daemon was RESTARTED before verification/' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'RESTARTED before verification|pid changed' \
           "treating a still-running old PID as success is caught"

restore
perl -ni -e 'print unless /third run reported changed=0/' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'changed=0|no-op' \
           "allowing second-run churn is caught"

restore
perl -ni -e 'print unless /VACUUM INTO/' "$BACKUP_TPL"
expect_red semaphore-harness-integrity.yml 'VACUUM INTO|live-file copy|WAL' \
           "a backup that blindly copies a live WAL database is caught"

echo
echo "── the macOS account lifecycle ──"
restore
perl -pi -e 's{tests/run-semaphore-launchd\.sh --with-account}{tests/run-semaphore-launchd.sh}' "$GATE_SH"
expect_red semaphore-harness-integrity.yml 'with-account|account path' \
           "a gate that skips the account-management path is caught"

restore
perl -pi -e 's{^  TEST_USER="_semt\$\(openssl rand -hex 4\)"$}{  TEST_USER="_semaphore"}' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml '_semt|PRODUCTION' \
           "a gate that would use the PRODUCTION account name is caught"

restore
perl -ni -e 'print unless /refusing: generated the PRODUCTION name/' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'PRODUCTION name|disposable identity' \
           "removing the production-name refusal from creation is caught"

restore
perl -ni -e 'print unless /REFUSING: that is the PRODUCTION account/' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'PRODUCTION account|disposable identity' \
           "removing the production-name refusal from deletion is caught"

restore
# ⚠️ WITHOUT THE RECORDED SETS THE COLLISION CHECK IS VACUOUS: a uid is
# "free" only relative to what was in use beforehand.
perl -ni -e 'print unless /^  UIDS_BEFORE=/' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'UIDS_BEFORE|Directory Services' \
           "dropping the recorded UID set is caught"

restore
perl -ni -e 'print unless /^  GIDS_BEFORE=/' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'GIDS_BEFORE|Directory Services' \
           "dropping the recorded GID set is caught"

restore
perl -ni -e 'print unless /dsmemberutil checkmembership -U "\$TEST_USER" -G admin/' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'admin|Directory Services' \
           "not checking admin membership is caught"

restore
perl -ni -e 'print unless /dsmemberutil checkmembership -U "\$TEST_USER" -G wheel/' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'wheel|Directory Services' \
           "not checking wheel membership is caught"

restore
perl -pi -e 's{T_SHELL=\$\(dscl \. -read "/Users/\$TEST_USER" UserShell}{T_SHELL=\$(echo skip}' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'UserShell|Directory Services' \
           "not checking the login shell is caught"

restore
perl -pi -e 's{dscl \. -read "/Users/\$TEST_USER" AuthenticationAuthority}{true}g' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'AuthenticationAuthority|Directory Services' \
           "not checking for a usable password is caught"

restore
perl -pi -e 's{IsHidden=\$\{T_HIDDEN:-unset\}}{hidden-unchecked}' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'IsHidden|Directory Services' \
           "dropping the hidden-account proof is caught"

restore
# ⚠️ ORDER: files must go while the identity still resolves, or they are
# left owned by a uid that no longer exists.
# ⚠️ THE BLOCK IS MOVED, NOT DELETED. Deleting it would make the ordering
# assertion fail with a Jinja index error — a failure for the wrong reason.
# Swapping the marker comment inverts the documented order while leaving
# both operations present, which is exactly the defect being modelled.
perl -pi -e 's{^  \# ── STEP 4: FILES FIRST, WHILE THE IDENTITY STILL RESOLVES ──+$}{  # ── STEP 4: identity first (WRONG ORDER) ──}' "$MACOS_SH"
perl -0pi -e 's{(  case "\$ROOT" in\n    /\*/semaphore-disposable\.\*\) tsudo rm -rf "\$ROOT" \&\& echo "  removed \$ROOT" ;;\n    \*\) echo "  REFUSING to remove unexpected path: \$ROOT" ;;\n  esac\n)}{}s' "$MACOS_SH"
perl -0pi -e 's{(      tsudo dscacheutil -flushcache >/dev/null 2>&1\n)}{$1      case "\$ROOT" in\n        /*/semaphore-disposable.*) tsudo rm -rf "\$ROOT" \&\& echo "  removed \$ROOT" ;;\n        *) echo "  REFUSING to remove unexpected path: \$ROOT" ;;\n      esac\n}s' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'FILES BEFORE THE IDENTITY|BEFORE the user record' \
           "deleting the account before its files is caught"

restore
perl -ni -e 'print unless /dscacheutil -flushcache/' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'flushcache|exact records' \
           "skipping the directory-service cache flush is caught"

restore
perl -ni -e 'print unless /id \$TEST_USER no longer resolves/' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'no longer resolves|exact records' \
           "teardown that does not prove the identity is gone is caught"

restore
perl -pi -e 's{tsudo dscl \. -delete "/Users/\$TEST_USER"}{tsudo pkill -f "_semt"; tsudo dscl . -delete "/Users/\$TEST_USER"}' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml 'prefix or pattern|pkill' \
           "teardown matching an account by broad pattern is caught"

restore
perl -ni -e 'print unless /no disposable _semt account survives/' "$GATE_SH"
expect_red semaphore-harness-integrity.yml '_semt account survives|sweeps for strays' \
           "a gate that does not sweep for stray identities is caught"

restore
# ⚠️ FOUND BY THE CONTROLLER GATE. $TMPDIR is drwx------ and per-user on
# macOS, so a service account cannot traverse it to reach the binary.
perl -pi -e 's{mktemp -d /private/tmp/semaphore-disposable\.XXXXXX}{mktemp -d -t semaphore-disposable.XXXXXX}' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml '/private/tmp|traversable|TMPDIR' \
           "a disposable prefix under \$TMPDIR the service account cannot reach is caught"

restore
perl -ni -e 'print unless /^chmod 0711 "\$ROOT"$/' "$MACOS_SH"
expect_red semaphore-harness-integrity.yml '0711|traversable' \
           "a disposable prefix left untraversable is caught"

echo
echo "── everything is restored ──"
restore
for s in semaphore-config semaphore-task-shape semaphore-harness-integrity; do
  if ansible-playbook "tests/${s}.yml" >"$WORK/out" 2>&1; then
    ok "tests/${s}.yml is green again"
  else
    bad "tests/${s}.yml is green again" "THE MUTATIONS WERE NOT FULLY REVERTED — check git status"
    tail -5 "$WORK/out" | sed 's/^/           /'
  fi
done

echo
if [ "$fail" -gt 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) checks." >&2
  exit 1
fi
echo "PASS — $pass checks: the pinned release, checksum verification, the"
echo "loopback-only listener, the dedicated service identity, every secret"
echo "contract, no_log, the handler flush, preflight ordering, Git's"
echo "authority and the disposable harness's own safety properties are all"
echo "proved to FAIL when broken, each for its own reason."
