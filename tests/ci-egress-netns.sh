#!/usr/bin/env bash
# Runs INSIDE a throwaway, privileged Linux container (network namespaces
# only; nothing on the controller is touched). Sends real packets through a
# RENDERED ci-egress policy and reports what gets through.
#
#   ci-egress-netns.sh <policy.nft> <bridge> <gw/cidr> <vm-ip> <expect: hardened|default>
#
# Topology (the container's own namespace plays dc1-x86):
#   vm   (<vm-ip>, fd72::50, plus a spoofable 192.0.2.9)  —  <bridge> on the "host"
#   lan  10.0.0.5  (a LAN service; also the origin of an inbound attempt)
#   wan  198.51.100.5  (the "public internet": 443 open, 8080 open)
#   host listeners on 0.0.0.0/:: 443 (production Caddy stand-in), udp 53, udp 67
# IPv6 is deliberately PRESENT on the bridge here (the drift case): the
# policy, not the bridge configuration, must stop it.
set -uo pipefail
POLICY="$1" BR="$2" GWCIDR="$3" VMIP="$4" MODE="$5"
GW="${GWCIDR%/*}"; PFX="${GWCIDR#*/}"
pass=0; fail=0
ok()  { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }

# Ubuntu's default reverse-path filter is LOOSE (2), which admits a spoofed source
# that is routable at all; model that, not a stricter lab default.
sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1 net.ipv6.conf.all.disable_ipv6=0 \
  net.ipv6.conf.default.disable_ipv6=0 net.ipv4.conf.all.rp_filter=2 net.ipv4.conf.default.rp_filter=2
for ns in vm lan wan; do ip netns add $ns; ip netns exec $ns sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0; ip -n $ns link set lo up; done

ip link add "$BR" type veth peer name vm0 netns vm
ip addr add "$GWCIDR" dev "$BR"; ip -6 addr add fd72::1/64 dev "$BR" nodad; ip link set "$BR" up
ip -n vm addr add "$VMIP/$PFX" dev vm0; ip -n vm addr add 192.0.2.9/32 dev vm0
ip -n vm -6 addr add fd72::50/64 dev vm0 nodad; ip -n vm link set vm0 up
ip -n vm route add default via "$GW"

ip link add lanhost type veth peer name lan0 netns lan
ip addr add 10.0.0.1/24 dev lanhost; ip link set lanhost up
ip -n lan addr add 10.0.0.5/24 dev lan0; ip -n lan link set lan0 up; ip -n lan route add default via 10.0.0.1

ip link add wanhost type veth peer name wan0 netns wan
ip addr add 198.51.100.1/24 dev wanhost; ip link set wanhost up
ip -n wan addr add 198.51.100.5/24 dev wan0; ip -n wan link set wan0 up; ip -n wan route add default via 198.51.100.1
sleep 1.5   # link-local addresses settle

cat > /tmp/listen.py <<'PY'
import socket, sys, threading
log = sys.argv[1]
def tcp(fam, addr, port):
    s = socket.socket(fam, socket.SOCK_STREAM); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if fam == socket.AF_INET6: s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
    s.bind((addr, port)); s.listen(16)
    while True:
        c, _ = s.accept(); c.close()
def udp(addr, port):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind((addr, port))
    while True:
        d, a = s.recvfrom(2048)
        with open(log, 'a') as f: f.write(f"{port} {a[0]} {d.decode(errors='replace').strip()}\n")
for spec in sys.argv[2:]:
    kind, addr, port = spec.split(',')
    fn = {'t4': lambda a, p: tcp(socket.AF_INET, a, p), 't6': lambda a, p: tcp(socket.AF_INET6, a, p), 'u': udp}[kind]
    threading.Thread(target=fn, args=(addr, int(port)), daemon=True).start()
threading.Event().wait()
PY
python3 /tmp/listen.py /tmp/host-udp.log t4,0.0.0.0,443 t6,::,443 u,0.0.0.0,53 u,0.0.0.0,67 &
ip netns exec lan python3 /tmp/listen.py /tmp/lan-udp.log t4,10.0.0.5,443 u,10.0.0.5,5140 &
ip netns exec wan python3 /tmp/listen.py /tmp/wan-udp.log t4,198.51.100.5,443 t4,198.51.100.5,8080 &
ip netns exec vm python3 /tmp/listen.py /tmp/vm-udp.log t4,0.0.0.0,22 &
sleep 1

nft -f "$POLICY" || { echo "policy did not load"; exit 2; }
LL=$(ip -6 addr show dev "$BR" scope link | awk '/inet6/{print $2}' | cut -d/ -f1 | head -1)

tcp_from() { ip netns exec "$1" timeout 4 nc -z -w 2 "${@:2}" >/dev/null 2>&1; }
udp_from() { ip netns exec "$1" sh -c "printf 'probe-$RANDOM\n' | timeout 3 nc -u -w 1 $2" >/dev/null 2>&1; sleep 0.5; }

check() { # description, expected (open|blocked), actual rc (0=open)
  local got=blocked; [ "$3" -eq 0 ] && got=open
  if [ "$got" = "$2" ]; then ok "$1: $got"; else bad "$1" "expected $2, got $got"; fi
}
seen() { grep -q "$2" "$1" 2>/dev/null && echo 0 || echo 1; }

H=$([ "$MODE" = hardened ] && echo blocked || echo open)   # the two gaps the hardening closes
S=$([ "$MODE" = hardened ] && echo blocked || echo open)   # inbound NEW (sibling isolation, TW only)

tcp_from vm "$GW" 443;                 check "VM → host service on the bridge address (IPv4 :443)" blocked $?
tcp_from vm -6 fd72::1 443;            check "VM → host service over IPv6 (fd72::1 :443)" "$H" $?
tcp_from vm -6 "$LL%vm0" 443;          check "VM → host service over IPv6 link-local ($LL :443)" "$H" $?
tcp_from vm 10.0.0.5 443;              check "VM → LAN service (10.0.0.5:443)" blocked $?
tcp_from vm 198.51.100.5 443;          check "VM → public internet :443" open $?
tcp_from vm 198.51.100.5 8080;         check "VM → public internet :8080 (not an allowed port)" blocked $?
: > /tmp/host-udp.log
udp_from vm "-s $VMIP $GW 53";        check "VM → its own gateway resolver (udp/53)" open "$(seen /tmp/host-udp.log '^53 ')"
: > /tmp/host-udp.log
udp_from vm "-p 68 -s $VMIP $GW 67";  check "VM → DHCP on the host (udp 68→67)" open "$(seen /tmp/host-udp.log '^67 ')"
: > /tmp/lan-udp.log
udp_from vm "-s 192.0.2.9 10.0.0.5 5140"; check "VM with a SPOOFED source → LAN udp/5140" "$H" "$(seen /tmp/lan-udp.log '^5140 192.0.2.9')"
: > /tmp/host-udp.log
udp_from vm "-s 192.0.2.9 $GW 53";   check "VM with a SPOOFED source → host udp/53" "$H" "$(seen /tmp/host-udp.log '^53 192.0.2.9')"
tcp_from lan "$VMIP" 22;               check "LAN → VM, a NEW inbound connection" "$S" $?

echo "  counters:"; nft list table inet "$(awk '/^table inet [a-z_]+ \{$/{print $3; exit}' "$POLICY")" | grep -E 'counter packets [1-9]' | sed 's/^\s*/    /' | head -20
printf -- '── %s policy: %d passed, %d failed ──\n' "$MODE" "$pass" "$fail"
[ "$fail" -eq 0 ]
