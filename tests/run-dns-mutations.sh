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
INSTALL=roles/coredns/tasks/install.yml
VERIFY=roles/coredns/tasks/verify.yml
SHAPE=tests/dns-task-shape.yml
MAIN_TASKS=roles/coredns/tasks/main.yml
CONFIGURE=roles/coredns/tasks/configure.yml
PREREQ=roles/coredns/tasks/verifier-prereq.yml
# ⚠️ A TEST SCRIPT MUTATED AS IF IT WERE PRODUCTION CODE. The macOS harness
# runs a real root daemon beside the live resolver, so its safety properties
# are load-bearing in exactly the way a role's are, and they get the same
# treatment: break one, require tests/dns-harness-integrity.yml to notice.
LAUNCHD=tests/run-coredns-launchd.sh

WORK=$(mktemp -d -t dns-mutations.XXXXXX)
restore() {
  [ -f "$WORK/defaults" ] && cp "$WORK/defaults" "$DEFAULTS"
  [ -f "$WORK/corefile" ] && cp "$WORK/corefile" "$COREFILE"
  [ -f "$WORK/zone" ] && cp "$WORK/zone" "$ZONE"
  [ -f "$WORK/hosts" ] && cp "$WORK/hosts" "$HOSTS"
  [ -f "$WORK/install" ] && cp "$WORK/install" "$INSTALL"
  [ -f "$WORK/verify" ] && cp "$WORK/verify" "$VERIFY"
  [ -f "$WORK/shape" ] && cp "$WORK/shape" "$SHAPE"
  [ -f "$WORK/main_tasks" ] && cp "$WORK/main_tasks" "$MAIN_TASKS"
  [ -f "$WORK/configure" ] && cp "$WORK/configure" "$CONFIGURE"
  [ -f "$WORK/prereq" ] && cp "$WORK/prereq" "$PREREQ"
  [ -f "$WORK/launchd" ] && cp "$WORK/launchd" "$LAUNCHD"
  return 0
}
cleanup() { restore; rm -rf "$WORK"; }
trap cleanup EXIT INT TERM

cp "$DEFAULTS" "$WORK/defaults"
cp "$COREFILE" "$WORK/corefile"
cp "$ZONE" "$WORK/zone"
cp "$HOSTS" "$WORK/hosts"
cp "$INSTALL" "$WORK/install"
cp "$VERIFY" "$WORK/verify"
cp "$SHAPE" "$WORK/shape"
cp "$MAIN_TASKS" "$WORK/main_tasks"
cp "$CONFIGURE" "$WORK/configure"
cp "$PREREQ" "$WORK/prereq"
cp "$LAUNCHD" "$WORK/launchd"

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
for s in dns-zone dns-services dns-inventory dns-install-platform dns-task-shape dns-harness-integrity; do
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
echo "── the macOS/Linux extraction split ──"
# ⚠️ THE SPLIT EXISTS BECAUSE A REAL DEPLOYMENT DIED ON IT. Running
# playbooks/dns.yml from dc1-arm-1 stopped on the primary with
# "Command /usr/bin/tar detected as tar type bsd. GNU tar required." — after
# the pinned checksum had already matched. These mutations put that failure
# back, one way at a time.
restore

# 1. The regression itself: one unarchive task for everybody, as it was.
perl -0pi -e 's/- name: Unpack it \(macOS.*?(?=- name: Unpack it \(Linux\))//s' "$INSTALL"
perl -0pi -e 's/(- name: Unpack it \(Linux\).*?\n  when:\n)    - coredns_needs_install \| bool\n    - not \(coredns_is_darwin \| bool\)\n/$1    - coredns_needs_install | bool\n/s' "$INSTALL"
expect_red dns-install-platform.yml 'exactly one task invoking /usr/bin/tar|macOS cannot use' \
           "removing the Darwin branch is caught"

# 2. The split inverted: macOS gets unarchive, Linux gets the system tar.
#    Reversed rather than deleted, because an inverted condition still LOOKS
#    like a platform split in review — and still fails on the Mac.
restore
perl -0pi -e 's/    - coredns_is_darwin \| bool\n/    - __SWAP__\n/' "$INSTALL"
perl -0pi -e 's/    - not \(coredns_is_darwin \| bool\)\n/    - coredns_is_darwin | bool\n/' "$INSTALL"
perl -0pi -e 's/    - __SWAP__\n/    - not (coredns_is_darwin | bool)\n/' "$INSTALL"
expect_red dns-install-platform.yml 'needs_install AND is_darwin|condition is|NOT is_darwin|unarchive task is reachable on Darwin' \
           "inverting the platform split is caught"

