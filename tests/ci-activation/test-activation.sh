#!/bin/bash
# Local tests for tools/ci-activation: hostcheck.sh (snapshot, verify, compare, probe verdicts) and
# provision-truewealth.sh (checkout verification, the before-record gate, exit-status propagation).
# No host, no sudo, no network: the libraries are sourced (HOSTCHECK_LIB=1 / PROVISION_LIB=1) and
# every host command is a stand-in. Run by tests/run-ci-runner-truewealth.sh §13.
#   bash tests/ci-activation/test-activation.sh
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd -P)"
HC="$REPO/tools/ci-activation/hostcheck.sh"
PROV="$REPO/tools/ci-activation/provision-truewealth.sh"
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  pass  $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL  $1"; echo "        $2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3] got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "output lacks [$3]";; esac; }

# shellcheck disable=SC1090
HOSTCHECK_LIB=1 . "$HC"

echo "── helpers"
eq "RC marker parsed"                "$(printf 'noise\nRC=124\n' | rc_of)" 124
eq "missing RC marker -> empty"      "$(printf 'lxc: error\n' | rc_of)" ""
eq "tcp 0 -> open"                   "$(tcp_outcome 0)" open
eq "tcp 124 -> timeout"              "$(tcp_outcome 124)" timeout
eq "tcp 1 -> fastfail"               "$(tcp_outcome 1)" fastfail
eq "tcp 127 (tool missing) -> error" "$(tcp_outcome 127)" error
eq "tcp no marker -> error"          "$(tcp_outcome '')" error
eq "icmp 1 -> timeout"               "$(icmp_outcome 1)" timeout
eq "icmp 2 -> error"                 "$(icmp_outcome 2)" error

echo "── classification (class guest host)"
eq "guest connects -> FAIL"                          "$(classify required open open)" FAIL
eq "guest connects to documented-absent -> FAIL"     "$(classify expected-absent open timeout)" FAIL
eq "guest timeout, host connects -> PASS"            "$(classify required timeout open)" PASS
eq "guest fast failure, host connects -> INCONCL."   "$(classify required fastfail open)" INCONCLUSIVE
eq "both unreachable, required -> INCONCLUSIVE"      "$(classify required timeout timeout)" INCONCLUSIVE
eq "both unreachable, documented absent -> EXP_UNAV" "$(classify expected-absent timeout fastfail)" EXPECTED_UNAVAILABLE
eq "documented absent but live, guest blocked -> PASS" "$(classify expected-absent timeout open)" PASS
eq "guest probe could not run -> INCONCLUSIVE"       "$(classify required error open)" INCONCLUSIVE
eq "host control could not run -> INCONCLUSIVE"      "$(classify required timeout error)" INCONCLUSIVE
eq "positive control connects -> PASS"               "$(positive_status open)" PASS
eq "positive control times out -> FAIL"              "$(positive_status timeout)" FAIL
eq "positive control could not run -> INCONCLUSIVE"  "$(positive_status error)" INCONCLUSIVE

echo "── policy inspection"
# nft's listed form: tab-indented, counters with values, blank line between chains.
raw=$(tw_table_expected | sed -E -e 's/(^|[[:space:]])counter /\1counter packets 17 bytes 1020 /' -e 's/^counter packets 17 bytes 1020 drop$/counter packets 3 bytes 180 drop/' \
      | awk '/^table/ || /^}$/ && !c {print; next} /^chain/ {c=1; print "\t" $0; next} /^}$/ {c=0; print "\t}"; print ""; next} {print "\t\t" $0}')
eq "live listing with counters and tabs == reviewed rendering" "$(printf '%s\n' "$raw" | normalize_nft | policy_verdict)" PASS
eq "a missing deny rule is detected" \
   "$(printf '%s\n' "$raw" | grep -v 'ip daddr 10.0.0.0/8' | normalize_nft | policy_verdict)" FAIL
eq "an added accept rule is detected" \
   "$(printf '%s\n%s\n' "$raw" '		iifname "citwbr0" accept' | normalize_nft | policy_verdict)" FAIL
eq "an absent table is FAIL" "$(printf '' | normalize_nft | policy_verdict)" FAIL

echo "── verdict aggregation (sections judged separately)"
run() { ( R_SEC=(); R_ST=(); R_MSG=(); eval "$1"; summarize ) 2>&1; }
ALLOK='rec readiness PASS r; rec keel PASS k; rec isolation PASS i'

out=$(run "$ALLOK"); rc=$?
eq "all sections pass -> exit 0" "$rc" 0; has "all pass -> RESULT: OK" "$out" "RESULT: OK"

