#!/usr/bin/env bash
# Runs INSIDE the deploy harness container (tests/tools/deploy-harness.Dockerfile),
# started by tests/run-truewealth-role.sh section 6 with:
#   - the Docker socket (it drives the local engine),
#   - --network host (the engine's network namespace: published loopback
#     ports, `ss`, the ingress on :443),
#   - a work volume mounted at the SAME path the engine sees ($1), so the
#     compose file's bind paths resolve for the daemon,
#   - the repository at /repo (read-only) and the TrueWealth dc1 compose file
#     at /app/compose.dc1.yml.
#
# Scenarios, each with the REAL role (tests/truewealth-deploy.yml):
#   a  first deployment (v1)                → success recorded, no rollback target
#   b  unchanged re-run                     → changed=0, no record rewritten
#   c  v2 with a pending migration          → recovery point, worker stopped then
#                                             restarted, success, rollback = v1
#   d  unchanged re-run                     → changed=0, rollback still v1
#   e  same release, rotated secret          → recreated and re-verified; rollback
#                                             still v1 (never replaced by itself)
#   f  v3: a failing migration              → attempt failed@migrate, success record
#                                             untouched, recovery point kept, worker
#                                             NOT restarted, nothing rolled back
#   g  v4 with the ingress down             → migrate+start ok, verify fails:
#                                             attempt failed@verify, success untouched
#   h  v4 again with the ingress back       → success; rollback = v2 (last distinct)
#   i  a stray container in the project     → reported, NOT removed
#   j  v5: web crashes printing secrets     → failed@start with bounded diagnostics;
#                                             no synthetic secret in any output
#   gate  the rollback-floor gate, TrueWealth docs/rollback-floor-contract.md:
#      k    v4 again (no floor)             → proceeds (direct comparison)
#      A3   v6 (batch 7) on legacy rows     → refused 'unverified', told the adoption
#                                             command; operator adopts; re-run deploys
#      A5   v6 again, then v7, v7 again     → changed=0 / normal deploy / changed=0
#      A6   v8 with 0117 pending            → recovery point, worker stop, migrate, up
#      A4   v8 with 0117's text edited      → refused 'mismatch'
#      A1   v9 (newest 0115) vs floor 0116  → refused 'below_floor'
#      A2   floor raised to 0125, batch-5   → refused by direct comparison
#      C4   rollback to v7 under 0125       → refused; v4 under 0116 → refused;
#           rollback to v7 under 0116       → proceeds (0117 is unknown to it, allowed)
#      every refusal: C3 checked before/after (containers, images, worker,
#      schema, floor, recovery points, records)
set -uo pipefail
W="$1"
pass=0; fail=0
ok()  { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }
export ANSIBLE_CONFIG=/repo/ansible.cfg ANSIBLE_ROLES_PATH=/repo/roles ANSIBLE_NOCOLOR=1 ANSIBLE_RETRY_FILES_ENABLED=0
PROJECT=twtest-deploy
PORT=3197
HOST=tw.dc1.test
LABEL=twtask=tw-deploy-test

mkdir -p "$W/repo/infra/dc1" "$W/root" "$W/sbin" "$W/bundles" "$W/caddy" "$W/logs"
git config --global user.email test@example.test; git config --global user.name test
git config --global --add safe.directory '*'
git -C "$W/repo" init -q

# ── Fixture releases: one commit each, the dc1 compose file with its data
#    paths moved into the work volume (nothing else changed) ─────────────────
declare -A COMMIT MIG KIND FLOORC MUTATE
MIG[v1]="0001_base.sql 0002_seed.sql"
MIG[v2]="0001_base.sql 0002_seed.sql 0003_nickname.sql"
MIG[v3bad]="0001_base.sql 0002_seed.sql 0003_nickname.sql 0004_bad.sql"
MIG[v4]="0001_base.sql 0002_seed.sql 0003_nickname.sql 0004_notes.sql"
MIG[v5bad]="${MIG[v4]}"
# The rollback-floor gate (section "gate"): batch-7 style migrators
# (checksums, floor, `verdict:`) whose floor constant is the stand-in
# 0116_platform_admins.sql, and one batch-5 style build that knows no floor.
FLOOR=0116_platform_admins.sql
MIG[v6]="${MIG[v4]} 0115_sessions.sql 0116_platform_admins.sql"; KIND[v6]=verdict
MIG[v7]="${MIG[v6]}";                                            KIND[v7]=verdict
MIG[v8]="${MIG[v6]} 0117_pinned.sql";                            KIND[v8]=verdict
MIG[v8mm]="${MIG[v8]}";        KIND[v8mm]=verdict; MUTATE[v8mm]=0117_pinned.sql
MIG[v9low]="${MIG[v4]} 0115_sessions.sql";                       KIND[v9low]=verdict
MIG[v10b5]="${MIG[v8]}";                                         KIND[v10b5]=plain
VERSIONS="v1 v2 v3bad v4 v5bad v6 v7 v8 v8mm v9low v10b5"
for v in $VERSIONS; do
  [ "${KIND[$v]:-plain}" = verdict ] && FLOORC[$v]="$FLOOR"
  # v9low also defines postgres differently (a label): a `compose run` that
  # brought up dependencies would RECREATE postgres before the gate decided.
  { sed "s#/srv/data/services/truewealth#$W/root#g" /app/compose.dc1.yml \
      | if [ "$v" = v9low ]; then awk '{ print } /^  postgres:$/ { print "    labels: { io.truewealth.test.variant: v9low }" }'; else cat; fi
    printf '# stand-in fixture release %s\n' "$v"; } \
    > "$W/repo/infra/dc1/compose.dc1.yml"
  git -C "$W/repo" add -A && git -C "$W/repo" commit -qm "fixture $v"
  COMMIT[$v]="$(git -C "$W/repo" rev-parse HEAD)"
