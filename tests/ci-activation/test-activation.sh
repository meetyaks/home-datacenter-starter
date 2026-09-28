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
# Every destination leaves the stand-in guest through enp5s0 here; R1/R2 cover the other routes.
# shellcheck disable=SC2034  # read by the sourced probe_target
GUEST_EXTIF=enp5s0
guest_route() { printf '%s via 10.72.0.1 dev enp5s0 src 10.72.0.226 uid 0\nRC=0\n' "$1"; }
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
        # The guest's routes, as observed live: its own docker0 holds 172.17.0.1 (a local route).
        # STUB_NO_DEFAULT, STUB_ROUTE_FAIL and STUB_OVERLAP_18 (the guest also has 172.18/16) vary them.
        *"ip -4 route show default"*) [ -n "${STUB_NO_DEFAULT:-}" ] || echo "default via 10.72.0.1 dev enp5s0 proto dhcp src 10.72.0.226 metric 100";;
        *"ip -4 route get"*) ip=${!#}
          if [ -n "${STUB_ROUTE_FAIL:-}" ]; then echo "RTNETLINK answers: Operation not permitted"; echo RC=2
          elif [ "$ip" = 172.17.0.1 ]; then echo "local 172.17.0.1 dev lo table local src 172.17.0.1 uid 0"; echo RC=0
          elif [ "$ip" = 172.18.0.1 ] && [ -n "${STUB_OVERLAP_18:-}" ]; then echo "172.18.0.1 dev br-0badc0ffee src 172.18.0.1 uid 0"; echo RC=0
          elif [ "$ip" = 10.72.0.1 ]; then echo "10.72.0.1 dev enp5s0 src 10.72.0.226 uid 0"; echo RC=0
          else echo "$ip via 10.72.0.1 dev enp5s0 src 10.72.0.226 uid 0"; echo RC=0; fi;;
        *MISSING=*) [ -n "${STUB_GUEST_TOOLQ_FAIL:-}" ] && { echo "Error: websocket: close 1006" >&2; exit 1; }; echo "MISSING=";;
        */dev/tcp/*) ip=$(eval echo "\${$(($# - 1))}"); port=$(eval echo "\${$#}")
                     # the guest's own resolver answers; so does its OWN docker0 address (a guest-local
                     # listener) — which must never be probed as a host target; STUB_ALT_OPEN lets the
                     # guest reach the host bridge 172.18.0.1 (forbidden connectivity)
                     if [ "$ip:$port" = 10.72.0.1:53 ]; then echo RC=0
                     elif [ "$ip" = 172.17.0.1 ]; then echo "RC=${STUB_GUEST_DOCKER0_RC:-0}"
                     elif [ "$ip" = 172.18.0.1 ] && [ -n "${STUB_ALT_OPEN:-}" ]; then echo RC=0
                     else echo RC=124; fi;;
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
      # The host's bridge networks: the default bridge (docker0, 172.17.0.1) and Keel's compose
      # network (no bridge-name option, 172.18.0.1). STUB_NET_FAIL / STUB_NO_ALT vary them.
      "network ls --filter driver=bridge --format {{.ID}}") [ -n "${STUB_NET_FAIL:-}" ] && { echo "permission denied" >&2; exit 1; }
                                                            echo aaa111bbb222ccc; [ -n "${STUB_NO_ALT:-}" ] || echo ddd333eee444fff;;
      "network inspect"*) [ -n "${STUB_NET_FAIL:-}" ] && exit 1
                          echo "aaa111bbb222ccc|bridge|docker0|172.17.0.1 "
                          [ -n "${STUB_NO_ALT:-}" ] || echo "ddd333eee444fff|keel-lab_default|<no value>|$([ -n "${STUB_NO_GW:-}" ] || echo "172.18.0.1 ")";;
      # The nine containers of Keel's Compose file: postgres, nats, temporal, minio and gateway
      # (long-running, health-checked), runtime-worker and web (long-running, no health check),
      # bootstrap and minio-bucket (one-shots). STUB_MISSING (names to omit), STUB_EXTRA (a name
      # to add), STUB_UNHEALTHY, STUB_LONGRUN_EXITED, STUB_BOOTSTRAP_EXIT, STUB_BOOTSTRAP_OOM,
      # STUB_BOOTSTRAP_STATUS, STUB_NO_BOOTSTRAP and STUB_INSPECT_FAIL inject faults.
      inspect*) c=${!#}
        if [ -n "${STUB_INSPECT_FAIL:-}" ] && [ "$c" = keel-lab-minio-bucket ]; then echo "Error: No such object: $c" >&2; exit 1; fi
        case "$c" in
          keel-lab-bootstrap) echo "/$c restarts=0 status=${STUB_BOOTSTRAP_STATUS:-exited} exit=${STUB_BOOTSTRAP_EXIT:-0} oom=${STUB_BOOTSTRAP_OOM:-false} health=none";;
          keel-lab-minio-bucket) echo "/$c restarts=0 status=exited exit=0 oom=false health=none";;
          keel-lab-gateway) if [ -n "${STUB_LONGRUN_EXITED:-}" ]; then echo "/$c restarts=0 status=exited exit=0 oom=false health=none"
                            else echo "/$c restarts=0 status=running exit=0 oom=false health=healthy"; fi;;
          keel-lab-postgres) echo "/$c restarts=0 status=running exit=0 oom=false health=$([ -n "${STUB_UNHEALTHY:-}" ] && echo unhealthy || echo healthy)";;
          keel-lab-nats|keel-lab-temporal|keel-lab-minio) echo "/$c restarts=0 status=running exit=0 oom=false health=healthy";;
          *) echo "/$c restarts=0 status=running exit=0 oom=false health=none";;
        esac;;
      *Image*|*Names*)
        for c in postgres nats temporal minio minio-bucket bootstrap gateway runtime-worker web ${STUB_EXTRA:-}; do
          case "$c" in keel-lab-*) ;; *) c=keel-lab-$c;; esac
          case " ${STUB_MISSING:-} " in *" $c "*) continue;; esac
          [ "$c" = keel-lab-bootstrap ] && [ -n "${STUB_NO_BOOTSTRAP:-}" ] && continue
          case "$a" in *Image*) echo "$c image:1 keel";; *) echo "$c";; esac
        done;;
      stats*) echo "keel-lab-gateway 1.00% 100MiB / 27GiB";;
      *) echo "stub docker: unhandled [$a]" >&2; exit 99;;
    esac;;
  curl) printf '%s' "${STUB_CURL_CODE:-200}";;
  free) echo "Mem: 27000 9000";;
  vgs|lvs) echo "ubuntu-vg $(after && echo 24.68g || echo 74.68g)";;
  ip) case "$a" in "-4 -o addr show dev tailscale0") echo "7: tailscale0    inet 100.79.95.22/32 scope global tailscale0";;
        "-4 -o addr show dev br-ddd333eee444") echo "9: br-ddd333eee444    inet 172.18.0.1/16 brd 172.18.255.255 scope global br-ddd333eee444";; esac;;
  timeout|ping) exit 0;;
  tee) cat >/dev/null; echo "tee: write error: No space left on device" >&2; exit 1;;
  *) echo "stub: unknown command $name" >&2; exit 99;;
esac
STUB
chmod +x "$T/bin/stub"
for c in sudo nft iptables-save iptables systemctl lxc docker curl free vgs lvs ip timeout ping; do ln -s stub "$T/bin/$c"; done
ln -s ../bin/stub "$T/teefail/tee"
# hostcheck.sh binds its expected Keel inventory to the SHA-256 of the reviewed Compose file. The
# stand-ins run it against a synthetic Compose file instead: the wrappers below source the (staged)
# script and point the binding at TEST_COMPOSE / TEST_COMPOSE_SHA256. The script itself honours no
# such override; D1/D2 test the real binding.
cat > "$T/hc-run.sh" <<'RUN'
HOSTCHECK_LIB=1 . "$1"; shift
[ -n "${TEST_COMPOSE:-}" ] && KEEL_COMPOSE_LIVE=$TEST_COMPOSE
[ -n "${TEST_COMPOSE_SHA256:-}" ] && KEEL_COMPOSE_SHA256=$TEST_COMPOSE_SHA256
hostcheck_main "$@"
RUN
cat > "$T/probe-run.sh" <<'RUN'
HOSTCHECK_LIB=1 . "$1"
[ -n "${TEST_COMPOSE:-}" ] && KEEL_COMPOSE_LIVE=$TEST_COMPOSE
[ -n "${TEST_COMPOSE_SHA256:-}" ] && KEEL_COMPOSE_SHA256=$TEST_COMPOSE_SHA256
# PostgreSQL is not on the LAN; STUB_ALT_NO_LISTENER: nothing answers on the host bridge 172.18.0.1
host_tcp() { if [ "$2" = 5432 ]; then echo 124; elif [ "$1" = 172.18.0.1 ] && [ -n "${STUB_ALT_NO_LISTENER:-}" ]; then echo 124; else echo 0; fi; }
host_icmp() { echo 0; }
is_local() { case "$1" in 10.0.0.3|10.72.0.1|10.71.0.1|172.17.0.1|172.18.0.1|100.79.95.22) return 0;; esac; return 1; }
probe "$2" "${3:-}"
RUN
cat > "$T/gate-run.sh" <<'RUN'
PROVISION_LIB=1 . "$1"
# shellcheck disable=SC2086
rsh() { local c=${1//\~/$HOME}; case "$c" in sha256sum*) shasum -a 256 ${c#sha256sum };;
                                             "bash "*) set -- ${c#bash }; "$BASH" "$HC_RUN" "$@";; *) eval "$c";; esac; }
require_before_record "$2" "$3"
echo "GATE PASSED $BEFORE_DIR"
RUN
# The stand-in dc1-x86 home holds a staged copy of hostcheck.sh, as the runbook's staging step leaves it.
newhome() { H="$T/home$1"; mkdir -p "$H/ci-shared-check"; cp "$HC" "$H/ci-shared-check/hostcheck.sh"; }
hc() { HOME="$H" PATH="$T/bin:$PATH" STUB_DIR="$T" "$BASH" "$T/hc-run.sh" "$HC" "$@" 2>&1; }
export HC_RUN="$T/hc-run.sh"
# A synthetic Compose file shaped like Keel's: an anchor block, comments, nine services with
# container_name and restart, and the two one-shots with restart: 'no'.
cat > "$T/compose.lab.yml" <<'YML'
name: keel-lab
x-keel-env: &keel-env
  KEEL_LOG_LEVEL: info
services:
  # ── data ──
  postgres:
    image: pgvector/pgvector:pg16
    container_name: keel-lab-postgres
    restart: unless-stopped
    healthcheck:
      test: ['CMD', 'pg_isready']
  nats:
    container_name: keel-lab-nats
    restart: unless-stopped
  temporal:
    container_name: keel-lab-temporal
    restart: unless-stopped
  minio:
    container_name: keel-lab-minio
    restart: unless-stopped
  minio-bucket:
    container_name: keel-lab-minio-bucket
    restart: 'no'
    depends_on:
      minio:
        condition: service_healthy
  bootstrap:
    container_name: keel-lab-bootstrap
    restart: 'no'
    environment:
      <<: *keel-env
  gateway:
    container_name: keel-lab-gateway
    restart: unless-stopped
    depends_on:
      bootstrap:
        condition: service_completed_successfully
  runtime-worker:
    container_name: keel-lab-runtime-worker
    restart: unless-stopped
  web:
    container_name: keel-lab-web
    restart: unless-stopped
# No named volumes.
YML
export TEST_COMPOSE="$T/compose.lab.yml"
TEST_COMPOSE_SHA256=$(shasum -a 256 "$TEST_COMPOSE" | awk '{print $1}'); export TEST_COMPOSE_SHA256
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
eq "snapshot exits nonzero" "$rc" 1; has "unhealthy container named" "$out" "long-running /keel-lab-postgres is not healthy: health=unhealthy"
B=$(newest before); eq "all five endpoints were 200" "$(grep -c ' 200$' "$B/stable/keel-health.txt")" 5
[ ! -e "$B/COMPLETE" ] && ok "no completion record" || bad "no completion record" "found"
out=$(STUB_UNHEALTHY=1 probe_run); rc=$?; eq "probe with an unhealthy Keel container -> FAIL (1)" "$rc" 1
has "probe names it in Keel preservation" "$out" "long-running /keel-lab-postgres is not healthy"

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

echo "── I1 the expected Keel inventory comes from the Compose file (pure)"
INV="$T/inventory.txt"; keel_inventory < "$TEST_COMPOSE" > "$INV"
eq "nine services derived, sorted, with container and restart policy" "$(tr '\n' ';' < "$INV")" \
   "bootstrap keel-lab-bootstrap no;gateway keel-lab-gateway unless-stopped;minio keel-lab-minio unless-stopped;minio-bucket keel-lab-minio-bucket no;nats keel-lab-nats unless-stopped;postgres keel-lab-postgres unless-stopped;runtime-worker keel-lab-runtime-worker unless-stopped;temporal keel-lab-temporal unless-stopped;web keel-lab-web unless-stopped;"
eq "a usable inventory has no defects" "$(keel_inventory_problems < "$INV")" ""
ip_() { printf '%s\n' "$1" | keel_inventory | keel_inventory_problems; }
has "a restart: no service that verify.yml does not name -> refused" "$(ip_ "$(sed "s/  web:/  migrate:\n    container_name: keel-lab-migrate\n    restart: 'no'\n  web:/" "$TEST_COMPOSE")")" \
    "service migrate is restart: no but not a one-shot in roles/keel/tasks/verify.yml"
has "a one-shot that is long-running in the file -> refused" "$(ip_ "$(awk '/container_name: keel-lab-bootstrap/ {print; getline; print "    restart: unless-stopped"; next} {print}' "$TEST_COMPOSE")")" \
    "one-shot bootstrap is not restart: no"
has "a one-shot absent from the file -> refused" "$(ip_ "$(awk '/^  minio-bucket:/ {skip=1; next} skip && /^  [a-z]/ {skip=0} !skip' "$TEST_COMPOSE")")" \
    "one-shot minio-bucket is not a service in the Compose file"
has "a service without container_name -> refused" "$(ip_ "$(grep -v 'container_name: keel-lab-web' "$TEST_COMPOSE")")" "service web has no container_name"
has "two services, one container_name -> refused" "$(ip_ "$(sed 's/container_name: keel-lab-web/container_name: keel-lab-gateway/' "$TEST_COMPOSE")")" "used twice"
has "no services at all -> refused" "$(ip_ "name: x")" "no services found"

echo "── K1 Keel container contract over the inventory: one-shot jobs vs long-running services (pure)"
OK1='/keel-lab-bootstrap restarts=0 status=exited exit=0 oom=false health=none
/keel-lab-gateway restarts=0 status=running exit=0 oom=false health=healthy
/keel-lab-minio restarts=0 status=running exit=0 oom=false health=healthy
/keel-lab-minio-bucket restarts=0 status=exited exit=0 oom=false health=none
/keel-lab-nats restarts=0 status=running exit=0 oom=false health=healthy
/keel-lab-postgres restarts=0 status=running exit=0 oom=false health=healthy
/keel-lab-runtime-worker restarts=2 status=running exit=0 oom=false health=none
/keel-lab-temporal restarts=0 status=running exit=0 oom=false health=healthy
/keel-lab-web restarts=0 status=running exit=0 oom=false health=none'
kp() { printf '%s\n' "$1" | keel_state_problems "$INV"; }
eq "every expected container once, one-shots exited 0, the rest running/healthy -> no problems" "$(kp "$OK1")" ""
has "one-shot nonzero exit -> blocked" "$(kp "${OK1/bootstrap restarts=0 status=exited exit=0/bootstrap restarts=0 status=exited exit=1}")" \
    "one-shot /keel-lab-bootstrap did not complete successfully: status=exited exit=1 oom=false"
has "one-shot OOM-killed -> blocked" "$(kp "${OK1/minio-bucket restarts=0 status=exited exit=0 oom=false/minio-bucket restarts=0 status=exited exit=137 oom=true}")" \
    "one-shot /keel-lab-minio-bucket did not complete successfully: status=exited exit=137 oom=true"
has "one-shot OOM-killed even with exit 0 -> blocked" "$(kp "${OK1/bootstrap restarts=0 status=exited exit=0 oom=false/bootstrap restarts=0 status=exited exit=0 oom=true}")" "oom=true"
has "one-shot never ran (created) -> blocked" "$(kp "${OK1/bootstrap restarts=0 status=exited/bootstrap restarts=0 status=created}")" "status=created"
has "one-shot still running -> blocked" "$(kp "${OK1/bootstrap restarts=0 status=exited/bootstrap restarts=0 status=running}")" "status=running"
has "one-shot missing -> blocked" "$(kp "$(printf '%s\n' "$OK1" | grep -v keel-lab-bootstrap)")" "expected one-shot /keel-lab-bootstrap is missing"
has "one-shot listed twice -> blocked" "$(kp "$OK1
/keel-lab-bootstrap restarts=0 status=exited exit=0 oom=false health=none")" "appears 2 times"
has "long-running exited (even exit 0) -> blocked" "$(kp "${OK1/gateway restarts=0 status=running/gateway restarts=0 status=exited}")" \
    "long-running /keel-lab-gateway is not running: status=exited exit=0"
has "long-running restarting -> blocked" "$(kp "${OK1/worker restarts=2 status=running/worker restarts=2 status=restarting}")" "status=restarting"
has "long-running health starting -> blocked" "$(kp "${OK1/gateway restarts=0 status=running exit=0 oom=false health=healthy/gateway restarts=0 status=running exit=0 oom=false health=starting}")" "is not healthy: health=starting"
has "long-running unhealthy -> blocked" "$(kp "${OK1/postgres restarts=0 status=running exit=0 oom=false health=healthy/postgres restarts=0 status=running exit=0 oom=false health=unhealthy}")" "is not healthy: health=unhealthy"
has "missing long-running runtime-worker -> blocked" "$(kp "$(printf '%s\n' "$OK1" | grep -v keel-lab-runtime-worker)")" "expected long-running /keel-lab-runtime-worker is missing"
has "missing long-running postgres -> blocked" "$(kp "$(printf '%s\n' "$OK1" | grep -v keel-lab-postgres)")" "expected long-running /keel-lab-postgres is missing"
has "missing long-running web -> blocked" "$(kp "$(printf '%s\n' "$OK1" | grep -v keel-lab-web)")" "expected long-running /keel-lab-web is missing"
has "long-running listed twice -> blocked" "$(kp "$OK1
/keel-lab-nats restarts=0 status=running exit=0 oom=false health=healthy")" "expected long-running /keel-lab-nats appears 2 times"
has "unexpected keel-lab container -> blocked" "$(kp "$OK1
/keel-lab-debug restarts=0 status=running exit=0 oom=false health=none")" "unexpected container /keel-lab-debug"
has "unknown state line (old v1 format) -> blocked" "$(kp "$OK1
/keel-lab-web restarts=0 running healthy")" "unrecognised state line"
has "no containers at all -> every expected container missing" "$(kp "")" "expected long-running /keel-lab-postgres is missing"
has "empty inventory -> blocked, never vacuously OK" "$(printf '%s\n' "$OK1" | keel_state_problems /dev/null)" "no expected Keel inventory"
ep() { ( KEEL_COMPOSE_SHA256=$TEST_COMPOSE_SHA256; keel_evidence_problems "$@" ); }
printf '%s\n' "$OK1" > "$T/state-ok.txt"
eq "bound Compose + its inventory + good state -> no problems" "$(ep "$TEST_COMPOSE" "$INV" "$T/state-ok.txt")" ""
has "Compose file that is not the reviewed definition -> blocked" "$(keel_evidence_problems "$TEST_COMPOSE" "$INV" "$T/state-ok.txt")" \
    "the deployed Compose file is not the reviewed definition at keel_commit 9b0d36f0"
grep -v keel-lab-web "$INV" > "$T/inv-short.txt"
has "recorded inventory that disagrees with the Compose file -> blocked" "$(ep "$TEST_COMPOSE" "$T/inv-short.txt" "$T/state-ok.txt")" \
    "the recorded inventory does not match the Compose file"

echo "── D1 the inventory binding matches roles/keel (drift)"
eq "KEEL_COMMIT is roles/keel's keel_commit" "$KEEL_COMMIT" "$(awk '/^keel_commit:/ {print $2}' "$REPO/roles/keel/defaults/main.yml")"
eq "KEEL_COMPOSE_LIVE is keel_root/compose.lab.yml" "$KEEL_COMPOSE_LIVE" \
   "$(awk '/^keel_root:/ {print $2}' "$REPO/roles/keel/defaults/main.yml")/compose.lab.yml"
has "keel_compose_file default names compose.lab.yml under keel_root" "$(grep '^keel_compose_file:' "$REPO/roles/keel/defaults/main.yml")" '"{{ keel_root }}/compose.lab.yml"'
dep=$(awk '/^- name: Install the stack definition from the built commit/ {p=1} p && /^- name:/ && !/built commit/ {exit} p' "$REPO/roles/keel/tasks/deploy.yml")
has "deploy.yml installs the file with a plain copy (byte-identical, not templated)" "$dep" "ansible.builtin.copy:"
has "deploy.yml copies infra/lab/compose.lab.yml of the built commit" "$dep" 'src: "{{ keel_build_dir }}/infra/lab/compose.lab.yml"'
has "deploy.yml writes it to keel_compose_file" "$dep" 'dest: "{{ keel_compose_file }}"'
case "$dep" in *template*) bad "not templated" "$dep";; *) ok "not templated";; esac

echo "── D2 the bound hash and inventory re-derived from Keel's source at keel_commit (drift)"
KSRC="${KEEL_SOURCE_REPO:-$HOME/Projects/keel}"
if GIT_NO_LAZY_FETCH=1 git -C "$KSRC" cat-file -e "$KEEL_COMMIT:infra/lab/compose.lab.yml" 2>/dev/null; then
  GIT_NO_LAZY_FETCH=1 git -C "$KSRC" show "$KEEL_COMMIT:infra/lab/compose.lab.yml" > "$T/compose.real.yml"
  eq "SHA-256 of infra/lab/compose.lab.yml at keel_commit == KEEL_COMPOSE_SHA256" "$(shasum -a 256 "$T/compose.real.yml" | awk '{print $1}')" "$KEEL_COMPOSE_SHA256"
  keel_inventory < "$T/compose.real.yml" > "$T/inv.real.txt"
  eq "the real file yields a usable inventory" "$(keel_inventory_problems < "$T/inv.real.txt")" ""
  eq "its one-shots (restart: no) are exactly verify.yml's" "$(awk '$3 == "no" {print $1}' "$T/inv.real.txt" | tr '\n' ' ')" "bootstrap minio-bucket "
  eq "the stand-in fixture has the real file's inventory" "$(cat "$T/inv.real.txt")" "$(cat "$INV")"
  # end to end with the REAL binding: no hash override, the real file as the deployed one
  newhome real; out=$(TEST_COMPOSE="$T/compose.real.yml" TEST_COMPOSE_SHA256="" STUB_PHASE=before hc snapshot before "$SHA"); rc=$?
  eq "snapshot against the real, unmodified binding -> OK" "$rc" 0
  sed 's/keel-lab-web/keel-lab-www/' "$T/compose.real.yml" > "$T/compose.real-edited.yml"
  newhome real2; out=$(TEST_COMPOSE="$T/compose.real-edited.yml" TEST_COMPOSE_SHA256="" STUB_PHASE=before hc snapshot before "$SHA"); rc=$?
  eq "one edited byte in the deployed file -> snapshot INCOMPLETE" "$rc" 1; has "binding named" "$out" "is not the reviewed definition"
else
  echo "  skip  Keel source not available at $KSRC (set KEEL_SOURCE_REPO): the hash and inventory are bound by D1 only"
fi

# The one-shot list is the one roles/keel/tasks/verify.yml exempts from "running".
contract=$(sed -n "s/.*grep -vE '\^(\([a-z|-]*\)) '.*/\1/p" "$REPO/roles/keel/tasks/verify.yml" | tr '|' '\n' | sort | tr '\n' ' ')
eq "one-shot set equals roles/keel/tasks/verify.yml's exemption" "$contract" "$(printf '%s\n' $KEEL_ONESHOT_SERVICES | sort | tr '\n' ' ')"
case "$(cat "$REPO/roles/keel/tasks/deploy.yml")" in *"inspect --format"*"State.ExitCode"*"keel-lab-bootstrap"*) ok "deploy.yml also requires keel-lab-bootstrap's exit code";;
  *) bad "deploy.yml bootstrap exit contract" "not found";; esac

