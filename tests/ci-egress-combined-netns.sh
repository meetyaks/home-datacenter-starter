#!/usr/bin/env bash
# Runs INSIDE a throwaway, privileged Linux container (network namespaces only;
# nothing outside the container is touched; `docker run --rm` removes it all).
#
#   ci-egress-combined-netns.sh <keel render dir> <truewealth render dir>
#
# Loads the ACTUAL rendered Keel and TrueWealth egress policies TOGETHER, via
# their ACTUAL appliers (nftables table + DOCKER-USER rules), on a simulated
# dc1-x86: Docker's FORWARD DROP with DOCKER-USER, a Tailscale-style iptables
# chain and interface, both LXD bridges, the host's LAN address, the admin
# plane on the LAN, and a "public" network. Then, in both application orders
# and after re-application, it proves with real packets:
#   - each runner's permitted outbound traffic (443, its own DNS) still works;
#   - TrueWealth cannot reach production host services, the admin plane,
#     Tailscale addresses, Keel's bridge/resolver or Keel's VM;
#   - unsolicited inbound (from the LAN and from Keel's VM), spoofed-source
#     and IPv6 traffic from/into TrueWealth are refused;
#   - applying/re-applying TrueWealth leaves Keel's table, Keel's DOCKER-USER
#     rules and every unrelated iptables/nft rule byte-identical (compared
#     WITHOUT counters), and adds its own rules exactly once.
# Controls: with no CI policy (FORWARD ACCEPT) every later-blocked flow
# SUCCEEDS — listeners and routing work, so a later failure is the policy;
# with only the nft tables and no DOCKER-USER rules, even allowed egress
# fails — the appliers' DOCKER-USER half is what admits it.
set -uo pipefail
K="$1" T="$2"
pass=0; fail=0
ok()  { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }

# The appliers read these exact paths (rendered into them).
grep -q '^POLICY=/etc/nftables.d/ci-egress.nft$' "$K/ci-egress-apply.sh" || { echo "unexpected Keel applier"; exit 2; }
grep -q '^POLICY=/etc/nftables.d/ci-egress-tw.nft$' "$T/ci-egress-apply.sh" || { echo "unexpected TW applier"; exit 2; }

sysctl -qw net.ipv4.ip_forward=1 net.ipv6.conf.all.forwarding=1 net.ipv6.conf.all.disable_ipv6=0 \
  net.ipv6.conf.default.disable_ipv6=0 net.ipv4.conf.all.rp_filter=2 net.ipv4.conf.default.rp_filter=2
for ns in vmk vmt lan wan; do
  ip netns add $ns; ip netns exec $ns sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0
  ip -n $ns link set lo up
done
# Keel's bridge and VM (IPv4 only, as created)
ip link add lxdbr0 type veth peer name eth0 netns vmk
ip addr add 10.71.0.1/24 dev lxdbr0; ip link set lxdbr0 up
ip -n vmk addr add 10.71.0.50/24 dev eth0; ip -n vmk link set eth0 up; ip -n vmk route add default via 10.71.0.1
# TrueWealth's bridge and VM — IPv6 deliberately PRESENT (drift) and a spoofable address
ip link add citwbr0 type veth peer name eth0 netns vmt
ip addr add 10.72.0.1/24 dev citwbr0; ip -6 addr add fd72::1/64 dev citwbr0 nodad; ip link set citwbr0 up
ip -n vmt addr add 10.72.0.50/24 dev eth0; ip -n vmt addr add 192.0.2.9/32 dev eth0
ip -n vmt -6 addr add fd72::50/64 dev eth0 nodad; ip -n vmt link set eth0 up
ip -n vmt route add default via 10.72.0.1; ip -n vmt -6 route add default via fd72::1
# The LAN: dc1-x86 is 10.0.0.3, the admin plane 10.0.0.22
ip link add wlp3s0 type veth peer name eth0 netns lan
ip addr add 10.0.0.3/24 dev wlp3s0; ip link set wlp3s0 up
ip -n lan addr add 10.0.0.22/24 dev eth0; ip -n lan link set eth0 up; ip -n lan route add default via 10.0.0.3
# "Public" network, IPv4 and IPv6
ip link add uplink type veth peer name eth0 netns wan
ip addr add 198.51.100.1/24 dev uplink; ip -6 addr add fd99::1/64 dev uplink nodad; ip link set uplink up
ip -n wan addr add 198.51.100.5/24 dev eth0; ip -n wan -6 addr add fd99::5/64 dev eth0 nodad; ip -n wan link set eth0 up
ip -n wan route add default via 198.51.100.1; ip -n wan -6 route add default via fd99::1
# Tailscale-style interface and a Docker bridge address on the host
ip link add tailscale0 type dummy; ip addr add 100.79.95.22/32 dev tailscale0; ip link set tailscale0 up
ip link add docker0 type dummy; ip addr add 172.17.0.1/16 dev docker0; ip link set docker0 up
sleep 1.5

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
        with open(log, 'a') as f: f.write(f"{port} {a[0]}\n")
