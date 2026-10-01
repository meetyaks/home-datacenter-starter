#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# EVERYTHING THE DEV CONTROLLER NEEDS BEFORE IT CAN RECONCILE, ON A NEW MAC.
#
#   sudo scripts/bootstrap-dev-controller.sh
#   sudo scripts/bootstrap-dev-controller.sh --check     # report, change nothing
#
# ⚠️ WHY THIS IS A SCRIPT AND NOT A LIST IN A DOCUMENT. The controller's
# prerequisites are a service account, four files with exact owners and modes,
# and a host-key pin taken from an authoritative source. Written as prose they
# get done slightly differently on every machine — and the differences are
# invisible until an unattended run fails at 3am as the wrong user, or trusts
# a host key somebody accepted once. Written as a script they are the same
# every time, and the drift shows up as a diff.
#
# ⚠️ IDEMPOTENT, AND IT NEVER REPLACES A SECRET IT DID NOT JUST CREATE. Run it
# twice and the second run reports "already present" for everything. It will
# not regenerate a deploy key that exists — that would silently invalidate the
# key registered on GitHub and break the reconciler until somebody noticed.
#
# ⚠️ IT PRINTS NO SECRET, EVER. The private key and the vault password are
# written straight to their final paths with their final modes. The public key
# and its fingerprint ARE printed, because the operator has to carry them to
# GitHub.
#
# ⚠️ WHAT IT DELIBERATELY DOES NOT DO:
#   · create the GHCR token — GitHub has no API to mint a classic PAT, so that
#     stays a human step in the UI (see the closing report)
#   · add the deploy key to GitHub — a separate, revocable decision
#   · install or load the launchd plist
#   · touch dc1-x86, DNS, or anything outside this machine
#
# macOS only. It refuses elsewhere rather than half-applying: a Linux
# controller needs useradd, a different home convention and systemd, and a
# script that guesses at those is worse than one that says it has not been
# written yet.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# ── THE CONTRACT. These are read from, not invented here. ───────────────────
#
# Every path and mode below is the one roles/keel_reconcile/defaults/main.yml,
# the launchd plist and docs/keel-dev-reconcile.md already declare. Changing
# one here without changing it there is the drift this script exists to stop,
# so tests/controller-bootstrap.yml checks they still agree.
KEEL_ETC=/etc/keel
DEPLOY_KEY="$KEEL_ETC/keel-deploy-key"
KNOWN_HOSTS="$KEEL_ETC/known_hosts"
VAULT_PASS="$KEEL_ETC/vault-pass"
RECONCILE_CONF="$KEEL_ETC/reconcile.conf"
LOG_DIR=/var/log/keel

# ⚠️ THE CHECKOUT IS WHERE THIS SCRIPT LIVES, NOT A CONSTANT. This file is at
# <checkout>/scripts/bootstrap-dev-controller.sh, so the checkout is two
# levels up — correct on every console, whatever its layout. An earlier
# version hardcoded `/opt/home-datacenter-starter`, a path that was invented
# rather than observed; the real console keeps its checkout in an operator's
# home, so the daemon would have been pointed at nothing.
CHECKOUT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
PLIST_TEMPLATE="$CHECKOUT/roles/keel_reconcile/files/launchd/com.meetyaks.keel-reconcile-dev.plist.template"
PLIST_RENDERED="$KEEL_ETC/com.meetyaks.keel-reconcile-dev.plist"

# ⚠️ WHO THE DAEMON RUNS AS, AND WHY IT IS A CHOICE. PR #5 argues for a
# dedicated account: a deployment must not depend on a person's login session,
# keychain or shell. But a console that has been in use for a while already
# has an operator account with the checkouts in its home, and bolting a
# hidden second account onto it is a change to how that machine works —
# somebody's decision, not this script's.
#
#   KEEL_SERVICE_USER=<name>   provision for an account that already exists
#   KEEL_SERVICE_USER=<new>    plus KEEL_CREATE_SERVICE_USER=1 to create it
#
# The default is the account that owns the checkout, which is the account a
# manual run already happens as — so the credentials this provisions are
# usable immediately, and the move to a dedicated account is a later,
# deliberate step rather than a precondition.
SERVICE_USER=${KEEL_SERVICE_USER:-$(stat -f '%Su' "$CHECKOUT" 2>/dev/null || stat -c '%U' "$CHECKOUT")}
SERVICE_GROUP=${KEEL_SERVICE_GROUP:-staff}
SERVICE_REALNAME="Keel DEV reconciler"
CREATE_SERVICE_USER=${KEEL_CREATE_SERVICE_USER:-0}
SERVICE_HOME=${KEEL_SERVICE_HOME:-/var/keel}