done

# ── Stand-in images and transfer bundles (images already present under their
#    recorded identity, so images.yml loads nothing; the archives are
#    placeholders the controller still hashes) ────────────────────────────────
PLATFORM=""
for v in $VERSIONS; do
  c="${COMMIT[$v]}"; d="$W/bundles/$v"; mkdir -p "$d"; imgs=""
  for role in web worker compute migrator; do
    docker build -q --label "$LABEL" --build-arg ROLE="$role" --build-arg VERSION="$v" --build-arg COMMIT="$c" \
      --build-arg MIGRATIONS="${MIG[$v]}" --build-arg MIGRATOR="${KIND[$v]:-plain}" --build-arg FLOOR="${FLOORC[$v]:-}" \
      --build-arg MUTATE="${MUTATE[$v]:-}" -t "twtest-standin/$role:$v" /repo/tests/fixtures/tw-standin > /dev/null \
      || { echo "stand-in build failed ($role $v)"; exit 2; }
    id="$(docker image inspect --format '{{.Id}}' "twtest-standin/$role:$v")"
    [ -n "$PLATFORM" ] || PLATFORM="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "twtest-standin/$role:$v")"
    tag="truewealth/$role:${c:0:12}-${id:7:12}"
    docker tag "twtest-standin/$role:$v" "$tag"
    printf 'stand-in placeholder %s %s\n' "$role" "$v" > "$d/$role.tar"
    sha="$(sha256sum "$d/$role.tar" | cut -d' ' -f1)"
    imgs="$imgs{\"role\":\"$role\",\"title\":\"truewealth-$role\",\"archive\":\"$role.tar\",\"archiveSha256\":\"sha256:$sha\",\"configDigest\":\"$id\",\"manifestDigest\":\"$id\",\"acceptLoadedIds\":[\"$id\"],\"localTag\":\"$tag\"},"
  done
  printf '{"synthetic":"stand-in evidence %s"}\n' "$v" > "$d/evidence.json"
  esha="$(sha256sum "$d/evidence.json" | cut -d' ' -f1)"
  printf '{"schema":"truewealth-transfer/2","commit":"%s","source":"https://github.com/meetyaks/truewealth","evidenceClass":"test-standin","platform":"%s","run":{"id":4242,"attempt":1,"workflowPath":"n/a","workflowSha":"n/a","headSha":"%s","headBranch":"n/a","event":"n/a","conclusion":"n/a","verifiedWith":"none (stand-in fixture)"},"artifact":null,"evidenceFile":"evidence.json","evidenceSha256":"sha256:%s","images":[%s]}\n' \
    "$c" "$PLATFORM" "$c" "$esha" "${imgs%,}" > "$d/transfer.json"
done

# ── A real TLS ingress with an internal CA, trusted by this "host" ───────────
cat > "$W/caddy/Caddyfile" <<EOF
{
	local_certs
	skip_install_trust
	auto_https disable_redirects
	admin off
}
$HOST {
	tls internal
	reverse_proxy 127.0.0.1:$PORT
}
EOF
start_ingress() {
  docker run -d --name twtest-ingress --label "$LABEL" --network host -v "$W/caddy:/etc/caddy:ro" \
    -v "$W/caddy-data:/data" "${CADDY_IMAGE:?}" caddy run --config /etc/caddy/Caddyfile --adapter caddyfile > /dev/null
}
start_ingress
for _ in $(seq 1 30); do docker exec twtest-ingress test -f /data/caddy/pki/authorities/local/root.crt 2>/dev/null && break; sleep 1; done
docker exec twtest-ingress cat /data/caddy/pki/authorities/local/root.crt > /usr/local/share/ca-certificates/twtest-ingress.crt
update-ca-certificates > /dev/null 2>&1

cat > "$W/vars.yml" <<EOF
truewealth_project: $PROJECT
truewealth_root: $W/root
truewealth_source_repo: $W/repo
truewealth_sbin_dir: $W/sbin
truewealth_run_id: "4242"
truewealth_run_attempt: "1"
truewealth_accept_evidence_classes: [test-standin]
truewealth_platform: $PLATFORM
truewealth_expected_architecture: "{{ ansible_architecture }}"
truewealth_data_mount: $W
truewealth_manage_ingress: false
truewealth_hostname: $HOST
truewealth_web_loopback_port: $PORT
truewealth_backup_enabled: false
truewealth_wait_timeout_seconds: 75
truewealth_health_retries: 4
truewealth_health_delay_seconds: 3
truewealth_vault_db_password: synthetic-db-password-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')
truewealth_vault_key_secret: synthetic-key-secret-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
truewealth_vault_compute_token: synthetic-compute-token-$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')
truewealth_vault_redis_password: syntheticRedis$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
EOF