out=$(run "$ALLOK; rec isolation INCONCLUSIVE 'Keel VM: address not found'"); rc=$?
eq "required INCONCLUSIVE -> exit 2" "$rc" 2
has "required INCONCLUSIVE -> isolation section INCONCLUSIVE" "$out" "TrueWealth isolation coverage  INCONCLUSIVE"
has "required INCONCLUSIVE -> readiness still OK"            "$out" "Infrastructure readiness       OK"
has "required INCONCLUSIVE -> named in summary"              "$out" "INCONCLUSIVE: Keel VM: address not found"

out=$(run "$ALLOK; rec isolation EXPECTED_UNAVAILABLE 'Postgres 10.0.0.3:5432'"); rc=$?
eq "documented-absent optional target -> exit 0" "$rc" 0
has "documented-absent -> counted separately" "$out" "1 pass, 0 fail, 0 inconclusive, 1 expected-unavailable"
has "documented-absent -> labelled not evidence" "$out" "EXPECTED_UNAVAILABLE (not isolation evidence): Postgres 10.0.0.3:5432"

out=$(run "rec readiness PASS r; rec keel PASS k; rec isolation EXPECTED_UNAVAILABLE x"); rc=$?
eq "only EXPECTED_UNAVAILABLE in a section establishes nothing -> exit 2" "$rc" 2

out=$(run "rec readiness PASS r; rec keel PASS k"); rc=$?
eq "a section with no checks -> exit 2" "$rc" 2

out=$(run "rec readiness PASS r; rec keel FAIL 'health 503'; rec isolation INCONCLUSIVE x; rec isolation PASS y"); rc=$?
eq "FAIL outranks INCONCLUSIVE -> exit 1" "$rc" 1
has "Keel FAIL reported in Keel section"          "$out" "Keel preservation              FAIL"
has "isolation stays INCONCLUSIVE, not merged"    "$out" "TrueWealth isolation coverage  INCONCLUSIVE"
has "readiness stays OK, not merged"              "$out" "Infrastructure readiness       OK"

out=$(run "$ALLOK; rec isolation \"\$(positive_status timeout)\" 'own resolver'"); rc=$?
eq "failed positive control -> exit 1" "$rc" 1

out=$(run "$ALLOK; rec evidence INFO 'counters +0'; rec readiness INFO 'unit inactive'"); rc=$?
eq "INFO lines never change the verdict" "$rc" 0

echo "── probe_target wiring (stand-in probes)"
GT=124; HT=0
CF=$(mktemp); echo 0 > "$CF"; trap 'rm -f "$CF"' EXIT
guest_tcp() { echo "$GT"; }; host_tcp() { echo "$HT"; }
guest_icmp() { echo "$GT"; }; host_icmp() { echo "$HT"; }
is_local() { [ "$1" = 10.0.0.3 ]; }
drop_packets() { local c; c=$(( $(cat "$CF") + 2 )); echo "$c" > "$CF"; echo "$c"; }   # runs in $(…): state in a file
# shellcheck disable=SC2034  # R_SEC is read by the sourced rec/summarize
pt() { ( R_SEC=(); R_ST=(); R_MSG=(); probe_target "$@" >/dev/null; echo "${R_ST[0]}|${R_MSG[0]}|${R_MSG[1]:-}" ); }
r=$(GT=124 HT=0 pt required tcp 10.0.0.3 443 "host Caddy")
has "blocked+host reachable -> PASS"                  "$r" "PASS|"
has "PASS wording is an observed outcome"             "$r" "observed: guest no response within 4 s; host connected"
has "counter evidence is labelled supporting, chain input" "$r" "input drop rules +2 packets during the guest attempt (shared; supporting only)"
r=$(GT=124 HT=124 pt expected-absent tcp 10.0.0.3 5432 "Postgres")
has "documented absent, unreachable -> EXPECTED_UNAVAILABLE" "$r" "EXPECTED_UNAVAILABLE|"
r=$(GT=124 HT=124 pt required tcp 10.0.0.22 22 "admin sshd")
has "required target not answering from host -> INCONCLUSIVE" "$r" "INCONCLUSIVE|"
r=$(GT=0 HT=0 pt required tcp 10.0.0.22 22 "admin sshd")
has "guest connects -> FAIL" "$r" "FAIL|"
r=$(GT=127 HT=0 pt required tcp 10.0.0.22 22 "admin sshd")
has "guest tool missing (rc 127) -> INCONCLUSIVE" "$r" "INCONCLUSIVE|"
r=$(GT='' HT=0 pt required tcp 10.0.0.22 22 "admin sshd")
has "lxc exec failed (no marker) -> INCONCLUSIVE" "$r" "INCONCLUSIVE|"
r=$(pt required icmp "" "" "Keel VM")
has "missing address -> INCONCLUSIVE, not skipped" "$r" "INCONCLUSIVE|Keel VM: address not found"
r=$(GT=1 HT=0 pt required icmp 10.71.0.50 "" "Keel VM")
has "ICMP no reply, host reply -> PASS on forward chain" "$r" "forward drop rules"

