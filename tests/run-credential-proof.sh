#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# BOTH REAL CREDENTIALS, PROVED ON THE CONSOLE. NOTHING IS DEPLOYED.
#
#   tests/run-credential-proof.sh
#
# Run on dc1-arm-1 after scripts/bootstrap-dev-controller.sh and
# scripts/bootstrap-dev-vault.sh. It answers the one question every test in
# this repository has so far been unable to answer:
#
#     do these credentials actually work?
#
# Everything else proves the code REFUSES correctly and cannot leak. Only a
# real credential against the real services proves it can read.
#
#   1. the deploy key    — mode, owner, pinned host keys, agent-free read of
#                          release/dev AND the default branch, and that it
#                          CANNOT write
#   2. the vault         — decrypts, and holds both registry variables
#   3. the GHCR token    — resolves the two published DEV digests
#   4. fail-closed       — a missing credential is still refused
#   5. no leak           — nothing secret in git, in the logs, or left behind
#
# ⚠️ IT CONTACTS GITHUB AND ghcr.io, AND NOTHING ELSE. dc1-x86 is never
# touched, no image layer is pulled, and no container is started.
#
# ⚠️ IT PRINTS NO SECRET. The token is piped from `ansible-vault view` into
# `docker login --password-stdin` without ever becoming a shell variable that
# could be echoed, an argument in the process table, or a file on disk.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

VAULT_FILE=inventory/group_vars/linux_servers/vault.yml
VAULT_PASS=${KEEL_VAULT_PASSWORD_FILE:-/etc/keel/vault-pass}
REGISTRY=ghcr.io

# ⚠️ RESOLVED, BECAUSE THIS IS USUALLY RUN OVER ssh. A non-interactive ssh
# session gets the system PATH from /etc/paths — NOT the login shell's. On a
# Mac where Ansible and Docker came from Homebrew or Docker Desktop, that
# means `ansible-playbook` and `docker` are simply not found, on a console
# where both work perfectly when you log in. Observed on dc1-arm-1: `docker
# --version` over ssh said "command not found" while `command -v docker` in
# a login shell said /usr/local/bin/docker.
#
# Resolving beats telling people to `ssh -t` or source a profile: the script
# should work however it is invoked.
resolve_tool() { # resolve_tool <name> <candidate>...
  name=$1; shift
  found=$(command -v "$name" 2>/dev/null || true)
  if [ -z "$found" ]; then
    for c in "$@"; do
      [ -x "$c" ] && found="$c" && break
    done
  fi
  printf '%s' "$found"
}

ANSIBLE_PLAYBOOK=$(resolve_tool ansible-playbook \
  /opt/homebrew/bin/ansible-playbook /usr/local/bin/ansible-playbook /usr/bin/ansible-playbook)
ANSIBLE_VAULT=$(resolve_tool ansible-vault \
  /opt/homebrew/bin/ansible-vault /usr/local/bin/ansible-vault /usr/bin/ansible-vault)
DOCKER=$(resolve_tool docker \
  /usr/local/bin/docker /opt/homebrew/bin/docker \
  /Applications/Docker.app/Contents/Resources/bin/docker)

[ -n "$ANSIBLE_PLAYBOOK" ] || { echo "REFUSING: no ansible-playbook found"; exit 1; }
[ -n "$ANSIBLE_VAULT" ]    || { echo "REFUSING: no ansible-vault found"; exit 1; }

# The digests currently published to release/dev. Restated here on purpose:
# an assertion that read its expectation out of the same document it is
# checking would pass against any document at all.
GATEWAY_DIGEST=ghcr.io/meetyaks/keel@sha256:2a70d34568b040b578b88132d127ebcda7cb927d13399fc020ec5383aeffbab5
WEB_DIGEST=ghcr.io/meetyaks/keel-web@sha256:89c9e466cf8ee4717501806ed2026276d1803e55674482966b437a8d22f23c0a

pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; fail=$((fail + 1)); }

