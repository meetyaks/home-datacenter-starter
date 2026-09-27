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
declare -A COMMIT MIG
MIG[v1]="0001_base.sql 0002_seed.sql"
MIG[v2]="0001_base.sql 0002_seed.sql 0003_nickname.sql"
MIG[v3bad]="0001_base.sql 0002_seed.sql 0003_nickname.sql 0004_bad.sql"
MIG[v4]="0001_base.sql 0002_seed.sql 0003_nickname.sql 0004_notes.sql"
MIG[v5bad]="${MIG[v4]}"
for v in v1 v2 v3bad v4 v5bad; do
  { sed "s#/srv/data/services/truewealth#$W/root#g" /app/compose.dc1.yml; printf '# stand-in fixture release %s\n' "$v"; } \
    > "$W/repo/infra/dc1/compose.dc1.yml"
  git -C "$W/repo" add -A && git -C "$W/repo" commit -qm "fixture $v"
  COMMIT[$v]="$(git -C "$W/repo" rev-parse HEAD)"
done

# ── Stand-in images and transfer bundles (images already present under their
#    recorded identity, so images.yml loads nothing; the archives are
#    placeholders the controller still hashes) ────────────────────────────────
PLATFORM=""
for v in v1 v2 v3bad v4 v5bad; do
  c="${COMMIT[$v]}"; d="$W/bundles/$v"; mkdir -p "$d"; imgs=""
  for role in web worker compute migrator; do
    docker build -q --label "$LABEL" --build-arg ROLE="$role" --build-arg VERSION="$v" --build-arg COMMIT="$c" \
      --build-arg MIGRATIONS="${MIG[$v]}" -t "twtest-standin/$role:$v" /repo/tests/fixtures/tw-standin > /dev/null \
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

printf -- '── deploy harness: %d passed, %d failed ──\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
