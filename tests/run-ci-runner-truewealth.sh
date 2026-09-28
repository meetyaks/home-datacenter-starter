#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# A SECOND CI RUNNER ON THE SAME HOST, ISOLATED FROM THE FIRST AND FROM
# PRODUCTION — and the first one unchanged by its arrival.
#
#   tests/run-ci-runner-truewealth.sh      static, controller-only
#
# dc1-ci-tw-1 (TrueWealth) is a second instance of roles/ci_runner beside
# dc1-ci-1 (Keel). Keel's completed hook destroys every container and volume on
# its daemon, so sharing that daemon is unsafe for both; the boundary here is a
# separate VM with its own disk, bridge, subnet, egress table and runner.
#
# What this proves, statically:
#   1. the TrueWealth play and every role entry point still parse;
#   2. the instance renders with the role's own templates and valid shell;
#   3. it shares NO host-side name with Keel's instance, and its subnet does
#      not overlap anything the repository records;
#   4. its egress policy has the sibling-isolation rules and wider denies;
#   5. it registers to TrueWealth only, with exactly the required labels;
#   6. KEEL'S INSTANCE RENDERS BYTE-IDENTICALLY to the commit this change is
#      based on, and its task-level egress values are unchanged;
#   7. both policies are accepted by a real nft (in a throwaway container);
#   8. the preflight sibling/stranger and capacity decisions (role expressions,
#      fabricated `lxc list` output).
#
# What it cannot prove: anything about the live host (capacity, routes, the
# LAN address, LXD's actual state). Those are collected through dc1-arm-1 and
# are enforced again by preflight at provisioning time.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.."

R="${TMPDIR:-/tmp}/ci-runner-tw.$$"
mkdir -p "$R/tw" "$R/keel-now" "$R/keel-base"
trap 'rm -rf "$R"' EXIT

pass=0
fail=0
ok()   { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }
skip() { printf '  \033[33mskip\033[0m  %s\n         %s\n' "$1" "$2"; }

# The commit the multi-instance change is based on. Keel's instance must
# render exactly as it did there.
BASE="${CI_RUNNER_BASE:-934ca20de24f7c3df82b01679ce439b1eea1f96b}"

echo "── 1. entry points parse ──"
if ansible-playbook --syntax-check playbooks/ci-runner-truewealth.yml > "$R/pb.log" 2>&1; then
  ok "playbooks/ci-runner-truewealth.yml parses"
else
  bad "playbooks/ci-runner-truewealth.yml parses" "$(tail -3 "$R/pb.log")"
fi
if ansible-playbook --syntax-check tests/ci-runner-parse.yml > "$R/parse.log" 2>&1; then
  ok "every ci_runner task file parses"
else
  bad "every ci_runner task file parses" "$(tail -3 "$R/parse.log")"
fi
if grep -q 'vars/ci-runner-truewealth.yml' playbooks/ci-runner-truewealth.yml \
   && ! grep -rqE 'ci-runner-truewealth|dc1-ci-tw-1|meetyaks/truewealth' inventory/ playbooks/ci-runner.yml playbooks/site.yml; then
  ok "TrueWealth values live in play vars only (not inventory, not Keel's play, not site.yml)"
else
  bad "TrueWealth values are play-scoped" "they would change what Keel's play renders or does"
fi

echo
echo "── 2. the TrueWealth instance renders ──"
if ansible-playbook tests/ci-runner-render-truewealth.yml -e render_dir="$R/tw" > "$R/render.log" 2>&1; then
  ok "all templates render with the TrueWealth vars and pass bash -n"
else
  bad "the TrueWealth instance renders" "$(tail -5 "$R/render.log")"
fi
names="$R/tw/host-names.txt"
keel="$R/tw/host-names-keel.txt"

