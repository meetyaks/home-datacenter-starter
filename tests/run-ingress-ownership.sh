#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# REGRESSION — ingress has ONE owner, runs FIRST, and the Keel route is correct.
#
#   tests/run-ingress-ownership.sh
#
# ═══ WHAT THIS IS ABOUT ══════════════════════════════════════════════════════
#
# A deployment finished with every Keel service healthy and completely
# unreachable: there was no Caddy on the host. The Keel role had always deferred
# to "separately managed shared infrastructure" that nothing in this repository
# ever managed.
#
# Three things have to stay true now, and none of them needs a host to check:
#
#   1. roles/caddy owns the package, the service and the main Caddyfile, and
#      roles/keel owns exactly one drop-in.
#   2. Caddy is provisioned BEFORE Keel, in the same play, and Keel's preflight
#      refuses to spend a build otherwise.
#   3. The Keel route uses the console's same-origin mount rather than splitting
#      ~80 gateway prefixes from the SPA's router by path — which cannot be done
#      correctly, because several prefixes belong to both.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0
fail=0
ok()  { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }

# ── 1. One owner ───────────────────────────────────────────────────────────
echo "── 1. ingress has exactly one owner ──"

[ -f roles/caddy/tasks/main.yml ] && ok "roles/caddy exists" \
  || bad "roles/caddy exists" "no dedicated ingress role"

if grep -qE '^\s*- name:\s*Install Caddy\s*$' roles/caddy/tasks/main.yml; then
  ok "roles/caddy installs the package"
else
  bad "roles/caddy installs the package" "no install task found"
fi

# The Keel role must NOT install Caddy, own its service, or write the main file.
offenders=$(grep -rnE 'apt:|systemd_service:|systemd:' roles/keel/tasks/ 2>/dev/null \
            | grep -viE 'docker|^\s*#' || true)
if [ -z "$offenders" ]; then
  ok "roles/keel installs no packages and manages no services"
else
  bad "roles/keel stays out of service management" "found:"
  printf '%s\n' "$offenders" | head -4 | sed 's/^/           /'
fi

# DOCUMENTATION IS NOT CODE. The README has to name the file on the other side
# of the ownership boundary in order to describe it, and an earlier version of
# this check grepped the whole role directory and failed on its own prose —
# the same way a check once failed on a module's comment saying it had no
# subprocess call. Only executable content is searched.
writes_main=$(grep -rn --include='*.yml' --include='*.j2' --include='*.py' \
              'caddy_config_file\|/etc/caddy/Caddyfile' roles/keel/ 2>/dev/null || true)
if [ -n "$writes_main" ]; then
  bad "roles/keel never writes the main Caddyfile" "it references the main Caddyfile"
  printf '%s\n' "$writes_main" | head -3 | sed 's/^/           /'
else
  ok "roles/keel never references the main Caddyfile (in code)"
fi

# Exactly one drop-in, and it is Keel's own.
dropins=$(grep -rhoE 'keel_caddy_site_file|conf\.d/[a-z-]+\.caddy' roles/keel/tasks/ roles/keel/defaults/ 2>/dev/null | sort -u | wc -l | tr -d ' ')
if [ "$dropins" -ge 1 ] && grep -q 'keel_caddy_site_file' roles/keel/tasks/caddy.yml; then
  ok "roles/keel writes exactly its own drop-in"
else
  bad "roles/keel writes exactly its own drop-in" "found $dropins references"
fi

# The reload handler belongs to the owner, and must not be duplicated.
if grep -q 'name: Reload Caddy' roles/caddy/handlers/main.yml; then
  ok "roles/caddy defines the Reload Caddy handler"
else
  bad "roles/caddy defines Reload Caddy" "missing"
fi
if grep -qE '^\s*-\s*name:\s*Reload Caddy\s*$' roles/keel/handlers/main.yml; then
  bad "the handler is not duplicated" "roles/keel also defines Reload Caddy — ambiguous resolution"
else
  ok "roles/keel does not duplicate the handler (it only notifies)"
fi