for spec in sys.argv[2:]:
    kind, addr, port = spec.split(',')
    fn = {'t4': lambda a, p: tcp(socket.AF_INET, a, p), 't6': lambda a, p: tcp(socket.AF_INET6, a, p), 'u': udp}[kind]
    threading.Thread(target=fn, args=(addr, int(port)), daemon=True).start()
threading.Event().wait()
PY
# Host: production Caddy (443), Postgres (5432), sshd (22) on every address; both bridge resolvers
python3 /tmp/listen.py /tmp/host.log t4,0.0.0.0,443 t6,::,443 t4,0.0.0.0,5432 t4,0.0.0.0,22 u,10.71.0.1,53 u,10.72.0.1,53 &
ip netns exec lan python3 /tmp/listen.py /tmp/lan.log t4,10.0.0.22,22 t4,10.0.0.22,443 u,10.0.0.22,5140 &
ip netns exec wan python3 /tmp/listen.py /tmp/wan.log t4,198.51.100.5,443 t4,198.51.100.5,8080 t6,::,443 &
ip netns exec vmk python3 /tmp/listen.py /tmp/vmk.log t4,0.0.0.0,22 t4,0.0.0.0,443 &
ip netns exec vmt python3 /tmp/listen.py /tmp/vmt.log t4,0.0.0.0,22 t4,0.0.0.0,443 &
sleep 1

tcp_ok() { ip netns exec "$1" timeout 4 nc -z -w 2 "${@:2}" >/dev/null 2>&1; }
udp_seen() { # ns "nc args" logfile pattern
  : > "$3"; ip netns exec "$1" sh -c "printf 'p\n' | timeout 3 nc -u -w 1 $2" >/dev/null 2>&1; sleep 0.5
  grep -q "$4" "$3"
}
LL=$(ip -6 addr show dev citwbr0 scope link | awk '/inet6/{print $2}' | cut -d/ -f1 | head -1)

# Every flow the contract talks about: name|kind|expect-with-policy|probe
flows() {
  cat <<EOF
TW → public :443 (allowed)|open|tcp_ok vmt 198.51.100.5 443
TW → public :8080 (not an allowed port)|blocked|tcp_ok vmt 198.51.100.5 8080
TW → its own resolver (udp/53)|open|udp_seen vmt '-s 10.72.0.50 10.72.0.1 53' /tmp/host.log '^53 10.72.0.50'
TW → production Caddy on the host LAN address 10.0.0.3:443|blocked|tcp_ok vmt 10.0.0.3 443
TW → production Postgres 10.0.0.3:5432|blocked|tcp_ok vmt 10.0.0.3 5432
TW → host service on its own gateway 10.72.0.1:443|blocked|tcp_ok vmt 10.72.0.1 443
TW → host sshd via the Tailscale address 100.79.95.22:22|blocked|tcp_ok vmt 100.79.95.22 22
TW → host via the Docker bridge address 172.17.0.1:443|blocked|tcp_ok vmt 172.17.0.1 443
TW → the admin plane 10.0.0.22:22|blocked|tcp_ok vmt 10.0.0.22 22
TW → Keel's resolver 10.71.0.1 (udp/53)|blocked|udp_seen vmt '-s 10.72.0.50 10.71.0.1 53' /tmp/host.log '^53 10.72.0.50'
TW → Keel's VM 10.71.0.50:443|blocked|tcp_ok vmt 10.71.0.50 443
TW spoofed source → LAN udp/5140|blocked|udp_seen vmt '-s 192.0.2.9 10.0.0.22 5140' /tmp/lan.log '^5140 192.0.2.9'
TW spoofed source → host udp/53|blocked|udp_seen vmt '-s 192.0.2.9 10.72.0.1 53' /tmp/host.log '^53 192.0.2.9'
TW IPv6 → host fd72::1:443|blocked|tcp_ok vmt -6 fd72::1 443
TW IPv6 link-local → host :443|blocked|tcp_ok vmt -6 $LL%eth0 443
TW IPv6 → public fd99::5:443|blocked|tcp_ok vmt -6 fd99::5 443
LAN (admin plane) → TW VM :22, unsolicited|blocked|tcp_ok lan 10.72.0.50 22
Keel VM → TW VM :443, unsolicited|blocked|tcp_ok vmk 10.72.0.50 443
Keel → public :443 (allowed)|open|tcp_ok vmk 198.51.100.5 443
Keel → public :8080|blocked|tcp_ok vmk 198.51.100.5 8080
Keel → its own resolver (udp/53)|open|udp_seen vmk '-s 10.71.0.50 10.71.0.1 53' /tmp/host.log '^53 10.71.0.50'
Keel → production Caddy 10.0.0.3:443|blocked|tcp_ok vmk 10.0.0.3 443
Keel → the admin plane 10.0.0.22:22|blocked|tcp_ok vmk 10.0.0.22 22
EOF
}
run_flows() { # label, mode: expect|all-open|all-blocked-egress
  local label="$1" mode="$2" name kind cmd got want n_bad=0 msg=""
  while IFS='|' read -r name kind cmd; do
    if eval "$cmd"; then got=open; else got=blocked; fi
    case "$mode" in
      expect) want="$kind" ;;
      all-open) want=open ;;
    esac
    if [ "$got" != "$want" ]; then n_bad=$((n_bad + 1)); msg="$msg; $name: got $got, want $want"; fi
  done < <(flows)
  [ "$n_bad" -eq 0 ] && ok "$label ($(flows | wc -l | tr -d ' ') flows)" || bad "$label" "${msg#; }"
}