# 3. The Darwin branch losing its needs_install gate — a converged node would
#    re-extract on every run.
restore
perl -0pi -e 's/(- name: Unpack it \(macOS.*?\n  when:\n)    - coredns_needs_install \| bool\n/$1/s' "$INSTALL"
expect_red dns-install-platform.yml 'needs_install AND is_darwin|condition is' \
           "the Darwin branch losing its needs_install gate is caught"

# 4. argv replaced by shell text. The staging path is interpolated, so a path
#    with a space would be re-split — on the node serving the whole LAN's DNS.
restore
perl -0pi -e 's/  ansible\.builtin\.command:\n    argv:\n      - \/usr\/bin\/tar\n      - -xzf\n      - "\{\{ coredns_download_tmp\.path \}\}\/coredns\.tgz"\n      - -C\n      - "\{\{ coredns_download_tmp\.path \}\}"\n/  ansible.builtin.shell:\n    cmd: "\/usr\/bin\/tar -xzf \{\{ coredns_download_tmp.path \}\}\/coredns.tgz -C \{\{ coredns_download_tmp.path \}\}"\n/s' "$INSTALL"
expect_red dns-install-platform.yml 'shell or raw task appears|exactly one task invoking' \
           "replacing argv with a shell string is caught"

# 5. The extracted-binary assertion deleted — the copy then fails with
#    "Source .../coredns not found", the symptom rather than the cause.
restore
perl -0pi -e 's/- name: Confirm the extraction produced it.*?(?=- name: Install it)//s' "$INSTALL"
expect_red dns-install-platform.yml 'assertion must sit after BOTH extraction|stat .*assert .*copy' \
           "deleting the extracted-binary assertion is caught"

# 6. The assertion kept but moved AFTER the copy, where it can no longer
#    prevent anything.
restore
perl -0pi -e 'my $a; s/(- name: Look for the binary.*?)(?=- name: Install it)/$a = $1; ""/se;
              s/(- name: Remove the staging directory)/$a$1/s' "$INSTALL"
expect_red dns-install-platform.yml 'assertion must sit after BOTH extraction|stat .*assert .*copy|before the copy' \
           "moving the assertion after the copy is caught"

# 7. The checksum dropped from the download — extraction would then run
#    unvouched-for bytes through tar and install the result as root.
restore
perl -0pi -e 's/    checksum: "sha256:\{\{ coredns_checksums\[coredns_platform\] \}\}"\n//' "$INSTALL"
expect_red dns-install-platform.yml 'must come before both extraction|checksum' \
           "dropping the download checksum is caught"

echo
echo "── the directories the role installs into ──"
# ⚠️ THE SECOND dc1-arm-1 FAILURE. The corrected Darwin extraction worked —
# tar succeeded, the binary was there, isreg passed at 73,452,546 bytes — and
# the next task said "Destination directory /usr/local/sbin does not exist".
# A stock macOS has no /usr/local/sbin and `copy` will not create one.
restore

# 1. The regression itself: the binary directory assumed rather than created.
edit 's{^    - "\{\{ coredns_bin_dir \}\}"\n}{}' "$INSTALL"
expect_red dns-install-platform.yml 'No directory task includes coredns_bin_dir|does not exist' \
           "dropping coredns_bin_dir from the bootstrap loop is caught"

# 2. A second task for it — one owner becomes two, and the mode and group
#    then have two places to drift apart.
restore
perl -0pi -e 's{^    - "\{\{ coredns_bin_dir \}\}"\n}{}m;
              s{(\n- name: Create the service account)}{\n- name: Create the binary directory separately\n  ansible.builtin.file:\n    path: "\{\{ coredns_bin_dir \}\}"\n    state: directory\n    owner: root\n    group: "\{\{ \x27wheel\x27 if coredns_is_darwin else \x27root\x27 \}\}"\n    mode: "0755"\n  become: true\n$1}s' "$INSTALL"
expect_red dns-install-platform.yml 'exactly one directory-creating task|One task creates all three' \
           "splitting the directories across two tasks is caught"

