#!/bin/bash
# TrueWealth CI runner — shared-host checks on dc1-x86 (run as labadmin, via `ssh -t` from dc1-arm-1).
# Changes NOTHING on the host: reads state, writes only under ~/ci-shared-check (0700).
#
#   hostcheck.sh snapshot <before|after-provision|after-failure> <40-char SHA>
#                                     exit 0 only when a completion record was written
#   hostcheck.sh verify <phase> <40-char SHA> [max-age-minutes]
#                                     validates the newest <phase> snapshot's completion record
#   hostcheck.sh compare <40-char SHA>
#                                     newest before-* vs newest after-provision-*; both must verify
#   hostcheck.sh probe <40-char SHA>  live checks after provisioning;
#                                     exit 0 OK, 1 FAIL, 2 INCONCLUSIVE, 3 evidence log failure
#
# Staged on dc1-x86 at ~/ci-shared-check/hostcheck.sh from an exact-commit checkout on dc1-arm-1;
# tools/ci-activation/provision-truewealth.sh refuses to provision unless the staged copy is
# byte-identical to this file. Operator runbook: roles/ci_runner/README.md, "Activation from
# dc1-arm-1". Tests: tests/ci-activation/test-activation.sh (run by tests/run-ci-runner-truewealth.sh §13).
#
# The snapshot takes the shared-host snapshot the runbook describes, with `sudo docker`, and is FAIL-CLOSED: every required collector's own exit
# status and output are checked; diagnostics go to errors/; a snapshot is a valid baseline only
# when its COMPLETE record exists and verifies (SHA, phase, snapshot identity, evidence hashes).
# Probes create no listeners, files, containers or configuration in the guest or on the host
# (only the evidence files under ~/ci-shared-check); they open short TCP connections and send
# ICMP echo requests, which targets may log.
set -uo pipefail
BASE="$HOME/ci-shared-check"
HOSTCHECK_SELF="${BASH_SOURCE[0]}"
die() { echo "STOP: $*" >&2; exit 1; }
sha_ok() { [ "${#1}" -eq 40 ] && case "$1" in *[!0-9a-f]*) false;; *) true;; esac; }
sha256_of() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
newest_dir() { ls -1d "$BASE/$1"-2* 2>/dev/null | sort | tail -n 1; }


RECORD_FORMAT="hostcheck-snapshot v3"   # v3: the expected Keel inventory, derived from the bound Compose file
# Every file a completion record must bind. A snapshot missing any of them is not a baseline.
REQUIRED_EVIDENCE="INFRA_SHA raw/nft-keel.txt raw/nft-ruleset.txt raw/nft-lxd.txt raw/iptables.txt
raw/iptables-nat.txt raw/dc1-ci-1.yaml raw/keel-ps.txt raw/keel-compose.yml stable/keel-nft.txt stable/iptables.txt
stable/iptables-nat.txt stable/nft-other.txt stable/lxd-lxdbr0.txt stable/units.txt stable/dc1-ci-1.txt
stable/lxdbr0.txt stable/keel-inventory.txt stable/keel-containers.txt stable/keel-state.txt stable/keel-health.txt
volatile/docker-user.txt"
KEEL_HEALTH_URLS="http://127.0.0.1:3000/healthz http://127.0.0.1:3000/readyz http://127.0.0.1:8080/
https://keel.dc1.lan/ https://keel.dc1.lan/__keel/healthz"
KEEL_DU_RULES=('-A DOCKER-USER -i lxdbr0 -j ACCEPT' '-A DOCKER-USER -o lxdbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT')
TW_DU_RULES=('-A DOCKER-USER -i citwbr0 -j ACCEPT' '-A DOCKER-USER -o citwbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT')

# ── Keel's service inventory and container contract ─────────────────────────
#
# THE EXPECTED INVENTORY IS NOT A LIST KEPT HERE. It is derived, on the host, from Keel's own
# deployment definition: roles/keel/tasks/deploy.yml installs `infra/lab/compose.lab.yml` of the
# built Keel commit, as a plain copy, at keel_compose_file. That file is accepted only if its
# SHA-256 equals the reviewed file at the pinned keel_commit (below); every `container_name`
# under `services:` is then an expected container, required exactly once. tests/ci-activation
# binds these three values to roles/keel (keel_commit, keel_root/keel_compose_file, the copy
# task) and, where the Keel source is available, re-derives the hash and the inventory from
# `git show <keel_commit>:infra/lab/compose.lab.yml`.
KEEL_COMMIT="9b0d36f008e726f830d96c4a3932b28d13bf68dd"                                  # roles/keel keel_commit
KEEL_COMPOSE_LIVE="/srv/data/services/keel/compose.lab.yml"                            # keel_compose_file
KEEL_COMPOSE_SHA256="73a4ac347d5363c2e055db0d91926eefe25bd990de80fa619013bb87b3b872cc" # infra/lab/compose.lab.yml at KEEL_COMMIT
#
# ONE-SHOT JOBS are exactly the services roles/keel/tasks/verify.yml exempts from "running"
# (`^(bootstrap|minio-bucket) `); in the bound Compose file they are the services with
# `restart: 'no'`, and gate the gateway (and bootstrap the runtime-worker) through
# `service_completed_successfully`. The two sources must agree, or the inventory is refused.
# A one-shot must have COMPLETED SUCCESSFULLY: exited, exit code 0, not OOM-killed. Every other
# expected container is long-running: running, and healthy where it has a health check. A
# missing or duplicated expected container, an unexpected keel-lab container, a failed
# inspection, a nonzero exit or an unrecognised state blocks.
KEEL_ONESHOT_SERVICES="bootstrap minio-bucket"
# The evidence line for one container; explicit fields so a reader (and the classifier) never guesses.
KEEL_STATE_FORMAT='{{.Name}} restarts={{.RestartCount}} status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'

