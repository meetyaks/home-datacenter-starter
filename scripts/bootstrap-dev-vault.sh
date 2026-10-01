#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# PUT THE GHCR PULL CREDENTIAL IN THE VAULT, WITHOUT IT TOUCHING ANYTHING ELSE.
#
#   scripts/bootstrap-dev-vault.sh
#
# Run after scripts/bootstrap-dev-controller.sh, and after you have created
# the classic personal access token it told you to create. It handles both
# cases without being told which:
#
#   no vault yet   → creates one holding just the two registry variables
#   vault exists   → ADDS or REPLACES those two, leaving everything else
#                    untouched. This is the case on a console that has been
#                    deploying for a while: its vault already holds the
#                    database passwords, the JWT keys and the master key.
#
# ⚠️ THE TOKEN IS TYPED, NEVER PASSED. Read with `read -s` from the terminal,
# so it is never in shell history, never an argument in the process table,
# and never written anywhere unencrypted beyond a 0600 temporary file that is
# removed on every exit path. Every other route leaves a copy somewhere:
#
#   echo "$TOKEN" | …        → shell history, and argv if it is ever expanded
#   ansible-vault … "$TOKEN" → the process table, readable by every local user
#
# ⚠️ THE EXISTING VAULT IS NEVER AT RISK. The rewrite goes to a temporary
# file, which is decrypted and checked BEFORE it replaces the original. A
# vault that holds the only copy of an installation's master key does not get
# modified in place and hoped over.
#
# No sudo needed if you own the vault and can read the password file.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
VAULT_FILE=${KEEL_VAULT_FILE:-$REPO_ROOT/inventory/group_vars/linux_servers/vault.yml}
VAULT_PASS=${KEEL_VAULT_PASSWORD_FILE:-/etc/keel/vault-pass}

die() { printf 'REFUSING: %s\n' "$*" >&2; exit 1; }

command -v ansible-vault >/dev/null 2>&1 || die "ansible-vault is not on PATH"
[ -r "$VAULT_PASS" ] || die "no readable vault password file at $VAULT_PASS
          Run scripts/bootstrap-dev-controller.sh first, and — if this
          console already had a vault — write your EXISTING passphrase into
          that file rather than letting anything generate one."

# ── IT MUST NOT BE COMMITTABLE ──────────────────────────────────────────────
#
# Checked before anything is written: a vault that is briefly trackable is a
# vault somebody's editor or `git add -A` can pick up.
git -C "$REPO_ROOT" check-ignore -q "$VAULT_FILE" \
  || die "$VAULT_FILE is not covered by .gitignore. Refusing to write a vault
          that git would offer to commit."

umask 077
WORK=$(mktemp -d)
# ⚠️ EVERY EXIT PATH, INCLUDING AN INTERRUPT. This directory holds the
# decrypted vault for as long as it takes to rewrite it.
trap 'rm -rf "$WORK"' EXIT INT TERM

PLAIN="$WORK/vault.yml"
MODE=create
if [ -e "$VAULT_FILE" ]; then
  MODE=update
  head -1 "$VAULT_FILE" | grep -q 'ANSIBLE_VAULT;' \
    || die "$VAULT_FILE exists but is NOT encrypted. Refusing to touch it —
          look at what it is before anything rewrites it."
  ansible-vault view --vault-password-file "$VAULT_PASS" "$VAULT_FILE" > "$PLAIN" \
    || die "the vault did not decrypt with $VAULT_PASS.
          If this console used --ask-vault-pass, that file must contain the
          SAME passphrase — not a generated one."
  printf 'Updating %s\n' "$VAULT_FILE"
  printf '  it decrypts, and holds %s variable(s) — all of them preserved\n\n' \
    "$(grep -cE '^[a-zA-Z_][a-zA-Z0-9_]*:' "$PLAIN" || echo 0)"
else
  printf 'Creating %s\n\n' "$VAULT_FILE"
  {
    echo "---"
    echo "# The GHCR pull credential for the DEV reconciler."
    echo "#"
    echo "# ⚠️ NOT COMPLETE FOR A DEPLOYMENT. The database passwords, JWT keys"
    echo "# and master key still have to be added — see vault.yml.example."
  } > "$PLAIN"
fi

printf 'GHCR pull credential. Nothing you type is echoed, kept in shell history,\n'
printf 'or passed as a command argument.\n\n'