echo "── K2 one-shot handling end to end (snapshot, verify, compare, probe)"
newhome 9
out=$(STUB_PHASE=before hc snapshot before "$SHA"); rc=$?; eq "one-shots exited 0 -> snapshot OK" "$rc" 0
B=$(newest before)
has "one-shot exit evidence kept in the snapshot" "$(cat "$B/stable/keel-state.txt")" "/keel-lab-bootstrap restarts=0 status=exited exit=0 oom=false health=none"
has "record binds the container evidence" "$(cat "$B/COMPLETE")" "stable/keel-state.txt"
sleep 1; out=$(STUB_PHASE=after hc snapshot after-provision "$SHA"); A=$(newest after-provision)
out=$(hc compare "$SHA"); rc=$?; eq "compare with one-shot evidence on both sides -> OK" "$rc" 0
has "after snapshot keeps one-shot evidence too" "$(cat "$A/stable/keel-state.txt")" "/keel-lab-minio-bucket restarts=0 status=exited exit=0 oom=false"
out=$(probe_run); rc=$?; eq "probe with completed one-shots -> OK" "$rc" 0
has "probe states one-shots completed" "$out" "all 9 services of the reviewed Compose file present once; one-shots (bootstrap minio-bucket) completed with exit 0"
has "probe keeps container evidence" "$(cat "$(newest probe)/keel-state.txt")" "/keel-lab-bootstrap restarts=0 status=exited exit=0"
newhome 10
out=$(STUB_PHASE=before STUB_BOOTSTRAP_EXIT=1 hc snapshot before "$SHA"); rc=$?
eq "failed one-shot (exit 1) -> snapshot INCOMPLETE" "$rc" 1; has "failed one-shot named" "$out" "one-shot /keel-lab-bootstrap did not complete successfully: status=exited exit=1"
[ ! -e "$(newest before)/COMPLETE" ] && ok "failed one-shot -> no record" || bad "failed one-shot -> no record" "found"
out=$(STUB_BOOTSTRAP_EXIT=1 probe_run); rc=$?; eq "failed one-shot -> probe FAIL (1)" "$rc" 1
newhome 10b; out=$(STUB_PHASE=before STUB_BOOTSTRAP_EXIT=137 STUB_BOOTSTRAP_OOM=true hc snapshot before "$SHA"); rc=$?
eq "OOM-killed one-shot -> snapshot INCOMPLETE" "$rc" 1; has "OOM named" "$out" "oom=true"
newhome 10c; out=$(STUB_PHASE=before STUB_NO_BOOTSTRAP=1 hc snapshot before "$SHA"); rc=$?
eq "missing one-shot -> snapshot INCOMPLETE" "$rc" 1; has "missing one-shot named" "$out" "one-shot /keel-lab-bootstrap is missing"
out=$(STUB_NO_BOOTSTRAP=1 probe_run); rc=$?; eq "missing one-shot -> probe FAIL (1)" "$rc" 1
newhome 10d; out=$(STUB_PHASE=before STUB_BOOTSTRAP_STATUS=created hc snapshot before "$SHA"); rc=$?
eq "one-shot in unknown/unfinished state -> snapshot INCOMPLETE" "$rc" 1
newhome 10e; out=$(STUB_PHASE=before STUB_INSPECT_FAIL=1 hc snapshot before "$SHA"); rc=$?
eq "inspection fails -> snapshot INCOMPLETE" "$rc" 1; has "inspection failure named" "$out" "docker inspect keel-lab-minio-bucket"
out=$(STUB_INSPECT_FAIL=1 probe_run); rc=$?; eq "inspection fails -> probe INCONCLUSIVE (2)" "$rc" 2
newhome 10f; out=$(STUB_PHASE=before STUB_LONGRUN_EXITED=1 hc snapshot before "$SHA"); rc=$?
eq "exited long-running service -> snapshot INCOMPLETE" "$rc" 1; has "exited long-running named" "$out" "long-running /keel-lab-gateway is not running: status=exited"
out=$(STUB_LONGRUN_EXITED=1 probe_run); rc=$?; eq "exited long-running service -> probe FAIL (1)" "$rc" 1
out=$(hc verify before "$SHA" 120); rc=$?; eq "only failed snapshots in this home -> verify refuses" "$rc" 1
# verify re-applies the contract to bound evidence: a record written over a failed one-shot is refused
newhome 11
STUB_PHASE=before hc snapshot before "$SHA" >/dev/null; B=$(newest before)
sed -i.bak 's#^/keel-lab-bootstrap .*#/keel-lab-bootstrap restarts=0 status=exited exit=2 oom=false health=none#' "$B/stable/keel-state.txt"
# shellcheck disable=SC1090
( HOSTCHECK_LIB=1 . "$HC"; write_record "$B" before "$SHA" ) || bad "re-record" "write_record failed"
out=$(hc verify before "$SHA" 120); rc=$?
eq "record over a failed one-shot -> verify refuses" "$rc" 1; has "verify names the contract" "$out" "Keel container contract: one-shot /keel-lab-bootstrap did not complete successfully"
sed -i.v1 '1s/.*/hostcheck-snapshot v1/' "$B/COMPLETE"
out=$(hc verify before "$SHA" 120); rc=$?; eq "v1 record (old state format) -> refused" "$rc" 1; has "format named" "$out" "unknown format"