deploy() { # name version [extra ansible args…]
  local n="$1" v="$2"; shift 2
  ansible-playbook /repo/tests/truewealth-deploy.yml -e @"$W/vars.yml" -e truewealth_commit="${COMMIT[$v]}" \
    -e truewealth_transfer_dir="$W/bundles/$v" "$@" > "$W/logs/$n.log" 2>&1 </dev/null
}
recap_changed() { grep -E '^localhost +:' "$W/logs/$1.log" | sed -E 's/.*changed=([0-9]+).*/\1/'; }
jf() { jq -r "$2" "$W/root/$1" 2>/dev/null; }
sha() { sha256sum "$W/root/$1" 2>/dev/null | cut -d' ' -f1; }
running() { docker inspect --format '{{.State.Running}}' "$PROJECT-$1-1" 2>/dev/null; }
revision() { docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$PROJECT-$1-1" 2>/dev/null; }

echo "── 0. check mode on a fresh host ──"
deploy check v1 --check --diff; rc=$?
[ $rc -eq 0 ] && [ -z "$(docker ps -aq --filter "label=com.docker.compose.project=$PROJECT")" ] \
  && [ ! -e "$W/root/DEPLOYMENT_MANIFEST.json" ] && [ ! -e "$W/root/DEPLOYMENT_ATTEMPT.json" ] \
  && grep -q 'CHECK MODE: controller-side verification' "$W/logs/check.log" \
  && ok "--check --diff passes on a fresh host, starts nothing and writes no record" || bad "check mode" "rc=$rc $(grep -E 'fatal|FAILED' "$W/logs/check.log" | head -3)"
leak=""; for k in truewealth_vault_db_password truewealth_vault_key_secret truewealth_vault_redis_password; do
  v="$(sed -n "s/^$k: //p" "$W/vars.yml")"; grep -qF -- "$v" "$W/logs/check.log" && leak="$leak $k"; done
[ -z "$leak" ] && ok "--diff shows no secret value (secret files are diff: false)" || bad "diff leaks" "$leak"

echo "── a. first deployment ──"
deploy a v1; rc=$?
[ $rc -eq 0 ] && ok "v1 deploys (migrate 2, up --wait, identity, readyz, loopback, DNS, trusted HTTPS, revision)" \
  || bad "v1 deploys" "$(grep -E 'FAILED|fatal|msg' "$W/logs/a.log" | head -6)"
[ "$(jf DEPLOYMENT_MANIFEST.json .commit)" = "${COMMIT[v1]}" ] && [ "$(jf DEPLOYMENT_MANIFEST.json .schema)" = truewealth-deploy/2 ] \
  && ok "the success record is v1" || bad "success record v1" "$(jf DEPLOYMENT_MANIFEST.json .commit)"
[ ! -e "$W/root/ROLLBACK_PREVIOUS.json" ] && ok "no rollback target yet (nothing succeeded before)" || bad "no rollback target" "exists"
[ "$(jf DEPLOYMENT_ATTEMPT.json .status)" = succeeded ] && [ "$(jf DEPLOYMENT_ATTEMPT.json .preMigrationRecoveryPoint)" = null ] \
  && ok "attempt closed as succeeded; no recovery point on a first deployment (no data to protect)" || bad "attempt a" "$(jf DEPLOYMENT_ATTEMPT.json '.status,.preMigrationRecoveryPoint')"

echo "── b. unchanged re-run ──"
m_sha="$(sha DEPLOYMENT_MANIFEST.json)"; a_sha="$(sha DEPLOYMENT_ATTEMPT.json)"
deploy b v1; rc=$?
[ $rc -eq 0 ] && [ "$(recap_changed b)" = 0 ] && ok "an unchanged re-run reports changed=0" || bad "unchanged re-run" "rc=$rc changed=$(recap_changed b) $(grep -E 'changed:' "$W/logs/b.log" | head -5)"
[ "$(sha DEPLOYMENT_MANIFEST.json)" = "$m_sha" ] && [ "$(sha DEPLOYMENT_ATTEMPT.json)" = "$a_sha" ] \
  && ok "no record was rewritten (manifest and attempt byte-identical)" || bad "records untouched" "rewritten"
grep -q 'UNCHANGED (converge and verify only' "$W/logs/b.log" && grep -q 'Deployed identity' "$W/logs/b.log" \
  && ok "it still verified (readyz, HTTPS, identity)" || bad "unchanged run verifies" "verify did not run"

echo "── c. a release with a pending migration ──"
deploy c v2; rc=$?
rp="$(jf DEPLOYMENT_ATTEMPT.json .preMigrationRecoveryPoint)"
[ $rc -eq 0 ] && [ "$(jf DEPLOYMENT_MANIFEST.json .commit)" = "${COMMIT[v2]}" ] && ok "v2 deploys; success record v2" \
  || bad "v2 deploys" "$(grep -E 'FAILED|fatal|msg' "$W/logs/c.log" | head -6)"
[ "$(jf ROLLBACK_PREVIOUS.json .commit)" = "${COMMIT[v1]}" ] && ok "rollback target = the previous verified deployment (v1)" || bad "rollback v1" "$(jf ROLLBACK_PREVIOUS.json .commit)"
case "$rp" in "$W/root/backups/pre-migration/"*) [ -f "$rp/db.dump" ] && [ -f "$rp/manifest.json" ] \
  && [ "$(jq -r .reason "$rp/manifest.json")" = pre-migration ] && [ "$(jq -r .snapshot.appliedMigrations "$rp/manifest.json")" = 2 ] \
  && ok "a pre-migration recovery point was taken first (2 migrations, the state before v2's)" || bad "recovery point content" "$rp" ;;
  *) bad "recovery point recorded" "$rp" ;; esac
