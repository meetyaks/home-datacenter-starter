#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Is each pinned image ANONYMOUSLY resolvable, by digest, for linux/amd64?
#
#   check-anonymous-pull.sh <ref> [<ref> …]      ref = host/repo@sha256:<64 hex>
#
# ═══ WHY THIS EXISTS ═════════════════════════════════════════════════════════
#
# A deployment stopped mid-run on:
#
#     HEAD https://quay.io/v2/minio/minio/manifests/sha256:7d80fd23… → 401
#
# The digest had been verified — resolved, pulled, and the container actually
# run — a short time earlier. Nothing about the deployment changed. The UPSTREAM
# changed: MinIO withdrew those repositories from public registries.
#
# Nothing in the existing checks could notice. They asked whether the compose
# file names a digest, whether a tag resolves to it, and whether the image runs.
# All three stayed true while the image became unpullable, because all three
# were answered from a LOCAL CACHE or from a one-off manual check. The only
# question that matters to a deploy is the one nobody was asking: can a machine
# with no credentials and no cached copy fetch this, right now?
#
# ═══ WHY RAW HTTP, NOT `docker pull` ═════════════════════════════════════════
#
# `docker pull` succeeds from the local image store, and `docker` sends whatever
# credentials happen to be in ~/.docker/config.json. Both would turn this into a
# check that passes on exactly the machines where it does not matter.
#
# curl against the registry API has no image store to fall back on and sends no
# credentials, so a 200 here is a statement about the REGISTRY, not this host.
# The HTTP status is printed for every request, which is the evidence that the
# request was made at all.
#
# Exit 0 only if every reference passes every check.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

[ $# -ge 1 ] || { echo "usage: $0 <ref>…" >&2; exit 2; }

fails=0

for ref in "$@"; do
  echo "── $ref"

  case "$ref" in
    *@sha256:*) : ;;
    *) echo "   FAIL  not pinned by digest"; fails=$((fails + 1)); continue ;;
  esac

  digest="${ref##*@}"
  before_at="${ref%@*}"
  # A leading component containing a dot or a colon is a registry host;
  # otherwise the reference is an implicit Docker Hub one.
  first="${before_at%%/*}"
  case "$first" in
    *.*|*:*) registry="$first"; repo="${before_at#*/}" ;;
    *)       registry="registry-1.docker.io"
             case "$before_at" in
               */*) repo="$before_at" ;;
               *)   repo="library/$before_at" ;;
             esac ;;
  esac

  # ── token, via whatever the registry's own 401 tells us to use ────────────
  wwwauth=$(curl -sS -o /dev/null -D - --max-time 25 "https://${registry}/v2/" 2>/dev/null \
            | tr -d '\r' | grep -i '^www-authenticate:' | head -1)
  realm=$(printf '%s' "$wwwauth"   | sed -n 's/.*realm="\([^"]*\)".*/\1/p')
  service=$(printf '%s' "$wwwauth" | sed -n 's/.*service="\([^"]*\)".*/\1/p')

  token=""
  if [ -n "$realm" ]; then
    tokurl="${realm}?scope=repository:${repo}:pull"
    [ -n "$service" ] && tokurl="${tokurl}&service=${service}"
    # No -u and no netrc: anonymous by construction.
    token=$(curl -sS --max-time 25 "$tokurl" 2>/dev/null \
            | sed -E 's/.*"(access_)?token"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/' | head -1)
    [ "${#token}" -lt 8 ] && token=""
  fi

  ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

  auth_hdr=()
  [ -n "$token" ] && auth_hdr=(-H "Authorization: Bearer ${token}")

  # ── 1. does the DIGEST resolve, anonymously, at the registry? ─────────────
  hdrs=$(curl -sS -o /dev/null -D - --max-time 30 -X HEAD \
           "${auth_hdr[@]}" -H "Accept: ${ACCEPT}" \
           "https://${registry}/v2/${repo}/manifests/${digest}" 2>/dev/null | tr -d '\r')
  code=$(printf '%s' "$hdrs" | awk '/^HTTP\//{c=$2} END{print c+0}')
  echo "   HEAD manifest        HTTP ${code}"

  if [ "$code" != "200" ]; then
    echo "   FAIL  not anonymously resolvable (HTTP ${code})."
    case "$code" in
      401|403) echo "         The registry refuses this repository to clients without credentials." ;;
      404)     echo "         The manifest is gone from this registry." ;;
      429)     echo "         Rate limited — distinct from a refusal; retry before concluding." ;;
    esac
    fails=$((fails + 1))
    continue
  fi

  # ── 2. is it the digest we pinned? ───────────────────────────────────────
  served=$(printf '%s' "$hdrs" | grep -i '^docker-content-digest:' | awk '{print $2}' | head -1)
  if [ -n "$served" ] && [ "$served" != "$digest" ]; then
    echo "   FAIL  registry served ${served}, not the pinned digest"
    fails=$((fails + 1))
    continue
  fi
  echo "   digest confirmed     ${digest:0:26}…"

  # ── 3. does it carry linux/amd64? ────────────────────────────────────────
  #
  # ⚠️ PARSED, NOT GREPPED. An index lists each platform as an entry whose own
  # `mediaType` is `…image.manifest…`, so a grep for that string matches inside
  # a multi-platform index and reports "single-platform" — skipping the very
  # check this step exists to perform. The first version of this script did
  # exactly that and passed pgvector without ever looking for amd64.
  #
  # python3 is a safe dependency here: Ansible already requires it on the
  # target, and the controller runs it too.
  body=$(curl -sS --max-time 30 "${auth_hdr[@]}" -H "Accept: ${ACCEPT}" \
           "https://${registry}/v2/${repo}/manifests/${digest}" 2>/dev/null)
  arch_result=$(printf '%s' "$body" | python3 -c '
import json, sys
INDEX = ("application/vnd.oci.image.index.v1+json",
         "application/vnd.docker.distribution.manifest.list.v2+json")
try:
    m = json.load(sys.stdin)
except Exception as e:
    print("ERR could not parse the manifest: %s" % str(e)[:60]); raise SystemExit
mt = m.get("mediaType", "")
if mt in INDEX or "manifests" in m:
    plats = [(e.get("platform") or {}) for e in (m.get("manifests") or [])]
    hits = [p for p in plats
            if p.get("architecture") == "amd64" and p.get("os") == "linux"]
    names = ",".join(sorted({"%s/%s" % (p.get("os"), p.get("architecture"))
                             for p in plats if p.get("architecture")}))
    if hits:
        print("OK index carries linux/amd64 (of: %s)" % names)
    else:
        print("ERR index has no linux/amd64 entry (only: %s)" % (names or "none"))
else:
    # A single-platform manifest states its architecture in the config blob,
    # not here, so this cannot be confirmed from the manifest alone.
    print("SINGLE %s" % (mt or "unknown media type"))
' 2>/dev/null)

  case "$arch_result" in
    OK*)     echo "   linux/amd64          ${arch_result#OK }" ;;
    SINGLE*) echo "   FAIL  single-platform manifest (${arch_result#SINGLE }); cannot confirm linux/amd64"
             fails=$((fails + 1)); continue ;;
    *)       echo "   FAIL  ${arch_result#ERR }"
             fails=$((fails + 1)); continue ;;
  esac

  echo "   OK"
done

echo
if [ "$fails" -gt 0 ]; then
  echo "FAILED: ${fails} image(s) are not anonymously pullable as pinned." >&2
  exit 1
fi
echo "PASS — every pinned image resolves anonymously, by digest, with linux/amd64."