echo "── more pure helpers"
eq "is-enabled 'enabled' -> PASS"              "$(enabled_status enabled)" PASS
eq "is-enabled 'disabled' -> FAIL"             "$(enabled_status disabled)" FAIL
eq "is-enabled unreadable -> INCONCLUSIVE"     "$(enabled_status '')" INCONCLUSIVE
eq "clean VM config -> no findings" "$(printf 'config:\n  limits.cpu: "4"\ndevices:\n  root:\n    path: /\n    pool: ci-tw-pool\n    type: disk\n' | vm_config_findings)" ""
has "host path disk -> finding" "$(printf 'devices:\n  d:\n    source: /srv/data\n    type: disk\n' | vm_config_findings)" "host path source"
has "passthrough -> finding"    "$(printf 'devices:\n  g:\n    type: gpu\n' | vm_config_findings)" "passthrough device"
has "raw override -> finding"   "$(printf 'config:\n  raw.qemu: -device foo\n' | vm_config_findings)" "raw.* hypervisor"

# ═══ end-to-end with stand-ins: the real snapshot / verify / compare / probe / provision gate ═══
# Every host command (sudo, nft, iptables(-save), systemctl, lxc, docker, curl, …) is a stub whose
# behaviour is set by STUB_* variables; HOME is a throwaway directory. Nothing touches this Mac's
# firewall, containers or network.
T=$(mktemp -d); trap 'rm -f "$CF"; rm -rf "$T"' EXIT
SHA=455c088bd750791faccb1e94ff2af52c8fe78ac2
mkdir -p "$T/bin" "$T/teefail"
tw_table_expected | sed -E -e 's/(^|[[:space:]])counter /\1counter packets 9 bytes 540 /' > "$T/tw-listed.txt"
cat > "$T/bin/stub" <<'STUB'
#!/bin/bash
# Stand-in for host commands. STUB_PHASE=before|after; STUB_FAIL_NFT, STUB_FAIL_IPT_S, STUB_UNHEALTHY,
# STUB_FAIL_LXC_CONFIG, STUB_FAIL_LXC_TYPE, STUB_GUEST_TOOLQ_FAIL, STUB_KEEL_CHANGED inject faults.
name=$(basename "$0"); a="$*"; ph=${STUB_PHASE:-before}
after() { [ "$ph" = after ]; }
keel() { printf 'table inet ci_egress {\n\tchain forward {\n\t\ttype filter hook forward priority filter - 10; policy accept;\n'
         printf '\t\tiifname "lxdbr0" ip daddr 10.0.0.0/8 counter%s drop\n' "$1"
         [ -n "${STUB_KEEL_CHANGED:-}" ] && after && printf '\t\tiifname "lxdbr0" accept\n'
         printf '\t}\n}\n'; }