# Compose file on stdin -> "service container_name restart" per service, sorted. A service
# without a container_name or restart policy yields a line the inventory check rejects.
keel_inventory() {
  awk '
    /^services:[[:space:]]*$/ { in_s = 1; next }
    in_s && /^[^[:space:]#]/ { in_s = 0 }
    !in_s { next }
    /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { if (svc != "") print svc, (cn == "" ? "-" : cn), (rs == "" ? "-" : rs)
                                         svc = $1; sub(/:$/, "", svc); cn = ""; rs = ""; next }
    /^    container_name:/ { cn = $2 }
    /^    restart:/ { rs = $2; gsub(/["\047]/, "", rs) }
    END { if (svc != "") print svc, (cn == "" ? "-" : cn), (rs == "" ? "-" : rs) }' | sort
}
# Inventory on stdin -> one line per defect; no output means it is a usable contract.
keel_inventory_problems() {
  awk -v oneshots="$KEEL_ONESHOT_SERVICES" '
    BEGIN { n = split(oneshots, o, " "); for (i = 1; i <= n; i++) want[o[i]] = 1 }
    NF == 0 { next }
    NF != 3 { print "unrecognised inventory line: " $0; next }
    { rows++ }
    $2 == "-" { print "service " $1 " has no container_name" }
    $3 == "-" { print "service " $1 " has no restart policy" }
    $3 == "no" && !($1 in want) { print "service " $1 " is restart: no but not a one-shot in roles/keel/tasks/verify.yml" }
    ($1 in want) { got[$1] = 1; if ($3 != "no") print "one-shot " $1 " is not restart: no in the Compose file" }
    ($2 in cont) { print "container_name " $2 " is used twice" } { cont[$2] = 1 }
    END { if (rows == 0) print "no services found in the Compose file"
          for (k in want) if (!(k in got)) print "one-shot " k " is not a service in the Compose file" }'
}
# keel_state_problems INVENTORY-FILE < state lines -> one line per violation of the container
# contract; no output means every expected container is present once and in its required state.
keel_state_problems() {
  awk -v oneshots="$KEEL_ONESHOT_SERVICES" '
    BEGIN { n = split(oneshots, o, " "); for (i = 1; i <= n; i++) os[o[i]] = 1 }
    FNR == NR { if (NF == 3) { c = "/" $2; exp_[c] = ($1 in os) ? "one-shot" : "long-running"; seen[c] = 0; ninv++ }; next }
    NF == 0 { next }
    $0 !~ /^\/[^ ]+ restarts=[0-9]+ status=[a-z]+ exit=-?[0-9]+ oom=(true|false) health=[a-z]+$/ { print "unrecognised state line: " $0; next }
    {
      name = $1; split($3, s, "="); split($4, x, "="); split($5, m, "="); split($6, h, "=")
      if (!(name in exp_)) { print "unexpected container " name " (not in the reviewed Compose inventory)"; next }
      seen[name]++
      if (exp_[name] == "one-shot") {
        if (s[2] != "exited" || x[2] != "0" || m[2] != "false")
          print "one-shot " name " did not complete successfully: status=" s[2] " exit=" x[2] " oom=" m[2]
      } else if (s[2] != "running") {
        print "long-running " name " is not running: status=" s[2] " exit=" x[2] " oom=" m[2]
      } else if (h[2] != "none" && h[2] != "healthy") {
        print "long-running " name " is not healthy: health=" h[2]
      }
    }
    END { if (ninv == 0) print "no expected Keel inventory"
          for (k in seen) { if (seen[k] == 0) print "expected " exp_[k] " " k " is missing"
                            else if (seen[k] > 1) print "expected " exp_[k] " " k " appears " seen[k] " times" } }' "$1" -
}
# The whole contract for one set of evidence: bound Compose copy + derived inventory + state.
# keel_evidence_problems COMPOSE-COPY INVENTORY-FILE STATE-FILE
keel_evidence_problems() {
  local h
  h=$(sha256_of "$1" 2>/dev/null | awk '{print $1}')
  [ "$h" = "$KEEL_COMPOSE_SHA256" ] || echo "the deployed Compose file is not the reviewed definition at keel_commit ${KEEL_COMMIT:0:8} (sha256 ${h:-unreadable})"
  keel_inventory < "$1" | cmp -s - "$2" || echo "the recorded inventory does not match the Compose file"
  keel_inventory_problems < "$2"
  keel_state_problems "$2" < "$3"
}

# ═══ snapshot ═══════════════════════════════════════════════════════════════
SNAP_BAD=0
bad_ev() { SNAP_BAD=$((SNAP_BAD + 1)); echo "  REQUIRED EVIDENCE MISSING OR INVALID: $*"; }
# One command, stdout -> evidence file, stderr -> errors/. Returns the command's own status
# (no pipeline, so no stage can hide a failure).
collect() { local rel=$1; shift; "$@" > "$D/$rel" 2> "$D/errors/${rel//\//_}.err"; }
has_line() { grep -E -- "$2" "$1" >/dev/null 2>&1; }
first_line_is() { [ "$(sed -n 1p "$1" 2>/dev/null)" = "$2" ]; }
count_line() { grep -cxF -- "$1" "$2" 2>/dev/null; }
strip_ipt() { awk '{gsub(/\[[0-9]+:[0-9]+\]/, "")} /^#/ || /citwbr0/ {next} {print}' "$1"; }
opt() { local rel=$1; shift; collect "$rel" "$@" || echo "  optional context not collected: $rel (see errors/)"; }

snapshot() {
  local PHASE="${1:-}" SHA="${2:-}" u en ac url code rc c n m bad r
  case "$PHASE" in before|after-provision|after-failure) ;; *) die "phase must be before, after-provision or after-failure";; esac
  sha_ok "$SHA" || die "second argument must be the 40-character infrastructure SHA"
  sudo -v || die "sudo refused"
  D="$BASE/$PHASE-$(date -u +%Y%m%dT%H%M%SZ)"
  [ ! -e "$D" ] || die "snapshot directory already exists: $D (wait a second and retry)"
  mkdir -p "$D/stable" "$D/volatile" "$D/raw" "$D/errors" && chmod -R go-rwx "$BASE" || die "cannot create $D"
  echo "$SHA" > "$D/INFRA_SHA" || die "cannot write $D/INFRA_SHA"
  SNAP_BAD=0
  echo "== snapshot $D (phase $PHASE, infrastructure $SHA)"

  # Keel's egress table — required, byte-compared
  if collect raw/nft-keel.txt sudo nft -s list table inet ci_egress && first_line_is "$D/raw/nft-keel.txt" 'table inet ci_egress {'; then
    cp "$D/raw/nft-keel.txt" "$D/stable/keel-nft.txt" || bad_ev "copy of Keel's table"
  else bad_ev "nft -s list table inet ci_egress (see errors/)"; fi

  # every other nft table (iptables-nft's, Keel's, TrueWealth's and LXD's are covered elsewhere)
  if collect raw/nft-ruleset.txt sudo nft -s list ruleset && has_line "$D/raw/nft-ruleset.txt" '^table inet ci_egress \{$'; then
    awk '/^# Warning/ {next} /^table (ip|ip6) (filter|nat|mangle|raw|security) \{|^table inet (ci_egress|ci_egress_tw|lxd) \{/ {s=1} s && /^\}/ {s=0; next} !s' \
      "$D/raw/nft-ruleset.txt" > "$D/stable/nft-other.txt" || bad_ev "derivation of nft-other"
  else bad_ev "nft -s list ruleset (see errors/)"; fi

  # LXD's lxdbr0 rules
  if collect raw/nft-lxd.txt sudo nft -s list table inet lxd && first_line_is "$D/raw/nft-lxd.txt" 'table inet lxd {'; then
    awk '/lxdbr0/' "$D/raw/nft-lxd.txt" > "$D/stable/lxd-lxdbr0.txt" && [ -s "$D/stable/lxd-lxdbr0.txt" ] || bad_ev "LXD's lxdbr0 rules: none found"
  else bad_ev "nft -s list table inet lxd (see errors/)"; fi

  # iptables filter (all chains incl. Docker's, Tailscale's, Keel's) and nat; counters and citwbr0 removed
  if collect raw/iptables.txt sudo iptables-save && has_line "$D/raw/iptables.txt" '^\*filter$' \
     && has_line "$D/raw/iptables.txt" '^:DOCKER-USER ' && has_line "$D/raw/iptables.txt" '^COMMIT$'; then
    strip_ipt "$D/raw/iptables.txt" > "$D/stable/iptables.txt" || bad_ev "derivation of iptables"
  else bad_ev "iptables-save (see errors/)"; fi
  if collect raw/iptables-nat.txt sudo iptables-save -t nat && has_line "$D/raw/iptables-nat.txt" '^\*nat$' \
     && has_line "$D/raw/iptables-nat.txt" '^COMMIT$'; then
    strip_ipt "$D/raw/iptables-nat.txt" > "$D/stable/iptables-nat.txt" || bad_ev "derivation of iptables-nat"
  else bad_ev "iptables-save -t nat (see errors/)"; fi

  # DOCKER-USER, and Keel's two rules in it exactly once
  if collect volatile/docker-user.txt sudo iptables -S DOCKER-USER && has_line "$D/volatile/docker-user.txt" '^-N DOCKER-USER$'; then
    for r in "${KEEL_DU_RULES[@]}"; do
      n=$(count_line "$r" "$D/volatile/docker-user.txt"); [ "$n" = 1 ] || bad_ev "Keel's DOCKER-USER rule present $n times: $r"
    done
  else bad_ev "iptables -S DOCKER-USER (see errors/)"; fi

  # units: every state must be readable; docker, LXD and Caddy must be active
  : > "$D/stable/units.txt" || bad_ev "write units"
  for u in ci-egress docker snap.lxd.daemon caddy; do
    en=$(systemctl is-enabled "$u" 2>>"$D/errors/units.err"); ac=$(systemctl is-active "$u" 2>>"$D/errors/units.err")
    echo "$u ${en:-?} ${ac:-?}" >> "$D/stable/units.txt" || bad_ev "write units"
    case "$en" in enabled|enabled-runtime|disabled|static|indirect|generated|alias|linked|linked-runtime|masked|masked-runtime|transient) ;;
      *) bad_ev "unit $u: is-enabled unreadable ('${en}')";; esac
    case "$ac" in active|inactive|failed|activating|deactivating|reloading) ;; *) bad_ev "unit $u: is-active unreadable ('${ac}')";; esac
  done
  for u in docker snap.lxd.daemon caddy; do grep -E "^$u [^ ]+ active$" "$D/stable/units.txt" >/dev/null || bad_ev "unit $u is not active"; done

  # dc1-ci-1's configuration (volatile.* keys removed) and lxdbr0
  if collect raw/dc1-ci-1.yaml sudo lxc config show dc1-ci-1 --expanded && has_line "$D/raw/dc1-ci-1.yaml" '^config:'; then
    awk '$1 !~ /^volatile\./' "$D/raw/dc1-ci-1.yaml" > "$D/stable/dc1-ci-1.txt" || bad_ev "derivation of dc1-ci-1"
  else bad_ev "lxc config show dc1-ci-1 --expanded (see errors/)"; fi
  collect stable/lxdbr0.txt sudo lxc network show lxdbr0 && has_line "$D/stable/lxdbr0.txt" '^name: lxdbr0$' \
    || bad_ev "lxc network show lxdbr0 (see errors/)"

  # Keel's expected inventory, from the deployed Compose file — accepted only as the reviewed
  # definition at keel_commit (checked with the containers below)
  if collect raw/keel-compose.yml sudo cat "$KEEL_COMPOSE_LIVE" && [ -s "$D/raw/keel-compose.yml" ]; then
    keel_inventory < "$D/raw/keel-compose.yml" > "$D/stable/keel-inventory.txt" || bad_ev "derivation of keel-inventory"
  else bad_ev "read $KEEL_COMPOSE_LIVE (see errors/)"; : > "$D/stable/keel-inventory.txt"; fi

  # Keel's containers: every one inspected and judged by the container contract above — each
  # expected container exactly once, one-shots completed with exit 0, long-running ones running
  # (healthy where checked), nothing unexpected
  if collect raw/keel-ps.txt sudo docker ps -a --filter name=keel-lab --format '{{.Names}} {{.Image}} {{.Label "com.docker.compose.project"}}' \
     && [ -s "$D/raw/keel-ps.txt" ]; then
    sort "$D/raw/keel-ps.txt" > "$D/stable/keel-containers.txt" || bad_ev "derivation of keel-containers"
    : > "$D/stable/keel-state.txt"
    for c in $(awk '{print $1}' "$D/stable/keel-containers.txt"); do
      sudo docker inspect --format "$KEEL_STATE_FORMAT" "$c" \
        >> "$D/stable/keel-state.txt" 2>>"$D/errors/keel-state.err" || bad_ev "docker inspect $c (see errors/)"
    done
    n=$(awk 'END {print NR}' "$D/stable/keel-state.txt"); m=$(awk 'END {print NR}' "$D/stable/keel-containers.txt")
    [ "$n" = "$m" ] || bad_ev "container state for $n of $m Keel containers"
    bad=$(keel_evidence_problems "$D/raw/keel-compose.yml" "$D/stable/keel-inventory.txt" "$D/stable/keel-state.txt")
    [ -z "$bad" ] || bad_ev "Keel container contract: $(printf '%s' "$bad" | tr '\n' ';')"
  else bad_ev "docker ps keel-lab: error or no containers (see errors/)"; fi

  # Keel's own health contract (roles/keel/tasks/verify.yml): all 200, certificates verified
  : > "$D/stable/keel-health.txt"
  for url in $KEEL_HEALTH_URLS; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" 2>>"$D/errors/keel-health.err"); rc=$?
    echo "$url ${code:-none}" >> "$D/stable/keel-health.txt"
    { [ "$rc" -eq 0 ] && [ "$code" = 200 ]; } || bad_ev "health $url: HTTP ${code:-none}, curl exit $rc"
  done

  # VOLATILE — context only, expected to differ; a failure here is reported, not required
  opt volatile/memory.txt free -m
  opt volatile/vgs.txt sudo vgs ubuntu-vg
  opt volatile/lvs.txt sudo lvs ubuntu-vg
  opt volatile/docker-stats.txt sudo docker stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.MemUsage}}'
  opt volatile/keel-nft-counters.txt sudo nft list table inet ci_egress
  opt volatile/lxc-list.txt sudo lxc list --format csv -c ns4
  find "$D/errors" -type f -empty -exec rm -f {} + 2>/dev/null   # keep only real diagnostics
  chmod -R go-rwx "$BASE"

  echo "== Keel health:"; sed 's/^/   /' "$D/stable/keel-health.txt"
  echo "== Keel containers:"; sed 's/^/   /' "$D/stable/keel-state.txt" 2>/dev/null
  if [ "$SNAP_BAD" -ne 0 ]; then
    echo "RESULT: INCOMPLETE — $SNAP_BAD required item(s) missing or invalid. NO completion record was written;"
    echo "        this snapshot is not a baseline. Diagnostics: $D/errors/"
    return 1
  fi
  write_record "$D" "$PHASE" "$SHA" || { echo "RESULT: INCOMPLETE — the completion record could not be written"; return 1; }
  verify_record "$D" "$PHASE" "$SHA" "" >/dev/null || { echo "RESULT: INCOMPLETE — the completion record does not verify"; return 1; }
  echo "RESULT: OK — completion record $D/COMPLETE"
}

