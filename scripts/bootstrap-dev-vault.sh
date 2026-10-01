#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# PUT THE GHCR PULL CREDENTIAL IN THE VAULT, WITHOUT IT TOUCHING ANYTHING ELSE.
#
#   sudo scripts/bootstrap-dev-vault.sh
#
# Run after scripts/bootstrap-dev-controller.sh, and after you have created
# the classic personal access token it told you to create.
#
# ⚠️ THE TOKEN IS TYPED, NEVER PASSED. It is read with `read -s` from the
# terminal, so it never appears in your shell history, never becomes an
# argument in the process table, and is never written anywhere unencrypted.
# Every other way of getting a secret into a file leaves a copy somewhere:
#
#   echo "$TOKEN" | …        → shell history, and argv if it is ever expanded
#   ansible-vault … "$TOKEN" → the process table, readable by every local user
#   a temporary plaintext    → still on the disk after `rm`, and in Time Machine
#
# ⚠️ IT WRITES ONLY THE TWO REGISTRY VARIABLES. The deployment vault needs
# more than this — database passwords, JWT keys, the master key — and those
# belong to the deployment, not to the reconciler's credential. If the vault
# already exists this script REFUSES rather than overwriting it, because
# clobbering a vault that holds the only copy of a key is not recoverable.
#
# macOS or Linux; it only needs ansible-vault and a terminal.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
VAULT_FILE="$REPO_ROOT/inventory/group_vars/linux_servers/vault.yml"
VAULT_PASS=${KEEL_VAULT_PASSWORD_FILE:-/etc/keel/vault-pass}
SERVICE_USER=${KEEL_SERVICE_USER:-keeladmin}

die() { printf 'REFUSING: %s\n' "$*" >&2; exit 1; }

command -v ansible-vault >/dev/null 2>&1 || die "ansible-vault is not on PATH"
[ -r "$VAULT_PASS" ] || die "no readable vault password file at $VAULT_PASS — run scripts/bootstrap-dev-controller.sh first"

# ⚠️ NEVER OVERWRITE AN EXISTING VAULT. It may hold the only copy of the
# installation's master key and JWT private key; a fresh file in its place
# would be unrecoverable and the loss would not be noticed until a deployment.
if [ -e "$VAULT_FILE" ]; then
  die "$VAULT_FILE already exists.
          To ADD or CHANGE the registry credential in it, edit it in place —
          the token is typed into your editor and never leaves it:

            sudo ansible-vault edit --vault-password-file $VAULT_PASS \\
              $VAULT_FILE"
fi

# ── IT MUST NOT BE COMMITTABLE ──────────────────────────────────────────────
#
# Checked before the file is created, not after: a vault that is briefly
# trackable is a vault somebody's editor or `git add -A` can pick up.
if ! git -C "$REPO_ROOT" check-ignore -q "$VAULT_FILE"; then
  die "$VAULT_FILE is not covered by .gitignore. Refusing to create a vault
          that git would offer to commit."
fi

printf 'Creating %s\n\n' "$VAULT_FILE"
printf 'GHCR pull credential. Nothing you type here is echoed, stored in shell\n'
printf 'history, or passed as a command argument.\n\n'

# The GitHub account the token belongs to. Not secret, but prompted rather
# than guessed so the vault records who the credential actually is.
printf '  GitHub username for ghcr.io: '
read -r REGISTRY_USERNAME
[ -n "$REGISTRY_USERNAME" ] || die "a username is required"

printf '  Classic PAT with read:packages (hidden): '
read -rs REGISTRY_TOKEN
printf '\n'
[ -n "$REGISTRY_TOKEN" ] || die "a token is required"

# ⚠️ A SANITY CHECK ON SHAPE, NOT A SUBSTITUTE FOR TRYING IT. GitHub's
# container registry accepts ONLY a classic PAT; a fine-grained token
# (`github_pat_…`) authenticates against the API and is then rejected by
# ghcr.io with a message about credentials that sends people looking at the
# wrong thing. Catching it here costs nothing.
case "$REGISTRY_TOKEN" in
  github_pat_*)
    die "that is a fine-grained personal access token. GitHub Packages
          supports only a classic PAT for the container registry — see
          https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry" ;;
  gho_*)
    die "that is an OAuth token, probably from \`gh auth\`. The unattended
          controller must not borrow an interactive login: it is tied to a
          person, it is refreshed out from under the daemon, and it carries
          far more than read:packages." ;;
esac

umask 077
STAGED=$(mktemp)
# ⚠️ REMOVED ON EVERY EXIT PATH, INCLUDING AN INTERRUPT. This file holds the
# token in the clear for the few milliseconds before it is encrypted.
trap 'rm -f "$STAGED"' EXIT INT TERM

{
  echo "---"
  echo "# The GHCR pull credential for the DEV reconciler."
  echo "#"
  echo "# Created by scripts/bootstrap-dev-vault.sh. Read by"
  echo "# roles/keel/tasks/registry.yml, which feeds the token to"
  echo "# \`docker login --password-stdin\` under no_log and logs out again in"
  echo "# an always block."
  echo "#"
  echo "# This vault is NOT complete for a deployment: the database passwords,"
  echo "# JWT keys and master key still have to be added. See"
  echo "# vault.yml.example for the full set."
  echo "keel_vault_registry_username: \"${REGISTRY_USERNAME}\""
  echo "keel_vault_registry_token: \"${REGISTRY_TOKEN}\""
} > "$STAGED"

unset REGISTRY_TOKEN

ansible-vault encrypt --vault-password-file "$VAULT_PASS" \
  --output "$VAULT_FILE" "$STAGED" >/dev/null
rm -f "$STAGED"

# The vault belongs to the account that will read it, like its password file.
if id "$SERVICE_USER" >/dev/null 2>&1 && [ "$(id -u)" -eq 0 ]; then
  chown "$SERVICE_USER" "$VAULT_FILE"
fi
chmod 0600 "$VAULT_FILE"

# ── PROVE IT, WITHOUT PRINTING IT ───────────────────────────────────────────
head -1 "$VAULT_FILE" | grep -q '^\$ANSIBLE_VAULT;' \
  || die "the file was written but is not encrypted — delete $VAULT_FILE and investigate"

ansible-vault view --vault-password-file "$VAULT_PASS" "$VAULT_FILE" \
  | grep -q '^keel_vault_registry_token:' \
  || die "the vault does not decrypt to the expected variables"

printf '\n  %s\n' "$VAULT_FILE"
printf '    encrypted   yes (\$ANSIBLE_VAULT header)\n'
printf '    decrypts    yes, to keel_vault_registry_username and _token\n'
printf '    owner/mode  %s %s\n' \
  "$(stat -f '%Su' "$VAULT_FILE" 2>/dev/null || stat -c '%U' "$VAULT_FILE")" \
  "$(stat -f '%OLp' "$VAULT_FILE" 2>/dev/null || stat -c '%a' "$VAULT_FILE")"
printf '    git         ignored\n'
printf '\n  The token is now only in this encrypted file. Nothing printed it.\n'
printf '  Verify it can actually pull: tests/run-registry-credential-proof.sh\n'