echo "── R1 the guest's route decides whether a probe is evidence about the host (pure)"
eq "via the external interface -> external" "$(route_verdict 0 '10.0.0.3 via 10.72.0.1 dev enp5s0 src 10.72.0.226 uid 0' enp5s0)" external
eq "direct on the external interface -> external" "$(route_verdict 0 '10.72.0.1 dev enp5s0 src 10.72.0.226 uid 0' enp5s0)" external
eq "the live 172.17.0.1 route (guest's own docker0) -> guest-local" "$(route_verdict 0 'local 172.17.0.1 dev lo src 172.17.0.1 uid 0' enp5s0)" guest-local
eq "dev lo without 'local' -> guest-local" "$(route_verdict 0 '172.17.0.1 dev lo src 172.17.0.1' enp5s0)" guest-local
eq "broadcast -> guest-local" "$(route_verdict 0 'broadcast 172.17.255.255 dev docker0 src 172.17.0.1' enp5s0)" guest-local
eq "overlapping guest network -> other:<dev>" "$(route_verdict 0 '172.18.0.1 dev br-0badc0ffee src 172.18.0.1 uid 0' enp5s0)" other:br-0badc0ffee
eq "guest docker0 subnet (not its own address) -> other:docker0" "$(route_verdict 0 '172.17.0.5 dev docker0 src 172.17.0.1' enp5s0)" other:docker0
eq "unreachable -> no-route" "$(route_verdict 2 'RTNETLINK answers: Network is unreachable' enp5s0)" no-route
eq "query failed -> unreadable" "$(route_verdict 2 'RTNETLINK answers: Operation not permitted' enp5s0)" unreadable
eq "no marker (lxc exec failed) -> unreadable" "$(route_verdict '' '' enp5s0)" unreadable
eq "external interface unknown -> unreadable" "$(route_verdict 0 '10.0.0.3 via 10.72.0.1 dev enp5s0' '')" unreadable
# probe_target never probes (or counts) a destination that does not leave through the external interface
guest_route() { printf 'local 172.17.0.1 dev lo src 172.17.0.1 uid 0\nRC=0\n'; }
r=$(GT=0 HT=0 pt required tcp 172.17.0.1 443 "docker0")
has "guest-local target with a guest listener -> INCONCLUSIVE, never FAIL or PASS" "$r" "INCONCLUSIVE|docker0 172.17.0.1:443: the address is local to the guest (route: local 172.17.0.1 dev lo"
guest_route() { printf '172.18.0.1 dev br-0badc0ffee src 172.18.0.1 uid 0\nRC=0\n'; }
r=$(GT=124 HT=0 pt required tcp 172.18.0.1 443 "bridge")
has "overlapping target -> INCONCLUSIVE, not PASS" "$r" "INCONCLUSIVE|bridge 172.18.0.1:443: the guest routes it via its own br-0badc0ffee, not enp5s0"
guest_route() { printf 'RTNETLINK answers: Operation not permitted\nRC=2\n'; }
r=$(GT=124 HT=0 pt required tcp 10.0.0.3 443 "host Caddy"); has "route query failed -> INCONCLUSIVE" "$r" "INCONCLUSIVE|host Caddy 10.0.0.3:443: the guest's route query failed"
r=$(GUEST_EXTIF='' GT=124 HT=0 pt required tcp 10.0.0.3 443 "host Caddy"); has "external interface unknown -> INCONCLUSIVE" "$r" "the guest's external interface is unknown"
guest_route() { printf '%s via 10.72.0.1 dev enp5s0 src 10.72.0.226 uid 0\nRC=0\n' "$1"; }
r=$(GT=124 HT=0 pt required tcp 10.0.0.3 443 "host Caddy"); has "PASS records the guest route" "$r" "guest route: 10.0.0.3 via 10.72.0.1 dev enp5s0"