# ── 2. Ordering and the early gate ─────────────────────────────────────────
echo
echo "── 2. Caddy is provisioned before Keel, and Keel refuses otherwise ──"

caddy_line=$(grep -n 'name: caddy' playbooks/keel.yml | head -1 | cut -d: -f1)
keel_line=$(grep -n 'name: keel' playbooks/keel.yml | head -1 | cut -d: -f1)
if [ -n "$caddy_line" ] && [ -n "$keel_line" ] && [ "$caddy_line" -lt "$keel_line" ]; then
  ok "the playbook includes caddy (line $caddy_line) before keel (line $keel_line)"
else
  bad "caddy runs before keel" "caddy at '${caddy_line:-absent}', keel at '${keel_line:-absent}'"
fi

if grep -q 'caddy_role_applied' roles/caddy/tasks/main.yml; then
  ok "roles/caddy publishes caddy_role_applied"
else
  bad "roles/caddy publishes the fact" "nothing for Keel's preflight to assert on"
fi

if grep -q 'caddy_role_applied' roles/keel/tasks/preflight.yml; then
  ok "Keel's PREFLIGHT asserts it (before any build is spent)"
else
  bad "Keel asserts the fact in preflight" "not found in preflight.yml"
fi

# It must be asserted in preflight, not only discovered at the caddy step —
# that is the difference between failing in seconds and failing after two
# image builds and a stack start.
pre_line=$(grep -n 'caddy_role_applied' roles/keel/tasks/preflight.yml | head -1 | cut -d: -f1)
arch_line=$(grep -n 'Confirm the target is the expected architecture' roles/keel/tasks/preflight.yml | head -1 | cut -d: -f1)
if [ -n "$pre_line" ] && [ -n "$arch_line" ] && [ "$pre_line" -lt "$arch_line" ]; then
  ok "the ingress gate is the FIRST preflight check (line $pre_line)"
else
  bad "the ingress gate is early" "at line ${pre_line:-absent}, architecture check at ${arch_line:-absent}"
fi

# ── 3. The route uses the same-origin mount ────────────────────────────────
echo
echo "── 3. the Keel route does not split gateway prefixes by path ──"

TPL=roles/keel/templates/keel.caddy.j2

if grep -qE '^\s*@api\b|path /auth|path /records' "$TPL"; then
  bad "no path-prefix API matcher" "the template still splits by prefix, which cannot be correct"
  grep -nE '@api|path /' "$TPL" | head -3 | sed 's/^/           /'
else
  ok "no @api path matcher remains"
fi

upstreams=$(grep -cE '^\s*reverse_proxy ' "$TPL")
if [ "$upstreams" = 1 ]; then
  ok "exactly one upstream in the route"
else
  bad "exactly one upstream" "found $upstreams reverse_proxy directives"
fi

if grep -q 'keel_web_loopback_port' "$TPL" && ! grep -q 'keel_gateway_loopback_port' "$TPL"; then
  ok "the single upstream is the console, not the gateway"
else
  bad "the upstream is the console" "the template still names the gateway port"
fi

if grep -q 'tls internal' "$TPL"; then
  ok "the site uses Caddy's internal CA (tls internal)"
else
  bad "internal TLS" "the site does not request tls internal"
fi

# The mount must be a plain path — configure-nginx.sh rejects anything else —
# and it must not be an absolute origin, which is what caused the collision.
mount=$(grep -E '^keel_web_gateway_mount:' roles/keel/defaults/main.yml | awk '{print $2}')
case "$mount" in
  /[A-Za-z0-9_/-]*) ok "keel_web_gateway_mount is a plain path ($mount)" ;;
  *) bad "the gateway mount is a plain path" "got '$mount'; an absolute origin reintroduces the prefix collision" ;;
esac

if grep -q "VITE_KEEL_GATEWAY_URL={{ keel_web_gateway_mount }}" roles/keel/tasks/build.yml; then
  ok "the console image is built with that mount"