echo
echo "── 3. no shared host-side name, no overlapping subnet ──"
if [ -f "$names" ] && [ -f "$keel" ]; then
  for k in vm lv mount pool bridge subnet table policy applier unit stage scope labels; do
    a="$(awk -v k="$k" '$1 == k { $1 = ""; print substr($0, 2); exit }' "$names")"
    b="$(awk -v k="$k" '$1 == k { $1 = ""; print substr($0, 2); exit }' "$keel")"
    a="${a%% reserve*}"; a="${a% [0-9]*g}"
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]; then
      ok "$k differs: '$a' vs Keel's '$b'"
    else
      bad "$k differs from Keel's" "TrueWealth '$a', Keel '$b'"
    fi
  done
  sub="$(awk '$1 == "subnet" { print $2 }' "$names")"
  case "$sub" in
    10.0.0.*|10.71.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*|100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*|169.254.*)
      bad "the subnet does not overlap a recorded network" "$sub overlaps the LAN, dc1-ci-1, Docker, Tailscale or link-local" ;;
    10.*.*.0/24) ok "subnet $sub is clear of the LAN (10.0.0.0/24), dc1-ci-1 (10.71.0.0/24), Docker, Tailscale" ;;
    *) bad "the subnet is a private /24" "got $sub" ;;
  esac
  if [ "${#sub}" -gt 0 ] && [ "$(awk '$1 == "bridge" { print length($2) }' "$names")" -le 15 ]; then
    ok "the bridge name fits Linux's 15-character interface limit"
  else
    bad "the bridge name fits IFNAMSIZ" "$(awk '$1 == "bridge"' "$names")"
  fi
else
  bad "host-side names recorded" "the render did not produce them"
fi

echo
echo "── 4. the TrueWealth egress policy ──"
nft="$R/tw/ci-egress.nft"
if [ -f "$nft" ]; then
  grep -q '^table inet ci_egress_tw {' "$nft" && ! grep -qE '^table inet ci_egress \{' "$nft" \
    && ok "its own table (ci_egress_tw), never Keel's (ci_egress)" \
    || bad "its own table" "it would replace Keel's table"
  grep -qE 'ip daddr 10\.0\.0\.0/8 counter drop' "$nft" \
    && ok "all of 10.0.0.0/8 is dropped — the LAN and dc1-ci-1's subnet" \
    || bad "10.0.0.0/8 is dropped" "the VM could reach the sibling CI subnet"
  missing=""
  for cidr in 100.64.0.0/10 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16; do
    grep -qE "ip daddr ${cidr//./\\.} counter drop" "$nft" || missing="$missing $cidr"
  done
  [ -z "$missing" ] && ok "Tailscale, Docker, other RFC1918 and link-local ranges are dropped" \
    || bad "every private range is dropped" "not dropped:$missing"
  grep -qE 'oifname "citwbr0" ct state new counter drop' "$nft" \
    && ok "nothing can open a connection INTO the TrueWealth bridge (sibling isolation)" \
    || bad "new inbound connections are dropped" "dc1-ci-1 could connect to dc1-ci-tw-1"
  if grep -qE 'ip daddr 10\.72\.0\.1 (udp|tcp) dport 53 counter accept' "$nft" \
     && ! grep -qE 'udp dport \{ 53, 67 \}' "$nft"; then
    ok "DNS is answered only by this bridge's own gateway"
  else
    bad "DNS is limited to the own gateway" "the VM could query dc1-ci-1's bridge resolver"
  fi
  input=$(awk '/chain input/{p=1} p&&/^  }/{exit} p' "$nft")
  echo "$input" | grep -qE '^\s+counter drop$' \
    && ok "every other host service is denied to anything on the bridge (catch-all keyed on the interface)" \
    || bad "host services are denied" "no interface-keyed catch-all drop in the input chain"
  # Hardening (ci_isolation_hardening): IPv6 and spoofed sources.
  [ "$(grep -cE 'meta nfproto ipv6 counter drop' "$nft")" -eq 3 ] \
    && ok "IPv6 is dropped from the bridge (input) and through it in both directions (forward)" \
    || bad "IPv6 dropped" "$(grep -n 'nfproto' "$nft")"
  grep -qE 'iifname "citwbr0" ip saddr != 10\.72\.0\.0/24 counter drop' "$nft" \
    && ok "a spoofed source address is dropped before any other forward rule" \
    || bad "spoofed sources dropped" "no saddr != subnet drop"
  grep -qE '^\s+iifname "citwbr0" counter drop$' "$nft" \
    && ok "the forward catch-all is keyed on the interface, not the source address" \
    || bad "interface-keyed forward catch-all" "missing"
  echo "$input" | grep -qE 'udp sport 68 udp dport 67 counter accept' \
    && ok "DHCP is admitted by its ports (a DISCOVER comes from 0.0.0.0)" \
    || bad "DHCP admitted" "missing"
  last=$(awk '/counter/{l=$0} END{print l}' "$nft")
  case "$last" in *drop*) ok "the last rule from the bridge is a drop" ;; *) bad "the last rule is a drop" "$last" ;; esac
  grep -q 'POLICY=/etc/nftables.d/ci-egress-tw.nft' "$R/tw/ci-egress-apply.sh" \
    && grep -q "BRIDGE='citwbr0'" "$R/tw/ci-egress-apply.sh" \
    && ok "its applier loads its own policy file and permits only its own bridge" \
    || bad "the applier is instance-scoped" "$(grep -E '^(POLICY|BRIDGE)=' "$R/tw/ci-egress-apply.sh")"
