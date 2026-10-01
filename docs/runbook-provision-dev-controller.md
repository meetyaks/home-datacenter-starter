# Provisioning the DEV controller on `dc1-arm-1`

Everything the unattended reconciler needs, in order, on the administration console. **Nothing here deploys Keel**, loads the launchd daemon, or touches `dc1-x86`.

> **Where:** `dc1-arm-1`, the Ansible control node — the machine [`roles/keel/README.md`](../roles/keel/README.md) means by *"Run from `~/Projects/home-datacenter-starter` on dc1-arm-1"*.
>
> **Not** on `dc1-x86` (a host that decided what to run could decide wrongly), **not** on a CI runner, and **not** on a laptop. A fifteen-minute reconciler on a machine that sleeps mostly does not run, and when that machine is reimaged DEV stops reconciling with nothing to say why.

**Time:** about 15 minutes, most of it waiting for you to click through GitHub.

---

## 0. Before you start

You need, on `dc1-arm-1`:

- `git`, `ansible` (with `ansible-vault`), `docker`, `curl`, `python3` — all but docker ship with the usual toolchain
- admin on `meetyaks/keel` (to add a deploy key)
- `sudo`

Check the first group in one go:

```bash
for c in git ansible-playbook ansible-vault docker curl python3 ssh-keygen; do
  printf '%-18s %s\n' "$c" "$(command -v "$c" || echo 'MISSING')"
done
```

---

## 1. Get the checkout onto the console

```bash
mkdir -p ~/Projects && cd ~/Projects
git clone git@github.com:meetyaks/home-datacenter-starter.git   # or: cd home-datacenter-starter && git fetch
cd home-datacenter-starter
git checkout feat/keel-dev-auto-reconcile
git log --oneline -1
```

> The scripts work out the checkout path from **their own location**, so it does not matter whether this is `~/Projects/…` or anywhere else. Nothing is hardcoded. (An earlier version of this repository did hardcode `/opt/home-datacenter-starter`, which existed nowhere — the wrapper refused with "no deployment checkout" on a machine where the checkout was plainly there.)

---

## 2. Look at what the bootstrap intends, before granting it sudo

```bash
scripts/bootstrap-dev-controller.sh --check
```

No sudo, changes nothing. It prints `WOULD …` for each step and names the account it would run as — by default **the owner of the checkout**, i.e. you.