echo "── R2 host Docker bridge target: discovered, route-checked, host-controlled (end to end)"
newhome r
out=$(probe_run); rc=$?; P=$(newest probe)
eq "live reproduction + valid alternative -> probe OK (0)" "$rc" 0
has "172.17.0.1 rejected as guest-local, with identity and route" "$out" "docker bridge bridge (docker0) 172.17.0.1: guest route 'local 172.17.0.1 dev lo table local src 172.17.0.1 uid 0' is guest-local, not via enp5s0; rejected"
has "alternative selected with route and host control" "$out" "docker bridge keel-lab_default (br-ddd333eee444) 172.18.0.1: guest route '172.18.0.1 via 10.72.0.1 dev enp5s0 src 10.72.0.226 uid 0'; host control :443 connected; selected"
has "alternative probed: observed outcome and route recorded" "$out" "PASS                  host Docker bridge keel-lab_default (br-ddd333eee444), Caddy 172.18.0.1:443 — observed: guest no response within 4 s; host connected; guest route: 172.18.0.1 via 10.72.0.1 dev enp5s0"
case "$out" in *"PASS"*"172.17.0.1:443"*|*"FAIL"*"172.17.0.1"*) bad "172.17.0.1 never counted (its guest listener answers)" "$out";; *) ok "172.17.0.1 never counted (its guest listener answers)";; esac
has "probe log keeps the candidate evidence" "$(cat "$P/probe.txt")" "172.17.0.1: guest route"
out=$(STUB_NO_ALT=1 probe_run); rc=$?
eq "only the guest-local docker0 exists -> INCONCLUSIVE (2)" "$rc" 2; has "no valid target named" "$out" "host Docker bridge: no bridge address both leaves the guest via enp5s0 and answers a host-side control"
out=$(STUB_OVERLAP_18=1 probe_run); rc=$?
eq "alternative overlaps a guest network -> INCONCLUSIVE (2)" "$rc" 2; has "overlap recorded" "$out" "172.18.0.1: guest route '172.18.0.1 dev br-0badc0ffee src 172.18.0.1 uid 0' is other:br-0badc0ffee"
out=$(STUB_ALT_NO_LISTENER=1 probe_run); rc=$?
eq "alternative has no host-side listener -> INCONCLUSIVE (2)" "$rc" 2; has "failed control recorded" "$out" "host control :443 no response within 4 s; rejected (no live host-side target)"
out=$(STUB_NO_GW=1 probe_run); rc=$?
eq "no IPAM gateway: the bridge interface's own address is read -> OK (0)" "$rc" 0
has "fallback address selected" "$out" "docker bridge keel-lab_default (br-ddd333eee444) 172.18.0.1: guest route"
out=$(STUB_NET_FAIL=1 probe_run); rc=$?
eq "Docker network discovery fails -> INCONCLUSIVE (2)" "$rc" 2; has "discovery failure named" "$out" "host Docker bridge: discovery failed"
out=$(STUB_ROUTE_FAIL=1 probe_run); rc=$?
eq "guest route queries fail -> INCONCLUSIVE (2)" "$rc" 2; has "route failure named for a target" "$out" "host LAN address, Caddy ingress 10.0.0.3:443: the guest's route query failed"
case "$out" in *"PASS                  host LAN address"*) bad "no denied-target PASS without a route" "$out";; *) ok "no denied-target PASS without a route";; esac
out=$(STUB_NO_DEFAULT=1 probe_run); rc=$?
eq "guest default route unreadable -> INCONCLUSIVE (2)" "$rc" 2; has "default route named" "$out" "the guest's default route could not be read"
out=$(STUB_ALT_OPEN=1 probe_run); rc=$?
eq "forbidden connectivity to the host bridge -> FAIL (1)" "$rc" 1; has "forbidden connectivity named" "$out" "FAIL                  host Docker bridge keel-lab_default (br-ddd333eee444), Caddy 172.18.0.1:443 — observed: guest connected"