else
  bad "the TrueWealth egress policy renders" "no ci-egress.nft produced"
fi

echo
echo "── 5. registration: TrueWealth only, exact labels ──"
reg="$R/tw/register.sh"
if [ -f "$reg" ]; then
  grep -q "\-\-url 'https://github.com/meetyaks/truewealth'" "$reg" \
    && ok "repository-scoped to meetyaks/truewealth" \
    || bad "repository-scoped" "$(grep -- '--url' "$reg")"
  grep -q "\-\-labels 'self-hosted,linux,x64,local-dc-ci'" "$reg" \
    && ok "labels are exactly self-hosted,linux,x64,local-dc-ci" \
    || bad "labels are exact" "$(grep -- '--labels' "$reg")"
  grep -q "\-\-name 'dc1-ci-tw-1'" "$reg" && ok "registered under its own name (dc1-ci-tw-1)" \
    || bad "own runner name" "$(grep -- '--name' "$reg")"
  ! grep -q -- '--ephemeral' "$reg" && grep -q -- '--disableupdate' "$reg" \
    && ok "non-ephemeral with self-update disabled (the role's registration policy)" \
    || bad "registration policy" "unexpected flags"
else
  bad "the registration script renders" "not produced"
fi
started="$R/tw/job-started.sh"
if [ -f "$started" ]; then
  missing=""
  for p in '10.0.0.254:443' '10.0.0.254:5432' '10.71.0.1:53' '10.72.0.1:443'; do
    grep -q "'$p'" "$started" || missing="$missing $p"
  done
  [ -z "$missing" ] && ok "the started hook probes production (443/5432), dc1-ci-1's resolver and its own gateway" \
    || bad "every isolation probe is rendered" "missing:$missing"
fi
grep -q 'ci_tw_host_lan_ip is match' playbooks/ci-runner-truewealth.yml \
  && ok "the play refuses to run without the host's LAN address as an IPv4" \
  || bad "the LAN-address guard" "probes could render from a name and prove nothing"
if grep -qE '/srv|docker\.sock|source:' playbooks/vars/ci-runner-truewealth.yml; then
  bad "no host path, socket or device in the instance vars" "$(grep -nE '/srv|docker\.sock|source:' playbooks/vars/ci-runner-truewealth.yml)"
else
  ok "the instance vars add no host path, Docker socket or device"
fi

