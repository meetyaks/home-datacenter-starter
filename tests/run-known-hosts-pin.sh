#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# THE HOST-KEY PIN IS VERIFIED, NOT JUST FETCHED.
#
#   tests/run-known-hosts-pin.sh
#
# ⚠️ THE GUARD THIS EXERCISES IS THE ONE THAT MATTERS MOST ON THIS PATH. The
# controller decides what the DEV site runs, from a document it fetches over
# SSH. If it can be made to trust the wrong host key, it can be handed the
# wrong document. `ssh-keyscan` — the usual way to fill known_hosts — pins
# whatever answers on port 22 and authenticates nothing.
#
# scripts/lib/github-known-hosts.py instead recomputes each key's fingerprint
# and compares it against the fingerprint GitHub publishes beside it. This
# proves that comparison actually rejects things, by handing it documents
# that are wrong in one specific way each.
#
# ⚠️ OFFLINE. Every case is a local fixture; the live document is fetched by
# the bootstrap script, not by this suite. A test that needed GitHub to be
# reachable would be red for reasons unrelated to the change.
#
# Controller-only; everything it creates is under /tmp and removed at the end.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

PIN=scripts/lib/github-known-hosts.py
ROOT=/tmp/keel-known-hosts-pin

cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT INT TERM
rm -rf "$ROOT"; mkdir -p "$ROOT"

pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; [ -n "${2:-}" ] && echo "        $2"; fail=$((fail + 1)); }

# ⚠️ A REAL, SELF-CONSISTENT DOCUMENT, BUILT HERE. Not a copy of GitHub's —
# a committed snapshot of real host keys would go stale the day they rotate,
# and the suite would fail for a reason that is not a defect. These are
# throwaway keys generated now, with fingerprints computed the same way
# OpenSSH computes them.
python3 tests/lib/make-meta-fixtures.py "$ROOT" || {
  echo "could not build fixtures"; exit 1
}

echo "── a self-consistent document is pinned ────────────────────────────"
if "$PIN" "$ROOT/good.json" "$ROOT/good.known_hosts" >"$ROOT/good.out" 2>&1; then
  ok "accepted"
else
  bad "a correct document was refused" "$(cat "$ROOT/good.out")"
fi

if [ -s "$ROOT/good.known_hosts" ]; then
  ok "it wrote a known_hosts file"
else
  bad "nothing was written"
fi

# Every line must be `github.com <type> <key>` — ssh silently ignores a line
# it cannot parse, which would leave the host unpinned while the file looks
# populated.
if awk '{ if ($1 != "github.com" || NF < 3) exit 1 }' "$ROOT/good.known_hosts"; then
  ok "every line is a well-formed github.com entry"
else
  bad "a line is not a well-formed github.com entry" "$(cat "$ROOT/good.known_hosts")"
fi

# ⚠️ AND ssh ITSELF MUST ACCEPT IT. The format is the point: a file this
# script is happy with but `ssh` cannot read would pin nothing at all.
if ssh-keygen -l -f "$ROOT/good.known_hosts" >/dev/null 2>&1; then
  ok "ssh-keygen parses it as a known_hosts file"
else
  bad "ssh-keygen cannot parse the file this produced"
fi

echo
echo "── a document that does not check out is REFUSED ───────────────────"

refuses() { # refuses <label> <fixture> <expected-substring>
  local label="$1" fixture="$2" want="$3"
  local out rc
  # Captured together: testing `$?` on a later line reads whatever ran last,
  # which is how a check like this ends up asserting nothing.
  out=$("$PIN" "$ROOT/$fixture" "$ROOT/$fixture.known_hosts" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "$label" "it was ACCEPTED"
    return
  fi
  if ! grep -qF -- "$want" <<<"$out"; then
    bad "$label" "refused, but not for '$want': $out"
    return
  fi
  # ⚠️ AND IT WROTE NOTHING. A refusal that still left a partial known_hosts
  # would be the worst outcome: the next run would find the file present,
  # skip the pin, and trust it.
  if [ -e "$ROOT/$fixture.known_hosts" ]; then
    bad "$label" "refused, but left $fixture.known_hosts behind"
    return
  fi
  ok "$label"
}

refuses "a tampered key, with its published fingerprint left alone" \
  tampered-key.json "does not match what GitHub publishes"

refuses "a tampered fingerprint, with the key left alone" \
  tampered-fingerprint.json "does not match what GitHub publishes"

refuses "a document with no keys at all" \
  no-keys.json "carries no ssh_keys"

refuses "a document with keys but nothing to check them against" \
  no-fingerprints.json "no ssh_key_fingerprints"

refuses "a malformed key entry" \
  malformed.json "malformed host key entry"

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: ${fail} of $((fail + pass)) check(s)."
  exit 1
fi
echo "known_hosts pin: ${pass} checks — verified against published fingerprints, and refuses when they disagree."
