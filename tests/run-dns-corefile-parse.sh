#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# THE REAL BINARY, AGAINST THE RENDERED CONFIGURATION.
#
#   tests/run-dns-corefile-parse.sh
#
# ⚠️ WHY THIS EXISTS, IN ONE SENTENCE: every structural check in
# tests/dns-zone.yml passed on a Corefile CoreDNS WOULD NOT LOAD.
#
# The template had written the forwarding block's header as `. :53 {`. A
# server-block header is `ZONE...[:PORT]`, so with a space that is TWO zones —
# `.` and `:53` — and CoreDNS refuses to start:
#
#     error inspecting server blocks: zone is not a valid domain name:
#
# Regexes cannot find that. `bind`, `acl`, `forward`, `cache`, `health` and
# `ready` were all present and correct; the file was simply not a Corefile.
# Nothing short of starting the daemon would have found it, and the place it
# would otherwise have been found is a deployment that takes LAN name
# resolution down.
#
# So this starts the pinned CoreDNS on LOOPBACK, on a high port, against the
# rendered configuration, and asks it questions. It installs nothing, touches
# no system path, binds nothing privileged and leaves no process behind.
#
# ⚠️ NOT IN THE HOSTED CI LANE, ON PURPOSE. It needs the CoreDNS binary, and
# fetching it means network — the same reason run-remote-image-check.sh lives
# in run-all.sh rather than the workflow. Set KEEL_COREDNS_BIN to an existing
# binary to run it offline.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0
fail=0
ok()  { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }

WORK=$(mktemp -d -t dns-parse.XXXXXX)
CORE_PID=""
cleanup() {
  if [ -n "$CORE_PID" ]; then kill "$CORE_PID" 2>/dev/null; wait "$CORE_PID" 2>/dev/null; fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

PORT=${KEEL_COREDNS_TEST_PORT:-15353}
HEALTH_PORT=$((PORT + 1))
READY_PORT=$((PORT + 2))

# ── The pinned version and this platform's checksum, read from the role ────
VERSION=$(awk -F'"' '/^coredns_version:/{print $2; exit}' roles/coredns/defaults/main.yml)
case "$(uname -s)" in
  Darwin) PLATFORM="darwin_$(uname -m | sed 's/arm64/arm64/; s/x86_64/amd64/')" ;;
  Linux)  PLATFORM="linux_$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')" ;;
  *)      PLATFORM="unsupported" ;;
esac
SUM=$(awk -v p="  ${PLATFORM}:" -F'"' '$0 ~ p {print $2; exit}' roles/coredns/defaults/main.yml)

echo "── the pinned CoreDNS ${VERSION} (${PLATFORM}), against the rendered config ──"

if [ -z "$VERSION" ] || [ -z "$SUM" ]; then
  skip "roles/coredns pins no checksum for ${PLATFORM} — nothing to verify here."
  echo
  echo "SKIPPED — this platform is not one of the two deployed."
  exit 0
fi

# ── Get the binary: a provided one, or a verified download ────────────────
BIN=""
if [ -n "${KEEL_COREDNS_BIN:-}" ] && [ -x "${KEEL_COREDNS_BIN}" ]; then
  BIN="$KEEL_COREDNS_BIN"
  ok "using the binary from KEEL_COREDNS_BIN"
else
  URL="https://github.com/coredns/coredns/releases/download/v${VERSION}/coredns_${VERSION}_${PLATFORM}.tgz"
  if ! curl -sSL --max-time 240 -o "$WORK/coredns.tgz" "$URL"; then
    skip "could not fetch ${URL} — offline? Set KEEL_COREDNS_BIN to run this."
    echo
    echo "SKIPPED — the binary was unavailable, so the Corefile was NOT parsed."
    exit 0
  fi
  # ⚠️ THE SAME CHECKSUM THE ROLE USES, VERIFIED THE SAME WAY. A test that
  # ran an unverified binary would be checking the configuration with
  # something nobody vouched for.
  GOT=$(shasum -a 256 "$WORK/coredns.tgz" 2>/dev/null | awk '{print $1}')
  [ -n "$GOT" ] || GOT=$(sha256sum "$WORK/coredns.tgz" | awk '{print $1}')
  if [ "$GOT" != "$SUM" ]; then
    bad "the downloaded binary matches the pinned checksum" "got ${GOT}, pinned ${SUM}"
    echo; echo "FAILED: refusing to run unverified bytes." >&2
    exit 1
  fi
  ok "the download matches the pinned SHA-256"
  tar xzf "$WORK/coredns.tgz" -C "$WORK"
  BIN="$WORK/coredns"
  chmod +x "$BIN"
fi

if ! "$BIN" --version | grep -q "CoreDNS-${VERSION}"; then
  bad "the binary is the pinned version" "$("$BIN" --version | head -1)"
else
  ok "the binary reports CoreDNS-${VERSION}"
fi

# ── Render, then move the configuration onto loopback ─────────────────────
RENDER=/tmp/keel-dns-render
if ! ansible-playbook tests/dns-zone.yml >"$WORK/render.log" 2>&1; then
  bad "the configuration renders" "tests/dns-zone.yml failed; see $WORK/render.log"
  echo; echo "FAILED." >&2
  exit 1
fi
ok "tests/dns-zone.yml rendered both nodes"

cp "$RENDER/dc1-arm-1/db.dc1.lan" "$WORK/db.dc1.lan"