printf '  GitHub username for ghcr.io: '
read -r REGISTRY_USERNAME
[ -n "$REGISTRY_USERNAME" ] || die "a username is required"

printf '  Classic PAT with read:packages (hidden): '
read -rs REGISTRY_TOKEN
printf '\n'
[ -n "$REGISTRY_TOKEN" ] || die "a token is required"

# ⚠️ A CHECK ON SHAPE, NOT A SUBSTITUTE FOR TRYING IT. GitHub's container
# registry accepts ONLY a classic PAT. A fine-grained token authenticates
# against the API and is then rejected by ghcr.io with a message about
# credentials that sends people looking at the wrong thing.
case "$REGISTRY_TOKEN" in
  github_pat_*)
    die "that is a fine-grained personal access token. GitHub Packages
          supports only a classic PAT for the container registry — see
          https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry" ;;
  gho_*)
    die "that is an OAuth token, probably from \`gh auth\`. An unattended
          controller must not borrow an interactive login: it is tied to a
          person, it is refreshed out from under the daemon, and it carries
          far more than read:packages." ;;
esac

# ── REPLACE THE TWO LINES, KEEP EVERYTHING ELSE ─────────────────────────────
#
# ⚠️ A REWRITE, NOT AN APPEND. Appending a second
# `keel_vault_registry_token:` would leave the file with two, and YAML takes
# the last — so re-running this to rotate the token would look like it
# worked while the behaviour depended on ordering.
grep -vE '^keel_vault_registry_(username|token):' "$PLAIN" > "$PLAIN.new" || true
{
  echo "keel_vault_registry_username: \"${REGISTRY_USERNAME}\""
  echo "keel_vault_registry_token: \"${REGISTRY_TOKEN}\""
} >> "$PLAIN.new"
mv "$PLAIN.new" "$PLAIN"
unset REGISTRY_TOKEN

# ── ENCRYPT TO A TEMPORARY FILE, CHECK IT, THEN SWAP ────────────────────────
#
# ⚠️ THE ORIGINAL IS NOT TOUCHED UNTIL THE REPLACEMENT HAS BEEN PROVED TO
# DECRYPT. Encrypting in place and discovering afterwards that it is
# unreadable would destroy a vault that may hold the only copy of the
# installation's master key.
STAGED="$WORK/vault.enc"
ansible-vault encrypt --vault-password-file "$VAULT_PASS" --output "$STAGED" "$PLAIN" >/dev/null

head -1 "$STAGED" | grep -q 'ANSIBLE_VAULT;' || die "the replacement is not encrypted — $VAULT_FILE untouched"
ansible-vault view --vault-password-file "$VAULT_PASS" "$STAGED" | grep -q '^keel_vault_registry_token:' \
  || die "the replacement does not decrypt to the expected variables — $VAULT_FILE untouched"

if [ "$MODE" = update ]; then
  # A dated copy beside the original, in case something about the rewrite is
  # wrong in a way neither check noticed. Same mode, same owner.
  BACKUP="$VAULT_FILE.backup-$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$VAULT_FILE" "$BACKUP"
  printf '  previous vault kept at %s\n' "$(basename "$BACKUP")"
fi

cat "$STAGED" > "$VAULT_FILE"
chmod 0600 "$VAULT_FILE"

# ── PROVE IT, WITHOUT PRINTING IT ───────────────────────────────────────────
ansible-vault view --vault-password-file "$VAULT_PASS" "$VAULT_FILE" | grep -q '^keel_vault_registry_token:' \
  || die "the vault in place does not decrypt as expected — restore from the backup beside it"

printf '\n  %s\n' "$VAULT_FILE"
printf '    mode        %s\n' "$MODE"
printf '    encrypted   yes\n'
printf '    variables   %s, including the two registry ones\n' \
  "$(ansible-vault view --vault-password-file "$VAULT_PASS" "$VAULT_FILE" | grep -cE '^[a-zA-Z_][a-zA-Z0-9_]*:')"
printf '    owner/mode  %s %s\n' \
  "$(stat -f '%Su' "$VAULT_FILE" 2>/dev/null || stat -c '%U' "$VAULT_FILE")" \
  "$(stat -f '%OLp' "$VAULT_FILE" 2>/dev/null || stat -c '%a' "$VAULT_FILE")"
printf '    git         ignored\n'
printf '\n  The token is only in that encrypted file. Nothing printed it.\n'
printf '  Prove it can actually read the images: tests/run-credential-proof.sh\n'