# Set when an existing vault means the password file must be written by a
# person rather than generated. Reported again at the end, because a step
# left undone halfway up a long output is a step nobody notices.
VAULT_PASS_DEFERRED=0

# A name that says which machine and which job, so a deploy key list stays
# readable and a compromised host is revocable by name.
KEY_COMMENT="keel-dev-release-reader-$(hostname -s)"

say()  { printf '  %s\n' "$*"; }
head2() { printf '\n── %s %s\n' "$*" "$(printf '─%.0s' $(seq 1 $((66 - ${#1}))))"; }
die()  { printf 'REFUSING: %s\n' "$*" >&2; exit 1; }
act()  { [ "$CHECK_ONLY" -eq 0 ]; }

[ "$(uname -s)" = "Darwin" ] || die "this bootstraps a macOS controller; this is $(uname -s). The Linux variant is not written."

# ⚠️ ROOT ONLY WHEN IT WILL ACTUALLY CHANGE SOMETHING. `--check` reads state
# and writes nothing, so demanding sudo for it would mean the only way to see
# what this script intends is to give it the privilege to do it — which is
# backwards for a script whose whole job is creating accounts and secrets.
if act && [ "$(id -u)" -ne 0 ]; then
  die "run with sudo — it creates a service account and writes under /etc.
          To see what it WOULD do without granting that, run:
            scripts/bootstrap-dev-controller.sh --check"
fi

printf 'Keel DEV controller bootstrap on %s%s\n' "$(hostname -s)" \
  "$([ "$CHECK_ONLY" -eq 1 ] && echo '  (--check: reporting only)')"

# ── 1. THE SERVICE ACCOUNT ──────────────────────────────────────────────────
#
# ⚠️ NOT root AND NOT A PERSON. A deployment that runs as somebody's account
# depends on their login session, their keychain and their shell — and stops
# working the day they are on holiday or their password expires. It is hidden,
# has no password and has /usr/bin/false as its shell, so it cannot log in.
head2 "service account"
if id "$SERVICE_USER" >/dev/null 2>&1; then
  say "$SERVICE_USER already exists (uid $(id -u "$SERVICE_USER")) — using it, creating nothing"
elif [ "$CREATE_SERVICE_USER" != "1" ]; then
  # ⚠️ IT WILL NOT CREATE AN ACCOUNT BY ACCIDENT. A hidden system account is
  # a change to how the machine works — and on a managed device it is a
  # change somebody else may have opinions about. Asking for it explicitly
  # costs one environment variable; doing it silently costs a conversation
  # with whoever runs the fleet.
  die "no account named \"$SERVICE_USER\" exists.
          Either name one that does:
            sudo KEEL_SERVICE_USER=<existing> $0
          or ask for it to be created:
            sudo KEEL_SERVICE_USER=$SERVICE_USER KEEL_CREATE_SERVICE_USER=1 $0"
else
  if act; then
    # Lowest free uid in the service range, so it stays out of the way of
    # real accounts and off the login window.
    uid=450
    while dscl . -list /Users UniqueID | awk '{print $2}' | grep -qx "$uid"; do
      uid=$((uid + 1))
      [ "$uid" -lt 500 ] || die "no free service uid below 500"
    done
    dscl . -create "/Users/$SERVICE_USER"
    dscl . -create "/Users/$SERVICE_USER" RealName "$SERVICE_REALNAME"
    dscl . -create "/Users/$SERVICE_USER" UniqueID "$uid"
    dscl . -create "/Users/$SERVICE_USER" PrimaryGroupID 20
    dscl . -create "/Users/$SERVICE_USER" UserShell /usr/bin/false
    dscl . -create "/Users/$SERVICE_USER" NFSHomeDirectory "$SERVICE_HOME"
    dscl . -create "/Users/$SERVICE_USER" IsHidden 1
    # No password is set, deliberately: there is nothing to guess and nothing
    # to rotate. The account is reachable only as root, via `sudo -u`.
    say "created $SERVICE_USER (uid $uid, hidden, no password, shell /usr/bin/false)"
  else
    say "WOULD create $SERVICE_USER"
  fi
