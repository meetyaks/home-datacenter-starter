#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# REGRESSION — the gateway container gets NO KEEL_OIDC_* key in password-only
# mode, and all three in oidc mode.
#
#   tests/run-compose-auth-profile.sh
#
# ═══ THE DEFECT ══════════════════════════════════════════════════════════════
#
# An acceptance deployment came up with everything healthy except a CRASH-LOOPING
# GATEWAY (and the web container stuck at Created behind its health gate). Its
# config schema rejected:
#
#     oidcIssuer = invalid URL,  oidcClientId = empty,  oidcClientSecret = empty
#
# compose.lab.yml declares `KEEL_OIDC_ISSUER: ${KEEL_OIDC_ISSUER:-}`, and
# `${VAR:-}` ALWAYS EMITS THE KEY — unset becomes `KEY=`. The env template had
# correctly stopped rendering the three keys; Compose put them back as empty
# strings.
#
# ⚠️ ABSENT AND EMPTY ARE DIFFERENT STATES, AND ONLY ONE WAS TESTED. The
# production-boot check that passed review built its environment by hand and
# `unset` them — a state the real deployment never reaches. So every assertion
# below reads the RENDERED COMPOSE CONFIG, and the container-reality cases read
# the environment of a container Compose actually started.
#
# `assertProductionSafe` is not at fault and is not weakened: told the instance
# is password-only, it correctly did not require OIDC. The Zod schema that parses
# gateway config is a separate gate, and an empty string is not a missing value
# to it.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0
fail=0
ok()  { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }
die() { printf '\n\033[31mABORTED\033[0m — %s\n' "$1" >&2; exit 1; }

WORK=$(mktemp -d -t compose-auth.XXXXXX)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

command -v docker >/dev/null 2>&1 || die "docker is required to render a compose config"
docker info >/dev/null 2>&1 || die "the docker daemon is not reachable"

# ── The stack definition, from the commit this deployment pins ─────────────
#
# Read out of the Keel worktree at the PINNED SHA, so this suite tests the file
# the deployment will actually install rather than a copy kept here.
KEEL_REPO=${KEEL_REPO:-$HOME/Projects/keel}
PIN=$(awk '/^keel_commit:/{print $2; exit}' roles/keel/defaults/main.yml)
printf '%s' "$PIN" | grep -qE '^[0-9a-f]{40}$' \
  || die "could not read a 40-character keel_commit from roles/keel/defaults/main.yml"
echo "  stack definition from keel_commit ${PIN}"

git -C "$KEEL_REPO" cat-file -e "${PIN}:infra/lab/compose.lab.yml" 2>/dev/null \
  || die "commit ${PIN} is not in ${KEEL_REPO}; set KEEL_REPO to the Keel checkout"
git -C "$KEEL_REPO" show "${PIN}:infra/lab/compose.lab.yml" > "$WORK/compose.lab.yml"

# ── 0. The base stack must declare NO KEEL_OIDC_* key, in any form ─────────
#
# This is the root of the fix, and it is asserted rather than assumed: a key
# declared in the base — even valuelessly — reappears in `docker compose config`,
# and `${VAR:-}` puts it in the container as an empty string.
echo
echo "── 0. the pinned stack declares no KEEL_OIDC_* key ──"
decl=$(grep -cE '^[[:space:]]*KEEL_OIDC_[A-Z_]*:' "$WORK/compose.lab.yml" || true)
if [ "${decl:-0}" = "0" ]; then
  ok "compose.lab.yml declares 0 KEEL_OIDC_* keys"
else
  bad "the base declares no KEEL_OIDC_* key" "found ${decl}:"
  grep -nE '^[[:space:]]*KEEL_OIDC_[A-Z_]*:' "$WORK/compose.lab.yml" | sed 's/^/           /'
fi
if grep -qE 'KEEL_OIDC_[A-Z_]*: \$\{KEEL_OIDC_[A-Z_]*:-\}' "$WORK/compose.lab.yml"; then
  bad "the always-emit default is gone" "\${VAR:-} is back in the base — it emits the key even when unset"
else
  ok "no \${KEEL_OIDC_*:-} always-emit default in the base"
fi

# ── Render the role's env file and the overlay, for one auth profile ───────
render_profile() {
  local methods=$1 oidc=$2 dir="$WORK/$3"
  mkdir -p "$dir"
  cp "$WORK/compose.lab.yml" "$dir/compose.lab.yml"
  KEEL_AUTH_METHODS_OVERRIDE="$methods" KEEL_OIDC_OVERRIDE="$oidc" \
  ansible-playbook tests/compose-render.yml \
    -e "render_dir=$dir" -e "auth_methods=$methods" -e "want_oidc=$oidc" \
    > "$dir/render.log" 2>&1
  return $?
}