# Completion record: format, phase, SHA, snapshot identity, creation time, and the SHA-256 of every
# required evidence file, terminated by a count line (a truncated record does not verify).
write_record() { # dir phase sha
  local d=$1 f h n=0
  {
    echo "$RECORD_FORMAT"; echo "phase $2"; echo "infra_sha $3"; echo "snapshot $(basename "$d")"
    echo "host $(hostname)"; echo "created_epoch $(date +%s)"; echo "created_utc $(date -u +%FT%TZ)"
    for f in $REQUIRED_EVIDENCE; do
      [ -f "$d/$f" ] || return 1
      h=$(cd "$d" && sha256_of "$f" | awk '{print $1}') || return 1
      [ "${#h}" -eq 64 ] || return 1
      echo "file $h $f"; n=$((n + 1))
    done
    echo "end $n"
  } > "$d/COMPLETE.tmp" || return 1
  mv "$d/COMPLETE.tmp" "$d/COMPLETE"
}

VR_BAD=0
vr_bad() { VR_BAD=1; echo "  record invalid: $*"; }
verify_record() { # dir phase sha [max-age-minutes] -> 0 only if every check passes
  local d=$1 phase=$2 sha=$3 max=${4:-} r="$1/COMPLETE" f h nfile ce now n
  VR_BAD=0
  [ -f "$r" ] || { echo "  record invalid: no completion record in $d (snapshot incomplete or interrupted)"; return 1; }
  [ "$(sed -n 1p "$r")" = "$RECORD_FORMAT" ] || vr_bad "unknown format"
  [ "$(awk '$1 == "phase" {print $2}' "$r")" = "$phase" ] || vr_bad "phase is not $phase"
  case "$(basename "$d")" in "$phase"-2*) ;; *) vr_bad "directory name does not match phase $phase";; esac
  [ "$(awk '$1 == "infra_sha" {print $2}' "$r")" = "$sha" ] || vr_bad "recorded infrastructure SHA is not $sha"
  [ "$(cat "$d/INFRA_SHA" 2>/dev/null)" = "$sha" ] || vr_bad "INFRA_SHA file is not $sha"
  [ "$(awk '$1 == "snapshot" {print $2}' "$r")" = "$(basename "$d")" ] || vr_bad "snapshot identity does not match $(basename "$d")"
  nfile=$(awk '$1 == "file" {n++} END {print n + 0}' "$r")
  [ "$(tail -n 1 "$r")" = "end $nfile" ] || vr_bad "record truncated (no matching end line)"
  for f in $REQUIRED_EVIDENCE; do
    h=$(awk -v f="$f" '$1 == "file" && $3 == f {print $2}' "$r")
    if [ -z "$h" ]; then vr_bad "not bound by the record: $f"; continue; fi
    if [ ! -f "$d/$f" ]; then vr_bad "evidence file missing: $f"; continue; fi
    [ "$(cd "$d" && sha256_of "$f" | awk '{print $1}')" = "$h" ] || vr_bad "evidence changed after completion: $f"
  done
  n=$(awk '$2 == "200" {n++} END {print n + 0}' "$d/stable/keel-health.txt" 2>/dev/null)
  [ "$n" = 5 ] || vr_bad "Keel health is $n/5 at 200"
  # The same inventory and container contract the snapshot applied, re-applied to the bound evidence.
  if [ -f "$d/raw/keel-compose.yml" ] && [ -f "$d/stable/keel-inventory.txt" ] && [ -f "$d/stable/keel-state.txt" ]; then
    n=$(keel_evidence_problems "$d/raw/keel-compose.yml" "$d/stable/keel-inventory.txt" "$d/stable/keel-state.txt")
    [ -z "$n" ] || vr_bad "Keel container contract: $(printf '%s' "$n" | tr '\n' ';')"
  fi
  if [ -n "$max" ]; then
    ce=$(awk '$1 == "created_epoch" {print $2}' "$r"); now=$(date +%s)
    case "$ce" in ''|*[!0-9]*) vr_bad "no creation time";;
      *) if [ $((now - ce)) -lt -60 ] || [ $((now - ce)) -gt $((max * 60)) ]; then vr_bad "older than $max minutes (or in the future)"; fi;; esac
  fi
  return "$VR_BAD"
}