case "$name" in
  sudo) [ "${1:-}" = -v ] && exit 0; exec "$@";;
  nft)
    [ -n "${STUB_FAIL_NFT:-}" ] && { echo "Error: Could not process rule: Operation not permitted" >&2; exit 1; }
    case "$a" in
      "-s list table inet ci_egress") keel "";;
      "list table inet ci_egress") keel " packets 4 bytes 240";;
      "-s list ruleset") printf '# Warning: table ip filter is managed by iptables-nft, do not touch!\ntable ip filter {\n\tchain DOCKER-USER {\n\t}\n}\n'
                         keel ""; printf 'table inet lxd {\n\tchain fwd.lxdbr0 {\n\t\tiifname "lxdbr0" accept\n\t}\n}\n'
                         printf 'table inet tailscale-extra {\n\tchain x {\n\t}\n}\n'
                         after && printf 'table inet ci_egress_tw {\n\tchain input {\n\t}\n}\n'; exit 0;;
      "-s list table inet lxd") printf 'table inet lxd {\n\tchain fwd.lxdbr0 {\n\t\tiifname "lxdbr0" accept\n\t}\n'
                                after && printf '\tchain fwd.citwbr0 {\n\t\tiifname "citwbr0" accept\n\t}\n'; printf '}\n';;
      "list table inet ci_egress_tw") after && cat "$STUB_DIR/tw-listed.txt" && exit 0; echo "Error: No such file or directory" >&2; exit 1;;
      "list chain inet ci_egress_tw input"|"list chain inet ci_egress_tw forward") after && printf '\t\tcounter packets 7 bytes 420 drop\n';;
      *) echo "stub nft: unhandled [$a]" >&2; exit 99;;
    esac;;
  iptables-save)
    if [ "$a" = "-t nat" ]; then
      printf '*nat\n:POSTROUTING ACCEPT [%s]\n-A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE\n' "$(after && echo 99:999 || echo 1:2)"
      after && printf -- '-A POSTROUTING -s 10.72.0.0/24 ! -o citwbr0 -j MASQUERADE\n'; printf 'COMMIT\n'
    else
      printf '*filter\n:INPUT ACCEPT [%s]\n:FORWARD DROP [0:0]\n:DOCKER-USER - [0:0]\n:ts-input - [0:0]\n' "$(after && echo 99:999 || echo 1:2)"
      after && printf -- '-A DOCKER-USER -o citwbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n-A DOCKER-USER -i citwbr0 -j ACCEPT\n'
      printf -- '-A DOCKER-USER -o lxdbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n-A DOCKER-USER -i lxdbr0 -j ACCEPT\n-A DOCKER-USER -j RETURN\nCOMMIT\n'
    fi;;
  iptables)
    [ "$a" = "-S DOCKER-USER" ] || { echo "stub iptables: unhandled [$a]" >&2; exit 99; }
    [ -n "${STUB_FAIL_IPT_S:-}" ] && { echo "iptables: Permission denied" >&2; exit 4; }
    printf -- '-N DOCKER-USER\n'
    after && printf -- '-A DOCKER-USER -o citwbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n-A DOCKER-USER -i citwbr0 -j ACCEPT\n'
    printf -- '-A DOCKER-USER -o lxdbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n-A DOCKER-USER -i lxdbr0 -j ACCEPT\n-A DOCKER-USER -j RETURN\n';;
  systemctl)
    case "$1" in is-enabled) echo enabled;;
      is-active) case "$2" in docker|caddy|snap.lxd.daemon) echo active;; *) echo inactive; exit 3;; esac;; esac;;
  lxc)
    if [ "$1" = exec ]; then
      shift 4; g="$*"
      case "$g" in
        "sh -c echo __ALIVE__") echo __ALIVE__;;
        *MISSING=*) [ -n "${STUB_GUEST_TOOLQ_FAIL:-}" ] && { echo "Error: websocket: close 1006" >&2; exit 1; }; echo "MISSING=";;
        */dev/tcp/*) ip=$(eval echo "\${$(($# - 1))}"); port=$(eval echo "\${$#}")
                     if [ "$ip:$port" = 10.72.0.1:53 ]; then echo RC=0; else echo RC=124; fi;;
        *ping*) echo RC=1;;
        *curl*) echo RC=0;;
        *"ip -6"*) echo __OK__;;
        */srv/data*) echo ABSENT;;
        *"docker ps"*) echo __OK__;;
        "id -nG ghrunner") echo "ghrunner docker";;
        *) echo "stub lxc exec: unhandled [$g]" >&2; exit 99;;
      esac; exit 0
    fi
    case "$a" in
      "config show dc1-ci-1 --expanded") printf 'architecture: x86_64\nconfig:\n  limits.cpu: "8"\n  volatile.last_state.power: %s\ndevices:\n  root:\n    path: /\n    pool: ci-pool\n    type: disk\n' "$(after && echo RUNNING || echo STOPPED)";;
      "network show lxdbr0") printf 'config:\n  ipv4.address: 10.71.0.1/24\nname: lxdbr0\ntype: bridge\n';;
      "list --format csv -c ns4") printf 'dc1-ci-1,RUNNING,10.71.0.50 (enp5s0)\n'; after && printf 'dc1-ci-tw-1,RUNNING,10.72.0.50 (enp5s0)\n'; exit 0;;
      "list ^dc1-ci-tw-1$ -c s --format csv") after && echo RUNNING; exit 0;;
      "list ^dc1-ci-tw-1$ -c t --format csv") [ -n "${STUB_FAIL_LXC_TYPE:-}" ] && { echo "Error: not authorized" >&2; exit 1; }; echo VIRTUAL-MACHINE;;
      "config show dc1-ci-tw-1 --expanded") [ -n "${STUB_FAIL_LXC_CONFIG:-}" ] && { echo "Error: Instance not found" >&2; exit 1; }
                                            printf 'config:\n  limits.cpu: "4"\n  limits.memory: 6GiB\ndevices:\n  eth0:\n    network: citwbr0\n    type: nic\n  root:\n    path: /\n    pool: ci-tw-pool\n    type: disk\n';;
      "list ^dc1-ci-1$ -c s --format csv") echo RUNNING;;
      "list ^dc1-ci-1$ --format csv -c 4") echo "10.71.0.50 (enp5s0)";;
      "network get citwbr0 ipv6.address") echo none;;
      "network get citwbr0 ipv4.address") echo 10.72.0.1/24;;
      "config get dc1-ci-tw-1 limits.cpu") echo 4;;
      "config get dc1-ci-tw-1 limits.memory") echo 6GiB;;
      *) echo "stub lxc: unhandled [$a]" >&2; exit 99;;
    esac;;
  docker)
    case "$a" in
      inspect*) c=${!#}; if [ "$c" = keel-lab-db ] && [ -n "${STUB_UNHEALTHY:-}" ]; then echo "/$c restarts=0 running unhealthy"; else echo "/$c restarts=0 running healthy"; fi;;
      *Image*) printf 'keel-lab-api keel/api:1 keel\nkeel-lab-db postgres:16 keel\n';;
      *Status*) echo "keel-lab-api Up 2 days (healthy)"
                if [ -n "${STUB_UNHEALTHY:-}" ]; then echo "keel-lab-db Up 2 days (unhealthy)"; else echo "keel-lab-db Up 2 days (healthy)"; fi;;
      stats*) echo "keel-lab-api 1.00% 100MiB / 27GiB";;
      *) echo "stub docker: unhandled [$a]" >&2; exit 99;;
    esac;;
  curl) printf '%s' "${STUB_CURL_CODE:-200}";;
  free) echo "Mem: 27000 9000";;
  vgs|lvs) echo "ubuntu-vg $(after && echo 24.68g || echo 74.68g)";;
  ip) [ "$a" = "-4 -o addr show dev tailscale0" ] && echo "7: tailscale0    inet 100.79.95.22/32 scope global tailscale0";;
  timeout|ping) exit 0;;
  tee) cat >/dev/null; echo "tee: write error: No space left on device" >&2; exit 1;;
  *) echo "stub: unknown command $name" >&2; exit 99;;