# 3. A world-writable directory on the default PATH, holding a binary that
#    runs as root.
restore
perl -0pi -e 's{(state: directory\n    owner: root\n    group: [^\n]*\n    mode: )"0755"}{$1"0777"}s' "$INSTALL"
expect_red dns-install-platform.yml 'must be state=directory, owner=root, mode=0755|privilege-escalation' \
           "a world-writable binary directory is caught"

# 4. Not root-owned.
restore
perl -0pi -e 's{(state: directory\n    owner: )root}{$1nobody}s' "$INSTALL"
expect_red dns-install-platform.yml 'must be state=directory, owner=root' \
           "a non-root-owned binary directory is caught"

# 5. The platform branches swapped — wrong on BOTH nodes, and the kind of
#    thing that reads fine in review.
restore
edit "s{'wheel' if coredns_is_darwin else 'root'}{'root' if coredns_is_darwin else 'wheel'}" "$INSTALL"
expect_red dns-install-platform.yml 'wheel on Darwin, root on Linux|must be exactly' \
           "swapping the Darwin/Linux group is caught"

# 6. The path hardcoded, so the Linux node inherits a macOS directory.
restore
edit 's{^    - "\{\{ coredns_bin_dir \}\}"$}{    - /usr/local/sbin}' "$INSTALL"
expect_red dns-install-platform.yml 'hardcoded /usr/local|creates coredns_bin_dir' \
           "hardcoding /usr/local/sbin is caught"

# 7. Created, but too late — after the version check already tried to run
#    the binary out of it. Moving the failure is not fixing it.
restore
perl -0pi -e 'my $d; s{(- name: Create the directories this role installs into.*?)(?=\n- name: Create the service account)}{$d = $1; ""}se;
              s{(- name: Make a staging directory for the download)}{$d\n\n$1}s' "$INSTALL"
expect_red dns-install-platform.yml 'it must be first|only moves the failure' \
           "creating the directories too late is caught"

echo
echo "── conditionals Ansible will actually accept ──"
# ⚠️ THE THIRD dc1-arm-1 FAILURE, AND THE MOST EXPENSIVE SURFACE IT COULD HAVE
# BEEN FOUND ON. The deployment reached the LAST task of the primary — CoreDNS
# installed, launchd running, every record already resolving — and died with
# "Conditional expressions must be strings", because an unquoted `that:` item
# containing ": " is parsed by YAML as a mapping. No controller-only suite
# executes verify.yml, so nothing had ever looked at it.
restore

# 1. The regression itself: drop the quotes back off.
perl -0pi -e "s{- 'coredns_reserved\.stdout is search\(\"status: NXDOMAIN\"\)'}{- coredns_reserved.stdout is search('status: NXDOMAIN')}" "$VERIFY"
expect_red dns-task-shape.yml 'parse as MAPPINGS rather than strings|must be quoted' \
           "an unquoted conditional containing \": \" is caught"

# 2. The quieter half: quoted, but with DOUBLE quotes, so YAML eats the \b
#    escapes and the word-boundary anchors become literal backspaces. The file
#    parses, the task runs, and the assertion silently matches nothing.
restore
# ⚠️ RE-TARGETED WHEN THE \b FORM WAS REMOVED. This originally rewrote the
# `search("flags:[^;]*\baa\b")` line; once that was replaced by the
# escape-free form the substitution matched nothing, the file was left
# untouched, and the runner reported "the mutation went unnoticed" — the
# correct verdict for a mutation that never landed, and the reason this was
# noticed at all rather than quietly degrading into a no-op.
perl -0pi -e "s{- 'coredns_reserved\.stdout is search\(\"flags:\[\^;\]\* aa\[ ;\]\"\)'}{- \"coredns_reserved.stdout is search('flags:[^;]*\\\\baa\\\\b')\"}" "$VERIFY"
expect_red dns-task-shape.yml 'non-printable character|eaten by a double-quoted' \
           "a double-quoted conditional whose escapes are eaten is caught"

# 3. The same trap in a `when:` rather than a `that:` — both are refused by
#    Ansible, so both are collected. List form, which yields a mapping item
#    exactly as the `that:` case did.
restore
perl -0pi -e 's{(- name: Give the daemon a moment to bind\n)}{$1  when:\n    - coredns_zone is search(\x27dc1: lan\x27)\n}' "$VERIFY"
expect_red dns-task-shape.yml 'parse as MAPPINGS rather than strings' \
           "the same trap in a when: clause is caught"