# ── Control 1: no CI policy, forwarding open → every flow works ────────────
run_flows "control: with no CI policy every flow is reachable (listeners and routing work)" all-open

# ── Simulated Docker and Tailscale iptables state (the host's other owners) ─
iptables -N DOCKER-USER; iptables -A DOCKER-USER -j RETURN
iptables -N DOCKER; iptables -N DOCKER-ISOLATION-STAGE-1; iptables -A DOCKER-ISOLATION-STAGE-1 -j RETURN
iptables -P FORWARD DROP
iptables -A FORWARD -j DOCKER-USER
iptables -A FORWARD -j DOCKER-ISOLATION-STAGE-1
iptables -A FORWARD -o docker0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -o docker0 -j DOCKER
iptables -t nat -N DOCKER; iptables -t nat -A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
iptables -N ts-input; iptables -A INPUT -j ts-input; iptables -A ts-input -i lo -s 100.79.95.22 -j ACCEPT
iptables -A ts-input -s 100.115.92.0/23 ! -i tailscale0 -j RETURN
iptables -N ts-forward; iptables -I FORWARD 1 -j ts-forward; iptables -A ts-forward -o tailscale0 -j ACCEPT

strip() { sed -E 's/\[[0-9]+:[0-9]+\]//; /^#/d'; }
unrelated() { # everything but DOCKER-USER rules, without counters
  iptables-save | strip | grep -v -- '-A DOCKER-USER '; iptables-save -t nat | strip
  # nft tables NOT managed by iptables (those are covered above) and not the
  # two CI tables under test.
  nft -s list ruleset 2>/dev/null | grep -v '^# Warning' \
    | awk '/^table (ip|ip6) (filter|nat|mangle|raw|security) \{|^table inet ci_egress(_tw)? \{/{skip=1} skip&&/^\}/{skip=0; next} !skip'
}
duser() { iptables -S DOCKER-USER; }
keel_table() { nft -s list table inet ci_egress 2>/dev/null | sha256sum | cut -c1-16; }
tw_table() { nft -s list table inet ci_egress_tw 2>/dev/null | sha256sum | cut -c1-16; }
BASE_UNREL="$(unrelated | sha256sum | cut -c1-16)"

install -D -m 0600 "$K/ci-egress.nft" /etc/nftables.d/ci-egress.nft
install -D -m 0600 "$T/ci-egress.nft" /etc/nftables.d/ci-egress-tw.nft
install -m 0700 "$K/ci-egress-apply.sh" /usr/local/sbin/ci-egress-apply
install -m 0700 "$T/ci-egress-apply.sh" /usr/local/sbin/ci-egress-tw-apply

# ── Control 2: nft tables alone (no DOCKER-USER half) → allowed egress fails ─
nft -f /etc/nftables.d/ci-egress.nft && nft -f /etc/nftables.d/ci-egress-tw.nft
if ! tcp_ok vmt 198.51.100.5 443 && ! tcp_ok vmk 198.51.100.5 443; then
  ok "control: without the appliers' DOCKER-USER rules Docker's FORWARD DROP blocks even allowed egress"
else
  bad "control: DOCKER-USER necessity" "egress passed without DOCKER-USER rules"
fi
nft delete table inet ci_egress; nft delete table inet ci_egress_tw