# Inspect the rendered, MERGED compose config for one service.
#
# The overlay is added ONLY when it exists, mirroring `keel_compose_cmd`: in
# password-only mode the role renders none, and naming a missing file would make
# this suite test a configuration the deployment never assembles.
env_keys_for() {
  local dir=$1 svc=$2
  local files=(-f compose.lab.yml)
  [ -f "$dir/compose.auth-profile.yml" ] && files+=(-f compose.auth-profile.yml)
  ( cd "$dir" && KEEL_IMAGE=keel:test KEEL_WEB_IMAGE=keelweb:test \
      docker compose --env-file keel.env "${files[@]}" config --format json 2>/dev/null ) \
  | python3 -c "
import json,sys
svc = '$svc'
c = json.load(sys.stdin)
env = c['services'][svc].get('environment') or {}
for k in sorted(env):
    print(f'{k}={env[k]!r}')
"
}

# ── 1. Password-only: ZERO KEEL_OIDC_* keys ────────────────────────────────
echo
echo "── 1. password-only — no KEEL_OIDC_* key reaches the container ──"
render_profile password no pw || die "rendering the password-only profile failed; see $WORK/pw/render.log"

if [ -f "$WORK/pw/compose.auth-profile.yml" ]; then
  bad "password-only renders no overlay" "compose.auth-profile.yml was rendered anyway"
else
  ok "password-only renders no OIDC overlay at all"
fi

for svc in gateway bootstrap runtime-worker; do
  keys=$(env_keys_for "$WORK/pw" "$svc" | grep -c '^KEEL_OIDC_' || true)
  if [ "${keys:-0}" = "0" ]; then
    ok "$svc: 0 KEEL_OIDC_* keys"
  else
    bad "$svc: no KEEL_OIDC_* keys" "found ${keys}:"
    env_keys_for "$WORK/pw" "$svc" | grep '^KEEL_OIDC_' | sed 's/^/           /'
  fi
done

# The posture variables must still ARRIVE WITH THEIR VALUES. An overlay that made
# these pass-through too would be the same defect wearing the fix's clothes.
gw=$(env_keys_for "$WORK/pw" gateway)
for expect in "KEEL_AUTH_METHODS='password'" "KEEL_ALLOW_PUBLIC_REGISTRATION='false'" "KEEL_ENV='production'"; do
  if printf '%s\n' "$gw" | grep -qF "$expect"; then
    ok "gateway carries $expect"
  else
    bad "gateway carries $expect" "got: $(printf '%s\n' "$gw" | grep -E "^${expect%%=*}=" || echo ABSENT)"
  fi
done

# ── 2. The env file itself must not carry them either ─────────────────────
echo
echo "── 2. the rendered env file omits them (the role's half of the fix) ──"
if [ "$(grep -c '^KEEL_OIDC_' "$WORK/pw/keel.env" || true)" = "0" ]; then
  ok "keel.env has 0 KEEL_OIDC_* lines"
else
  bad "keel.env omits KEEL_OIDC_*" "$(grep '^KEEL_OIDC_' "$WORK/pw/keel.env" | tr '\n' ' ')"
fi

# ── 3. Container reality, not just the rendered config ────────────────────
#
# THE CASE THAT MATTERS. `config` is Compose's own opinion; this asks a process.
echo
echo "── 3. a container Compose actually started sees no KEEL_OIDC_* ──"
cat > "$WORK/pw/probe.sh" <<'SH'
for v in KEEL_OIDC_ISSUER KEEL_OIDC_CLIENT_ID KEEL_OIDC_CLIENT_SECRET; do
  if env | grep -q "^${v}="; then echo "$v PRESENT"; else echo "$v ABSENT"; fi
done
for v in KEEL_AUTH_METHODS KEEL_ALLOW_PUBLIC_REGISTRATION; do
  echo "$v=$(printenv "$v" 2>/dev/null || echo '<unset>')"
done
SH
cat > "$WORK/pw/compose.probe.yml" <<'YAML'
# Replaces the gateway's image and command, and RESETS what it would otherwise
# inherit, so the probe can run anywhere:
#
#   volumes     the real service bind-mounts /srv/data/... which exists on the
#               managed host and nowhere else; keeping them fails the run with
#               "mounts denied" and proves nothing
#   depends_on  Postgres, NATS, Temporal and bootstrap are not needed to read
#               an environment variable
#
# The `environment:` is deliberately NOT reset — it is the whole point.
services:
  gateway:
    image: alpine:3
    entrypoint: ['sh', '/probe.sh']
    command: []
    user: root
    depends_on: !reset []
    volumes: !reset []
    healthcheck:
      disable: true
