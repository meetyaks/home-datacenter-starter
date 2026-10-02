#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# THE MANAGEMENT-NODE GUARD, EXECUTED.
#
#   tests/run-dns-controller-guard.sh
#
# ⚠️ WHY THIS IS A SCRIPT AND NOT AN ASSERTION ABOUT playbooks/dns.yml.
# Grepping the playbook for the guard proves the text exists. It does not
# prove the guard FIRES — and the thing being prevented is severe enough to
# deserve the real thing: `dns_servers` configures dc1-arm-1 over a LOCAL
# connection, so running playbooks/dns.yml on any other machine would install
# a LAN DNS server and a launchd daemon on THAT machine. On a laptop that
# leaves the house, that is a permanent service on the wrong host serving a
# zone for a network it is not on.
#
# So this RUNS the playbook here and requires it to refuse. On the real
# management node it is skipped, loudly — there the guard is supposed to pass,
# and a test that demanded a refusal would fail for the right configuration.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0
fail=0
ok()  { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }

WHOAMI=$(hostname -s 2>/dev/null || hostname)

echo "── the guard in playbooks/dns.yml, run on this machine (${WHOAMI}) ──"

if printf '%s' "$WHOAMI" | grep -qi '^dc1-arm-1'; then
  echo "  SKIP  this IS dc1-arm-1, where the guard is supposed to PASS."
  echo "        The refusal is proved on any other machine; run this from a"
  echo "        workstation to see it fire."
  echo
  echo "  Checking the guard still accepts this node instead:"
  if ansible-playbook playbooks/dns-controller-guard.yml >/tmp/dns-guard.log 2>&1; then
    ok "the guard accepts dc1-arm-1"
  else
    bad "the guard accepts dc1-arm-1" "it refused its own management node; see /tmp/dns-guard.log"
  fi
else
  # ⚠️ THE GUARD'S OWN PLAYBOOK, NOT dns.yml WITH A `--limit`. The first
  # version ran `playbooks/dns.yml --limit localhost` to isolate the guard
  # play; that left the second play with no hosts, and Ansible aborted the
  # whole run with "leaves us with no hosts to target" BEFORE evaluating the
  # guard. Exit status was non-zero, so the refusal looked proved — it was
  # not. The "refused for the right reason" check below is what caught it, and
  # the guard now lives in its own importable playbook so it can be run alone.
  if ansible-playbook playbooks/dns-controller-guard.yml >/tmp/dns-guard.log 2>&1; then
    bad "the playbook refuses to run outside dc1-arm-1" \
        "it SUCCEEDED on ${WHOAMI} — a local connection here would install DNS on this machine"
  else
    ok "refused on ${WHOAMI}, as it must be"

    # ⚠️ REFUSED FOR THE RIGHT REASON. A playbook that failed because of a
    # syntax error, a missing role or an unreachable host would also be
    # "non-zero", and would pass a check that only looked at the exit status —
    # while the guard itself was never evaluated.
    if grep -q 'REFUSING: this is' /tmp/dns-guard.log; then
      ok "refused by the management-node guard, naming this machine"
    else
      bad "refused by the guard" "non-zero for some other reason; see /tmp/dns-guard.log"
      tail -5 /tmp/dns-guard.log | sed 's/^/           /'
    fi

    if grep -q 'management node is dc1-arm-1' /tmp/dns-guard.log; then
      ok "the refusal says where to run it instead"
    else
      bad "the refusal names the right machine" "it refused without saying where to go"
    fi

    # And nothing may have been installed by the attempt.
    if [ -e /Library/LaunchDaemons/org.coredns.coredns.plist ]; then
      bad "nothing was installed on this machine" \
          "/Library/LaunchDaemons/org.coredns.coredns.plist exists on ${WHOAMI}"
    else
      ok "no CoreDNS daemon was installed on ${WHOAMI}"
    fi
    if [ -e /usr/local/etc/coredns/Corefile ]; then
      bad "nothing was installed on this machine" \
          "/usr/local/etc/coredns/Corefile exists on ${WHOAMI}"
    else
      ok "no Corefile was written on ${WHOAMI}"
    fi
  fi
fi

echo
if [ "$fail" -gt 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) checks." >&2
  exit 1
fi
echo "PASS — $pass checks."