check_state() { # label
  local label="$1"
  [ "$(unrelated | sha256sum | cut -c1-16)" = "$BASE_UNREL" ] \
    && ok "$label: Docker/Tailscale/other iptables and nft rules byte-identical (no counters)" \
    || bad "$label: unrelated rules changed" "$(diff <(echo) <(unrelated) | head -5)"
  local d; d="$(duser)"
  if [ "$(grep -c -- '-A DOCKER-USER -i lxdbr0 -j ACCEPT' <<<"$d")" = 1 ] \
     && [ "$(grep -c -- '-A DOCKER-USER -o lxdbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT' <<<"$d")" = 1 ] \
     && [ "$(grep -c -- '-A DOCKER-USER -i citwbr0 -j ACCEPT' <<<"$d")" = 1 ] \
     && [ "$(grep -c -- '-A DOCKER-USER -o citwbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT' <<<"$d")" = 1 ] \
     && [ "$(tail -1 <<<"$d")" = "-A DOCKER-USER -j RETURN" ] && [ "$(grep -c -- '^-A' <<<"$d")" = 5 ]; then
    ok "$label: DOCKER-USER holds each runner's two rules exactly once, Docker's RETURN last"
  else
    bad "$label: DOCKER-USER" "$(tr '\n' ';' <<<"$d")"
  fi
}

# ── Order A: Keel first, then TrueWealth, then TrueWealth again ─────────────
/usr/local/sbin/ci-egress-apply >/dev/null
KEEL_A="$(keel_table)"
/usr/local/sbin/ci-egress-tw-apply >/dev/null
[ "$(keel_table)" = "$KEEL_A" ] && ok "order A: applying TrueWealth leaves Keel's table byte-identical" || bad "order A: Keel table changed" "$KEEL_A -> $(keel_table)"
check_state "order A"
run_flows "order A (Keel → TrueWealth): every flow meets the contract" expect
TW_A="$(tw_table)"
/usr/local/sbin/ci-egress-tw-apply >/dev/null; /usr/local/sbin/ci-egress-tw-apply >/dev/null
[ "$(keel_table)" = "$KEEL_A" ] && [ "$(tw_table)" = "$TW_A" ] && ok "re-applying TrueWealth twice: both tables unchanged" || bad "re-apply TW" "keel $(keel_table) tw $(tw_table)"
check_state "after re-applying TrueWealth"
/usr/local/sbin/ci-egress-apply >/dev/null
[ "$(tw_table)" = "$TW_A" ] && ok "re-applying Keel leaves TrueWealth's table unchanged" || bad "re-apply Keel" "tw $(tw_table)"
check_state "after re-applying Keel"
run_flows "after re-application: every flow still meets the contract" expect

# ── Order B: from scratch, TrueWealth first, then Keel ──────────────────────
nft delete table inet ci_egress; nft delete table inet ci_egress_tw
for b in lxdbr0 citwbr0; do
  iptables -D DOCKER-USER -i $b -j ACCEPT
  iptables -D DOCKER-USER -o $b -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
done
[ "$(unrelated | sha256sum | cut -c1-16)" = "$BASE_UNREL" ] && [ "$(duser | grep -c -- '^-A')" = 1 ] \
  && ok "between orders: back to the baseline (test-owned rules removed by exact match)" || bad "reset" "state differs"
/usr/local/sbin/ci-egress-tw-apply >/dev/null
TW_B="$(tw_table)"
/usr/local/sbin/ci-egress-apply >/dev/null
[ "$(tw_table)" = "$TW_B" ] && ok "order B: applying Keel leaves TrueWealth's table byte-identical" || bad "order B: TW table changed" "$TW_B -> $(tw_table)"
[ "$(keel_table)" = "$KEEL_A" ] && [ "$TW_B" = "$TW_A" ] && ok "both tables are identical whichever order they were applied in" || bad "order independence" "keel $(keel_table)/$KEEL_A tw $TW_B/$TW_A"
check_state "order B"
run_flows "order B (TrueWealth → Keel): every flow meets the contract" expect

# ── Control 3: the structure checks detect a real change ───────────────────
iptables -A ts-forward -i tailscale0 -j ACCEPT
[ "$(unrelated | sha256sum | cut -c1-16)" != "$BASE_UNREL" ] && ok "control: a changed Tailscale rule IS detected by the unrelated-rules comparison" \
  || bad "control: unrelated-rules sensitivity" "a changed rule went unnoticed"
iptables -D ts-forward -i tailscale0 -j ACCEPT
iptables -I DOCKER-USER -i citwbr0 -j ACCEPT
[ "$(duser | grep -c -- '-A DOCKER-USER -i citwbr0 -j ACCEPT')" = 2 ] && ok "control: a duplicated DOCKER-USER rule IS visible to the exactly-once check" \
  || bad "control: DOCKER-USER sensitivity" "duplicate not visible"
iptables -D DOCKER-USER -i citwbr0 -j ACCEPT

printf -- '── combined policies: %d passed, %d failed ──\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