# 4. A task file that is not valid YAML at all. A SCALAR `when:` containing
#    ": " is a hard parse error rather than a mapping, and the suite used to
#    report it as "can only concatenate list (not CapturedExceptionMarker)" —
#    naming neither the file nor the cause.
restore
perl -0pi -e 's{(- name: Give the daemon a moment to bind\n)}{$1  when: coredns_zone is search(\x27dc1: lan\x27)\n}' "$VERIFY"
expect_red dns-task-shape.yml 'not valid YAML and Ansible could not read it' \
           "an unparseable task file is reported by name, not as a template error"

echo
echo "── conditionals that depend on a backslash escape ──"
# ⚠️ THE FOURTH dc1-arm-1 FAILURE, AND THE SUBTLEST SO FAR. The assertion
# `search("flags:[^;]*\baa\b")` failed inside a `that:` while the IDENTICAL
# expression returned True from a `debug` task against the same captured
# output. Ansible's conditional evaluation applies Python string-literal
# escape processing; ordinary templating does not. `\b` became a backspace
# and the expression matched nothing while looking perfectly correct.
restore

# 1. The regression itself.
perl -0pi -e 's{- .coredns_reserved\.stdout is search\("flags:\[\^;\]\* aa\[ ;\]"\).}{- \x27coredns_reserved.stdout is search("flags:[^;]*\\baa\\b")\x27}' "$VERIFY"
expect_red dns-task-shape.yml 'depend on a backslash escape|CONSUMES before the regex' \
           "a conditional relying on \\b is caught"

# 2. A different consumed escape, to prove the guard is not hard-coded to \b.
restore
perl -0pi -e 's{- .coredns_reserved\.stdout is search\("status: NXDOMAIN"\).}{- \x27coredns_reserved.stdout is search("status:\\nNXDOMAIN")\x27}' "$VERIFY"
expect_red dns-task-shape.yml 'depend on a backslash escape|CONSUMES before the regex' \
           "a conditional relying on \\n is caught"

# 3. ⚠️ THE NEGATIVE CASE, AND IT MATTERS AS MUCH AS THE OTHERS. `\d`, `\s`,
#    `\S`, `\w` and `\.` are INVALID Python escapes, so Python leaves them
#    alone and they reach the regex engine intact — which is why the record
#    assertions in this very file have always worked. A guard that refused
#    them too would be wrong and would force pointless rewrites of working
#    code. This adds one and requires the suite to stay GREEN.
restore
perl -0pi -e 's{(      - .coredns_reserved\.stdout is search\("status: NXDOMAIN"\).\n)}{$1      - \x27coredns_reserved.stdout is search("id: \\d+")\x27\n}' "$VERIFY"
if ansible-playbook tests/dns-task-shape.yml >"$WORK/out" 2>&1; then
  ok "a conditional using \\d is correctly ALLOWED (not a false positive)"
else
  bad "a conditional using \\d is correctly allowed" \
      "the guard rejected an escape Python does NOT consume; it is over-broad"
  grep -E "fatal|msg" "$WORK/out" | head -2 | sed 's/^/           /'
fi
restore

echo
echo "── the health/ready ports, and the host they share ──"
# ⚠️ THE FIFTH dc1-arm-1/dc1-x86 FAILURE, AND THE FIRST CAUSED BY THIS
# REPOSITORY COLLIDING WITH ITSELF. CoreDNS's health endpoint was
# 127.0.0.1:8080; roles/keel publishes its web console on the same loopback
# port via docker-proxy; dc1-x86 runs BOTH roles. CoreDNS crash-looped 173
# times with "listen tcp 127.0.0.1:8080: bind: address already in use" and
# reported it as a timeout on 10.0.0.3:53 — a port that was never involved.
restore

# 1. The collision itself, restored.
edit 's{^coredns_health_address: "127\.0\.0\.1:8653"}{coredns_health_address: "127.0.0.1:8080"}' "$DEFAULTS"
expect_red dns-zone.yml "must not use Keel's web console port|web console" \
           "reusing Keel's console port for health is caught"

# 2. The same collision on the readiness endpoint.
restore
edit 's{^coredns_ready_address: "127\.0\.0\.1:8654"}{coredns_ready_address: "127.0.0.1:8080"}' "$DEFAULTS"
expect_red dns-zone.yml "must not use Keel's web console port|web console" \
           "reusing Keel's console port for readiness is caught"