else
  bad "the build uses the mount" "build.yml bakes a different browser-facing base"
  grep -n 'VITE_KEEL_GATEWAY_URL' roles/keel/tasks/build.yml | sed 's/^/           /'
fi

# Changing the mount must force a rebuild: the image tag is the commit, so it
# does not change with a build arg and nothing else would notice.
if grep -q 'keel_web_base_changed' roles/keel/tasks/build.yml; then
  ok "a changed mount forces the console image to rebuild"
else
  bad "a changed mount forces a rebuild" "the tag would not change, so the old bundle would be kept"
fi

# ── 4. Ingress is part of 'done' ───────────────────────────────────────────
echo
echo "── 4. the deployment does not claim success before ingress passes ──"

for probe in 'INGRESS (DNS)' 'INGRESS:' 'INGRESS (API)' 'INGRESS (exposure)'; do
  if grep -qF "$probe" roles/keel/tasks/verify.yml; then
    ok "verify.yml reports '$probe' distinctly"
  else
    bad "verify.yml reports '$probe'" "an ingress fault would read as an application failure"
  fi
done

# CODE ONLY. Both files discuss `validate_certs: false` in comments explaining
# why it is not used, and a naive grep matches its own documentation — the same
# way an earlier check failed on a module's comment saying it had no subprocess
# call. Comment lines are stripped first.
disabled=$(grep -rhvE '^\s*#' roles/keel/tasks/verify.yml roles/caddy/tasks/main.yml 2>/dev/null \
           | grep -cE '^\s*validate_certs:\s*(false|no)\b' || true)
if [ "${disabled:-0}" -gt 0 ]; then
  bad "TLS verification is never disabled" "$disabled task(s) set validate_certs: false"
  grep -rnvE '^\s*#' roles/keel/tasks/verify.yml roles/caddy/tasks/main.yml 2>/dev/null \
    | grep -E 'validate_certs:\s*(false|no)\b' | head -3 | sed 's/^/           /'
else
  ok "no task disables TLS verification (comments about it do not count)"
fi

# ── 4b. A notified reload is applied before anything verifies it ───────────
#
# Ansible runs handlers at the END of a play. A role that notifies `Reload
# Caddy` and then verifies the site is reachable verifies a reload that has not
# happened — which is exactly what dc1-x86 did, with every file on disk
# correct and nothing listening on :80 or :443.
echo
echo "── 4b. the reload is applied before verification, not at end of play ──"

if [ -f roles/caddy/tasks/reload-and-verify.yml ]; then
  ok "roles/caddy owns a reload-and-prove-active sequence"
else
  bad "the owner provides the sequence" "roles/caddy/tasks/reload-and-verify.yml is missing"
fi

if grep -q 'meta: flush_handlers' roles/caddy/tasks/reload-and-verify.yml 2>/dev/null; then
  ok "it flushes handlers explicitly"
else
  bad "the sequence flushes handlers" "nothing forces the pending reload to run"
fi

# The application notifies, then asks the owner to apply — and must not carry
# its own reload command.
notify_line=$(grep -n 'notify: Reload Caddy' roles/keel/tasks/caddy.yml | head -1 | cut -d: -f1)
apply_line=$(grep -n 'tasks_from: reload-and-verify' roles/keel/tasks/caddy.yml | head -1 | cut -d: -f1)
if [ -n "$notify_line" ] && [ -n "$apply_line" ] && [ "$notify_line" -lt "$apply_line" ]; then
  ok "roles/keel notifies (line $notify_line) then applies via the owner (line $apply_line)"
else
  bad "the drop-in's reload is applied in place" \
      "notify=${notify_line:-absent} apply=${apply_line:-absent}"
fi

if grep -vE '^[[:space:]]*#' roles/keel/tasks/caddy.yml | grep -qE 'systemctl (reload|restart)|state: (reloaded|restarted)'; then
  bad "roles/keel duplicates no reload command" "it reloads the service itself"
else
  ok "roles/keel issues no reload of its own (the comment about it does not count)"
fi

