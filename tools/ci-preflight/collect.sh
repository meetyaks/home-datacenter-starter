#!/usr/bin/env bash
# READ-ONLY fact collection for a new CI runner VM on dc1-x86. Run it through
# playbooks/ci-runner-truewealth-preflight.yml (Ansible's `script` module, as
# root via --ask-become-pass). It changes nothing: every command below only
# reads, and it writes only to its own temporary directory, removed on exit.
#
# Output: ONE JSON document on stdout. Every section records the exact command,
# its exit status and its raw output; a missing tool or a failed command is
# recorded as such, never guessed. tools/ci-preflight/evaluate.py decides —
# and fails closed on anything it cannot read.
set -uo pipefail
export LC_ALL=C
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
n=0
cap() { # name, command…
  local name="$1"; shift
  n=$((n + 1))
  printf '%s' "$name" > "$T/$n.name"; printf '%s ' "$@" > "$T/$n.cmd"
  if command -v "$1" >/dev/null 2>&1; then
    timeout 60 "$@" > "$T/$n.out" 2> "$T/$n.err"; echo $? > "$T/$n.rc"
  else
    : > "$T/$n.out"; echo "not installed: $1" > "$T/$n.err"; echo 127 > "$T/$n.rc"
  fi
}

cap nproc              nproc
cap meminfo            cat /proc/meminfo
cap uname              uname -srm
cap lxc_list           lxc list --format json
cap lxc_networks       lxc network list --format json
cap lxc_storage        lxc storage list --format json
cap lxc_profiles       lxc profile list --format json
cap lxc_version        lxc version
cap vgs                vgs --reportformat json --units b --nosuffix -o vg_name,vg_size,vg_free
cap lvs                lvs --reportformat json --units b --nosuffix -o lv_name,vg_name,lv_size,lv_attr
cap docker_ps          docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
cap docker_stats       docker stats --no-stream --format '{{json .}}'
cap docker_limits      sh -c 'docker ps -q | xargs -r docker inspect --format "{{json .}}" | python3 -c "import json,sys
for l in sys.stdin:
  d=json.loads(l); print(json.dumps({\"name\":d[\"Name\"].lstrip(\"/\"),\"memory\":d[\"HostConfig\"][\"Memory\"],\"nanoCpus\":d[\"HostConfig\"][\"NanoCpus\"]}))"'
cap ip4_addr           ip -j -4 addr
cap ip6_addr           ip -j -6 addr
cap ip4_routes         ip -j -4 route show table all
cap ip6_routes         ip -j -6 route show table all
cap nft_tables         nft -j list tables
cap docker_forward     iptables -S FORWARD
cap sysctl_net         sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv6.conf.all.disable_ipv6
cap units              systemctl list-unit-files --no-legend --no-pager 'ci-egress*' 'snap.lxd*' 'lxd*' 'docker.service'
cap df                 df -B1 --output=target,size,avail / /var/lib /srv/data
cap loadavg            cat /proc/loadavg

python3 - "$T" "$n" <<'PY'
import json, sys, os
d, n = sys.argv[1], int(sys.argv[2])
out = {"schema": "ci-preflight-facts/1", "sections": {}}
for i in range(1, n + 1):
    r = lambda ext: open(os.path.join(d, f"{i}.{ext}"), errors="replace").read()
    out["sections"][r("name")] = {"cmd": r("cmd").strip(), "rc": int(r("rc")), "stdout": r("out"), "stderr": r("err")[-2000:]}
print(json.dumps(out))
PY