# 3. Health and readiness on the SAME port — the second one to bind dies, and
#    CoreDNS dies before :53 either way.
restore
edit 's{^coredns_ready_address: "127\.0\.0\.1:8654"}{coredns_ready_address: "127.0.0.1:8653"}' "$DEFAULTS"
expect_red dns-zone.yml "same port as each other|must not use" \
           "health and readiness sharing one port is caught"

# 4. Health moved off loopback, exposing an HTTP endpoint to every LAN client.
restore
edit 's{^coredns_health_address: "127\.0\.0\.1:8653"}{coredns_health_address: "0.0.0.0:8653"}' "$DEFAULTS"
expect_red dns-zone.yml "must bind 127\.0\.0\.1|loopback" \
           "a health endpoint off loopback is caught"

# 5. The rescue deleted from the bind wait, so a bind failure once again
#    reports the wrong port and says nothing about why.
restore
perl -0pi -e 's{\n  rescue:\n(?:.*\n)*?          do not stop the other service to make room for this one\.\n}{\n}' "$VERIFY"
# Either guard may fire first and both are correct: removing the rescue also
# removes the rescue-only task that proves block expansion reaches it.
expect_red dns-task-shape.yml 'rescue that reads the service log|candidate block|Ask the service why|rescue-only task' \
           "deleting the bind-wait rescue is caught"

# 6. The block flattening removed from the shape suite, which would silently
#    stop checking every conditional inside a block.
restore
# ⚠️ LINE-BASED, NOT A SLURPED PATTERN. The first version used a multi-line
# `-0pi` regex that a scripted edit had mangled — the `+`, `|` and `(` lost
# their escapes and became regex metacharacters, so it matched nothing, the
# file was untouched, and the runner reported "still PASSED". Correct verdict
# for a mutation that never landed; a one-line delete cannot be mangled.
perl -ni -e "print unless /selectattr\(.rescue., .defined.\)/" "$SHAPE"
if ansible-playbook tests/dns-task-shape.yml >"$WORK/out" 2>&1; then
  bad "dropping rescue expansion is caught" "tests/dns-task-shape.yml still PASSED"
elif grep -qE 'did not reach the nested tasks|rescue-only task' "$WORK/out"; then
  ok "dropping rescue expansion is caught"
else
  bad "dropping rescue expansion is caught" "failed for another reason"
  grep -E "fatal|msg" "$WORK/out" | head -2 | sed 's/^/           /'
fi

restore

echo
echo "── the handler flush, the port seam, and the harnesses themselves ──"
# ⚠️ THE SIXTH DEFECT AND THE SEAM THAT MADE IT TESTABLE. Without the flush,
# Ansible runs the restart at the END of the play, so verify.yml interrogates
# the process still running the old configuration — observed on dc1-arm-1 as
# PID 35119 serving 8181 while the Corefile on disk said 8654.
restore

# 1. The regression itself: no flush at all.
perl -ni -e 'print unless /ansible\.builtin\.meta: flush_handlers/' "$MAIN_TASKS"
expect_red dns-task-shape.yml 'flush handlers exactly once|Found\s+flush at \[\]' \
           "removing the handler flush is caught"

# 2. Flushed, but AFTER verification — which prevents nothing.
restore
perl -0pi -e 's{(- name: Apply every pending restart.*?\n  ansible\.builtin\.meta: flush_handlers\n)}{}s;
              s{(- name: Verify it answers\n  ansible\.builtin\.include_tasks: verify\.yml\n)}{$1\n- name: Apply every pending restart BEFORE anything verifies the service\n  ansible.builtin.meta: flush_handlers\n}s' "$MAIN_TASKS"
expect_red dns-task-shape.yml 'BEFORE verify\.yml runs|Found\s+flush at' \
           "flushing AFTER verification is caught"

# 3. Flushed BEFORE the configuration is even written, so nothing is pending.
restore
perl -0pi -e 's{(- name: Apply every pending restart.*?\n  ansible\.builtin\.meta: flush_handlers\n)}{}s;
              s{(- name: Install the pinned binary\n)}{- name: Apply every pending restart BEFORE anything verifies the service\n  ansible.builtin.meta: flush_handlers\n\n$1}s' "$MAIN_TASKS"
expect_red dns-task-shape.yml 'AFTER the service is defined|Found\s+flush at' \
           "flushing before the configuration changes is caught"