verify_cmd() { # phase sha [max-age]
  local phase="${1:-}" sha="${2:-}" max="${3:-}" d
  case "$phase" in before|after-provision) ;; *) die "phase must be before or after-provision";; esac
  sha_ok "$sha" || die "the 40-character infrastructure SHA is required"
  case "$max" in ''|*[!0-9]*) [ -z "$max" ] || die "max age must be minutes";; esac
  d=$(newest_dir "$phase")
  [ -n "$d" ] || { echo "NOT VERIFIED: no $phase snapshot"; return 1; }
  echo "newest $phase snapshot: $d"
  if verify_record "$d" "$phase" "$sha" "$max"; then echo "VERIFIED $d"; return 0; fi
  echo "NOT VERIFIED: $d is not a valid baseline (the newest one is checked; older ones are never used instead)"
  return 1
}

compare() {
  local SHA="${1:-}" B A f=0 r n x
  sha_ok "$SHA" || die "compare needs the 40-character infrastructure SHA"
  B=$(newest_dir before); A=$(newest_dir after-provision)
  if [ -z "$B" ] || [ -z "$A" ]; then echo "RESULT: STOP — need a before and an after-provision snapshot"; return 1; fi
  echo "before: $B"; echo "after:  $A"
  verify_record "$B" before "$SHA" || f=1
  verify_record "$A" after-provision "$SHA" || f=1
  if [ "$f" -ne 0 ]; then echo "RESULT: STOP — a snapshot has no valid completion record; nothing was compared"; return 1; fi
  if [ ! "${B##*/before-}" \< "${A##*/after-provision-}" ]; then echo "RESULT: STOP — the after snapshot is not later than the before snapshot"; return 1; fi
  diff -r "$B/stable" "$A/stable"; r=$?
  case "$r" in
    0) echo "PASS stable/ identical (Keel table, Docker/Tailscale/Keel iptables, other nft, lxdbr0, units, dc1-ci-1, Keel containers, health)";;
    1) echo "FAIL stable/ differs (lines above) — regression"; f=1;;
    *) echo "FAIL diff could not compare the snapshots (exit $r)"; f=1;;
  esac
  for x in "${TW_DU_RULES[@]}" "${KEEL_DU_RULES[@]}"; do
    n=$(count_line "$x" "$A/volatile/docker-user.txt")
    if [ "$n" = 1 ]; then echo "PASS exactly once: $x"; else echo "FAIL $n times: $x"; f=1; fi
  done
  echo "-- volatile changes (context, not regressions):"
  for x in memory.txt vgs.txt lxc-list.txt; do
    if [ -f "$B/volatile/$x" ] && [ -f "$A/volatile/$x" ]; then echo "   $x"; diff "$B/volatile/$x" "$A/volatile/$x" | sed 's/^/     /'
    else echo "   $x: not collected in both snapshots"; fi
  done
  if [ "$f" -eq 0 ]; then echo "RESULT: OK — no regression"; return 0; fi
  echo "RESULT: STOP — regression; preserve evidence"; return 1
}

# ═══ probe: live checks after provisioning ═══════════════════════════════════
#
# Every check reports exactly one verdict:
#   PASS                  the required observation was made
#   FAIL                  forbidden connectivity succeeded, a required positive control
#                         failed, or required state is wrong
#   INCONCLUSIVE          a required check could not establish its result: a query or probe
#                         that failed or could not run, a missing tool or address, a target
#                         that does not answer even from the host, or an unexpected immediate
#                         failure. Any INCONCLUSIVE prevents overall success.
#   EXPECTED_UNAVAILABLE  a documented, intentionally absent service (listed below). It is
#                         NOT isolation evidence and does not count as a pass.
#   INFO                  context and supporting evidence; never changes a verdict
#
# Command status is checked before any output is interpreted: a failed query is INCONCLUSIVE,
# never PASS.
#
# A denied-target PASS records an OBSERVED CONNECTIVITY OUTCOME: from the guest, no
# connection (no response within the timeout); from the host, the same address and port
# connected. It does not by itself establish which rule, device or service stopped the
# guest's attempt. The counter lines are supporting evidence only: the counters are shared
# with any other traffic from the guest.
#
# The VM's configuration checks (type, host paths, passthrough devices, raw overrides) are
# configuration evidence; they do not test the hypervisor boundary itself.
#
# Sections are judged separately — infrastructure readiness, Keel preservation, TrueWealth
# isolation coverage — and all three must be OK.

VM=dc1-ci-tw-1
R_SEC=(); R_ST=(); R_MSG=()
rec() { R_SEC+=("$1"); R_ST+=("$2"); R_MSG+=("$3"); printf '%-21s %s\n' "$2" "$3"; }
QOUT=""; QRC=0
qry() { QOUT=$("$@" 2>&1); QRC=$?; }   # run a query; keep its output AND its status