fi

# ⚠️ ONLY FOR AN ACCOUNT THIS SCRIPT JUST CREATED. An account that already
# exists has a home already, and reaching into somebody's home directory to
# re-mode it is not this script's business.
if act && [ "$CREATE_SERVICE_USER" = "1" ]; then
  install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0700 "$SERVICE_HOME"
  install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0700 "$SERVICE_HOME/.ssh"
  say "home $SERVICE_HOME (0700) and $SERVICE_HOME/.ssh (0700)"
fi

# ── 2. THE DIRECTORIES ──────────────────────────────────────────────────────
head2 "directories"
if act; then
  install -d -o root -g wheel -m 0755 "$KEEL_ETC"
  install -d -o "$SERVICE_USER" -g "$SERVICE_GROUP" -m 0750 "$LOG_DIR"
  say "$KEEL_ETC (root, 0755)"
  say "$LOG_DIR ($SERVICE_USER, 0750)"
else
  say "WOULD ensure $KEEL_ETC (root 0755) and $LOG_DIR ($SERVICE_USER 0750)"
fi
if [ -d "$CHECKOUT" ]; then
  say "$CHECKOUT present"
else
  say "$CHECKOUT ABSENT — clone the deployment repository there before the first run"
fi

# ── 3. THE DEPLOY KEY ───────────────────────────────────────────────────────
#
# ⚠️ ed25519, AND DEDICATED TO THIS MACHINE AND THIS JOB. Not the operator's
# key, not the dc1-x86 key: a credential shared between two purposes cannot be
# revoked for one of them. The comment names the host so a deploy-key list
# stays readable and a rebuilt machine is revocable by name.
head2 "deploy key"
if [ -f "$DEPLOY_KEY" ]; then
  # ⚠️ NEVER REGENERATED. Overwriting would silently invalidate the public key
  # registered on GitHub, and the reconciler would start failing authentication
  # with no obvious cause. Replacing a key is a deliberate act: remove this
  # file and the GitHub deploy key together, then re-run.
  say "already present — NOT regenerated (remove it and its GitHub deploy key to rotate)"
elif act; then
  ssh-keygen -t ed25519 -N '' -C "$KEY_COMMENT" -f "$DEPLOY_KEY" -q
  say "generated $DEPLOY_KEY"
else
  say "WOULD generate $DEPLOY_KEY"
fi

if act && [ -f "$DEPLOY_KEY" ]; then
  # 0400: readable by the service account and nobody else. ssh refuses a
  # group- or world-readable key anyway, but it refuses at the point of use,
  # with a message that reads like a local permissions problem.
  chown "$SERVICE_USER:$SERVICE_GROUP" "$DEPLOY_KEY" "$DEPLOY_KEY.pub"
  chmod 0400 "$DEPLOY_KEY"
  chmod 0644 "$DEPLOY_KEY.pub"
  say "owner $SERVICE_USER, private 0400, public 0644"
fi

# ── 4. THE HOST-KEY PIN ─────────────────────────────────────────────────────
#
# ⚠️ FROM GitHub's PUBLISHED KEYS, AND CROSS-CHECKED AGAINST ITS PUBLISHED
# FINGERPRINTS. `ssh-keyscan` pins whatever answers on port 22, which is
# precisely the thing being guarded against — it would happily record an
# interceptor. api.github.com/meta is served over TLS with a validated
# certificate chain and carries both the keys and their fingerprints, so the
# two are compared here before anything is written.
head2 "github host-key pin"
if [ -f "$KNOWN_HOSTS" ] && grep -q '^github\.com ' "$KNOWN_HOSTS" 2>/dev/null; then
  say "already pinned at $KNOWN_HOSTS"
elif act; then
  meta=$(mktemp); trap 'rm -f "$meta"' EXIT
  curl -fsS --proto '=https' --tlsv1.2 \
    -H 'Accept: application/vnd.github+json' \
    https://api.github.com/meta -o "$meta" \
    || die "could not fetch https://api.github.com/meta — refusing to fall back to ssh-keyscan"

  staged=$(mktemp)
  # Recomputes each key's fingerprint and compares it with the one GitHub
  # publishes beside it. A mismatch writes nothing and exits non-zero.
  "$(dirname "$0")/lib/github-known-hosts.py" "$meta" "$staged" \
    || die "GitHub's served host keys did not match its published fingerprints — nothing was pinned"
  install -o root -g wheel -m 0444 "$staged" "$KNOWN_HOSTS"
  rm -f "$staged"
  say "pinned $KNOWN_HOSTS (root, 0444)"
