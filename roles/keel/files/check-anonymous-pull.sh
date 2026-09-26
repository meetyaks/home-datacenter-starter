#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Is each pinned image ANONYMOUSLY resolvable, by digest, for linux/amd64?
#
#   check-anonymous-pull.sh <ref> [<ref> …]      ref = host[:port]/repo[:tag]@sha256:<64 hex>
#
# Every reference is ONE ARGUMENT. Nothing here is ever re-parsed as shell, and
# the caller must pass references as discrete argv elements — see the note on
# data channels below, which exists because getting that wrong broke a real run.
#
# ═══ WHY THIS EXISTS ═════════════════════════════════════════════════════════
#
# A deployment stopped mid-run on:
#
#     HEAD https://quay.io/v2/minio/minio/manifests/sha256:7d80fd23… → 401
#
# The digest had been verified — resolved, pulled, the container actually run —
# a short time earlier. Nothing local changed. Upstream withdrew the repository.
#
# Nothing in the other checks could notice. They ask whether a digest is pinned,
# whether a tag resolves to it, and whether the image runs; all three stay true
# while the image becomes unpullable, because all three can be answered from a
# LOCAL CACHE. The only question a deploy depends on is the one nobody was
# asking: can a machine with no credentials and no cached copy fetch this, now?
#
# ═══ WHY RAW HTTP, NOT `docker pull` ═════════════════════════════════════════
#
# `docker pull` succeeds from the local image store, and sends whatever
# credentials are in ~/.docker/config.json. Both would make this pass on exactly
# the machines where it does not matter. curl has no image store to fall back on
# and sends nothing, so a 200 is a statement about the REGISTRY.
#
# ═══ ⚠️ CODE AND DATA TRAVEL ON DIFFERENT CHANNELS ═══════════════════════════
#
# This was once invoked through `ansible.builtin.script` with the image list
# interpolated into the command string. The list was newline-separated, so the
# shell received it as a PROGRAM: line 1 ran this checker with one reference,
# and lines 2..5 were executed as commands.
#
#     /bin/sh: 2: ghcr.io/meetyaks/minio...: not found
#     /bin/sh: 3: nats...: not found
#
# Worse than noisy: the checker saw ONE image, verified it, and printed PASS.
# A green check that had examined a fifth of its input.
#
# So: references arrive as argv, `for ref in "$@"`, and this script counts what
# it verified and refuses to print PASS unless that equals what it was given.
# No eval, no xargs, no word splitting, no command substitution on a reference.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <image-ref> [<image-ref> …]" >&2
  echo "       each reference is one argument; none is ever interpreted as shell" >&2
  exit 2
fi

total=$#
verified=0
declare -a results=()

# A reference is opaque, but it is not arbitrary. Anything outside the character
# set a registry reference can contain is REJECTED AND NEVER USED — if a space
# or a metacharacter reaches here, something upstream is passing shell text
# rather than data, and running it is the last thing this should do.
ref_is_wellformed() {
  case "$1" in
    *[!A-Za-z0-9._:/@+-]*) return 1 ;;
    '') return 1 ;;
    *) return 0 ;;
  esac
}

fail_ref() {
  printf '   FAIL  %s\n' "$2"
  results+=("FAIL  $1  — $2")
}