echo
echo "── 6. Keel's instance is unchanged ──"
if git cat-file -e "$BASE^{commit}" 2>/dev/null; then
  git archive "$BASE" roles/ci_runner tests/ci-runner-render.yml | tar -x -C "$R/keel-base"
  if (cd "$R/keel-base" && ansible-playbook tests/ci-runner-render.yml -e render_dir="$R/keel-base/out" \
        > "$R/keel-base.log" 2>&1 || { mkdir -p out && ansible-playbook tests/ci-runner-render.yml -e render_dir="$R/keel-base/out" > "$R/keel-base.log" 2>&1; }) \
     && ansible-playbook tests/ci-runner-render.yml -e render_dir="$R/keel-now" > "$R/keel-now.log" 2>&1; then
    # ONE reviewed exception: the guest registration/removal scripts now hand
    # the token to the runner as ACTIONS_RUNNER_INPUT_TOKEN instead of
    # --token (it was a process argument inside the guest). Everything else
    # must be byte-identical; for those three files, only comment lines and
    # lines naming the token may differ.
    if diff -r -x 'register.sh' -x 'register-ephemeral.sh' -x 'unregister.sh' "$R/keel-base/out" "$R/keel-now" > "$R/keel.diff"; then
      ok "every other Keel artefact renders byte-identically to $BASE ($(ls "$R/keel-now" | wc -l | tr -d ' ') files)"
    else
      bad "Keel renders identically" "$(head -20 "$R/keel.diff")"
    fi
    norm() { sed -E 's/ --token "\$TOKEN"//' "$1" | grep -vE '^\s*#|TOKEN|^\s*\\$'; }
    tokdiff=""
    for g in register.sh register-ephemeral.sh unregister.sh; do
      diff <(norm "$R/keel-base/out/$g") <(norm "$R/keel-now/$g") >/dev/null || tokdiff="$tokdiff $g"
      grep -vE '^\s*#' "$R/keel-now/$g" | grep -q -- '--token' && tokdiff="$tokdiff $g(--token)"
      grep -q 'export ACTIONS_RUNNER_INPUT_TOKEN="\$TOKEN"' "$R/keel-now/$g" || tokdiff="$tokdiff $g(no env)"
    done
    [ -z "$tokdiff" ] \
      && ok "Keel's guest register/unregister scripts differ ONLY in token transport (env, not --token)" \
      || bad "Keel token-transport change is the only difference" "$tokdiff"
  else
    bad "Keel renders at both commits" "$(tail -3 "$R/keel-base.log" "$R/keel-now.log")"
  fi
else
  skip "Keel renders identically to the base" "commit $BASE is not in this clone"
fi
if ansible-playbook tests/ci-runner-multi-instance.yml > "$R/multi.log" 2>&1; then
  ok "Keel's defaults: same host-side names, capacity check / VG reserve / sibling isolation off"
else
  bad "Keel's defaults are unchanged" "$(grep -E 'FAILED|msg' "$R/multi.log" | head -3)"
fi

echo
echo "── 7. a real nft accepts both policies ──"
if command -v nft >/dev/null 2>&1; then
  nft -c -f "$nft" > "$R/nft.log" 2>&1 && ok "nft accepts the TrueWealth policy" || bad "nft accepts the policy" "$(tail -3 "$R/nft.log")"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  img="${NFT_TEST_IMAGE:-ubuntu:24.04}"
  # A throwaway container with its own network namespace: -c only parses and
  # checks the ruleset, and nothing is loaded on this controller.
  if docker run --rm --cap-add NET_ADMIN -v "$R/tw:/tw:ro" -v "$R/keel-now:/keel:ro" "$img" \
       sh -c 'apt-get -qq update >/dev/null && apt-get -qq install -y nftables >/dev/null \
              && nft -c -f /tw/ci-egress.nft && nft -c -f /keel/ci-egress.nft' > "$R/nft.log" 2>&1; then
    ok "nft (in a throwaway $img container) accepts the TrueWealth and Keel policies"
  else
    bad "nft accepts both policies" "$(tail -5 "$R/nft.log")"
  fi
else
  skip "nft accepts both policies" "no nft and no Docker on this controller; the role validates on the host"
fi

echo
echo "── 8. preflight decisions for two instances ──"
if grep -q 'failed=0' "$R/multi.log"; then
  n=$(grep -cE '^TASK \[(Keel|TrueWealth) ' "$R/multi.log")
  ok "sibling/stranger and capacity scenarios hold ($n role-expression scenarios)"
else
  bad "preflight scenarios" "$(grep -E 'FAILED|msg' "$R/multi.log" | head -3)"
fi