grep -q 'Stop the worker before the schema changes' "$W/logs/c.log" && [ "$(jf DEPLOYMENT_ATTEMPT.json .workerStoppedForMigration)" = true ] \
  && [ "$(running worker)" = true ] && [ "$(revision worker)" = "${COMMIT[v2]}" ] \
  && ok "the worker was stopped before migrating and runs v2 after verification" || bad "worker handling" "$(running worker) $(revision worker)"
n_rp=$(ls -1d "$W/root/backups/pre-migration/"*Z 2>/dev/null | wc -l)

echo "── d. unchanged re-run ──"
r_sha="$(sha ROLLBACK_PREVIOUS.json)"; m_sha="$(sha DEPLOYMENT_MANIFEST.json)"
deploy d v2; rc=$?
[ $rc -eq 0 ] && [ "$(recap_changed d)" = 0 ] && [ "$(sha ROLLBACK_PREVIOUS.json)" = "$r_sha" ] && [ "$(sha DEPLOYMENT_MANIFEST.json)" = "$m_sha" ] \
  && ok "unchanged re-run of v2: changed=0; rollback target and success record untouched" || bad "unchanged v2" "rc=$rc changed=$(recap_changed d)"
[ "$(ls -1d "$W/root/backups/pre-migration/"*Z 2>/dev/null | wc -l)" = "$n_rp" ] && ok "no recovery point when nothing is pending" || bad "no extra recovery point" "one was taken"

echo "── e. same release, rotated secret ──"
deploy e v2 -e truewealth_vault_compute_token=synthetic-rotated-token-000000000000; rc=$?
[ $rc -eq 0 ] && [ "$(jf DEPLOYMENT_MANIFEST.json .commit)" = "${COMMIT[v2]}" ] && [ "$(sha DEPLOYMENT_MANIFEST.json)" != "$m_sha" ] \
  && ok "a changed input redeploys and re-verifies (new success record)" || bad "rotated secret redeploys" "rc=$rc"
[ "$(jf ROLLBACK_PREVIOUS.json .commit)" = "${COMMIT[v1]}" ] && ok "the rollback target is still v1 — never replaced by the same release" || bad "rollback kept" "$(jf ROLLBACK_PREVIOUS.json .commit)"
sed -i 's/^truewealth_vault_compute_token: .*/truewealth_vault_compute_token: synthetic-rotated-token-000000000000/' "$W/vars.yml"

echo "── f. a failing migration ──"
m_sha="$(sha DEPLOYMENT_MANIFEST.json)"; r_sha="$(sha ROLLBACK_PREVIOUS.json)"
deploy f v3bad; rc=$?
[ $rc -ne 0 ] && [ "$(jf DEPLOYMENT_ATTEMPT.json .status)" = failed ] && [ "$(jf DEPLOYMENT_ATTEMPT.json .failedStage)" = migrate ] \
  && ok "the deployment fails at 'migrate'; the attempt records it" || bad "migration failure recorded" "rc=$rc $(jf DEPLOYMENT_ATTEMPT.json '.status,.failedStage')"
[ "$(sha DEPLOYMENT_MANIFEST.json)" = "$m_sha" ] && [ "$(sha ROLLBACK_PREVIOUS.json)" = "$r_sha" ] \
  && ok "success record and rollback target untouched (last verified is still v2)" || bad "records untouched on failure" "changed"
grep -qE 'Migrations FAILED \(exit 1\): migrate: FAILED — relation .?.core.no_such_table.?. does not exist' "$W/logs/f.log" \
  && grep -q "Still pending: \['0004_bad.sql'\]" "$W/logs/f.log" && grep -q 'The schema was NOT rolled back' "$W/logs/f.log" \
  && ok "bounded report: the failure line, what is still pending, and that nothing was rolled back" || bad "migration failure report" "$(grep -E 'FAILED|pending' "$W/logs/f.log" | head -4)"
rpf="$(jf DEPLOYMENT_ATTEMPT.json .preMigrationRecoveryPoint)"
[ -f "$rpf/db.dump" ] && grep -q "Pre-migration recovery point: $rpf" "$W/logs/f.log" && ok "the recovery point exists and the operator is told where" || bad "recovery point on failure" "$rpf"
[ "$(running worker)" = false ] && [ "$(revision web)" = "${COMMIT[v2]}" ] && [ "$(running web)" = true ] \
  && grep -q 'has NOT been restarted' "$W/logs/f.log" \
  && ok "the worker stays stopped (said so); web still serves v2" || bad "state after migration failure" "worker=$(running worker) web=$(revision web)"
docker exec "$PROJECT-postgres-1" psql -U truewealth -d truewealth -AtX -c "SELECT count(*) FROM public._tw_migrations" | grep -qx 3 \
  && ok "the database keeps v2's schema (3 migrations); nothing was restored or reverted" || bad "schema after failure" "unexpected"