# ── pure helpers (unit-tested by hostcheck-test.sh) ─────────────────────────
rc_of() { sed -n 's/^RC=\([0-9][0-9]*\)$/\1/p' | tail -n 1; }
tcp_outcome()  { case "${1:-}" in 0) echo open;; 124) echo timeout;; 1) echo fastfail;; *) echo error;; esac; }
icmp_outcome() { case "${1:-}" in 0) echo open;; 1) echo timeout;; *) echo error;; esac; }
say_outcome() { # kind outcome
  case "$1:$2" in
    tcp:open) echo "connected";;              icmp:open) echo "reply received";;
    tcp:timeout) echo "no response within 4 s";; icmp:timeout) echo "no reply within 2 s";;
    tcp:fastfail) echo "failed immediately (a reset or unreachable reply came back)";;
    *) echo "probe could not run";;
  esac
}
# class: required | expected-absent ; g/h: guest/host outcome
classify() {
  local class=$1 g=$2 h=$3
  if [ "$g" = open ]; then echo FAIL; return; fi
  if [ "$g" = error ] || [ "$h" = error ]; then echo INCONCLUSIVE; return; fi
  if [ "$h" = open ]; then
    if [ "$g" = timeout ]; then echo PASS; else echo INCONCLUSIVE; fi
    return
  fi
  if [ "$class" = expected-absent ]; then echo EXPECTED_UNAVAILABLE; else echo INCONCLUSIVE; fi
}
positive_status() { case "$1" in open) echo PASS;; error) echo INCONCLUSIVE;; *) echo FAIL;; esac; }
# The guest's route to a destination (`ip -4 route get` exit status and first line) against its
# external interface. Only "external" makes a denied-target probe evidence about the HOST boundary:
#   guest-local   the address is the guest's own (e.g. its docker0 172.17.0.1) — the probe would test the guest
#   other:<dev>   the guest routes it via another of its interfaces (an overlapping network)
#   no-route      the guest has no route at all
#   unreadable    the query failed or its output is not understood
route_verdict() { # rc line external-interface
  local rc=$1 line=$2 ext=$3 dev
  if [ "$rc" != 0 ]; then case "$line" in *nreachable*|*prohibit*) echo no-route;; *) echo unreadable;; esac; return; fi
  case "$line" in
    "local "*|"broadcast "*|"multicast "*) echo guest-local; return;;
    "unreachable "*|"prohibit "*|"blackhole "*|"throw "*) echo no-route; return;;
  esac
  dev=$(printf '%s\n' "$line" | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}')
  if [ -z "$dev" ] || [ -z "$ext" ]; then echo unreadable
  elif [ "$dev" = lo ]; then echo guest-local
  elif [ "$dev" = "$ext" ]; then echo external
  else echo "other:$dev"; fi
}
enabled_status() { # systemctl is-enabled output -> verdict
  case "$1" in enabled) echo PASS;; disabled|static|indirect|generated|alias|linked|linked-runtime|masked|masked-runtime|enabled-runtime|transient) echo FAIL;; *) echo INCONCLUSIVE;; esac
}
# VM configuration (lxc config show --expanded): the role's own assertions plus passthrough and raw overrides
vm_config_findings() {
  local c; c=$(cat)
  printf '%s\n' "$c" | grep -E 'source:[[:space:]]*/' >/dev/null && echo "a disk device has a host path source"
  printf '%s\n' "$c" | grep -E '/srv|docker\.sock' >/dev/null && echo "/srv or docker.sock referenced"
  printf '%s\n' "$c" | grep -E 'type:[[:space:]]*(unix-char|unix-block|unix-hotplug|usb|gpu|pci|infiniband)$' >/dev/null && echo "a passthrough device is attached"
  printf '%s\n' "$c" | grep -E '^[[:space:]]*raw\.[a-z.]+:' >/dev/null && echo "a raw.* hypervisor/LXC override is set"
  printf '%s\n' "$c" | grep -E 'security\.privileged:[[:space:]]*"?true' >/dev/null && echo "security.privileged is true"
  return 0
}
normalize_nft() { sed -E -e 's/(^|[[:space:]])counter packets [0-9]+ bytes [0-9]+/\1counter/' -e 's/^[[:space:]]+//' -e '/^$/d'; }
# The TrueWealth table exactly as nftables 1.0.9 lists the rendering of playbooks/vars/ci-runner-truewealth.yml,
# counters removed. tests/run-ci-runner-truewealth.sh §13 loads the freshly rendered policy into a real nft
# and fails if this text and the listing ever diverge.
tw_table_expected() {
  cat <<'EOF'
table inet ci_egress_tw {
chain input {
type filter hook input priority filter - 10; policy accept;
iifname != "citwbr0" accept
meta nfproto ipv6 counter drop
ct state established,related accept
ip saddr 10.72.0.0/24 ip daddr 10.72.0.1 udp dport 53 counter accept
ip saddr 10.72.0.0/24 ip daddr 10.72.0.1 tcp dport 53 counter accept
udp sport 68 udp dport 67 counter accept
counter drop
}
chain forward {
type filter hook forward priority filter - 10; policy accept;
iifname "citwbr0" meta nfproto ipv6 counter drop
oifname "citwbr0" meta nfproto ipv6 counter drop
ct state established,related accept
oifname "citwbr0" ct state new counter drop
iifname "citwbr0" ip saddr != 10.72.0.0/24 counter drop
iifname "citwbr0" ip daddr 10.0.0.0/8 counter drop
iifname "citwbr0" ip daddr 100.64.0.0/10 counter drop
iifname "citwbr0" ip daddr 172.16.0.0/12 counter drop
iifname "citwbr0" ip daddr 192.168.0.0/16 counter drop
iifname "citwbr0" ip daddr 169.254.0.0/16 counter drop
iifname "citwbr0" ip saddr 10.72.0.0/24 tcp dport { 80, 443 } counter accept
iifname "citwbr0" ip saddr 10.72.0.0/24 udp dport 123 counter accept
iifname "citwbr0" counter drop
}
}
EOF
}
policy_verdict() { # normalized live table on stdin
  local live; live=$(cat)
  if [ -z "$live" ]; then echo FAIL; elif [ "$live" = "$(tw_table_expected)" ]; then echo PASS; else echo FAIL; fi
}

summarize() {
  local s name v p f i e k n=${#R_SEC[@]} overall=OK
  echo; echo "══ SUMMARY"
  for s in readiness keel isolation; do
    case $s in readiness) name="Infrastructure readiness";; keel) name="Keel preservation";; *) name="TrueWealth isolation coverage";; esac
    p=0; f=0; i=0; e=0; k=0
    while [ "$k" -lt "$n" ]; do
      if [ "${R_SEC[$k]}" = "$s" ]; then
        case "${R_ST[$k]}" in PASS) p=$((p+1));; FAIL) f=$((f+1));; INCONCLUSIVE) i=$((i+1));; EXPECTED_UNAVAILABLE) e=$((e+1));; esac
      fi
      k=$((k+1))
    done
    if [ "$f" -gt 0 ]; then v=FAIL; elif [ "$i" -gt 0 ] || [ "$p" -eq 0 ]; then v=INCONCLUSIVE; else v=OK; fi
    printf '  %-30s %-13s %d pass, %d fail, %d inconclusive, %d expected-unavailable\n' "$name" "$v" "$p" "$f" "$i" "$e"
    if [ "$v" = FAIL ]; then overall=FAIL; elif [ "$v" = INCONCLUSIVE ] && [ "$overall" = OK ]; then overall=INCONCLUSIVE; fi
  done
  k=0
  while [ "$k" -lt "$n" ]; do
    case "${R_ST[$k]}" in
      FAIL|INCONCLUSIVE) echo "  ${R_ST[$k]}: ${R_MSG[$k]}";;
      EXPECTED_UNAVAILABLE) echo "  EXPECTED_UNAVAILABLE (not isolation evidence): ${R_MSG[$k]}";;
    esac
    k=$((k+1))
  done
  echo "  Not covered live: spoofed-source traffic, unsolicited inbound into the guest, UDP other than"
  echo "  DNS, and destinations not listed. Spoofing and inbound are covered only by the namespace test"
  echo "  (tests/run-ci-runner-truewealth.sh §12). Counter lines are supporting evidence, not attribution."
  echo "  VM configuration checks are configuration evidence; they do not test the hypervisor boundary."
  case $overall in
    OK) echo "RESULT: OK"; return 0;;
    FAIL) echo "RESULT: FAIL — preserve evidence; change nothing"; return 1;;
    *) echo "RESULT: INCONCLUSIVE — not established; preserve evidence; change nothing"; return 2;;
  esac
}

# ── live helpers (read-only) ─────────────────────────────────────────────────
X() { sudo lxc exec "$VM" -T -- "$@"; }
guest_tcp()  { X sh -c 'timeout 4 bash -c "exec 3<>/dev/tcp/$0/$1" >/dev/null 2>&1; echo "RC=$?"' "$1" "$2" 2>/dev/null | rc_of; }
guest_icmp() { X sh -c 'ping -4 -n -c 1 -W 2 "$0" >/dev/null 2>&1; echo "RC=$?"' "$1" 2>/dev/null | rc_of; }
host_tcp()   { timeout 4 bash -c 'exec 3<>/dev/tcp/$0/$1' "$1" "$2" >/dev/null 2>&1; echo $?; }
host_icmp()  { ping -4 -n -c 1 -W 2 "$1" >/dev/null 2>&1; echo $?; }
is_local()   { ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -x -- "$1" >/dev/null; }
# The guest's `ip -4 route get` for one address: its output followed by an RC=<status> marker.
guest_route() { X sh -c 'ip -4 route get "$0" 2>&1; echo "RC=$?"' "$1" </dev/null 2>/dev/null; }
route_line_of() { grep -v '^RC=' | sed -n 1p; }
# The host's Docker bridge networks, from Docker's own metadata (read-only):
# "network interface address" per line. Returns 1 when discovery itself fails.
docker_bridge_candidates() {
  local ids meta line id name opt gws iface a
  ids=$(sudo docker network ls --filter driver=bridge --format '{{.ID}}' 2>/dev/null) || return 1
  [ -n "$ids" ] || return 1
  # shellcheck disable=SC2086
  # '|'-separated: a missing option renders as "<no value>", which contains a space.
  meta=$(sudo docker network inspect --format '{{.Id}}|{{.Name}}|{{index .Options "com.docker.network.bridge.name"}}|{{range .IPAM.Config}}{{.Gateway}} {{end}}' $ids 2>/dev/null) || return 1
  printf '%s\n' "$meta" | while IFS='|' read -r id name opt gws; do
    [ -n "$id" ] || continue
    case "$opt" in ''|'<no value>') iface="br-$(printf '%s' "$id" | cut -c1-12)";; *) iface=$opt;; esac
    a=$(printf '%s\n' $gws | grep -E '^[0-9]+(\.[0-9]+){3}$' | sed -n 1p)
    # No gateway in IPAM: read the bridge interface's own address (read-only).
    [ -n "$a" ] || a=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sed -n 1p)
    echo "$name $iface ${a:--}"
  done | sort -k1,1 | awk '$1 == "bridge" {print; next} {rest[NR] = $0} END {for (i = 1; i <= NR; i++) if (i in rest) print rest[i]}'
}
drop_packets() { # sum of packets on the drop rules of one chain of inet ci_egress_tw; empty if unreadable
  sudo nft list chain inet ci_egress_tw "$1" 2>/dev/null \
    | awk '/counter packets [0-9]+ bytes [0-9]+ drop/ {for (i = 1; i <= NF; i++) if ($i == "packets") s += $(i + 1); n++} END {if (n) print s + 0}'
}