# Sections 9 and 10 need real Linux behaviour (runuser, /proc, network
# namespaces, nftables). They run in a throwaway container built from
# tests/tools/test-tools.Dockerfile (pinned base), labelled for exact cleanup.
TOOLS_IMAGE=""
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if docker build -q --label twtask=hds-test-tools -t hds-test-tools:local \
       -f tests/tools/test-tools.Dockerfile tests/tools > "$R/tools.log" 2>&1; then
    TOOLS_IMAGE=hds-test-tools:local
  fi
fi

echo
echo "── 9. runner tokens never become process arguments (synthetic tokens) ──"
if [ -n "$TOOLS_IMAGE" ]; then
  if docker run --rm --label twtask=hds-token-test -v "$PWD:/repo:ro" "$TOOLS_IMAGE" \
       bash /repo/tests/ci-runner-token-harness.sh > "$R/token.log" 2>&1; then
    ok "register/unregister token handling: $(grep -o '[0-9]* passed' "$R/token.log" | tail -1) (tests/ci-runner-token-harness.sh)"
  else
    bad "token handling" "$(grep -A1 FAIL "$R/token.log" | head -8)"
  fi
else
  skip "token handling" "needs Docker to build the Linux test toolbox"
fi

echo
echo "── 10. the rendered policies, with real packets (network namespaces) ──"
if [ -n "$TOOLS_IMAGE" ]; then
  if docker run --rm --privileged --label twtask=hds-egress-test -v "$R/tw:/p:ro" -v "$PWD/tests:/t:ro" "$TOOLS_IMAGE" \
       bash /t/ci-egress-netns.sh /p/ci-egress.nft citwbr0 10.72.0.1/24 10.72.0.50 hardened > "$R/netns-tw.log" 2>&1; then
    ok "TrueWealth (hardened): $(grep -o '[0-9]* passed' "$R/netns-tw.log" | tail -1) packet-level expectations — IPv6, spoofed sources, host services, LAN and inbound refused; 443 out allowed"
  else
    bad "TrueWealth policy with real packets" "$(grep -A1 FAIL "$R/netns-tw.log" | head -8)"
  fi
  # Keel's policy is unchanged by this work. The same probes RECORD its
  # behaviour: its IPv4 denies hold, and the IPv6 and spoofed-source paths are
  # open (a finding for Keel's instance, not changed here).
  if docker run --rm --privileged --label twtask=hds-egress-test -v "$R/keel-now:/p:ro" -v "$PWD/tests:/t:ro" "$TOOLS_IMAGE" \
       bash /t/ci-egress-netns.sh /p/ci-egress.nft lxdbr0 10.71.0.1/24 10.71.0.50 default > "$R/netns-keel.log" 2>&1; then
    ok "Keel (unchanged) behaves as documented: IPv4 denies hold; IPv6 to host services and spoofed sources pass (recorded finding)"
  else
    bad "Keel policy behaves as documented" "$(grep -A1 FAIL "$R/netns-keel.log" | head -8)"
  fi
else
  skip "policies with real packets" "needs Docker (privileged, network namespaces)"
fi


echo
echo "── 11. the read-only capacity/network preflight (fixtures; no host contact) ──"
if PYTHONDONTWRITEBYTECODE=1 python3 tests/ci-preflight/test_evaluate.py > "$R/pf-unit.log" 2>&1; then
  ok "evaluator decisions: $(grep -o 'Ran [0-9]* tests' "$R/pf-unit.log") (limits incl. inherited/percent/pinned, headroom, storage, names, subnet in addresses/routes/LXD/LAN, unknowns fail closed)"
else
  bad "evaluator fixture tests" "$(tail -8 "$R/pf-unit.log")"