echo "── R3 a corrected checker probes an existing deployment and records itself separately"
newhome prov; CK=0123456789abcdef0123456789abcdef01234567
out=$(HOME="$H" PATH="$T/bin:$PATH" STUB_DIR="$T" STUB_PHASE=after "$BASH" "$T/probe-run.sh" "$HC" "$SHA" "$CK" 2>&1); rc=$?; P=$(newest probe)
eq "probe with a checker commit -> OK" "$rc" 0
eq "INFRA_SHA stays the deployment's revision" "$(cat "$P/INFRA_SHA")" "$SHA"
has "CHECKER records the checker commit" "$(cat "$P/CHECKER")" "checker_commit $CK"
has "CHECKER records the checker's own SHA-256" "$(cat "$P/CHECKER")" "checker_sha256 $(shasum -a 256 "$HC" | awk '{print $1}')"
has "the header shows both" "$out" "commit $CK; deployment (INFRA_SHA) $SHA"
out=$(probe_run); P=$(newest probe); has "without a checker commit it is recorded as unrecorded" "$(cat "$P/CHECKER")" "checker_commit unrecorded"
out=$(HOME="$H" PATH="$T/bin:$PATH" STUB_DIR="$T" STUB_PHASE=after "$BASH" "$T/probe-run.sh" "$HC" "$SHA" "not-a-sha" 2>&1); rc=$?
eq "a malformed checker commit is refused" "$rc" 1