echo "── g. start succeeds, post-start verification fails (ingress down) ──"
docker stop twtest-ingress > /dev/null
deploy g v4; rc=$?
[ $rc -ne 0 ] && [ "$(jf DEPLOYMENT_ATTEMPT.json .failedStage)" = verify ] \
  && ok "migrate and start pass; trusted-HTTPS verification fails; attempt failed@verify" || bad "verify failure" "rc=$rc stage=$(jf DEPLOYMENT_ATTEMPT.json .failedStage) $(grep -E 'fatal' "$W/logs/g.log" | head -2)"
[ "$(sha DEPLOYMENT_MANIFEST.json)" = "$m_sha" ] && [ "$(sha ROLLBACK_PREVIOUS.json)" = "$r_sha" ] \
  && ok "an unverified deployment is not recorded as a success (record still v2, rollback still v1)" || bad "no success without verification" "records changed"
grep -q "last VERIFIED deployment is still ${COMMIT[v2]}" "$W/logs/g.log" && grep -q 'CODE rollback' "$W/logs/g.log" \
  && ok "the failure names the last verified release and separates code rollback from a database restore" || bad "failure guidance" "missing"

echo "── h. the same release once the ingress is back ──"
docker start twtest-ingress > /dev/null; sleep 2
deploy h v4; rc=$?
[ $rc -eq 0 ] && [ "$(jf DEPLOYMENT_MANIFEST.json .commit)" = "${COMMIT[v4]}" ] && [ "$(jf DEPLOYMENT_ATTEMPT.json .status)" = succeeded ] \
  && ok "v4 verifies and is recorded" || bad "v4 recorded" "rc=$rc $(grep -E 'fatal|msg' "$W/logs/h.log" | head -3)"
[ "$(jf ROLLBACK_PREVIOUS.json .commit)" = "${COMMIT[v2]}" ] && ok "rollback target = v2, the last DISTINCT verified release (not the failed attempts)" || bad "rollback v2" "$(jf ROLLBACK_PREVIOUS.json .commit)"

echo "── i. a container the compose file does not define ──"
docker run -d --name "$PROJECT-stray" --label "$LABEL" --label "com.docker.compose.project=$PROJECT" --label com.docker.compose.service=stray \
  --label com.docker.compose.oneoff=False "twtest-standin/web:v4" python3 -c 'import time; time.sleep(3600)' > /dev/null
deploy i v4; rc=$?
[ $rc -eq 0 ] && grep -q "are not part of this deployment" "$W/logs/i.log" && grep -q "$PROJECT-stray" "$W/logs/i.log" \
  && [ "$(docker inspect --format '{{.State.Running}}' "$PROJECT-stray")" = true ] \
  && ok "the stray container is reported and NOT removed" || bad "stray container" "rc=$rc"
docker rm -f "$PROJECT-stray" > /dev/null

echo "── j. web crashes printing secret-shaped output ──"
deploy j v5bad; rc=$?
[ $rc -ne 0 ] && [ "$(jf DEPLOYMENT_ATTEMPT.json .failedStage)" = start ] && grep -q 'did not become healthy' "$W/logs/j.log" \
  && ok "failure at 'start' with bounded diagnostics" || bad "start failure" "rc=$rc stage=$(jf DEPLOYMENT_ATTEMPT.json .failedStage)"
grep -qE 'web +(restarting|exited|running)' "$W/logs/j.log" && grep -q 'health-check exit codes' "$W/logs/j.log" && grep -q 'error-like' "$W/logs/j.log" \
  && ok "diagnostics show states, health and log counts" || bad "diagnostic content" "$(grep -A12 'SERVICE' "$W/logs/j.log" | head -12)"
leak=""
for s in SYNTHETIC-DB-PASSWORD-6f1c SYNTHETICBEARERTOKEN0123456789abcdef SYNTHETIC-KEY-SECRET-9a8b7c6d5e4f synthetic-victim@example.test 1234567.89; do
  grep -qF -- "$s" "$W/logs/j.log" && leak="$leak $s"
done
[ -z "$leak" ] && ok "no synthetic secret, e-mail or amount from the crashing container reaches the output" || bad "diagnostics leak" "$leak"
excerpt="$("$W/sbin/truewealth-diagnose" --log-excerpt 2>&1)"
leak=""
for s in SYNTHETIC-DB-PASSWORD-6f1c SYNTHETICBEARERTOKEN0123456789abcdef SYNTHETIC-KEY-SECRET-9a8b7c6d5e4f synthetic-victim@example.test 1234567.89; do
  printf '%s' "$excerpt" | grep -qF -- "$s" && leak="$leak $s"
done
printf '%s' "$excerpt" | grep -q 'fatal: cannot start' && [ -z "$leak" ] \
  && ok "the opt-in excerpt is redacted (useful text kept, secrets/e-mail/amounts replaced)" || bad "excerpt redaction" "leaked:$leak"
[ "$(jf DEPLOYMENT_MANIFEST.json .commit)" = "${COMMIT[v4]}" ] && ok "the success record still names v4" || bad "record after start failure" "changed"