esac
STUB
chmod +x "$T/bin/stub"
for c in sudo nft iptables-save iptables systemctl lxc docker curl free vgs lvs ip timeout ping; do ln -s stub "$T/bin/$c"; done
ln -s ../bin/stub "$T/teefail/tee"
cat > "$T/probe-run.sh" <<'RUN'
HOSTCHECK_LIB=1 . "$1"
host_tcp() { if [ "$2" = 5432 ]; then echo 124; else echo 0; fi; }   # PostgreSQL is not on the LAN
host_icmp() { echo 0; }
is_local() { case "$1" in 10.0.0.3|10.72.0.1|10.71.0.1|172.17.0.1|100.79.95.22) return 0;; esac; return 1; }
probe "$2"
RUN
cat > "$T/gate-run.sh" <<'RUN'
PROVISION_LIB=1 . "$1"
rsh() { local c=${1//\~/$HOME}; case "$c" in sha256sum*) shasum -a 256 ${c#sha256sum };; *) eval "$c";; esac; }
require_before_record "$2" "$3"
echo "GATE PASSED $BEFORE_DIR"
RUN
# The stand-in dc1-x86 home holds a staged copy of hostcheck.sh, as the runbook's staging step leaves it.
newhome() { H="$T/home$1"; mkdir -p "$H/ci-shared-check"; cp "$HC" "$H/ci-shared-check/hostcheck.sh"; }
hc() { HOME="$H" PATH="$T/bin:$PATH" STUB_DIR="$T" "$BASH" "$HC" "$@" 2>&1; }
probe_run() { HOME="$H" PATH="$T/bin:$PATH" STUB_DIR="$T" STUB_PHASE=after "$BASH" "$T/probe-run.sh" "$HC" "$SHA" 2>&1; }
gate() { HOME="$H" PATH="$T/bin:$PATH" STUB_DIR="$T" "$BASH" "$T/gate-run.sh" "$PROV" "$HC" "$SHA" 2>&1; }
newest() { ls -1d "$H/ci-shared-check/$1"-2* 2>/dev/null | sort | tail -n 1; }

echo "── E1 complete successful path"
newhome 1
out=$(STUB_PHASE=before hc snapshot before "$SHA"); rc=$?
eq "snapshot before exits 0" "$rc" 0; has "snapshot before: RESULT OK" "$out" "RESULT: OK — completion record"
B=$(newest before); [ -f "$B/COMPLETE" ] && ok "completion record written" || bad "completion record written" "none in $B"
has "record binds the SHA" "$(cat "$B/COMPLETE" 2>/dev/null)" "infra_sha $SHA"
has "record binds the snapshot identity" "$(cat "$B/COMPLETE" 2>/dev/null)" "snapshot $(basename "$B")"
has "record binds evidence hashes" "$(cat "$B/COMPLETE" 2>/dev/null)" "stable/keel-health.txt"
out=$(hc verify before "$SHA" 120); rc=$?; eq "verify before exits 0" "$rc" 0; has "verify prints VERIFIED" "$out" "VERIFIED $B"
out=$(gate); rc=$?; eq "provision gate passes on a valid record" "$rc" 0; has "gate names the snapshot" "$out" "GATE PASSED $B"
sleep 1
out=$(STUB_PHASE=after hc snapshot after-provision "$SHA"); rc=$?; eq "snapshot after-provision exits 0" "$rc" 0
out=$(hc compare "$SHA"); rc=$?; eq "compare exits 0" "$rc" 0; has "compare: no regression" "$out" "RESULT: OK — no regression"
has "compare: citwbr0 rules exactly once" "$out" "PASS exactly once: -A DOCKER-USER -i citwbr0 -j ACCEPT"
out=$(probe_run); rc=$?; eq "probe exits 0" "$rc" 0; has "probe RESULT OK" "$out" "RESULT: OK"
has "probe: three sections OK" "$out" "TrueWealth isolation coverage  OK"
has "probe: VM type from a successful query" "$out" "is a virtual machine"
has "probe: config described as configuration evidence" "$out" "configuration evidence, not a test of the hypervisor"
has "probe: PostgreSQL documented absent, not evidence" "$out" "EXPECTED_UNAVAILABLE (not isolation evidence)"
P=$(newest probe); has "probe log complete (RESULT line written)" "$(cat "$P/probe.txt" 2>/dev/null)" "RESULT: OK"
sleep 1; out=$(STUB_PHASE=after STUB_KEEL_CHANGED=1 hc snapshot after-provision "$SHA"); out=$(hc compare "$SHA"); rc=$?
eq "a changed Keel table is a regression" "$rc" 1

echo "── E2 collector failure (reviewer reproduction: every nft read fails)"
newhome 2
out=$(STUB_PHASE=before STUB_FAIL_NFT=1 hc snapshot before "$SHA"); rc=$?
eq "snapshot before exits nonzero" "$rc" 1; has "snapshot before: INCOMPLETE" "$out" "RESULT: INCOMPLETE"
case "$out" in *"RESULT: OK"*) bad "snapshot before never says OK" "$out";; *) ok "snapshot before never says OK";; esac
B=$(newest before); [ ! -e "$B/COMPLETE" ] && ok "no completion record" || bad "no completion record" "found $B/COMPLETE"
has "diagnostics preserved in errors/" "$(cat "$B"/errors/raw_nft-keel.txt.err 2>/dev/null)" "Operation not permitted"
sleep 1
out=$(STUB_PHASE=after STUB_FAIL_NFT=1 hc snapshot after-provision "$SHA"); rc=$?; eq "snapshot after-provision exits nonzero" "$rc" 1
out=$(hc compare "$SHA"); rc=$?; eq "compare exits nonzero" "$rc" 1
case "$out" in *"no regression"*) bad "compare never reports no regression" "$out";; *) ok "compare never reports no regression";; esac
has "compare names the missing record" "$out" "no completion record"
out=$(hc verify before "$SHA" 120); rc=$?; eq "verify before exits nonzero" "$rc" 1
out=$(gate); rc=$?; eq "provision gate refuses" "$rc" 1; has "gate says why" "$out" "no valid completion record"