fi
PYTHONDONTWRITEBYTECODE=1 python3 tests/ci-preflight/test_evaluate.py --dump-fixture "$R/pf-ready.json"
PYTHONDONTWRITEBYTECODE=1 python3 tests/ci-preflight/test_evaluate.py --dump-overlap-fixture "$R/pf-overlap.json"
if HOME="$R/pfhome" ansible-playbook playbooks/ci-runner-truewealth-preflight.yml -e preflight_host=localhost \
     -e ansible_connection=local -e preflight_facts_file="$R/pf-ready.json" > "$R/pf-play.log" 2>&1 \
   && grep -q 'preflight: PASS' "$R/pf-play.log" \
   && [ "$(stat -f %Lp "$R/pfhome/ci-preflight/dc1-ci-tw-1" 2>/dev/null || stat -c %a "$R/pfhome/ci-preflight/dc1-ci-tw-1")" = 700 ]; then
  ok "the playbook renders the plan from the vars and passes a host with room (report dir 0700)"
else
  bad "preflight playbook (ready fixture)" "$(grep -E 'FAIL|UNKNOWN|fatal|msg' "$R/pf-play.log" | head -4)"
fi
if ! HOME="$R/pfhome2" ansible-playbook playbooks/ci-runner-truewealth-preflight.yml -e preflight_host=localhost \
       -e ansible_connection=local -e preflight_facts_file="$R/pf-overlap.json" > "$R/pf-play2.log" 2>&1 \
   && grep -q 'NOT READY' "$R/pf-play2.log" && grep -q 'FAIL    subnet vs routes' "$R/pf-play2.log"; then
  ok "the playbook refuses a host whose routing tables already use the subnet"
else
  bad "preflight playbook (overlap fixture)" "$(tail -5 "$R/pf-play2.log")"
fi
# Controller identity: the implicit localhost inherits `all`-group variables.
# With the TARGET's identity set there (a Linux user that does not exist on
# this controller, become, a remote temp under that user's home) and the play
# running with become, the delegated report tasks must still run locally as
# THIS controller user, without sudo, with a private temp dir under its HOME.
ctl_user="$(id -un)"
cat > "$R/pf-allvars.yml" <<'INV'
all:
  vars:
    ansible_user: labadmin-synthetic
    ansible_ssh_private_key_file: /nonexistent/home_datacenter_admin
    ansible_become: true
    ansible_become_method: sudo
    ansible_remote_tmp: /home/labadmin-synthetic/.ansible/tmp
    ansible_python_interpreter: /nonexistent/python3
  hosts:
    dc1-x86-synthetic:
      ansible_host: 192.0.2.10
INV
mkdir -p "$R/pfhome3"
if [ "$ctl_user" != labadmin-synthetic ] \
   && HOME="$R/pfhome3" ansible-playbook -i "$R/pf-allvars.yml" playbooks/ci-runner-truewealth-preflight.yml --become \
        -e preflight_host=dc1-x86-synthetic -e preflight_facts_file="$R/pf-ready.json" > "$R/pf-ctl.log" 2>&1 </dev/null \
   && grep -q 'preflight: PASS' "$R/pf-ctl.log" \
   && [ "$(stat -f '%Su %Lp' "$R/pfhome3/ci-preflight/dc1-ci-tw-1" 2>/dev/null || stat -c '%U %a' "$R/pfhome3/ci-preflight/dc1-ci-tw-1")" = "$ctl_user 700" ] \
   && [ "$(stat -f '%Lp' "$R/pfhome3/ci-preflight/dc1-ci-tw-1/facts.json" 2>/dev/null || stat -c '%a' "$R/pfhome3/ci-preflight/dc1-ci-tw-1/facts.json")" = 600 ] \
   && [ -d "$R/pfhome3/.ansible/tmp" ]; then
  ok "controller tasks run as the controller user ($ctl_user), no sudo, temp under its HOME — even with the target's identity in all-group vars"
else
  bad "controller identity for delegated tasks" "$(grep -m2 -oE 'fatal: .{0,200}' "$R/pf-ctl.log")"
fi
n_deleg=$(grep -rhE '^\s*delegate_to: localhost' playbooks roles/ci_runner | wc -l | tr -d ' ')
n_pinned=$(grep -rhE '^\s*vars: (&controller_connection|\*controller_connection)' playbooks roles/ci_runner | wc -l | tr -d ' ')
n_role=$(grep -rhE '^\s*delegate_to: localhost' roles/ci_runner playbooks/ci-runner.yml playbooks/ci-runner-truewealth.yml | wc -l | tr -d ' ')
[ "$n_deleg" -gt 0 ] && [ "$n_deleg" = "$n_pinned" ] && [ "$n_role" = 0 ] \
  && ok "every localhost-delegated task pins the controller connection ($n_pinned); provisioning and the runner role delegate none" \
  || bad "delegated tasks pinned" "delegated=$n_deleg pinned=$n_pinned in provisioning/role=$n_role"