for ref in "$@"; do
  echo "── $ref"

  if ! ref_is_wellformed "$ref"; then
    fail_ref "$ref" "invalid reference: contains whitespace or shell metacharacters. Not executed, not fetched — the caller is passing shell text rather than data."
    continue
  fi

  case "$ref" in
    *@sha256:*) : ;;
    *) fail_ref "$ref" "not pinned by digest"; continue ;;
  esac

  digest="${ref##*@}"
  before_at="${ref%@*}"

  # ⚠️ STRIP THE TAG FIRST. Pins look like `repo:TAG@sha256:…`, so removing only
  # the digest leaves the tag inside the repository path and every lookup 404s.
  # For `nats:2-alpine@…` it is worse: the first path component then contains a
  # colon and is mistaken for a registry host. Both happened.
  #
  # Only a colon AFTER the last slash is a tag; a colon before one is a PORT,
  # which is why `localhost:5000/foo:tag@sha256:…` has to survive this intact.
  last="${before_at##*/}"
  case "$last" in
    *:*) before_at="${before_at%:*}" ;;
  esac

  first="${before_at%%/*}"
  case "$first" in
    *.*|*:*) registry="$first"; repo="${before_at#*/}" ;;
    *)       registry="registry-1.docker.io"
             case "$before_at" in
               */*) repo="$before_at" ;;
               *)   repo="library/$before_at" ;;
             esac ;;
  esac

  # ── a token, via whatever the registry's own 401 asks for ────────────────
  wwwauth=$(curl -sS -o /dev/null -D - --max-time 25 "https://${registry}/v2/" 2>/dev/null \
            | tr -d '\r' | grep -i '^www-authenticate:' | head -1)
  realm=$(printf '%s' "$wwwauth"   | sed -n 's/.*realm="\([^"]*\)".*/\1/p')
  service=$(printf '%s' "$wwwauth" | sed -n 's/.*service="\([^"]*\)".*/\1/p')

  token=""
  if [ -n "$realm" ]; then
    tokurl="${realm}?scope=repository:${repo}:pull"
    [ -n "$service" ] && tokurl="${tokurl}&service=${service}"
    # No -u, no --netrc: anonymous by construction.
    token=$(curl -sS --max-time 25 "$tokurl" 2>/dev/null \
            | sed -E 's/.*"(access_)?token"[[:space:]]*:[[:space:]]*"([^"]+)".*/\2/' | head -1)
    [ "${#token}" -lt 8 ] && token=""
  fi

  ACCEPT='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
  auth_hdr=()
  [ -n "$token" ] && auth_hdr=(-H "Authorization: Bearer ${token}")

  # ── 1. does the DIGEST resolve, anonymously? ─────────────────────────────
  #
  # ⚠️ RETRIED, BUT ONLY FOR TRANSIENT FAILURES. A dropped connection or a 5xx
  # says nothing about whether an image is pullable, and a single one of those
  # blocking a deployment is a check that cries wolf — this suite flaked exactly
  # that way once, reporting 4 of 5 on a run that passed three times either side
  # of it.
  #
  # 401, 403 and 404 are NOT retried. They are the registry's answer, not a
  # hiccup, and retrying them would only slow the run down and blur the very
  # distinction this check exists to draw.
  attempt=1
  while : ; do
    hdrs=$(curl -sS -o /dev/null -D - --max-time 30 -X HEAD \
             "${auth_hdr[@]}" -H "Accept: ${ACCEPT}" \
             "https://${registry}/v2/${repo}/manifests/${digest}" 2>/dev/null | tr -d '\r')
    code=$(printf '%s' "$hdrs" | awk '/^HTTP\//{c=$2} END{print c+0}')
    case "$code" in
      0|429|5??)
        if [ "$attempt" -lt 3 ]; then
          echo "   HEAD manifest        HTTP ${code} — transient, retrying (${attempt}/2)"
          attempt=$((attempt + 1))
          sleep $((attempt * 2))
          continue
        fi
        ;;
    esac
    break
  done
  echo "   HEAD manifest        HTTP ${code}"

  if [ "$code" != "200" ]; then
    detail="anonymous manifest HEAD returned HTTP ${code} from ${registry}"
    case "$code" in
      401|403) detail="${detail} — the registry refuses this repository to clients without credentials" ;;
      404)     detail="${detail} — the manifest is gone from this registry" ;;
      429)     detail="${detail} — rate limited, which is distinct from a refusal; retry before concluding" ;;
      0)       detail="${detail} — no HTTP response at all; check the network path to ${registry}" ;;
    esac
    fail_ref "$ref" "$detail"
    continue
  fi

  # ── 2. is it the digest we pinned? ───────────────────────────────────────
  served=$(printf '%s' "$hdrs" | grep -i '^docker-content-digest:' | awk '{print $2}' | head -1)
  if [ -n "$served" ] && [ "$served" != "$digest" ]; then
    fail_ref "$ref" "registry served ${served}, not the pinned ${digest}"
    continue
  fi
  echo "   digest confirmed     ${digest:0:26}…"

  # ── 3. does it carry linux/amd64? ────────────────────────────────────────
  #
  # ⚠️ PARSED, NOT GREPPED. An index lists each platform as an entry whose own
  # `mediaType` is `…image.manifest…`, so grepping for that string matches
  # INSIDE a multi-platform index and reports "single-platform" — skipping the
  # check entirely. An earlier version did exactly that and passed an image
  # without ever looking for amd64.
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
    print("OK index carries linux/amd64 (of: %s)" % names if hits
          else "ERR index has no linux/amd64 entry (only: %s)" % (names or "none"))