**If you want a dedicated service account instead** (PR #5's argument: a deployment should not depend on a person's login session or keychain), say so explicitly — the script will never create one unasked:

```bash
sudo KEEL_SERVICE_USER=keeladmin KEEL_CREATE_SERVICE_USER=1 scripts/bootstrap-dev-controller.sh
```

Otherwise:

```bash
sudo scripts/bootstrap-dev-controller.sh
```

It creates:

| | |
|---|---|
| `/etc/keel/keel-deploy-key` | new Ed25519 key, `0400`, owned by the service account |
| `/etc/keel/known_hosts` | GitHub's host keys, **verified against GitHub's published fingerprints** |
| `/etc/keel/vault-pass` | 64 random characters, `0400`. Generated, never typed, never printed |
| `/etc/keel/reconcile.conf` | paths only — no secret belongs in a world-readable file |
| `/etc/keel/com.meetyaks.keel-reconcile-dev.plist` | rendered with the real paths. **Not loaded** |
| `/var/log/keel/` | `0750` |

It is **idempotent**: run it twice and the second run reports "already present" for everything. It will never regenerate the deploy key (that would silently invalidate the key you are about to register on GitHub) or the vault password (that would orphan the encrypted vault).

It prints **no secret**. It does print the public key and its fingerprint, which you need next.

---

## 3. Register the deploy key — read-only

The script prints the exact command. With a `gh` login that has admin on the repository:

```bash
gh api -X POST repos/meetyaks/keel/keys \
  -f title="keel-dev-release-reader-$(hostname -s)" \
  -F read_only=true \
  -f key="$(sudo cat /etc/keel/keel-deploy-key.pub)"
```

Or in the UI: **https://github.com/meetyaks/keel/settings/keys/new** — paste the printed public key and **leave "Allow write access" UNCHECKED**.

> `read_only=true` is not cosmetic. A site credential that can push can replace the release it just verified. Step 5 probes this and fails if the key can write.

---

## 4. Create the GHCR pull token

**https://github.com/settings/tokens/new?scopes=read:packages&description=keel-dev-ghcr-pull**

| | |
|---|---|
| type | **classic** personal access token |
| scopes | **`read:packages` and nothing else** — not `write:packages`, not `repo`, not `delete:packages` |
| expiry | set one, and write the date down |

> It must be a **classic** PAT. [GitHub's own documentation](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-container-registry) says *"GitHub Packages only supports authentication using a personal access token (classic)"* — a fine-grained token authenticates against the API and is then rejected by `ghcr.io`, with an error that sends you looking in the wrong place. The vault script refuses a `github_pat_…` for exactly that reason.

Then store it:

```bash
sudo scripts/bootstrap-dev-vault.sh
```

It asks for the username, then the token **hidden** (`read -s`). The token never reaches your shell history, never becomes a command argument, and is never written unencrypted. The script also refuses to overwrite an existing vault, and checks the file is gitignored *before* creating it.

---

## 5. Prove both credentials actually work

```bash
tests/run-credential-proof.sh
```

This is the step that matters. Every other test in this repository proves the code *refuses* correctly and cannot leak; only this one proves the credentials can *read*.

| it checks | |
|---|---|
| deploy key | mode, owner, pinned host keys |
| | agent-free read of `release/dev` **and** the default branch — with `SSH_AUTH_SOCK` unset and `IdentityAgent=none`, so a personal key in your ssh-agent cannot answer for it |
| | **write is refused** (`git push --dry-run`) |
| vault | encrypted at rest, decrypts, holds both registry variables |
| GHCR | resolves both published DEV digests — `manifest inspect`, so no layers are pulled |
| fail-closed | a missing deploy key is still refused, and the message names it |
| no leak | nothing in git, in the logs, or in any process argument |

It uses a **temporary Docker config**, so your own `~/.docker/config.json` is never touched, and logs out and deletes it on every exit path.

**If it passes, the credentials are ready.** Nothing has been deployed and `dc1-x86` has not been contacted.

---

## 6. Then — and only then — the first deployment

Still manual, still watched. See [Turning it on](keel-dev-reconcile.md#turning-it-on) for the full sequence; in short:

```bash
# A dry run that changes nothing and contacts no host beyond reading the channel.
bin/keel-reconcile-dev --check
```

The daemon comes last, after a real run has succeeded in front of a person:

```bash
sudo cp /etc/keel/com.meetyaks.keel-reconcile-dev.plist /Library/LaunchDaemons/
sudo launchctl bootstrap system /Library/LaunchDaemons/com.meetyaks.keel-reconcile-dev.plist
sudo launchctl print system/com.meetyaks.keel-reconcile-dev
```

---

## If something refuses

Read the refusal — they are written to be the whole explanation, not a code to look up.

| message | what it means |
|---|---|
| `no account named "…" exists` | the service account you asked for is not there. Either name one that is, or add `KEEL_CREATE_SERVICE_USER=1` |
| `GitHub's served host keys did not match its published fingerprints` | **stop and investigate.** Nothing was pinned. This is the check refusing to trust a document that does not verify |
| `is mode 0644 … must be 0400` | the deploy key is readable by someone else. A key a second account can read is not a dedicated credential |
| `cannot read refs/heads/release/dev` | the public key is not registered on `meetyaks/keel`, or not as a deploy key. Note this is checked with your own credential helper and ssh-agent **excluded** — it is answering for the service account, not for you |
| `appears to have WRITE access` | the "Allow write access" box was ticked. Remove the key on GitHub and add it again |
| `that is a fine-grained personal access token` | see step 4 — GHCR needs a classic PAT |
| `could NOT resolve …keel-web@sha256:…` | the token authenticates but cannot see that package. Check the token's owner can see both packages |

## Rotating

Both secrets are deliberately never regenerated in place. To rotate:

```bash
# deploy key — remove BOTH halves together, or the reconciler authenticates
# with a key GitHub no longer knows
gh api -X DELETE repos/meetyaks/keel/keys/<id>
sudo rm /etc/keel/keel-deploy-key /etc/keel/keel-deploy-key.pub
sudo scripts/bootstrap-dev-controller.sh      # generates a new one; re-do step 3

# GHCR token — the vault is edited in place, token typed into your editor
sudo ansible-vault edit --vault-password-file /etc/keel/vault-pass \
  inventory/group_vars/linux_servers/vault.yml
```