else
  say "WOULD pin $KNOWN_HOSTS from api.github.com/meta"
fi

# ── 5. THE VAULT PASSWORD ───────────────────────────────────────────────────
#
# Generated here rather than chosen by a person: it is never typed, so it may
# as well be long and random. It is written straight to its final path at 0400
# and is not printed, logged, or passed as an argument.
#
# ⚠️ BUT ONLY FOR A VAULT THAT DOES NOT EXIST YET. This console has been an
# Ansible control node for a while and its vault is decrypted with a
# passphrase a person types (`--ask-vault-pass`). Generating a fresh random
# password here would produce a file that does not open that vault — and the
# failure arrives later, as "Decryption failed", pointing at the vault rather
# than at the password file that was quietly wrong. So: if a vault is already
# there, this refuses and asks for the existing passphrase instead.
head2 "vault password"
if [ -f "$VAULT_PASS" ]; then
  say "already present — NOT regenerated (it would orphan the encrypted vault)"
elif [ -f "$CHECKOUT/inventory/group_vars/linux_servers/vault.yml" ]; then
  say "an encrypted vault ALREADY EXISTS at"
  say "  $CHECKOUT/inventory/group_vars/linux_servers/vault.yml"
  say ""
  say "Not generating a password: a new random one would not open it, and the"
  say "failure would surface later as \"Decryption failed\". Write the EXISTING"
  say "passphrase into the file yourself — typed, never echoed, never in"
  say "shell history:"
  say ""
  say "  sudo install -o $SERVICE_USER -m 0400 /dev/null $VAULT_PASS"
  say "  sudo sh -c 'stty -echo; printf \"vault passphrase: \"; head -1 > $VAULT_PASS; stty echo; echo'"
  say ""
  say "Then check it opens the vault, which prints nothing on success:"
  say "  ansible-vault view --vault-password-file $VAULT_PASS \\"
  say "    $CHECKOUT/inventory/group_vars/linux_servers/vault.yml > /dev/null && echo OK"
  VAULT_PASS_DEFERRED=1
elif act; then
  umask 077
  LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 64 > "$VAULT_PASS"
  printf '\n' >> "$VAULT_PASS"
  chown "$SERVICE_USER:$SERVICE_GROUP" "$VAULT_PASS"
  chmod 0400 "$VAULT_PASS"
  say "generated $VAULT_PASS ($SERVICE_USER, 0400) — value not shown and not logged"
else
  say "WOULD generate $VAULT_PASS"
fi

# ── 6. THE WRAPPER'S CONFIGURATION ──────────────────────────────────────────
#
# ⚠️ PATHS ONLY. No token, no passphrase. bin/keel-reconcile-dev sources this,
# so a value here would end up in a world-readable file for no reason — every
# secret reaches Ansible through the vault instead.
head2 "wrapper configuration"
if [ -f "$RECONCILE_CONF" ]; then
  say "already present at $RECONCILE_CONF — left alone"
elif act; then
  staged=$(mktemp)
  {
    echo "# Written by scripts/bootstrap-dev-controller.sh. PATHS ONLY —"
    echo "# never a token, never a passphrase: this file is world-readable."
    echo "KEEL_CHECKOUT=$CHECKOUT"
    echo "KEEL_VAULT_PASSWORD_FILE=$VAULT_PASS"
    echo "KEEL_ANSIBLE_PLAYBOOK=$(command -v ansible-playbook || echo /usr/local/bin/ansible-playbook)"
    echo "KEEL_RECONCILE_LOG=$LOG_DIR/reconcile-dev.log"
  } > "$staged"
  install -o root -g wheel -m 0644 "$staged" "$RECONCILE_CONF"
  rm -f "$staged"
  say "wrote $RECONCILE_CONF (root, 0644)"
else
  say "WOULD write $RECONCILE_CONF"
fi