else:
    print("SINGLE %s" % (mt or "unknown media type"))
' 2>/dev/null)

  case "$arch_result" in
    OK*)     echo "   linux/amd64          ${arch_result#OK }" ;;
    SINGLE*) fail_ref "$ref" "single-platform manifest (${arch_result#SINGLE }); linux/amd64 cannot be confirmed from the manifest alone"
             continue ;;
    *)       fail_ref "$ref" "${arch_result#ERR }"; continue ;;
  esac

  # ── 4. can a LAYER be fetched, not just the manifest? ────────────────────
  #
  # A manifest is metadata. A registry can serve it and still refuse the layers,
  # and then `docker pull` fails on an image this just called fine. One HEAD
  # against a real layer closes that and never downloads a body.
  sub=$(printf '%s' "$body" | python3 -c '
import json,sys
try: m=json.load(sys.stdin)
except Exception: raise SystemExit
for e in (m.get("manifests") or []):
    p=e.get("platform") or {}
    if p.get("architecture")=="amd64" and p.get("os")=="linux":
        print(e["digest"]); break
' 2>/dev/null)

  if [ -z "$sub" ]; then
    fail_ref "$ref" "could not locate the linux/amd64 submanifest to test a layer"
    continue
  fi

  layer=$(curl -sS --max-time 30 "${auth_hdr[@]}" \
            -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
            "https://${registry}/v2/${repo}/manifests/${sub}" 2>/dev/null \
          | python3 -c '
import json,sys
try: m=json.load(sys.stdin)
except Exception: raise SystemExit
ls=m.get("layers") or []
print(ls[0]["digest"] if ls else "")
' 2>/dev/null)

  if [ -z "$layer" ]; then
    fail_ref "$ref" "the linux/amd64 manifest lists no layers"
    continue
  fi

  bcode=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 -L -X HEAD \
            "${auth_hdr[@]}" "https://${registry}/v2/${repo}/blobs/${layer}" 2>/dev/null)
  if [ "$bcode" != "200" ]; then
    fail_ref "$ref" "manifest is served but its layers are not (blob HEAD HTTP ${bcode}); a pull would fail on an image whose metadata looks fine"
    continue
  fi
  echo "   layer fetchable      HTTP 200 (${layer:7:16}…)"

  echo "   OK"
  verified=$((verified + 1))
  results+=("ok    $ref")
done

# ── The summary, which is also the last line of defence ─────────────────────
#
# ⚠️ PASS REQUIRES verified == total. Not "no failures recorded", not "we got to
# the end" — an explicit count of images that passed every check, compared
# against the number handed in. When this was invoked wrongly it examined one
# image out of five and printed PASS; a count cannot be fooled that way, and
# every reference is listed so a short list is visible rather than implied.
echo
echo "─────────────────────────────────────────────────────────────────────"
printf 'verified %d of %d image(s)\n\n' "$verified" "$total"
for line in "${results[@]}"; do
  printf '  %s\n' "$line"
done
echo

if [ "$verified" -ne "$total" ]; then
  printf 'FAILED: %d of %d image(s) are not anonymously pullable as pinned.\n' \
    "$((total - verified))" "$total" >&2
  exit 1
fi

printf 'PASS — all %d image(s) resolve anonymously, by digest, with linux/amd64 and a fetchable layer.\n' "$total"