probe_target() { # class kind ip port label
  local class=$1 kind=$2 ip=$3 port=$4 label=$5 chain g h c0 c1 where
  if [ -z "$ip" ]; then rec isolation INCONCLUSIVE "$label: address not found on the host; the check could not run"; return; fi
  where=$ip; [ -n "$port" ] && where="$ip:$port"
  # The guest must route the destination out through its external interface; otherwise the probe
  # would test the guest itself (or an overlapping network) and say nothing about the host.
  local rt rl rv
  if [ -z "${GUEST_EXTIF:-}" ]; then
    rec isolation INCONCLUSIVE "$label $where: the guest's external interface is unknown, so its route cannot be checked"; return; fi
  rt=$(guest_route "$ip"); rl=$(printf '%s\n' "$rt" | route_line_of)
  rv=$(route_verdict "$(printf '%s\n' "$rt" | rc_of)" "$rl" "$GUEST_EXTIF")
  case "$rv" in
    external) ;;
    guest-local) rec isolation INCONCLUSIVE "$label $where: the address is local to the guest (route: $rl); not evidence about the host boundary"; return;;
    other:*) rec isolation INCONCLUSIVE "$label $where: the guest routes it via its own ${rv#other:}, not $GUEST_EXTIF (overlapping network; route: $rl); not evidence about the host boundary"; return;;
    no-route) rec isolation INCONCLUSIVE "$label $where: the guest has no route to it (route: $rl); not evidence about the host boundary"; return;;
    *) rec isolation INCONCLUSIVE "$label $where: the guest's route query failed (${rl:-no output})"; return;;
  esac
  if is_local "$ip"; then chain=input; else chain=forward; fi
  c0=$(drop_packets "$chain")
  if [ "$kind" = tcp ]; then g=$(tcp_outcome "$(guest_tcp "$ip" "$port")"); else g=$(icmp_outcome "$(guest_icmp "$ip")"); fi
  c1=$(drop_packets "$chain")
  if [ "$kind" = tcp ]; then h=$(tcp_outcome "$(host_tcp "$ip" "$port")"); else h=$(icmp_outcome "$(host_icmp "$ip")"); fi
  rec isolation "$(classify "$class" "$g" "$h")" "$label $where — observed: guest $(say_outcome "$kind" "$g"); host $(say_outcome "$kind" "$h"); guest route: $rl"
  if [ -n "$c0" ] && [ -n "$c1" ]; then
    rec evidence INFO "    counters: inet ci_egress_tw $chain drop rules +$((c1 - c0)) packets during the guest attempt (shared; supporting only)"
  else
    rec evidence INFO "    counters: inet ci_egress_tw $chain unreadable"
  fi
}

# The host-Docker-bridge target is DISCOVERED, never assumed: each bridge network's host address
# (Docker's metadata) must be an address of this host, must route out through the guest's external
# interface (a guest-local or overlapping destination is never evidence), and must answer a host-side
# control on :443. The first such address is probed; with none, the coverage stays INCONCLUSIVE.
# Every candidate's identity, route, host control and disposition is recorded.
select_docker_bridge_target() {
  local cands n i k a rt rl rv h chosen=-1
  local -a CN=() CI=() CA=()
  if ! cands=$(docker_bridge_candidates) || [ -z "$cands" ]; then
    rec isolation INCONCLUSIVE "host Docker bridge: discovery failed (docker network ls/inspect); no target could be selected"; return; fi
  while read -r n i a; do CN+=("$n"); CI+=("$i"); CA+=("$a"); done <<< "$cands"
  k=0
  while [ "$k" -lt "${#CN[@]}" ]; do
    n=${CN[$k]}; i=${CI[$k]}; a=${CA[$k]}; k=$((k + 1))
    if [ "$a" = - ]; then rec evidence INFO "    docker bridge $n ($i): no IPv4 address; rejected"; continue; fi
    if ! is_local "$a"; then rec evidence INFO "    docker bridge $n ($i) $a: not an address of this host; rejected"; continue; fi
    if [ -z "${GUEST_EXTIF:-}" ]; then rec evidence INFO "    docker bridge $n ($i) $a: guest external interface unknown; rejected"; continue; fi
    rt=$(guest_route "$a"); rl=$(printf '%s\n' "$rt" | route_line_of)
    rv=$(route_verdict "$(printf '%s\n' "$rt" | rc_of)" "$rl" "$GUEST_EXTIF")
    if [ "$rv" != external ]; then
      rec evidence INFO "    docker bridge $n ($i) $a: guest route '${rl:-none}' is $rv, not via $GUEST_EXTIF; rejected (not evidence about the host)"; continue; fi
    h=$(tcp_outcome "$(host_tcp "$a" 443)")
    if [ "$h" != open ]; then
      rec evidence INFO "    docker bridge $n ($i) $a: guest route '$rl'; host control :443 $(say_outcome tcp "$h"); rejected (no live host-side target)"; continue; fi
    rec evidence INFO "    docker bridge $n ($i) $a: guest route '$rl'; host control :443 connected; selected"
    chosen=$((k - 1)); break
  done
  if [ "$chosen" -lt 0 ]; then
    rec isolation INCONCLUSIVE "host Docker bridge: no bridge address both leaves the guest via ${GUEST_EXTIF:-its external interface} and answers a host-side control; coverage not established (candidates above)"
    return
  fi
  probe_target required tcp "${CA[$chosen]}" 443 "host Docker bridge ${CN[$chosen]} (${CI[$chosen]}), Caddy"
}

unit_check() { # section unit
  local en; en=$(systemctl is-enabled "$2" 2>/dev/null)
  rec "$1" "$(enabled_status "$en")" "unit $2 enabled (is-enabled: ${en:-unreadable})"
  rec "$1" INFO "unit $2 is $(systemctl is-active "$2" 2>/dev/null || true) (oneshot; the play applies the policy directly, so 'inactive' before a reboot is expected)"
}
du_check() { # section rule-file ok? rules...
  local sec=$1 file=$2 okq=$3 r n; shift 3
  for r in "$@"; do
    if [ "$okq" != 1 ]; then rec "$sec" INCONCLUSIVE "DOCKER-USER could not be read: $r"; continue; fi
    n=$(count_line "$r" "$file")
    if [ "$n" = 1 ]; then rec "$sec" PASS "DOCKER-USER exactly once: $r"; else rec "$sec" FAIL "DOCKER-USER $n times: $r"; fi
  done
}
table_check() { # section table label
  qry sudo nft list table inet "$2"
  if [ "$QRC" -eq 0 ]; then rec "$1" PASS "$3 is loaded"
  else case "$QOUT" in *"No such file or directory"*) rec "$1" FAIL "$3 is not loaded";; *) rec "$1" INCONCLUSIVE "$3: query failed: $QOUT";; esac; fi
}