echo "── E3 partial snapshots and damaged records"
newhome 3
STUB_PHASE=before hc snapshot before "$SHA" >/dev/null; B=$(newest before)
mv "$B/COMPLETE" "$B/COMPLETE.kept"
out=$(hc verify before "$SHA" 120); rc=$?; eq "record removed -> verify fails" "$rc" 1
has "fresh snapshot with 5 x HTTP 200 still refused" "$(grep -c ' 200$' "$B/stable/keel-health.txt")" 5
out=$(gate); rc=$?; eq "provision gate refuses a fresh 5x200 snapshot without a record" "$rc" 1
sed '$d' "$B/COMPLETE.kept" > "$B/COMPLETE"
out=$(hc verify before "$SHA" 120); rc=$?; eq "truncated record -> verify fails" "$rc" 1; has "truncation named" "$out" "record truncated"
cp "$B/COMPLETE.kept" "$B/COMPLETE"; echo "-A INPUT -j ACCEPT" >> "$B/stable/iptables.txt"
out=$(hc verify before "$SHA" 120); rc=$?; eq "evidence changed after completion -> fails" "$rc" 1; has "changed file named" "$out" "evidence changed after completion: stable/iptables.txt"
rm "$B/stable/keel-state.txt"
out=$(hc verify before "$SHA" 120); rc=$?; eq "evidence file missing -> fails" "$rc" 1
newhome 4
STUB_PHASE=before hc snapshot before "$SHA" >/dev/null; B=$(newest before)
out=$(hc verify before 0000000000000000000000000000000000000000 120); rc=$?; eq "another SHA -> fails" "$rc" 1
out=$(hc verify after-provision "$SHA"); rc=$?; eq "wrong phase (none taken) -> fails" "$rc" 1
sed -i.bak 's/^created_epoch .*/created_epoch 1000000000/' "$B/COMPLETE"
out=$(hc verify before "$SHA" 120); rc=$?; eq "stale record -> fails with max age" "$rc" 1; has "age named" "$out" "older than 120 minutes"
cp "$B/COMPLETE.bak" "$B/COMPLETE"; sleep 1
STUB_PHASE=before STUB_FAIL_NFT=1 hc snapshot before "$SHA" >/dev/null
out=$(hc verify before "$SHA" 120); rc=$?; eq "newest snapshot incomplete, older valid one NOT used instead" "$rc" 1