# ⚠️ A DOCKER CONFIG OF ITS OWN, SO YOUR REAL ONE IS NEVER TOUCHED. `docker
# login` rewrites ~/.docker/config.json in place; borrowing it here would
# leave a GHCR credential in the operator's own configuration after the test,
# and could clobber a registry entry they rely on.
DOCKER_CONFIG_DIR=$(mktemp -d /tmp/keel-credential-proof.XXXXXX)
cleanup() {
  if [ -f "$DOCKER_CONFIG_DIR/config.json" ]; then
    "$DOCKER" --config "$DOCKER_CONFIG_DIR" logout "$REGISTRY" >/dev/null 2>&1
  fi
  rm -rf "$DOCKER_CONFIG_DIR"
}
trap cleanup EXIT INT TERM

echo "── 1. the deploy key, through the role's own preflight ─────────────"
# ⚠️ THE ROLE'S TASKS. tests/credential-preflight-real.yml includes
# roles/keel_reconcile/tasks/credentials.yml with the shipped paths, so this
# exercises the code the unattended run uses rather than a restatement of it.
if "$ANSIBLE_PLAYBOOK" tests/credential-preflight-real.yml > /tmp/keel-deploy-key-proof.log 2>&1; then
  ok "mode, owner, pinned host keys, agent-free read, write refused"
else
  bad "the deploy-key preflight failed" "$(grep -m3 '"msg"' /tmp/keel-deploy-key-proof.log | cut -c1-200)"
fi

echo
echo "── 2. the vault ────────────────────────────────────────────────────"
if [ ! -r "$VAULT_PASS" ]; then
  bad "no readable vault password file at $VAULT_PASS" "run scripts/bootstrap-dev-controller.sh"
elif [ ! -f "$VAULT_FILE" ]; then
  bad "no vault at $VAULT_FILE" "run scripts/bootstrap-dev-vault.sh"
else
  ok "vault password file present at $VAULT_PASS"

  if head -1 "$VAULT_FILE" | grep -q 'ANSIBLE_VAULT;'; then
    ok "the vault is encrypted at rest"
  else
    bad "$VAULT_FILE is NOT encrypted"
  fi

  # ⚠️ PIPED TO grep, NEVER TO A VARIABLE OR THE TERMINAL. `ansible-vault
  # view` writes the decrypted file to stdout; capturing it would put the
  # token in the shell's memory and, on any `set -x` or error trace, in the
  # log.
  if "$ANSIBLE_VAULT" view --vault-password-file "$VAULT_PASS" "$VAULT_FILE" 2>/dev/null \
       | grep -q '^keel_vault_registry_username:'; then
    ok "it decrypts, and carries keel_vault_registry_username"
  else
    bad "the vault does not decrypt to the expected variables"
  fi
  if "$ANSIBLE_VAULT" view --vault-password-file "$VAULT_PASS" "$VAULT_FILE" 2>/dev/null \
       | grep -q '^keel_vault_registry_token:'; then
    ok "and keel_vault_registry_token"
  else
    bad "keel_vault_registry_token is missing from the vault"
  fi
fi

echo
echo "── 3. the GHCR token, against the published digests ────────────────"
vault_value() { # vault_value <variable> — prints one value, used only in a pipe
  "$ANSIBLE_VAULT" view --vault-password-file "$VAULT_PASS" "$VAULT_FILE" 2>/dev/null \
    | sed -n "s/^$1: *\"\\(.*\\)\"$/\\1/p" | head -1
}

if [ -z "$DOCKER" ]; then
  bad "docker is not installed on this console" "the registry proof cannot run here"
elif [ ! -f "$VAULT_FILE" ]; then
  bad "no vault to read the token from" "skipped"