if [ -n "$TOOLS_IMAGE" ]; then
  # The REAL collector on a Linux box that has none of LXD, Docker or LVM:
  # it must still emit a complete document, and the evaluator must refuse.
  if docker run --rm --label twtask=hds-preflight-test -v "$PWD:/repo:ro" "$TOOLS_IMAGE" \
       bash /repo/tools/ci-preflight/collect.sh > "$R/pf-collected.json" 2> "$R/pf-collect.err"; then
    python3 tools/ci-preflight/evaluate.py "$R/pf-collected.json" "$R/pfhome/ci-preflight/dc1-ci-tw-1/plan.json" > "$R/pf-eval.log" 2>&1; erc=$?
    if [ "$erc" -ne 0 ] && grep -q 'UNKNOWN cpu' "$R/pf-eval.log" && grep -q 'not installed: lxc' "$R/pf-eval.log"; then
      ok "the real collect.sh runs and missing tools are UNKNOWN, so the verdict is NOT READY"
    else
      bad "collector + evaluator fail closed" "rc=$erc $(tail -3 "$R/pf-eval.log")"
    fi
  else
    bad "collect.sh runs" "$(tail -3 "$R/pf-collect.err")"
  fi
else
  skip "real collector" "needs Docker"
fi

echo
echo "── 12. Keel's and TrueWealth's policies loaded TOGETHER (real packets, both orders) ──"
if [ -n "$TOOLS_IMAGE" ]; then
  if docker run --rm --privileged --label twtask=hds-egress-test -v "$R/keel-now:/k:ro" -v "$R/tw:/t:ro" -v "$PWD/tests:/tests:ro" "$TOOLS_IMAGE" \
       bash /tests/ci-egress-combined-netns.sh /k /t > "$R/netns-combined.log" 2>&1; then
    ok "both rendered policies and appliers together: $(grep -o '[0-9]* passed' "$R/netns-combined.log" | tail -1) — both orders, re-application, controls; Keel's table and unrelated rules unchanged"
  else
    bad "combined policies" "$(grep -A1 FAIL "$R/netns-combined.log" | head -8)"
  fi
else
  skip "combined policies" "needs Docker (privileged, network namespaces)"
fi

echo
echo "── 13. activation tooling: tools/ci-activation (stand-ins; no host contact) ──"
# hostcheck.sh (fail-closed snapshots, completion records, compare, probe verdicts) and
# provision-truewealth.sh (exact-commit checkout, implementation unchanged from the checked
# revision, the before-record gate, exit-status propagation).
if bash tests/ci-activation/test-activation.sh > "$R/activation.log" 2>&1; then
  ok "activation tooling: $(grep -o '[0-9]* passed, [0-9]* failed' "$R/activation.log" | tail -1)"
else
  bad "activation tooling" "$(grep -A1 'FAIL' "$R/activation.log" | head -12)"
fi
if [ -n "$TOOLS_IMAGE" ]; then
  if docker run --rm --privileged --network none --label twtask=hds-activation-test -v "$R/tw:/t:ro" \
       -v "$PWD/tools/ci-activation:/a:ro" -v "$PWD/tests/ci-activation:/ta:ro" "$TOOLS_IMAGE" \
       bash /ta/policy-listing.sh /t /a/hostcheck.sh > "$R/activation-listing.log" 2>&1; then
    ok "the probe's expected table equals the rendered policy as a real nft lists it"
  else
    bad "the probe's expected table matches the rendered policy" "$(head -30 "$R/activation-listing.log")"
  fi
else
  skip "probe's expected table vs a real nft listing" "needs Docker (privileged)"
fi
echo
printf '── %d passed, %d failed ──\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
