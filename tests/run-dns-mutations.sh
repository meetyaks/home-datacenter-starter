#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# A GUARD THAT HAS NEVER FAILED IS NOT A GUARD.
#
#   tests/run-dns-mutations.sh
#
# tests/dns-zone.yml, tests/dns-services.yml and tests/dns-inventory.yml all
# pass against the shipped configuration. That proves they agree with it — not
# that they would notice if it changed. So this breaks the configuration one
# way at a time and requires the suites to go RED, and red FOR THAT REASON: a
# failure for the wrong reason is not a pass, because the next person reads the
# message and fixes the thing it names.
#
# Every mutation is reverted from a byte-for-byte backup, including on an
# interrupt. Nothing here touches a host, a port or a daemon.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.."

DEFAULTS=roles/coredns/defaults/main.yml
COREFILE=roles/coredns/templates/Corefile.j2
ZONE=roles/coredns/templates/db.zone.j2
HOSTS=inventory/hosts.yml

WORK=$(mktemp -d -t dns-mutations.XXXXXX)
restore() {
  [ -f "$WORK/defaults" ] && cp "$WORK/defaults" "$DEFAULTS"
  [ -f "$WORK/corefile" ] && cp "$WORK/corefile" "$COREFILE"
  [ -f "$WORK/zone" ] && cp "$WORK/zone" "$ZONE"
  [ -f "$WORK/hosts" ] && cp "$WORK/hosts" "$HOSTS"
}
cleanup() { restore; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

cp "$DEFAULTS" "$WORK/defaults"
cp "$COREFILE" "$WORK/corefile"
cp "$ZONE" "$WORK/zone"
cp "$HOSTS" "$WORK/hosts"

pass=0
fail=0
ok()  { printf '  \033[32mok\033[0m    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }

# ⚠️ NOT `sed -i ''`, AND THIS COST A RED CI RUN. `-i ''` is BSD syntax: GNU
# sed takes the suffix ATTACHED (`-i.bak`), so on Linux it read the empty
# string as the script and the real script as a filename —
#
#   sed: can't read s/^coredns_version: …/: No such file or directory
#
# — and left the file UNTOUCHED. Eight mutations silently did nothing, the
# suites passed because there was nothing wrong with them, and this runner
# reported "the mutation went unnoticed". That verdict was CORRECT: the guard
# genuinely had not been proved. It passed on macOS and failed on the hosted
# runner, which is the only reason it was found.
#
# `perl -pi` behaves identically on both. Note perl regex, not sed BRE:
# `{64}` rather than `\{64\}`, and braces in Jinja markers are escaped.
edit() { perl -pi -e "$1" "$2"; }

# Run one suite and require it to FAIL, with a message matching $2.
#   expect_red <suite> <regex> <label>
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

echo "── no test script edits files with BSD-only sed ──"
# ⚠️ THE BUG THAT COST A RED CI RUN, MADE UNREPEATABLE. `sed -i ''` works on
# macOS and silently does NOTHING on Linux — GNU sed reads the empty string as
# the script and the real script as a filename. Eight mutations here landed
# nowhere on the hosted runner. Searching for the empty-suffix form only: a
# plain `sed -i 'script'` is valid GNU usage and appears legitimately in
# tests/run-caddy-handler-order.sh, which runs inside a Linux container.
#
# ⚠️ AND IT SKIPS COMMENT LINES, because the first version flagged THIS FILE:
# the explanation above contains the offending string, so a guard about
# portability failed on its own documentation. That is the third time in this
# repository that a text search matched prose instead of code — the same
# reason tests/dns-zone.yml scans a comment-stripped view for secrets.
#
# ⚠️ THE PATTERN USES `+` QUANTIFIERS SO IT CANNOT MATCH ITSELF, and the
# labels avoid the literal for the same reason. Written the obvious way, the
# detector line and its own failure message are the three remaining matches,
# and the check fails on a file whose only offence is describing the problem.
offenders=$(grep -rnE "sed +-i +''" tests/ roles/ playbooks/ scripts/ bin/ 2>/dev/null \
            | grep -vE ':[0-9]+:[[:space:]]*#' \
            | cut -d: -f1 | sort -u || true)
if [ -z "$offenders" ]; then
  ok "no script uses the BSD-only empty-suffix in-place sed form"
else
  bad "no script uses the BSD-only empty-suffix in-place sed form" \
      "these edit nothing on Linux: $(printf '%s' "$offenders" | tr '\n' ' ')"
fi

echo
echo "── the suites are green before anything is broken ──"
for s in dns-zone dns-services dns-inventory; do
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
echo "── every essential record, deleted ──"
# Each record is removed by deleting its two-line entry from the defaults.
for rec in dc1-arm-1 dc1-x86 keel-dev; do
  # The record blocks are `- name: X` followed by `  ip: Y`.
  perl -0pi -e "s/^  - name: \Q${rec}\E\n    ip: [0-9.]+\n//m" "$DEFAULTS"
  expect_red dns-zone.yml 'must be exactly|Three records' \
             "deleting ${rec} is caught"
done

echo
echo "── every essential record, repointed ──"
for rec in dc1-arm-1 dc1-x86 keel-dev; do
  perl -0pi -e "s/(^  - name: \Q${rec}\E\n    ip: )[0-9.]+/\${1}10.0.0.99/m" "$DEFAULTS"
  expect_red dns-zone.yml 'must be exactly|reserved addresses|Three records' \
             "repointing ${rec} to a foreign address is caught"
done

echo
echo "── the reserved production name, added ──"
# ⚠️ THE MUTATION THAT MATTERS MOST. `keel.dc1.lan` is reserved for future
# production on separate hardware. Adding it here — even "temporarily" at
# dc1-x86 — gives this DEV installation a second issuer and means the eventual
# production cutover has to take a live name away from a running environment.
# ⚠️ INSERTED INTO THE LIST, NOT APPENDED TO THE FILE. The first version did
# `>> defaults/main.yml`, which landed the entry after unrelated keys and made
# the file invalid YAML — so the suite failed with "Mapping values are not
# allowed in this context" instead of ever reaching the guard. Non-zero, and
# completely uninformative about whether the reserved name is refused.
perl -0pi -e 's/(  - name: keel-dev\n    ip: [0-9.]+\n)/$1  - name: keel\n    ip: 10.0.0.3\n/' "$DEFAULTS"
expect_red dns-zone.yml 'reserved for (future )?production|appears in the zone|must be exactly' \
           "adding the reserved keel.dc1.lan is caught"

echo
echo "── the pinned binaries ──"
edit 's{^  darwin_arm64: "[0-9a-f]*"}{  darwin_arm64: "deadbeef"}' "$DEFAULTS"
expect_red dns-zone.yml 'not pinned for both platforms|64-character' \
           "a malformed darwin checksum is caught"

edit 's{^  linux_amd64: "[0-9a-f]{64}"}{  linux_amd64: "0000000000000000000000000000000000000000000000000000000000000000"}' "$DEFAULTS"
expect_red dns-zone.yml 'does not match the verified values' \
           "a plausible-but-wrong linux checksum is caught"

edit 's{^coredns_version: "1\.14\.7"}{coredns_version: "1.14.8"}' "$DEFAULTS"
expect_red dns-zone.yml 'does not match the verified values' \
           "bumping the version without its checksums is caught"

echo
echo "── the forwarding loop ──"
# ⚠️ THE FAILURE THAT ONLY APPEARS AFTER THE ROUTER CHANGE. 10.0.0.1 will
# forward TO these resolvers; forwarding back to it loops every cache miss.
edit 's{^  - 1\.1\.1\.1}{  - 10.0.0.1}' "$DEFAULTS"
expect_red dns-zone.yml 'no path back to the router|loop|Upstreams are' \
           "forwarding back to Orbi is caught"

echo
echo "── LAN-only access ──"
edit 's{^    bind \{\{ addr \}\}}{    bind 0.0.0.0}' "$COREFILE"
expect_red dns-zone.yml 'does not bind only|bind 0\.0\.0\.0' \
           "binding the wildcard is caught"

restore
# Remove the ACL from the forwarding block only — an open resolver for anyone
# who can reach the port, while the authoritative block still looks correct.
perl -0pi -e 's/(forward \. \{\{ coredns_upstreams.*)/$1/s' "$COREFILE"
perl -0pi -e 's/    acl \{\n(?:.*\n)*?        block\n    \}\n\n    forward/    forward/' "$COREFILE"
expect_red dns-zone.yml 'ACL is wrong|open resolver' \
           "an unprotected forwarding block is caught"

echo
echo "── the zone template ──"
restore
perl -0pi -e 's/\{% for r in coredns_zone_records \| sort\(attribute=.name.\) %\}/{% for r in coredns_zone_records[:1] %}/' "$ZONE"
expect_red dns-zone.yml 'rendered zone does not say|byte-identical|three names' \
           "a template that silently drops records is caught"

echo
echo "── the inventory connection ──"
restore
edit 's{          ansible_host: 10\.0\.0\.3}{          ansible_host: dc1-x86}' "$HOSTS"
expect_red dns-inventory.yml 'must be the literal address|circular dependency' \
           "reverting dc1-x86 to an unresolvable name is caught"

echo
echo "── the service definitions ──"
PLIST=roles/coredns/templates/launchd.plist.j2
cp "$PLIST" "$WORK/plist"
restore_plist() { cp "$WORK/plist" "$PLIST"; }

perl -0pi -e 's/  <key>KeepAlive<\/key>\n  <true\/>/  <key>KeepAlive<\/key>\n  <false\/>/' "$PLIST"
if ansible-playbook tests/dns-services.yml >"$WORK/out" 2>&1; then
  bad "a resolver that gives up after a crash is caught" "tests/dns-services.yml still PASSED"
elif grep -qE 'KeepAlive and RunAtLoad' "$WORK/out"; then
  ok "a resolver that gives up after a crash is caught"
else
  bad "a resolver that gives up after a crash is caught" "failed for another reason"
fi
restore_plist

UNIT=roles/coredns/templates/systemd.service.j2
cp "$UNIT" "$WORK/unit"
edit 's{^Type=simple$}{Type=notify}' "$UNIT"
if ansible-playbook tests/dns-services.yml >"$WORK/out" 2>&1; then
  bad "Type=notify, which CoreDNS cannot satisfy, is caught" "tests/dns-services.yml still PASSED"
elif grep -qE 'sd_notify' "$WORK/out"; then
  ok "Type=notify, which CoreDNS cannot satisfy, is caught"
else
  bad "Type=notify, which CoreDNS cannot satisfy, is caught" "failed for another reason"
fi
cp "$WORK/unit" "$UNIT"

edit 's{^User=\{\{ coredns_linux_user \}\}$}{User=root}' "$UNIT"
if ansible-playbook tests/dns-services.yml >"$WORK/out" 2>&1; then
  bad "running the resolver as root is caught" "tests/dns-services.yml still PASSED"
elif grep -qE 'dedicated .coredns. user|must run as' "$WORK/out"; then
  ok "running the resolver as root is caught"
else
  bad "running the resolver as root is caught" "failed for another reason"
fi
cp "$WORK/unit" "$UNIT"

echo
echo "── everything is restored ──"
restore
cp "$WORK/plist" "$PLIST"
cp "$WORK/unit" "$UNIT"
for s in dns-zone dns-services dns-inventory; do
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
echo "PASS — $pass checks: every essential record, both checksums, the"
echo "forwarding loop, LAN-only access and both service definitions are"
echo "proved to FAIL when broken, each for its own reason."