echo "── E4 container health failure despite five HTTP 200s"
newhome 5
out=$(STUB_PHASE=before STUB_UNHEALTHY=1 hc snapshot before "$SHA"); rc=$?
eq "snapshot exits nonzero" "$rc" 1; has "unhealthy container named" "$out" "not running or not healthy: /keel-lab-db restarts=0 running unhealthy"
B=$(newest before); eq "all five endpoints were 200" "$(grep -c ' 200$' "$B/stable/keel-health.txt")" 5
[ ! -e "$B/COMPLETE" ] && ok "no completion record" || bad "no completion record" "found"
out=$(STUB_UNHEALTHY=1 probe_run); rc=$?; eq "probe with an unhealthy Keel container -> FAIL (1)" "$rc" 1
has "probe names it in Keel preservation" "$out" "a keel-lab container is not healthy"

echo "── E5 failed configuration queries never become PASS"
newhome 6
out=$(STUB_FAIL_LXC_CONFIG=1 probe_run); rc=$?; eq "config query fails -> exit 2" "$rc" 2
has "config query failure is INCONCLUSIVE" "$out" "configuration query failed; host-path, passthrough and raw-override checks could not run"
case "$out" in *"configuration shows no host-path"*) bad "no config PASS" "$out";; *) ok "no config PASS";; esac
out=$(STUB_FAIL_LXC_TYPE=1 probe_run); rc=$?; eq "type query fails -> exit 2" "$rc" 2; has "type INCONCLUSIVE" "$out" "type query failed"
out=$(STUB_GUEST_TOOLQ_FAIL=1 probe_run); rc=$?; eq "guest tool query fails -> exit 2" "$rc" 2
has "tool query failure named" "$out" "guest tool query failed"
case "$out" in *"PASS                  Docker is installed"*) bad "no Docker PASS" "$out";; *) ok "no Docker PASS";; esac
out=$(STUB_FAIL_IPT_S=1 probe_run); rc=$?; eq "DOCKER-USER unreadable -> exit 2" "$rc" 2; has "rules INCONCLUSIVE" "$out" "DOCKER-USER could not be read"

echo "── E6 evidence log failure"
newhome 7
out=$(HOME="$H" PATH="$T/teefail:$T/bin:$PATH" STUB_DIR="$T" STUB_PHASE=after "$BASH" "$T/probe-run.sh" "$HC" "$SHA" 2>&1); rc=$?
eq "tee failure -> exit 3" "$rc" 3; has "log failure named" "$out" "RESULT: LOG FAILURE"

echo "── E7 the provision gate uses the checkout's own hostcheck.sh"
newhome 8
STUB_PHASE=before hc snapshot before "$SHA" >/dev/null
out=$(gate); rc=$?; eq "staged copy identical -> gate passes" "$rc" 0
echo "# drift" >> "$H/ci-shared-check/hostcheck.sh"
out=$(gate); rc=$?; eq "staged copy differs from the checkout's -> gate refuses" "$rc" 1
has "gate names the mismatch" "$out" "is not this checkout's"
rm "$H/ci-shared-check/hostcheck.sh"
out=$(gate); rc=$?; eq "nothing staged -> gate refuses" "$rc" 1