YAML
probe_out=$( cd "$WORK/pw" && KEEL_IMAGE=keel:test KEEL_WEB_IMAGE=keelweb:test \
  docker compose --env-file keel.env \
    -f compose.lab.yml -f compose.probe.yml \
    run --rm --no-deps -v "$WORK/pw/probe.sh:/probe.sh:ro" gateway 2>/dev/null )
if [ -z "$probe_out" ]; then
  bad "the probe container ran" "no output; the container-reality case proved nothing"
else
  for v in KEEL_OIDC_ISSUER KEEL_OIDC_CLIENT_ID KEEL_OIDC_CLIENT_SECRET; do
    if printf '%s\n' "$probe_out" | grep -qx "$v ABSENT"; then
      ok "container: $v ABSENT"
    else
      bad "container: $v ABSENT" "$(printf '%s\n' "$probe_out" | grep "^$v" || echo 'no line')"
    fi
  done
  printf '%s\n' "$probe_out" | grep -qx 'KEEL_AUTH_METHODS=password' \
    && ok "container: KEEL_AUTH_METHODS=password" \
    || bad "container: KEEL_AUTH_METHODS=password" "$(printf '%s\n' "$probe_out" | grep KEEL_AUTH_METHODS)"
  printf '%s\n' "$probe_out" | grep -qx 'KEEL_ALLOW_PUBLIC_REGISTRATION=false' \
    && ok "container: KEEL_ALLOW_PUBLIC_REGISTRATION=false" \
    || bad "container: KEEL_ALLOW_PUBLIC_REGISTRATION=false" "$(printf '%s\n' "$probe_out" | grep KEEL_ALLOW_PUBLIC)"
fi

# ── 4. THE INVERSE: oidc mode must require and pass through all three ─────
echo
echo "── 4. oidc mode — all three arrive, with their values ──"
render_profile password,oidc yes oidc || die "rendering the oidc profile failed; see $WORK/oidc/render.log"

gwo=$(env_keys_for "$WORK/oidc" gateway)
for k in KEEL_OIDC_ISSUER KEEL_OIDC_CLIENT_ID KEEL_OIDC_CLIENT_SECRET; do
  line=$(printf '%s\n' "$gwo" | grep "^${k}=" || true)
  if [ -z "$line" ]; then
    bad "oidc: $k reaches the container" "the key is absent"
  elif printf '%s' "$line" | grep -qE "^${k}=''$"; then
    bad "oidc: $k has a value" "it arrived EMPTY — the very state that crash-looped the gateway"
  else
    ok "oidc: $line"
  fi
done

# …and the role must REFUSE to render an oidc profile with a missing value,
# rather than emitting an empty one.
echo
echo "── 5. oidc mode refuses to render an incomplete configuration ──"
if render_profile password,oidc missing-issuer bad-oidc; then
  bad "an incomplete oidc profile is refused" "rendering succeeded with no issuer"
else
  if grep -qE 'keel_oidc_issuer|oidc.*required|must be set' "$WORK/bad-oidc/render.log"; then
    ok "refused, naming the missing variable"
  else
    bad "the refusal names the problem" "it failed for some other reason"
    tail -5 "$WORK/bad-oidc/render.log" | sed 's/^/           /'
  fi
fi

# ── 6. Every compose invocation carries the overlay ───────────────────────
#
# A single forgotten call site would be the most misleading possible outcome:
# `config` reporting the key absent while `up` set it empty.
echo
echo "── 6. no compose invocation bypasses the overlay ──"
literal=$(grep -rn 'docker compose --env-file' roles/keel/tasks/*.yml 2>/dev/null || true)
if [ -z "$literal" ]; then
  ok "every invocation goes through keel_compose_cmd"
else
  bad "no site spells the invocation out" "found:"
  printf '%s\n' "$literal" | head -4 | sed 's/^/           /'
fi
if grep -qF 'keel_compose_auth_file) if keel_oidc_selected' roles/keel/defaults/main.yml; then
  ok "keel_compose_cmd adds the overlay's -f only when oidc is selected"
else
  bad "the overlay's -f is conditional on oidc" "keel_compose_cmd does not gate it on keel_oidc_selected"
fi
if [ "$(grep -c '^keel_compose_cmd:' roles/keel/defaults/main.yml)" = "1" ]; then
  ok "exactly one keel_compose_cmd definition (a duplicate would silently win)"
else
  bad "one keel_compose_cmd definition" "found $(grep -c '^keel_compose_cmd:' roles/keel/defaults/main.yml)"
fi

echo
if [ "$fail" -gt 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) checks." >&2
  exit 1
fi
echo "PASS — $pass checks: password-only renders and RUNS with zero KEEL_OIDC_* keys, the posture variables keep their values, oidc mode requires and passes all three, and no compose invocation bypasses the overlay."
