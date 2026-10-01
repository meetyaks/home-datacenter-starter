#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# THE RECONCILER, DRY, AGAINST THE RELEASE THAT ACTUALLY EXISTS.
#
#   tests/run-published-release-check-mode.sh
#
# tests/run-reconcile-check-mode.sh proves the reconciler's control flow using
# a channel document this repository writes. This one runs the same playbook
# under --check against tests/published-release-dev-channel.json — a
# byte-for-byte copy of what meetyaks/keel published to `release/dev` at
# f0bf450565ee3f4e0890b143368eaf4c9f15150d. Nothing in that document was
# written to make this pass.
#
# What it proves, and the list is deliberately short:
#   1. the reconciler reads the REAL document, reaches a decision, and names
#      the release and commit it would deploy
#   2. the drift report states the provenance being offered and the policy in
#      force — so an operator sees reduced assurance BEFORE a deployment,
#      not in current.json afterwards
#   3. --check takes no lock, writes no attempt record, no current.json and no
#      evidence; runs no docker command; and reaches no host
#
# ⚠️ IT DEPLOYS NOTHING, AND IT CANNOT. The reconcile role ends the host at
# `when: ansible_check_mode` before the lock is taken and before roles/keel is
# ever included. That is the property being exercised, not an assumption about
# it: the assertions below check the filesystem afterwards.
#
# ⚠️ NO NETWORK. The channel is served from a local git repository built here,
# and the Keel checkout is a --local clone of one already on this machine, so
# the role's `git fetch origin` reaches a path on disk. A test that needs the
# outside world to be in a particular state is not a test.
#
# Needs a Keel checkout containing the published commit. Set KEEL_CHECKOUT, or
# leave it to the same default the role uses. Without one the script SKIPS and
# says so — it does not quietly pass.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")/.." || exit 1

# What the recording says. Restated here so the assertions are about specific
# values rather than about whatever the document happens to contain.
RELEASE_ID=keel-20261001T010103Z-5bb120c97b56
GIT_SHA=5bb120c97b56bfe4c5da7d05d46de368fab62955
CHANNEL_DOC=tests/published-release-dev-channel.json

KEEL_CHECKOUT="${KEEL_CHECKOUT:-$HOME/Projects/keel}"

FIXTURE=/tmp/keel-published-channel-fixture
SRCFIX=/tmp/keel-published-source-fixture
WORKDIR=/tmp/keel-published-checkmode-workdir
STATE=/tmp/keel-published-checkmode-state
OUT=$(mktemp)

cleanup() { rm -rf "$FIXTURE" "$SRCFIX" "$WORKDIR" "$STATE" "$OUT"; }
trap cleanup EXIT
rm -rf "$FIXTURE" "$SRCFIX" "$WORKDIR" "$STATE"

# ── THE CONTROLLER'S KEEL CHECKOUT ──────────────────────────────────────────
#
# A `--local` clone hardlinks the object store, so this is cheap and, more to
# the point, its `origin` is a path — the role's `git fetch origin` touches
# nothing outside this machine.
if [ ! -d "$KEEL_CHECKOUT/.git" ]; then
  echo "SKIPPED: no Keel checkout at $KEEL_CHECKOUT (set KEEL_CHECKOUT)."
  echo "         This proof needs the repository that published $RELEASE_ID."
  exit 0
fi
if ! git -C "$KEEL_CHECKOUT" cat-file -e "${GIT_SHA}^{commit}" 2>/dev/null; then
  echo "SKIPPED: $KEEL_CHECKOUT does not contain commit ${GIT_SHA:0:12}."
  echo "         Fetch it, or point KEEL_CHECKOUT at a checkout that has it."
  exit 0
fi

git clone --quiet --local --no-checkout "$KEEL_CHECKOUT" "$SRCFIX"
git -C "$SRCFIX" remote set-url origin "$KEEL_CHECKOUT"

# ── A CHANNEL REPOSITORY SERVING THE PUBLISHED DOCUMENT ─────────────────────
mkdir -p "$FIXTURE/channels"
git -C "$FIXTURE" init --quiet --initial-branch=release/dev
git -C "$FIXTURE" config user.email fixture@example.invalid
git -C "$FIXTURE" config user.name "published release recording"
cp "$CHANNEL_DOC" "$FIXTURE/channels/dev.json"
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit --quiet -m "recording of release/dev at f0bf4505"