echo "── M1 a missing expected service fails even when all five HTTP endpoints return 200"
for gone in keel-lab-runtime-worker keel-lab-postgres keel-lab-web keel-lab-nats; do
  newhome "m-$gone"
  out=$(STUB_PHASE=before STUB_MISSING="$gone" hc snapshot before "$SHA"); rc=$?
  eq "$gone missing -> snapshot INCOMPLETE" "$rc" 1
  has "$gone missing -> named" "$out" "expected long-running /$gone is missing"
  B=$(newest before); eq "$gone missing -> all five endpoints were still 200" "$(grep -c ' 200$' "$B/stable/keel-health.txt")" 5
  [ ! -e "$B/COMPLETE" ] && ok "$gone missing -> no completion record" || bad "$gone missing -> no record" "found"
  out=$(STUB_MISSING="$gone" probe_run); rc=$?
  eq "$gone missing -> probe FAIL (1)" "$rc" 1; has "$gone missing -> probe names it" "$out" "expected long-running /$gone is missing"
done
newhome m-gate; out=$(STUB_PHASE=before STUB_MISSING=keel-lab-runtime-worker hc snapshot before "$SHA")
out=$(gate); rc=$?; eq "missing worker -> provision gate refuses" "$rc" 1
newhome m-extra; out=$(STUB_PHASE=before STUB_EXTRA=keel-lab-debug hc snapshot before "$SHA"); rc=$?
eq "unexpected keel-lab container -> snapshot INCOMPLETE" "$rc" 1; has "unexpected named" "$out" "unexpected container /keel-lab-debug"
out=$(STUB_EXTRA=keel-lab-debug probe_run); rc=$?; eq "unexpected keel-lab container -> probe FAIL (1)" "$rc" 1
sed 's/keel-lab-web$/keel-lab-www/' "$TEST_COMPOSE" > "$T/compose.edited.yml"
newhome m-edit; out=$(TEST_COMPOSE="$T/compose.edited.yml" STUB_PHASE=before hc snapshot before "$SHA"); rc=$?
eq "deployed Compose file differs from the bound one -> snapshot INCOMPLETE" "$rc" 1; has "binding named" "$out" "is not the reviewed definition"
out=$(TEST_COMPOSE="$T/compose.edited.yml" probe_run); rc=$?; eq "deployed Compose file differs -> probe FAIL (1)" "$rc" 1
newhome m-unread; out=$(TEST_COMPOSE="$T/no-such-compose.yml" STUB_PHASE=before hc snapshot before "$SHA"); rc=$?
eq "deployed Compose file unreadable -> snapshot INCOMPLETE" "$rc" 1; has "unreadable named" "$out" "read $T/no-such-compose.yml"
out=$(TEST_COMPOSE="$T/no-such-compose.yml" probe_run); rc=$?; eq "deployed Compose file unreadable -> probe INCONCLUSIVE (2)" "$rc" 2
# verify re-derives the inventory from the bound Compose copy: a record over a shortened inventory is refused
newhome m-inv; STUB_PHASE=before hc snapshot before "$SHA" >/dev/null; B=$(newest before)
grep -v keel-lab-web "$B/stable/keel-inventory.txt" > "$B/inv.tmp" && mv "$B/inv.tmp" "$B/stable/keel-inventory.txt"
grep -v keel-lab-web "$B/stable/keel-state.txt" > "$B/st.tmp" && mv "$B/st.tmp" "$B/stable/keel-state.txt"
# shellcheck disable=SC1090
( HOSTCHECK_LIB=1 . "$HC"; write_record "$B" before "$SHA" ) || bad "re-record" "write_record failed"
out=$(hc verify before "$SHA" 120); rc=$?
eq "record over an inventory without web -> verify refuses" "$rc" 1; has "inventory mismatch named" "$out" "the recorded inventory does not match the Compose file"
sed -i.v2 '1s/.*/hostcheck-snapshot v2/' "$B/COMPLETE"
out=$(hc verify before "$SHA" 120); rc=$?; eq "v2 record (no bound inventory) -> refused" "$rc" 1

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