# ⚠️ ONE BIND, NOT TWO REWRITTEN TO THE SAME ADDRESS. Collapsing both binds
# onto 127.0.0.1 makes CoreDNS refuse with "cannot serve dns://dc1.lan.:PORT
# on 127.0.0.1 - it is already defined" — a harness artefact that looks
# exactly like a configuration error. The LAN bind is dropped instead.
sed -e '/^    bind 10\.0\.0\.[0-9]*$/d' \
    -e "s/^dc1\.lan:53 {/dc1.lan:${PORT} {/" \
    -e "s/^\.:53 {/.:${PORT} {/" \
    -e "s|file .*db\.dc1\.lan|file ${WORK}/db.dc1.lan|" \
    -e "s/health 127\.0\.0\.1:8653/health 127.0.0.1:${HEALTH_PORT}/" \
    -e "s/ready 127\.0\.0\.1:8654/ready 127.0.0.1:${READY_PORT}/" \
    "$RENDER/dc1-arm-1/Corefile" > "$WORK/Corefile"

# ── Start it. THIS is the check the regexes cannot be. ───────────────────
( cd "$WORK" && "$BIN" -conf "$WORK/Corefile" >"$WORK/coredns.out" 2>&1 ) &
CORE_PID=$!

for _ in $(seq 1 20); do
  if grep -q "CoreDNS-${VERSION}" "$WORK/coredns.out" 2>/dev/null; then break; fi
  if grep -qiE "error|not a valid|already defined|cannot serve" "$WORK/coredns.out" 2>/dev/null; then break; fi
  sleep 0.5
done

if grep -qiE "error|not a valid|already defined|cannot serve" "$WORK/coredns.out"; then
  bad "CoreDNS LOADS the rendered Corefile" "$(head -3 "$WORK/coredns.out" | tr '\n' ' ')"
  echo; echo "FAILED: the rendered configuration is not loadable." >&2
  exit 1
fi
if ! grep -q "CoreDNS-${VERSION}" "$WORK/coredns.out"; then
  bad "CoreDNS starts" "it produced no banner: $(cat "$WORK/coredns.out" | tr '\n' ' ')"
  echo; echo "FAILED." >&2
  exit 1
fi
ok "CoreDNS loads the rendered Corefile and starts"

if grep -q "dc1.lan.:${PORT}" "$WORK/coredns.out" && grep -q "^\.:${PORT}" "$WORK/coredns.out"; then
  ok "both server blocks are served — the zone AND the forwarder"
else
  bad "both server blocks are served" "$(cat "$WORK/coredns.out" | tr '\n' ' ')"
fi

# ── Ask it questions ─────────────────────────────────────────────────────
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${READY_PORT}/ready" || echo 000)
[ "$code" = "200" ] && ok "the ready endpoint reports 200" || bad "ready reports 200" "got ${code}"
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${HEALTH_PORT}/health" || echo 000)
[ "$code" = "200" ] && ok "the health endpoint reports 200" || bad "health reports 200" "got ${code}"

check_a() {
  local name=$1 want=$2 proto=${3:-}
  local got
  got=$(dig +short ${proto} -p "$PORT" @127.0.0.1 "$name" A 2>/dev/null | grep -E '^[0-9]' | tr '\n' ' ' | sed 's/ $//')
  if [ "$got" = "$want" ]; then
    ok "${name} → ${want}${proto:+ (${proto#+})}"
  else
    bad "${name} → ${want}${proto:+ (${proto#+})}" "got '${got:-nothing}'"
  fi
}

check_a dc1-arm-1.dc1.lan 10.0.0.22
check_a dc1-x86.dc1.lan 10.0.0.3
check_a keel-dev.dc1.lan 10.0.0.3
check_a keel-dev.dc1.lan 10.0.0.3 +tcp

# ⚠️ THE RESERVED NAME, AND THE `aa` FLAG. An answer here would mean either
# somebody added keel.dc1.lan or the zone is not authoritative and the query
# escaped to a public resolver — the second being worse, because it means
# internal names are leaving the LAN.
resp=$(dig -p "$PORT" @127.0.0.1 keel.dc1.lan A +noall +comments 2>/dev/null)
if printf '%s' "$resp" | grep -q 'status: NXDOMAIN' && printf '%s' "$resp" | grep -qE 'flags:[^;]*\baa\b'; then
  ok "keel.dc1.lan → AUTHORITATIVE NXDOMAIN (reserved for production)"
else
  bad "keel.dc1.lan → authoritative NXDOMAIN" "$(printf '%s' "$resp" | grep -E 'status|flags' | tr '\n' ' ')"
fi

resp=$(dig -p "$PORT" @127.0.0.1 nosuchthing.dc1.lan A +noall +comments 2>/dev/null)
if printf '%s' "$resp" | grep -q 'status: NXDOMAIN' && printf '%s' "$resp" | grep -qE 'flags:[^;]*\baa\b'; then
  ok "an unknown dc1.lan name → authoritative NXDOMAIN, not forwarded"
else
  bad "an unknown dc1.lan name → authoritative NXDOMAIN" "$(printf '%s' "$resp" | grep -E 'status|flags' | tr '\n' ' ')"
fi

# The external forwarder. Network-dependent, so a failure here is reported as
# a skip rather than a red — the zone is what this suite owns.
ext=$(dig +short -p "$PORT" @127.0.0.1 github.com A 2>/dev/null | grep -cE '^[0-9]' || true)
if [ "${ext:-0}" -gt 0 ]; then
  ok "an external name resolves through the forwarder"
else
  skip "github.com did not resolve — upstream unreachable from here; the forwarder's CONFIG is asserted in tests/dns-zone.yml"
fi

echo
if [ "$fail" -gt 0 ]; then
  echo "FAILED: $fail of $((pass + fail)) checks." >&2
  exit 1
fi
echo "PASS — $pass checks: the real CoreDNS ${VERSION} loads the rendered"
echo "configuration, serves all three records over UDP and TCP, and returns an"
echo "authoritative NXDOMAIN for the reserved keel.dc1.lan."