# ── 7. THE launchd JOB, RENDERED BUT NOT LOADED ─────────────────────────────
#
# ⚠️ RENDERED HERE AND LEFT IN /etc/keel, NOT INSTALLED INTO
# /Library/LaunchDaemons. Rendering it is safe and makes the real paths
# reviewable; loading it starts a deployment schedule, which is a decision
# that comes after a watched manual run has succeeded. The operator copies it
# across when they are ready, and the copy is one command they can read.
head2 "launchd job"
if [ ! -r "$PLIST_TEMPLATE" ]; then
  say "template missing at $PLIST_TEMPLATE — skipped"
elif act; then
  staged=$(mktemp)
  sed -e "s|@@CHECKOUT@@|$CHECKOUT|g" \
      -e "s|@@SERVICE_USER@@|$SERVICE_USER|g" \
      -e "s|@@LOG_DIR@@|$LOG_DIR|g" \
      "$PLIST_TEMPLATE" > "$staged"

  # ⚠️ NO PLACEHOLDER MAY SURVIVE. A plist still containing `@@CHECKOUT@@`
  # loads happily and then fails to execute, with launchd reporting status
  # 127 and nothing saying why.
  if grep -q '@@[A-Z_]*@@' "$staged"; then
    rm -f "$staged"
    die "the rendered plist still contains placeholders: $(grep -o '@@[A-Z_]*@@' "$staged" | sort -u | tr '\n' ' ')"
  fi
  # And it must be a valid property list before it is offered to anybody.
  plutil -lint "$staged" >/dev/null || { rm -f "$staged"; die "the rendered plist is not a valid property list"; }

  install -o root -g wheel -m 0644 "$staged" "$PLIST_RENDERED"
  rm -f "$staged"
  say "rendered $PLIST_RENDERED (root, 0644) — NOT loaded"
  say "  checkout $CHECKOUT"
  say "  runs as  $SERVICE_USER"
else
  say "WOULD render $PLIST_RENDERED from the template (checkout $CHECKOUT, user $SERVICE_USER)"
fi

# ── WHAT A PERSON STILL HAS TO DO ───────────────────────────────────────────
head2 "what this script cannot do"
if [ "$VAULT_PASS_DEFERRED" = "1" ]; then
  printf '\n0. ⚠️ THE VAULT PASSWORD FILE IS STILL MISSING. See the vault-password\n'
  printf '   section above — this console already has an encrypted vault, so the\n'
  printf '   passphrase has to be the existing one, not a generated one. Nothing\n'
  printf '   below will work until %s exists.\n' "$VAULT_PASS"
fi
if [ -f "$DEPLOY_KEY.pub" ]; then
  printf '\n1. Add this as a READ-ONLY deploy key on meetyaks/keel\n'
  printf '   https://github.com/meetyaks/keel/settings/keys/new  — leave "Allow write access" UNCHECKED\n\n'
  sed 's/^/     /' "$DEPLOY_KEY.pub"
  printf '\n     fingerprint %s\n' "$(ssh-keygen -lf "$DEPLOY_KEY.pub" | awk '{print $2}')"
  printf '\n   Or, with a gh login that has admin on the repository:\n'
  printf '     gh api -X POST repos/meetyaks/keel/keys -f title=%s -F read_only=true \\\n' "$KEY_COMMENT"
  printf '       -f key="$(cat %s)"\n' "$DEPLOY_KEY.pub"
fi
cat <<'MANUAL'

2. Create the GHCR pull credential. GitHub has no API to mint one, so this is
   a UI step. GitHub Packages supports ONLY a classic personal access token
   for the container registry — a fine-grained token will not authenticate.

   https://github.com/settings/tokens/new?scopes=read:packages&description=keel-dev-ghcr-pull

     scopes       read:packages  — AND NOTHING ELSE
                  (not write:packages, not repo, not delete:packages)
     owner        the account that can see ghcr.io/meetyaks/keel and keel-web
     expiry       set one, and put the date in the runbook

   Then store it in the vault, which never leaves this machine unencrypted:

     sudo scripts/bootstrap-dev-vault.sh

3. Nothing here loads the launchd plist, and nothing here touches dc1-x86.
   The first deployment is MANUAL and WATCHED. Only once it has succeeded:

     sudo cp /etc/keel/com.meetyaks.keel-reconcile-dev.plist /Library/LaunchDaemons/
     sudo launchctl bootstrap system /Library/LaunchDaemons/com.meetyaks.keel-reconcile-dev.plist
MANUAL

printf '\nBootstrap %s.\n' "$([ "$CHECK_ONLY" -eq 1 ] && echo 'check complete — nothing was changed' || echo 'complete')"