echo "── W1 checkout verification (throwaway clones of this repository; no network)"
# verify_checkout exits through die, so each case runs in a subshell and reports its exit status.
# shellcheck disable=SC1090,SC2034  # PROVISION_LIB is read by the sourced wrapper
vc() { ( PROVISION_LIB=1; . "$PROV"; verify_checkout "$1" "$2" ) 2>&1; }
gitc() { git -C "$CL" -c user.name=test -c user.email=test@example.invalid "$@"; }
HEADSHA=$(git -C "$REPO" rev-parse HEAD)
CL="$T/clone"
GIT_NO_LAZY_FETCH=1 git clone --quiet --no-checkout "$REPO" "$CL" && git -C "$CL" checkout --quiet --detach "$HEADSHA"
CL=$(cd "$CL" && pwd -P)
out=$(vc "$CL" "$HEADSHA"); rc=$?; eq "exact, clean checkout with the checked implementation -> accepted" "$rc" 0
out=$(vc "$CL" "$(git -C "$CL" rev-parse HEAD^)"); rc=$?; eq "SHA other than HEAD -> refused" "$rc" 1; has "HEAD mismatch named" "$out" "checkout HEAD is"
out=$(vc "$CL" "${HEADSHA:0:12}"); rc=$?; eq "abbreviated SHA -> refused" "$rc" 1
touch "$CL/stray.txt"; out=$(vc "$CL" "$HEADSHA"); rc=$?; eq "untracked file -> refused" "$rc" 1; rm "$CL/stray.txt"
touch "$CL/inventory/group_vars/linux_servers/vault.yml"; out=$(vc "$CL" "$HEADSHA"); rc=$?
eq "ignored vault file present -> refused" "$rc" 1; has "vault named" "$out" "vault file"; rm "$CL/inventory/group_vars/linux_servers/vault.yml"
out=$(vc "$CL/roles" "$HEADSHA"); rc=$?; eq "not the top of the checkout -> refused" "$rc" 1
echo "doc" >> "$CL/roles/ci_runner/README.md"; gitc commit --quiet -am "doc only"; D1=$(git -C "$CL" rev-parse HEAD)
out=$(vc "$CL" "$D1"); rc=$?; eq "role README-only change -> accepted (documentation)" "$rc" 0
sed -i.bak 's/^ci_lv_size: 50g/ci_lv_size: 60g/' "$CL/playbooks/vars/ci-runner-truewealth.yml" && rm "$CL/playbooks/vars/ci-runner-truewealth.yml.bak"
gitc commit --quiet -am "allocation change"; D2=$(git -C "$CL" rev-parse HEAD)
out=$(vc "$CL" "$D2"); rc=$?; eq "allocation changed -> refused" "$rc" 1; has "changed path named" "$out" "playbooks/vars/ci-runner-truewealth.yml"
gitc checkout --quiet --detach "$D1"; echo "# x" >> "$CL/roles/ci_runner/templates/ci-egress.nft.j2"
gitc commit --quiet -am "policy change"; D3=$(git -C "$CL" rev-parse HEAD)
out=$(vc "$CL" "$D3"); rc=$?; eq "firewall policy template changed -> refused" "$rc" 1; has "template named" "$out" "roles/ci_runner/templates/ci-egress.nft.j2"
gitc checkout --quiet --orphan unrelated; gitc commit --quiet -m "same files, no history"; D4=$(git -C "$CL" rev-parse HEAD)
out=$(vc "$CL" "$D4"); rc=$?; eq "commit not descending from the checked revision -> refused" "$rc" 1

echo "── W2 provisioning exit status (the wrapper's own pipeline, stand-in ansible-playbook)"
# The exact lines from `set +e` to `exit "$rc"`; only </dev/tty is replaced (no terminal here).
sed -n '/^set +e$/,/^exit "\$rc"$/p' "$PROV" | sed 's#</dev/tty#</dev/null#' > "$T/apply.sh"
mkdir -p "$T/ap"; printf '#!/bin/bash\necho "stub ansible-playbook $*"\nexit "${STUB_RC:-0}"\n' > "$T/ap/ansible-playbook"; chmod +x "$T/ap/ansible-playbook"
ap() { ( PATH="$T/ap:$PATH" STUB_RC=$1 ROOT="$T" C="$SHA" KEY=/nonexistent LOG="$2" BEFORE_DIR=x \
         SSH_STRICT="-o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o IdentitiesOnly=yes" \
         "$BASH" -c 'set -euo pipefail; . "$0"' "$T/apply.sh" ) >/dev/null 2>&1; }
mkdir -p "$T/logs"
ap 0 "$T/logs/a.log"; eq "ansible 0, tee 0 -> 0" "$?" 0
ap 2 "$T/logs/b.log"; eq "ansible 2 (failed task) -> 2" "$?" 2
ap 4 "$T/logs/c.log"; eq "ansible 4 (unreachable) -> 4" "$?" 4
ap 0 "$T/nodir/d.log"; eq "tee cannot write the log -> 1" "$?" 1
ap 2 "$T/nodir/e.log"; eq "both fail -> ansible's status first" "$?" 2
args=$(cat "$T/logs/a.log")
for want in '-i inventory/hosts.yml playbooks/ci-runner-truewealth.yml' '--limit dc1-x86' '--diff --ask-become-pass' \
            '--ssh-extra-args=-o StrictHostKeyChecking=yes -o UpdateHostKeys=no -o IdentitiesOnly=yes' '-e ci_tw_host_lan_ip=10.0.0.3'; do
  has "provisioning argument: $want" "$args" "$want"
done
case "$args" in *--check*) bad "no --check in provisioning" "$args";; *) ok "no --check in provisioning";; esac
case "$args" in *--tags*|*register*) bad "no registration in provisioning" "$args";; *) ok "no registration in provisioning";; esac
eq "log mode 600" "$(stat -f '%Lp' "$T/logs/a.log" 2>/dev/null || stat -c '%a' "$T/logs/a.log")" 600

echo
echo "── $pass passed, $fail failed ──"
[ "$fail" -eq 0 ]