probe_body() {
  local D=$1 SHA=$2 out missing live duok st u code rc iok problems findings keelvm ts
  echo "== live checks for $VM (infrastructure $SHA), $(date -u +%FT%TZ)"

  echo "── Infrastructure readiness"
  for u in nft iptables lxc curl timeout ping ip awk sed; do
    command -v "$u" >/dev/null 2>&1 || sudo sh -c "command -v $u" >/dev/null 2>&1 \
      || rec readiness INCONCLUSIVE "host tool missing: $u (checks that need it cannot run)"
  done
  qry sudo lxc list "^${VM}\$" -c s --format csv
  if [ "$QRC" -ne 0 ]; then rec readiness INCONCLUSIVE "$VM state query failed: $QOUT"
  elif [ "$QOUT" = RUNNING ]; then rec readiness PASS "$VM is RUNNING"; else rec readiness FAIL "$VM state: ${QOUT:-not found}"; fi
  qry sudo lxc list "^${VM}\$" -c t --format csv
  if [ "$QRC" -ne 0 ]; then rec readiness INCONCLUSIVE "$VM type query failed: $QOUT"
  elif [ "$QOUT" = VIRTUAL-MACHINE ]; then rec readiness PASS "$VM is a virtual machine (own kernel; the boundary is the hypervisor)"
  else rec readiness FAIL "$VM type is '${QOUT}', expected VIRTUAL-MACHINE"; fi
  qry sudo lxc config show "$VM" --expanded
  if [ "$QRC" -ne 0 ] || [ -z "$QOUT" ]; then
    rec readiness INCONCLUSIVE "$VM configuration query failed; host-path, passthrough and raw-override checks could not run"
  else
    findings=$(printf '%s\n' "$QOUT" | vm_config_findings)
    if [ -n "$findings" ]; then rec readiness FAIL "$VM configuration: $(printf '%s' "$findings" | tr '\n' ';')"
    else rec readiness PASS "$VM configuration shows no host-path disk, passthrough device or raw override (configuration evidence, not a test of the hypervisor)"; fi
  fi
  GUEST_OK=0
  qry X sh -c 'echo __ALIVE__'
  if [ "$QRC" -eq 0 ] && [ "$QOUT" = __ALIVE__ ]; then GUEST_OK=1; rec readiness PASS "$VM answers over lxc exec"
  else rec readiness FAIL "$VM does not answer over lxc exec (exit $QRC)"; fi
  if [ "$GUEST_OK" = 1 ]; then
    qry X sh -c 'm=; for t in bash timeout curl ping ip docker id; do command -v "$t" >/dev/null 2>&1 || m="$m $t"; done; echo "MISSING=$m"'
    missing=$(printf '%s\n' "$QOUT" | sed -n 's/^MISSING=//p')
    if [ "$QRC" -ne 0 ] || ! printf '%s\n' "$QOUT" | grep '^MISSING=' >/dev/null; then
      rec readiness INCONCLUSIVE "guest tool query failed (exit $QRC); Docker presence unknown"
    else
      [ -n "$missing" ] && rec readiness INFO "guest tools missing:$missing — the checks that need them report INCONCLUSIVE"
      case " $missing " in *" docker "*) rec readiness FAIL "Docker is not installed in the guest";; *) rec readiness PASS "Docker is installed in the guest";; esac
    fi
  fi
  qry sudo nft list table inet ci_egress_tw
  if [ "$QRC" -eq 0 ]; then
    live=$(printf '%s\n' "$QOUT" | normalize_nft)
    if [ "$(printf '%s\n' "$live" | policy_verdict)" = PASS ]; then
      rec readiness PASS "table inet ci_egress_tw is loaded and equals the reviewed rendering (counters ignored)"
    else rec readiness FAIL "table inet ci_egress_tw differs from the reviewed rendering (diff below)"
         diff <(tw_table_expected) <(printf '%s\n' "$live") | sed 's/^/     /'; fi
  else case "$QOUT" in *"No such file or directory"*) rec readiness FAIL "table inet ci_egress_tw is not loaded";;
         *) rec readiness INCONCLUSIVE "table inet ci_egress_tw: query failed: $QOUT";; esac; fi
  duok=0; sudo iptables -S DOCKER-USER > "$D/docker-user.txt" 2> "$D/docker-user.err" && duok=1
  du_check readiness "$D/docker-user.txt" "$duok" "${TW_DU_RULES[@]}"
  unit_check readiness ci-egress-tw
  unit_check readiness ci-egress-tw-early
  qry sudo lxc network get citwbr0 ipv6.address
  if [ "$QRC" -ne 0 ]; then rec readiness INCONCLUSIVE "citwbr0 ipv6.address query failed: $QOUT"
  elif [ "$QOUT" = none ]; then rec readiness PASS "citwbr0 has no IPv6 address"; else rec readiness FAIL "citwbr0 ipv6.address='$QOUT', expected none"; fi
  qry sudo lxc network get citwbr0 ipv4.address
  if [ "$QRC" -ne 0 ]; then rec readiness INCONCLUSIVE "citwbr0 ipv4.address query failed: $QOUT"
  elif [ "$QOUT" = 10.72.0.1/24 ]; then rec readiness PASS "citwbr0 is 10.72.0.1/24"; else rec readiness FAIL "citwbr0 ipv4.address='$QOUT', expected 10.72.0.1/24"; fi
  qry sudo lxc config get "$VM" limits.cpu; st=$QOUT; qry sudo lxc config get "$VM" limits.memory
  rec readiness INFO "limits: cpu=$st memory=$QOUT"

  echo "── Keel preservation"
  table_check keel ci_egress "Keel's table inet ci_egress"
  unit_check keel ci-egress
  du_check keel "$D/docker-user.txt" "$duok" "${KEEL_DU_RULES[@]}"
  qry sudo lxc list '^dc1-ci-1$' -c s --format csv
  if [ "$QRC" -ne 0 ]; then rec keel INCONCLUSIVE "dc1-ci-1 state query failed: $QOUT"
  elif [ "$QOUT" = RUNNING ]; then rec keel PASS "dc1-ci-1 is RUNNING"; else rec keel FAIL "dc1-ci-1 state: ${QOUT:-not found}"; fi
  for u in $KEEL_HEALTH_URLS; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$u" 2>/dev/null); rc=$?
    if [ "$rc" -eq 127 ]; then rec keel INCONCLUSIVE "health $u: curl not available"
    elif [ "$rc" -eq 0 ] && [ "$code" = 200 ]; then rec keel PASS "health $u 200"
    else rec keel FAIL "health $u: HTTP ${code:-none}, curl exit $rc"; fi
  done
  # The same inventory and container contract as the snapshot: the deployed Compose file must be the
  # reviewed definition; every expected container exactly once; one-shots completed (exit 0); the
  # rest running and healthy where checked; nothing unexpected.
  qry sudo docker ps -a --filter name=keel-lab --format '{{.Names}}'
  if ! sudo cat "$KEEL_COMPOSE_LIVE" > "$D/keel-compose.yml" 2> "$D/keel-compose.err" || [ ! -s "$D/keel-compose.yml" ]; then
    rec keel INCONCLUSIVE "cannot read the deployed Compose file $KEEL_COMPOSE_LIVE; the expected inventory is unknown"
  elif [ "$QRC" -ne 0 ]; then rec keel INCONCLUSIVE "docker ps keel-lab failed: $QOUT"
  else
    keel_inventory < "$D/keel-compose.yml" > "$D/keel-inventory.txt"
    iok=1; : > "$D/keel-state.txt"
    for u in $(printf '%s\n' "$QOUT" | sort); do
      sudo docker inspect --format "$KEEL_STATE_FORMAT" "$u" >> "$D/keel-state.txt" 2>>"$D/keel-state.err" || iok=0
    done
    if [ "$iok" != 1 ]; then rec keel INCONCLUSIVE "docker inspect failed for a keel-lab container (see $D/keel-state.err)"
    else
      problems=$(keel_evidence_problems "$D/keel-compose.yml" "$D/keel-inventory.txt" "$D/keel-state.txt")
      if [ -n "$problems" ]; then rec keel FAIL "Keel container contract: $(printf '%s' "$problems" | tr '\n' ';')"
      else rec keel PASS "Keel containers: all $(awk 'END {print NR}' "$D/keel-inventory.txt") services of the reviewed Compose file present once; one-shots ($KEEL_ONESHOT_SERVICES) completed with exit 0; the rest running and healthy where checked"; fi
    fi
  fi

  echo "── TrueWealth isolation coverage"
  if [ "$GUEST_OK" != 1 ]; then
    rec isolation INCONCLUSIVE "the guest does not answer; no isolation check could run"
  else
    # The guest's external interface (from its default route): denied targets must leave through it.
    GUEST_EXTIF=""
    qry X sh -c 'ip -4 route show default'
    if [ "$QRC" -eq 0 ]; then GUEST_EXTIF=$(printf '%s\n' "$QOUT" | awk '{for (i = 1; i < NF; i++) if ($i == "dev") {print $(i + 1); exit}}'); fi
    if [ -n "$GUEST_EXTIF" ]; then rec evidence INFO "    guest default route: $(printf '%s' "$QOUT" | sed -n 1p) (external interface $GUEST_EXTIF)"
    else rec isolation INCONCLUSIVE "the guest's default route could not be read (exit $QRC); no denied target can be tied to the host boundary"; fi
    rec isolation "$(positive_status "$(tcp_outcome "$(guest_tcp 10.72.0.1 53)")")" "positive control: guest's own resolver 10.72.0.1:53 (TCP) must connect"
    out=$(X sh -c 'curl -sS -4 -m 20 -o /dev/null https://api.github.com/zen >/dev/null 2>&1; echo "RC=$?"' 2>/dev/null | rc_of)
    case "$out" in 0) st=PASS;; ''|126|127) st=INCONCLUSIVE;; *) st=FAIL;; esac
    rec isolation "$st" "positive control: https://api.github.com over IPv4 must succeed (curl exit ${out:-none})"
    qry sudo lxc list '^dc1-ci-1$' --format csv -c 4
    if [ "$QRC" -ne 0 ]; then rec isolation INCONCLUSIVE "Keel's runner VM dc1-ci-1: address query failed: $QOUT"
    else keelvm=$(printf '%s\n' "$QOUT" | grep -oE '10\.71\.0\.[0-9]+' | sed -n 1p)
         probe_target required icmp "$keelvm" "" "Keel's runner VM dc1-ci-1"; fi
    ts=$(ip -4 -o addr show dev tailscale0 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | sed -n 1p)
    probe_target required        tcp  10.0.0.3   443  "host LAN address, Caddy ingress"
    probe_target expected-absent tcp  10.0.0.3   5432 "host LAN address, PostgreSQL (documented absent: Keel binds it to 127.0.0.1 only)"
    probe_target required        tcp  10.72.0.1  443  "guest's own gateway, Caddy"
    probe_target required        tcp  10.71.0.1  53   "Keel's bridge resolver"
    probe_target required        tcp  10.0.0.22  22   "administration plane dc1-arm-1, sshd"
    probe_target required        tcp  "$ts"      443  "host Tailscale address, Caddy"
    select_docker_bridge_target
    qry X sh -c 'ip -6 -o addr show scope global && ip -6 route show default && echo __OK__'
    if [ "$QRC" -ne 0 ] || [ -z "$(printf '%s\n' "$QOUT" | grep -x __OK__)" ]; then rec isolation INCONCLUSIVE "IPv6: could not read the guest's IPv6 addresses and routes (exit $QRC)"
    elif [ -n "$(printf '%s\n' "$QOUT" | grep -vx __OK__)" ]; then rec isolation FAIL "IPv6: guest has a global address or default route: $(printf '%s\n' "$QOUT" | grep -vx __OK__ | tr '\n' ';')"
    else rec isolation PASS "IPv6: observed no global IPv6 address and no IPv6 default route in the guest"; fi
    qry X sh -c 'if test -e /srv/data; then echo PRESENT; else echo ABSENT; fi'
    if [ "$QRC" -eq 0 ] && [ "$QOUT" = ABSENT ]; then rec isolation PASS "/srv/data is not visible in the guest"
    elif [ "$QRC" -eq 0 ] && [ "$QOUT" = PRESENT ]; then rec isolation FAIL "/srv/data is visible in the guest"
    else rec isolation INCONCLUSIVE "/srv/data: check could not run (exit $QRC)"; fi
    qry X sh -c 'docker ps -a --format "{{.Names}}" && echo __OK__'
    if [ "$QRC" -ne 0 ] || [ -z "$(printf '%s\n' "$QOUT" | grep -x __OK__)" ]; then rec isolation INCONCLUSIVE "guest docker ps could not run (exit $QRC)"
    elif [ -n "$(printf '%s\n' "$QOUT" | grep keel)" ]; then rec isolation FAIL "a Keel container is visible in the guest"
    else rec isolation PASS "no Keel container visible in the guest's Docker"; fi
    qry X id -nG ghrunner
    if [ "$QRC" -ne 0 ] || [ -z "$QOUT" ]; then rec isolation INCONCLUSIVE "ghrunner's groups could not be read (exit $QRC)"
    else case " $QOUT " in *" sudo "*|*" admin "*|*" root "*|*" lxd "*) rec isolation FAIL "ghrunner is in an administrative group: $QOUT";;
                           *) rec isolation PASS "ghrunner is unprivileged (groups: $QOUT)";; esac; fi
  fi
  summarize
}