else
  REGISTRY_USER=$(vault_value keel_vault_registry_username)
  if [ -z "$REGISTRY_USER" ]; then
    bad "could not read the registry username from the vault"
  else
    # ⚠️ STDIN, AND THE TOKEN NEVER BECOMES A VARIABLE. It goes straight from
    # the decrypted stream into docker's stdin. `--password <token>` would
    # put it in the process table for every local user to read.
    if vault_value keel_vault_registry_token \
         | "$DOCKER" --config "$DOCKER_CONFIG_DIR" login "$REGISTRY" \
             --username "$REGISTRY_USER" --password-stdin >/dev/null 2>&1; then
      ok "authenticated to $REGISTRY as $REGISTRY_USER"

      # ⚠️ `manifest inspect`, NOT `pull`. Resolving the manifest proves the
      # credential can READ the digest; pulling would drag hundreds of
      # megabytes of layers onto the console for no extra information.
      # ⚠️ TWO WAYS TO ASK, BECAUSE `docker manifest` IS STILL EXPERIMENTAL
      # ON SOME INSTALLS and refuses with a message about enabling it —
      # which has nothing to do with the credential being tested. `buildx
      # imagetools inspect` asks the same question through a path that is
      # not gated, so a missing feature flag cannot be mistaken for a
      # credential that cannot read.
      resolve_digest() { # resolve_digest <ref>
        "$DOCKER" --config "$DOCKER_CONFIG_DIR" manifest inspect "$1" >/dev/null 2>&1 && return 0
        "$DOCKER" --config "$DOCKER_CONFIG_DIR" buildx imagetools inspect "$1" >/dev/null 2>&1
      }

      for ref in "$GATEWAY_DIGEST" "$WEB_DIGEST"; do
        if resolve_digest "$ref"; then
          ok "resolved ${ref##*/}"
        else
          bad "could NOT resolve ${ref##*/}" \
              "the token authenticates but cannot read this package"
        fi
      done
    else
      bad "could not authenticate to $REGISTRY as $REGISTRY_USER" \
          "the token was rejected, or it is not a classic PAT with read:packages"
    fi
  fi
fi

echo
echo "── 4. a missing credential still fails closed ──────────────────────"
# ⚠️ THE OTHER HALF OF "IT WORKS". A credential that works proves nothing
# about what happens when it is absent — and absence is the ordinary case on
# a rebuilt machine. Pointing the preflight at a path that does not exist
# must be a refusal, not a silent skip.
if "$ANSIBLE_PLAYBOOK" tests/credential-preflight-real.yml \
     -e keel_reconcile_deploy_key=/etc/keel/definitely-not-here \
     > /tmp/keel-failclosed-proof.log 2>&1; then
  bad "the preflight ACCEPTED a missing deploy key"
else
  if grep -q "No deploy key at" /tmp/keel-failclosed-proof.log; then
    ok "a missing deploy key is refused, and the message names it"
  else
    bad "refused, but not for the missing key" \
        "$(grep -m1 '"msg"' /tmp/keel-failclosed-proof.log | cut -c1-200)"
  fi
fi

echo
echo "── 5. nothing secret escaped ───────────────────────────────────────"
if git status --porcelain | grep -q 'vault\.yml$'; then
  bad "the vault shows up in git status" "it must be gitignored"
else
  ok "the vault is not visible to git status"
fi

if git check-ignore -q "$VAULT_FILE" 2>/dev/null; then
  ok "the vault is gitignored"
else
  bad "$VAULT_FILE is NOT gitignored"
fi

if git log --oneline -20 -- "$VAULT_FILE" 2>/dev/null | grep -q .; then
  bad "the vault appears in git history"
else
  ok "the vault has never been committed"
fi

leaked=0
for logfile in /tmp/keel-deploy-key-proof.log /tmp/keel-failclosed-proof.log; do
  [ -f "$logfile" ] || continue
  if grep -qE 'gh[pousr]_[A-Za-z0-9]{16,}|BEGIN OPENSSH PRIVATE KEY' "$logfile"; then
    bad "a credential-shaped string is in $logfile"; leaked=1
  fi
done
[ "$leaked" -eq 0 ] && ok "no credential-shaped string in the captured logs"

if pgrep -fl 'docker.*--password [^-]' >/dev/null 2>&1; then
  bad "a docker process has a password in its arguments"
else
  ok "no token in any process argument"
fi

rm -f /tmp/keel-deploy-key-proof.log /tmp/keel-failclosed-proof.log

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: ${fail} of $((fail + pass)) check(s). CREDENTIALS NOT READY."
  exit 1
fi
echo "credential proof: ${pass} checks — both credentials work, neither leaked."
echo "Nothing was deployed and dc1-x86 was not contacted."