# 4. The restart notification dropped from the Corefile template, so no
#    handler is ever pending and a config change never reaches the daemon.
restore
perl -0pi -e 's{(src: Corefile\.j2\n(?:.*\n)*?)  notify: Restart CoreDNS\n}{$1}' "$CONFIGURE"
expect_red dns-harness-integrity.yml 'notifies a restart|Corefile template must notify' \
           "dropping the Corefile restart notification is caught"

echo
echo "── the DNS port seam must not drift in production ──"
restore
edit 's{^coredns_dns_port: 53$}{coredns_dns_port: 5353}' "$DEFAULTS"
expect_red dns-zone.yml 'must be exactly 53|defaults to 53' \
           "changing the production DNS port default is caught"

restore
edit 's{^coredns_dns_port: 53$}{coredns_dns_port: 70000}' "$DEFAULTS"
expect_red dns-zone.yml 'must be exactly 53|defaults to 53' \
           "an out-of-range DNS port is caught"

restore
edit 's{^coredns_dns_port: 53$}{coredns_dns_port: 8653}' "$DEFAULTS"
expect_red dns-zone.yml 'must be exactly 53|defaults to 53|same port as each other' \
           "a DNS port colliding with the health port is caught"

restore
edit 's{^\{\{ coredns_zone \}\}:\{\{ coredns_dns_port \}\} \{$}{\{\{ coredns_zone \}\}:53 \{}' "$COREFILE"
expect_red dns-harness-integrity.yml 'hardcodes the DNS port|coredns_dns_port' \
           "one hardcoded :53 server block is caught"

echo
echo "── the verifier prerequisite the role now owns ──"
restore
perl -0pi -e 's{- name: Make sure this node can verify a resolver before it installs one\n(?:.*\n)*?  ansible\.builtin\.include_tasks: verifier-prereq\.yml\n}{}' "$MAIN_TASKS"
expect_red dns-harness-integrity.yml 'verifier-prereq|dig' \
           "removing dig ownership from the role is caught"

restore
# ⚠️ THE DEFECT THE FIRST NATIVE CI RUN FOUND. cache_valid_time compares a
# timestamp instead of asking whether the lists are usable, so a host whose
# lists were cleaned skips the refresh and cannot find the package.
perl -0pi -e 's{(    state: present\n    update_cache: true\n)}{$1    cache_valid_time: 3600\n}' "$PREREQ"
expect_red dns-task-shape.yml 'cache_valid_time|refreshed' \
           "re-adding cache_valid_time to the dig install is caught"

restore
perl -ni -e 'print unless /^    update_cache: true$/' "$PREREQ"
expect_red dns-task-shape.yml 'update_cache|refreshed' \
           "dropping update_cache from the dig install is caught"

echo
echo "── the disposable macOS harness must stay disposable ──"
restore
# A harness that pointed at the live prefix or label would destroy the very
# thing it is supposed to leave untouched.
perl -pi -e 's{^LABEL="org\.dc1\.corednsdisposable\$\{STAMP\}"$}{LABEL="org.coredns.coredns"}' "$LAUNCHD"
expect_red dns-harness-integrity.yml 'unique disposable label|org\.coredns\.coredns' \
           "a macOS harness reusing the LIVE launchd label is caught"

restore
perl -ni -e 'print unless /^trap teardown EXIT INT TERM$/' "$LAUNCHD"
expect_red dns-harness-integrity.yml 'teardown on success, failure and interrupt|trap' \
           "omitting the macOS teardown trap is caught"

restore
perl -ni -e 'print unless /the daemon was RESTARTED before verification/' "$LAUNCHD"
expect_red dns-harness-integrity.yml 'prove the pid changed|RESTARTED before verification' \
           "treating a still-running old PID as success is caught"

restore
perl -ni -e 'print unless /third run reported changed=0/' "$LAUNCHD"
expect_red dns-harness-integrity.yml 'changed=0|no-op' \
           "allowing second-run churn is caught"

echo
echo "── everything is restored ──"
restore
cp "$WORK/plist" "$PLIST"
cp "$WORK/unit" "$UNIT"
for s in dns-zone dns-services dns-inventory dns-install-platform dns-task-shape dns-harness-integrity; do
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
echo "forwarding loop, LAN-only access, both service definitions, the"
echo "macOS/Linux extraction split, the install directories, the handler"
echo "flush, the production DNS port, the role's ownership of dig, and the"
echo "disposable macOS harness's own safety properties are proved to"
echo "FAIL when broken, each for its own reason."