# probe <deployment SHA> [checker commit]
# The deployment SHA is the infrastructure revision that PROVISIONED the host (it goes to INFRA_SHA,
# as before). The checker is recorded separately, in CHECKER: this script's own SHA-256 always, and
# the commit it was staged from when given. A corrected checker can therefore probe an existing
# deployment without pretending to be the revision that built it.
probe() {
  local SHA="${1:-}" CC="${2:-}" D ps body teerc self
  sha_ok "$SHA" || die "argument must be the 40-character infrastructure SHA of the deployment"
  [ -z "$CC" ] || sha_ok "$CC" || die "the optional checker commit must be a 40-character SHA"
  sudo -v || die "sudo refused"
  self=$(sha256_of "$HOSTCHECK_SELF" 2>/dev/null | awk '{print $1}')
  D="$BASE/probe-$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$D" && chmod -R go-rwx "$BASE" && echo "$SHA" > "$D/INFRA_SHA" \
    && printf 'checker_sha256 %s\nchecker_commit %s\nchecker_path %s\n' "${self:-unreadable}" "${CC:-unrecorded}" "$HOSTCHECK_SELF" > "$D/CHECKER" \
    || die "cannot create $D"
  echo "== checker: $HOSTCHECK_SELF sha256 ${self:-unreadable}, commit ${CC:-unrecorded}; deployment (INFRA_SHA) $SHA"
  # The log is a pipeline, so the shell waits for tee and both statuses are checked.
  probe_body "$D" "$SHA" 2>&1 | tee "$D/probe.txt"
  ps=("${PIPESTATUS[@]}"); body=${ps[0]}; teerc=${ps[1]:-1}
  if [ "$teerc" -ne 0 ]; then
    echo "RESULT: LOG FAILURE — $D/probe.txt could not be written completely (tee exit $teerc); this run is not evidence"
    return 3
  fi
  if ! grep -E '^RESULT: ' "$D/probe.txt" >/dev/null 2>&1; then
    echo "RESULT: LOG FAILURE — $D/probe.txt has no RESULT line (checks exit $body); this run is not evidence"
    return 3
  fi
  return "$body"
}

hostcheck_main() {
  case "${1:-}" in
    snapshot) shift; snapshot "$@"; exit $? ;;
    verify)   shift; verify_cmd "$@"; exit $? ;;
    compare)  shift; compare "$@"; exit $? ;;
    probe)    shift; probe "$@"; exit $? ;;
    *) die "usage: hostcheck.sh snapshot <phase> <sha> | verify <phase> <sha> [max-min] | compare <sha> | probe <deployment-sha> [checker-commit]" ;;
  esac
}
if [ "${HOSTCHECK_LIB:-0}" != 1 ]; then hostcheck_main "$@"; fi