# ── The rollback-floor gate: TrueWealth docs/rollback-floor-contract.md,
#    acceptance tests A1-A6 and C1-C4, with the REAL role, a real
#    PostgreSQL and stand-in migrators. Each refusal compares everything C3
#    names, before and after: container and image identities, the worker,
#    the schema and the floor, recovery points, and the success and rollback
#    records byte for byte. ─────────────────────────────────────────────────
echo "── gate. the rollback-floor gate (A1-A6, C1-C4) ──"
# The operator's adoption uses the STAGED target files the refusal names.
CSTAGED="docker compose --project-name $PROJECT --env-file $W/root/staging/truewealth.env -f $W/root/staging/compose.dc1.yml"
pg() { docker exec "$PROJECT-postgres-1" psql -U truewealth -d truewealth -AtX -c "$1" 2>/dev/null; }
cid() { docker inspect --format '{{.Id}} {{.Image}} {{.State.StartedAt}}' "$PROJECT-$1-1" 2>/dev/null; }
n_rps() { ls -1d "$W/root/backups/pre-migration/"*Z 2>/dev/null | wc -l; }
snap() { # everything C3 says a refusal leaves as it is
  for s in web worker compute postgres redis; do printf '%s: %s\n' "$s" "$(cid "$s")"; done
  printf 'worker running: %s\n' "$(running worker)"
  printf 'manifest: %s rollback: %s\n' "$(sha DEPLOYMENT_MANIFEST.json)" "$(sha ROLLBACK_PREVIOUS.json)"
  # The LIVE configuration: a refused target must never become it.
  printf 'live env: %s live compose: %s\n' "$(sha env/truewealth.env)" "$(sha compose.dc1.yml)"
  printf 'recovery points: %s\n' "$(n_rps)"
  printf 'schema: %s\n' "$(pg "SELECT string_agg(t::text, ',' ORDER BY t.name) FROM public._tw_migrations t" | sha256sum | cut -c1-16)"
  printf 'floor: %s\n' "$(pg "SELECT value FROM public._tw_schema_meta WHERE key = 'rollback_floor'")"
}
mutated() { grep -E '^TASK \[.*(Take the pre-migration recovery point|Stop the worker before|Apply migrations|Start the stack and wait)' "$W/logs/$1.log"; }
refused() { # name reason rc before — a refusal at the gate, and C3
  local n="$1" why="$2" rc="$3" before="$4" after
  after="$(snap)"
  [ "$rc" -ne 0 ] && grep -q 'REFUSED by the rollback-floor gate' "$W/logs/$n.log" \
    && [ "$(jf DEPLOYMENT_ATTEMPT.json .status)" = failed ] && [ "$(jf DEPLOYMENT_ATTEMPT.json .failedStage)" = gate ] \
    && [ "$(jf DEPLOYMENT_ATTEMPT.json .gate.reason)" = "$why" ] && [ "$(jf DEPLOYMENT_ATTEMPT.json .gate.decision)" = refused ] \
    && ok "$n: refused at the gate with '$why'; attempt failed@gate records the decision" \
    || bad "$n: refused with $why" "rc=$rc attempt=$(jf DEPLOYMENT_ATTEMPT.json '[.status,.failedStage,.gate.reason]|join(" ")') $(grep -E 'fatal|REFUSED' "$W/logs/$n.log" | head -3)"
  [ "$after" = "$before" ] && [ -z "$(mutated "$n")" ] \
    && ok "$n: C3 holds — same containers and images, worker running, no migrate, no recovery point, schema/floor/records unchanged" \
    || bad "$n: C3" "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | head -8) $(mutated "$n" | head -3)"
  local live_before live_after
  live_before="$(printf '%s\n' "$before" | grep '^live env: ')"; live_after="$(printf '%s\n' "$after" | grep '^live env: ')"
  [ -n "$live_before" ] && [ "$live_after" = "$live_before" ] && ! printf '%s' "$live_after" | grep -q 'env:  ' \
    && grep -q "^TW_MIGRATE_IMAGE=" "$W/root/staging/truewealth.env" && [ "$(sha staging/truewealth.env)" != "$(sha env/truewealth.env)" ] \
    && ok "$n: the LIVE env and compose files are byte-identical to before; the refused target exists only in staging/" \
    || bad "$n: live configuration untouched" "before: $live_before / after: $live_after"
}

echo "   k. baseline: v4 again (batch-5 style, no floor in the database)"
deploy k v4; rc=$?
[ $rc -eq 0 ] && [ "$(jf DEPLOYMENT_MANIFEST.json .gate.decision)" = proceed ] && [ "$(jf DEPLOYMENT_MANIFEST.json .gate.verdict)" = null ] \
  && [ "$(jf DEPLOYMENT_MANIFEST.json .gate.floor)" = null ] && [ "$(jf DEPLOYMENT_MANIFEST.json .gate.head)" = 0004_notes.sql ] \
  && ok "k: a pre-verdict build with no floor proceeds by direct comparison; the manifest records the gate" \
  || bad "k: baseline" "rc=$rc $(jf DEPLOYMENT_MANIFEST.json .gate) $(grep -E 'fatal|REFUSED' "$W/logs/k.log" | head -3)"