# The Caddy step must come before verification in the role's own ordering.
caddy_step=$(grep -n 'include_tasks: caddy.yml' roles/keel/tasks/main.yml | head -1 | cut -d: -f1)
verify_step=$(grep -n 'include_tasks: verify.yml' roles/keel/tasks/main.yml | head -1 | cut -d: -f1)
if [ -n "$caddy_step" ] && [ -n "$verify_step" ] && [ "$caddy_step" -lt "$verify_step" ]; then
  ok "caddy.yml (line $caddy_step) runs before verify.yml (line $verify_step)"
else
  bad "the route is configured before it is verified" \
      "caddy=${caddy_step:-absent} verify=${verify_step:-absent}"
fi

# The active-state claim must come from the running process, not from files.
if grep -q 'caddy_admin_listen' roles/caddy/tasks/reload-and-verify.yml 2>/dev/null \
   && grep -q 'caddy_active_config_json' roles/keel/tasks/caddy.yml; then
  ok "the route is asserted against the LOADED config, not files on disk"
else
  bad "activation is proved from the running process" \
      "nothing reads the admin API and asserts the hostname is loaded"
fi

# ── 5b. No folded scalar splits on a literal backslash-n ───────────────────
#
# In a FOLDED (`>-`) or PLAIN scalar, YAML leaves `\n` as two characters, so
# `.split('\n')` matches nothing and returns the whole string as one element.
# In a DOUBLE-QUOTED scalar YAML turns it into a real newline and the same
# expression is correct — which is why this keeps coming back: the identical
# line is right in one place and wrong three lines away.
#
# Measured, not assumed: on a two-line value the folded form yields 1 element,
# `splitlines()` yields 2.
echo
echo "── 5b. no folded scalar splits on a literal backslash-n ──"

folded_split=0
for f in $(find roles playbooks -name '*.yml' 2>/dev/null); do
  # A `\n` split is only safe on a line whose value is double-quoted. Anything
  # else — folded, literal or plain — gets the literal two characters.
  while IFS= read -r hit; do
    lineno=${hit%%:*}
    body=${hit#*:}
    # Skip comments, and skip `msg: "…"` / `loop: "…"` double-quoted values.
    case "$body" in
      *'#'*split*) continue ;;
    esac
    printf '%s' "$body" | grep -qE ':[[:space:]]*"' && continue
    bad "no literal-backslash-n split: $f:$lineno" "folded/plain scalar — the split matches nothing"
    printf '           %s\n' "$(printf '%s' "$body" | sed 's/^[[:space:]]*//')"
    folded_split=$((folded_split + 1))
  done < <(grep -nF ".split('\\n')" "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#')
done
[ "$folded_split" -eq 0 ] && ok "every \\n split sits in a double-quoted scalar, where YAML makes it a newline"

# ── 5. Every "enforced:" citation names a test that exists ─────────────────
#
# A claim that cites its enforcer is only worth anything while the enforcer is
# real. This template shipped citing `tests/run-ingress-routing.sh`, a file that
# was never written — the reader is told the behaviour is verified and no
# verification exists, which is strictly worse than an uncited comment.
echo
echo "── 5. every 'enforced:' citation resolves to a real test ──"

dangling=0
for cited in $(grep -rhoE 'tests/[A-Za-z0-9._-]+\.(sh|yml)' \
                 roles/ playbooks/ 2>/dev/null | sort -u); do
  if [ ! -e "$cited" ]; then
    bad "cited enforcer exists: $cited" "no such file — the claim is unverified"
    grep -rn --include='*.yml' --include='*.j2' --include='*.py' --include='*.md' \
      -F "$cited" roles/ playbooks/ 2>/dev/null | head -2 | sed 's/^/           /'
    dangling=$((dangling + 1))
  fi
done
[ "$dangling" -eq 0 ] && ok "every cited test file exists"

echo
if [ "$fail" -gt 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) checks." >&2
  exit 1
fi
echo "PASS — $pass checks: one ingress owner, provisioned first and gated in preflight, a single-upstream route on the same-origin mount, and ingress counted as part of a successful deployment."