# ── THE DRY RUN ─────────────────────────────────────────────────────────────
#
# `allow_unavailable` is passed explicitly because this fixture inventory is
# not keel_dev and therefore — correctly — inherits the strict default. The
# published release's provenance is unavailable, so the strict default would
# refuse it, which tests/published-release-proof.yml proves separately. Here
# the subject is the reconciler's control flow, under DEV's real policy.
set +e
ansible-playbook playbooks/keel-reconcile.yml --check \
  -i tests/inventory-reconcile-fixture.yml \
  -e keel_reconcile_hosts=keel_reconcile_fixture \
  -e "keel_reconcile_channel_repo=$FIXTURE" \
  -e "keel_reconcile_workdir=$WORKDIR" \
  -e "keel_reconcile_state_dir=$STATE" \
  -e "keel_source_repo=$SRCFIX" \
  -e keel_release_provenance_policy=allow_unavailable \
  > "$OUT" 2>&1
run_rc=$?
set -e

fail=0
check() { if [ "$2" -eq 0 ]; then echo "  ok    $1"; else echo "  FAIL  $1"; fail=$((fail + 1)); fi; }
# ⚠️ `grep … ; check $?` DOES NOT WORK UNDER `set -e` — a bare failing grep is
# not in a condition context and the shell exits on the first failed check,
# reporting silence instead of a failure. Every text check goes through here.
want()     { if grep -q -e "$2" "$OUT"; then check "$1" 0; else check "$1" 1; fi; }
want_not() { if grep -qE -e "$2" "$OUT"; then check "$1" 1; else check "$1" 0; fi; }

echo "── the reconciler reads the published document ─────────────────────"
check "the check-mode run completed" "$run_rc"
if [ "$run_rc" -ne 0 ]; then
  echo "── playbook output ─────────────────────────────────────────────────"
  cat "$OUT"
  exit 1
fi

want "it names the published release"        "$RELEASE_ID"
want "it names the published commit"         "${GIT_SHA:0:12}"
want "it decided to deploy, and said so"     "DECISION deploy"

echo
echo "── and states the assurance BEFORE anything is deployed ────────────"
want "the drift report names the offered provenance" "offered        unavailable provenance"
want "and the policy in force"                       "policy         allow_unavailable"

echo
echo "── --check took no lock, wrote no record, deployed nothing ─────────"
# ⚠️ `absent <path>`, NOT `[ ! -e … ]; check … $?`. Passing `$?` as an argument
# reads the status of the LAST command in the argument list, which is a trap
# worth not leaving lying around even where it currently happens to work.
absent() { if [ -e "$2" ]; then check "$1" 1; else check "$1" 0; fi; }

absent "no deployment lock was taken"    "$STATE/reconcile.lock"
absent "no attempt record was written"   "$STATE/attempts"
absent "no deployment record was written" "$STATE/current.json"
absent "no evidence directory was created" "$STATE/evidence"
want_not "no docker command was run"   "docker (build|pull|compose)"
want_not "no image was pulled by digest" "@sha256:[0-9a-f]{64}.*(pull|docker)"

# ⚠️ AND IT NEVER CLAIMED TO HAVE VERIFIED ANYTHING. The reconciler does not
# verify — roles/keel does, and --check never reaches it. A dry run that
# printed "verified" would be stating something nothing had done.
want_not "nothing in the run claims verification" "(verified|attestation verify)"

recap=$(grep -E "^reconcile-fixture-host" "$OUT" | tail -1 || true)
case "$recap" in
  *failed=0*) check "PLAY RECAP reports failed=0" 0 ;;
  *) echo "  FAIL  PLAY RECAP: ${recap:-(absent)}"; fail=$((fail + 1)) ;;
esac

echo
if [ "$fail" -ne 0 ]; then
  echo "FAILED: ${fail} check(s)."
  echo "── playbook output ─────────────────────────────────────────────────"
  cat "$OUT"
  exit 1
fi
echo "Published release, check mode: decided, stated the assurance, changed nothing."