echo "   A3. legacy rows (no checksums), a batch-7 build"
before="$(snap)"; deploy a3 v6; rc=$?
refused a3 unverified $rc "$before"
grep -qF -- "$CSTAGED --profile ops run --rm -T --no-deps migrate node dist/ops/migrate.mjs --adopt-legacy-checksums" "$W/logs/a3.log" \
  && [ "$(running worker)" = true ] \
  && [ "$(pg "SELECT count(*) FROM information_schema.columns WHERE table_name = '_tw_migrations' AND column_name = 'checksum'")" = 0 ] \
  && ok "A3: the operator is told the adoption command, with the STAGED target files spelled out; the worker still runs; nothing was adopted (C2)" \
  || bad "A3: adoption instruction" "$(grep -o 'adopt[^"]*' "$W/logs/a3.log" | head -2) worker=$(running worker)"
# The OPERATOR's step (docs/operations.md, Migrations), exactly as the refusal
# gave it: the target build through the staged files, not the live ones.
$CSTAGED --profile ops run --rm -T --no-deps migrate node dist/ops/migrate.mjs --adopt-legacy-checksums > "$W/logs/a3-adopt.log" 2>&1; arc=$?
[ $arc -eq 0 ] && grep -q 'checksums adopted for 4 migration' "$W/logs/a3-adopt.log" \
  && ok "A3: the operator adopts the legacy checksums (outside the role)" || bad "A3: adoption" "rc=$arc $(tail -3 "$W/logs/a3-adopt.log")"
deploy a3b v6; rc=$?
[ $rc -eq 0 ] && [ "$(jf DEPLOYMENT_MANIFEST.json .commit)" = "${COMMIT[v6]}" ] && [ "$(jf DEPLOYMENT_MANIFEST.json .gate.verdict)" = ready ] \
  && [ "$(pg "SELECT value FROM public._tw_schema_meta WHERE key = 'rollback_floor'")" = "$FLOOR" ] \
  && ok "A3: after the adoption the re-run proceeds (verdict ready) and deploys v6; the floor is $FLOOR" \
  || bad "A3: re-run" "rc=$rc $(grep -E 'fatal|REFUSED' "$W/logs/a3b.log" | head -3)"

echo "   A5. at the floor, nothing pending: the same build, then a newer one"
m_sha="$(sha DEPLOYMENT_MANIFEST.json)"; a_sha="$(sha DEPLOYMENT_ATTEMPT.json)"; r_sha="$(sha ROLLBACK_PREVIOUS.json)"
deploy a5 v6; rc=$?
[ $rc -eq 0 ] && [ "$(recap_changed a5)" = 0 ] && grep -q 'Rollback-floor gate: PROCEED' "$W/logs/a5.log" \
  && [ "$(sha DEPLOYMENT_MANIFEST.json)" = "$m_sha" ] && [ "$(sha DEPLOYMENT_ATTEMPT.json)" = "$a_sha" ] && [ "$(sha ROLLBACK_PREVIOUS.json)" = "$r_sha" ] \
  && ok "A5: the UNCHANGED re-run passes the gate, reports changed=0 and writes nothing" || bad "A5: unchanged" "rc=$rc changed=$(recap_changed a5)"
n_rp="$(n_rps)"
deploy a5b v7; rc=$?
[ $rc -eq 0 ] && [ "$(jf DEPLOYMENT_MANIFEST.json .commit)" = "${COMMIT[v7]}" ] && [ "$(n_rps)" = "$n_rp" ] \
  && [ "$(jf ROLLBACK_PREVIOUS.json .commit)" = "${COMMIT[v6]}" ] && ! grep -qE '^TASK \[.*Apply migrations' "$W/logs/a5b.log" \
  && ok "A5: a newer build at the floor deploys normally (no recovery point, no migrate); rollback target v6" \
  || bad "A5: newer build" "rc=$rc $(grep -E 'fatal|REFUSED' "$W/logs/a5b.log" | head -3)"
m_sha="$(sha DEPLOYMENT_MANIFEST.json)"
deploy a5c v7; rc=$?
[ $rc -eq 0 ] && [ "$(recap_changed a5c)" = 0 ] && [ "$(sha DEPLOYMENT_MANIFEST.json)" = "$m_sha" ] \
  && ok "A5: and its UNCHANGED re-run writes nothing" || bad "A5: unchanged v7" "rc=$rc changed=$(recap_changed a5c)"

echo "   A6. at the floor, a migration pending"
deploy a6 v8; rc=$?
[ $rc -eq 0 ] && [ "$(jf DEPLOYMENT_MANIFEST.json .commit)" = "${COMMIT[v8]}" ] && [ "$(n_rps)" -gt "$n_rp" ] \
  && grep -q 'Stop the worker before the schema changes' "$W/logs/a6.log" && grep -qE '^TASK \[.*Apply migrations' "$W/logs/a6.log" \
  && [ "$(jf DEPLOYMENT_ATTEMPT.json .gate.verdict)" = pending ] && [ "$(jf DEPLOYMENT_MANIFEST.json .gate.verdict)" = pending ] \
  && [ "$(running worker)" = true ] && [ "$(revision worker)" = "${COMMIT[v8]}" ] && [ "$(jf ROLLBACK_PREVIOUS.json .commit)" = "${COMMIT[v7]}" ] \
  && ok "A6: verdict pending → recovery point, worker stop, migrate, up, as before; attempt and manifest record the gate" \
  || bad "A6: pending" "rc=$rc $(grep -E 'fatal|REFUSED' "$W/logs/a6.log" | head -3)"

echo "   A4. an applied migration's text differs"
before="$(snap)"; deploy a4 v8mm; rc=$?
refused a4 mismatch $rc "$before"
grep -q '0117_pinned.sql' "$W/logs/a4.log" && ok "A4: the refusal names the migration that differs" || bad "A4: names it" "missing"

echo "   A1. floor $FLOOR, a batch-7 build whose newest migration is 0115"
pg_before="$(cid postgres)"; before="$(snap)"; deploy a1 v9low; rc=$?
refused a1 below_floor $rc "$before"
grep -q 'io.truewealth.test.variant: v9low' "$W/root/staging/compose.dc1.yml" && [ -n "$pg_before" ] && [ "$(cid postgres)" = "$pg_before" ] \
  && [ -z "$(docker inspect --format '{{index .Config.Labels "io.truewealth.test.variant"}}' "$PROJECT-postgres-1")" ] \
  && ok "A1: the target defines postgres differently, and the gate's --status (--no-deps) did NOT recreate or restart postgres" \
  || bad "A1: postgres untouched" "before=$pg_before after=$(cid postgres)"
[ "$(jf DEPLOYMENT_ATTEMPT.json .gate.verdict)" = below_floor ] && [ "$(jf DEPLOYMENT_ATTEMPT.json .gate.head)" = 0115_sessions.sql ] \
  && ok "A1: verdict below_floor; head 0115_sessions.sql recorded" || bad "A1: record" "$(jf DEPLOYMENT_ATTEMPT.json .gate)"

echo "   A2. floor raised to a synthetic 0125, a batch-5 build (no floor knowledge)"
pg "UPDATE public._tw_schema_meta SET value = '0125_synthetic_future.sql' WHERE key = 'rollback_floor'" > /dev/null
before="$(snap)"; deploy a2 v10b5; rc=$?
refused a2 below_floor $rc "$before"
[ "$(jf DEPLOYMENT_ATTEMPT.json .gate.verdict)" = null ] && [ "$(jf DEPLOYMENT_ATTEMPT.json .gate.exit)" = 0 ] \
  && jf DEPLOYMENT_ATTEMPT.json .gate.path | grep -q '^direct comparison' \
  && ok "A2: the build's own --status said nothing was wrong (exit 0, no verdict); the direct comparison refused it" \
  || bad "A2: direct" "$(jf DEPLOYMENT_ATTEMPT.json .gate)"

echo "   C4. code rollbacks go through the same gate"
before="$(snap)"; deploy c4a v7; rc=$?
refused c4a below_floor $rc "$before"
[ "$(jf DEPLOYMENT_ATTEMPT.json .gate.rollbackTarget)" = true ] && grep -q 'the rollback target in ROLLBACK_PREVIOUS.json' "$W/logs/c4a.log" \
  && ok "C4: a rollback to ROLLBACK_PREVIOUS.json (v7) below the raised floor is refused, and named a rollback" || bad "C4: rollback named" "$(jf DEPLOYMENT_ATTEMPT.json .gate.rollbackTarget)"
pg "UPDATE public._tw_schema_meta SET value = '$FLOOR' WHERE key = 'rollback_floor'" > /dev/null
before="$(snap)"; deploy c4b v4; rc=$?
refused c4b below_floor $rc "$before"
deploy c4c v7; rc=$?
[ $rc -eq 0 ] && [ "$(jf DEPLOYMENT_MANIFEST.json .commit)" = "${COMMIT[v7]}" ] && [ "$(jf DEPLOYMENT_MANIFEST.json .gate.rollbackTarget)" = true ] \
  && [ "$(jf DEPLOYMENT_MANIFEST.json .gate.verdict)" = ready ] && [ "$(revision web)" = "${COMMIT[v7]}" ] \
  && [ "$(jf ROLLBACK_PREVIOUS.json .commit)" = "${COMMIT[v8]}" ] && ! grep -qE '^TASK \[.*Apply migrations' "$W/logs/c4c.log" \
  && ok "C4: a rollback at the floor to a build OLDER than the applied set (v7; 0117 unknown to it) proceeds and deploys" \
  || bad "C4: rollback above the floor" "rc=$rc $(grep -E 'fatal|REFUSED' "$W/logs/c4c.log" | head -3)"

leak=""
for k in truewealth_vault_db_password truewealth_vault_key_secret truewealth_vault_redis_password truewealth_vault_compute_token; do
  v="$(sed -n "s/^$k: //p" "$W/vars.yml")"
  for n in k a3 a3b a5 a5b a5c a6 a4 a1 a2 c4a c4b c4c; do grep -qF -- "$v" "$W/logs/$n.log" && leak="$leak $k@$n"; done
  grep -qF -- "$v" "$W/root/DEPLOYMENT_ATTEMPT.json" "$W/root/DEPLOYMENT_MANIFEST.json" && leak="$leak $k@records"
done
[ -z "$leak" ] && ok "no secret in any gate run's output or in the records" || bad "gate output leaks" "$leak"

printf -- '── deploy harness: %d passed, %d failed ──\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
