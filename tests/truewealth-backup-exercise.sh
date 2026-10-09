#!/usr/bin/env bash
# Backup/restore integrity exercise with the REAL TrueWealth migrator image and
# a real PostgreSQL, all data SYNTHETIC. Runs INSIDE the deploy harness
# container (tests/run-truewealth-role.sh section 4), in two phases around the
# seeding step (which uses the application's own code on the controller):
#
#   up <W>        start postgres from the dc1 compose file (data paths moved
#                 into the work volume; postgres published on 127.0.0.1 for
#                 the seeder) and apply every real migration
#   exercise <W>  render the role's scripts and prove:
#     - a backup taken WHILE synthetic writes run has manifest counts from the
#       dump's own snapshot (restore == manifest; live count moved on)
#     - restore-verify: schema, representative tables, orphans, key
#       fingerprint, every encrypted field decrypts with the app's own code,
#       and a KNOWN synthetic password verifies against its restored hash
#     - encryption to a synthetic age key; the "off-host" copy holds only the
#       ciphertext + manifest + COMPLETE (written last); recovery from that
#       copy with separately held identity and key files
#     - partial or tampered copies, the wrong identity, the wrong/missing
#       TW_KEY_SECRET and loose key-file permissions fail with their own exit
#       codes, and no key, password or identity appears in any output
#     - two backups never overlap (the second waits, then fails cleanly)
#     - a failed backup leaves no partial directory and says where it failed
#     - retention deletes nothing (not approved)
set -uo pipefail
PHASE="$1" W="$2"
pass=0; fail=0
ok()  { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }
export ANSIBLE_CONFIG=/repo/ansible.cfg ANSIBLE_ROLES_PATH=/repo/roles ANSIBLE_NOCOLOR=1
PROJECT=twtest-backup
ROOT="$W/root"
COMPOSE=(docker compose --project-name "$PROJECT" --env-file "$ROOT/env/truewealth.env" -f "$ROOT/compose.dc1.yml" -f "$ROOT/compose.test.yml")

if [ "$PHASE" = up ]; then
  mkdir -p "$ROOT/env" "$ROOT/secrets" "$ROOT/data/postgres" "$ROOT/data/redis" "$W/keys" "$W/offhost" "$W/sbin"
  chown 70:70 "$ROOT/data/postgres"; chmod 0700 "$ROOT/data/postgres"
  sed "s#/srv/data/services/truewealth#$ROOT#g" /app/compose.dc1.yml > "$ROOT/compose.dc1.yml"
  cat > "$ROOT/compose.test.yml" <<'EOF'
# TEST ONLY: publish postgres on the engine's loopback for the seeder. The
# dc1 file keeps postgres on the internal backend network only (nothing can
# be published from it), so the test also attaches it to default.
services:
  postgres:
    networks: [backend, default]
    ports: ['127.0.0.1:${TW_TEST_PG_PORT}:5432']
EOF
  hexr() { head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
  printf '%s\n' "syntheticRedis$(hexr 8)" > "$ROOT/secrets/redis_password"
  cat > "$ROOT/env/truewealth.env" <<EOF
TW_WEB_IMAGE=${MIGRATOR_IMAGE}
TW_WORKER_IMAGE=${MIGRATOR_IMAGE}
TW_COMPUTE_IMAGE=${MIGRATOR_IMAGE}
TW_MIGRATE_IMAGE=${MIGRATOR_IMAGE}
TW_WEB_PORT=3198
TW_DB_PASSWORD=synthetic-db-$(hexr 8)
TW_KEY_SECRET=synthetic-key-secret-$(hexr 12)
TW_SECRET_KEY=synthetic-llm-secret-$(hexr 12)
TW_COMPUTE_CALLER_TOKEN=synthetic-compute-$(hexr 8)
TW_REDIS_PASSWORD_FILE=$ROOT/secrets/redis_password
TW_TEST_PG_PORT=${PG_PORT}
EOF
  chmod 0600 "$ROOT/env/truewealth.env"
  "${COMPOSE[@]}" up -d --wait postgres > "$W/up.log" 2>&1 || { tail -20 "$W/up.log"; exit 1; }
  "${COMPOSE[@]}" --profile ops run --rm -T migrate > "$W/migrate.log" 2>&1 || { tail -5 "$W/migrate.log"; exit 1; }
  grep -E '^migrations applied' "$W/migrate.log"
  exit 0
fi

# ── exercise ────────────────────────────────────────────────────────────────
envv() { sed -n "s/^$1=//p" "$ROOT/env/truewealth.env"; }
KEY="$(envv TW_KEY_SECRET)"; LLM="$(envv TW_SECRET_KEY)"; DBPW="$(envv TW_DB_PASSWORD)"
DEMO_PW='DemoPass2026!'
age-keygen -o "$W/keys/age-identity" 2> "$W/keys/age.pub.txt"; chmod 0600 "$W/keys/age-identity"
PUB="$(sed -n 's/^Public key: //p' "$W/keys/age.pub.txt")"
AGE_SECRET="$(grep '^AGE-SECRET-KEY-' "$W/keys/age-identity")"
age-keygen -o "$W/keys/other-identity" 2>/dev/null; chmod 0600 "$W/keys/other-identity"
printf 'synthetic-offhost-ssh-key\n' > "$W/keys/offhost_ssh_key"; chmod 0600 "$W/keys/offhost_ssh_key"
printf 'TW_KEY_SECRET=%s\nTW_SECRET_KEY=%s\n' "$KEY" "$LLM" > "$W/keys/tw-keys"; chmod 0600 "$W/keys/tw-keys"
printf 'TW_KEY_SECRET=synthetic-WRONG-key-000000000000\n' > "$W/keys/wrong-keys"; chmod 0600 "$W/keys/wrong-keys"
printf 'TW_SECRET_KEY=%s\n' "$LLM" > "$W/keys/no-main-key"; chmod 0600 "$W/keys/no-main-key"
printf 'TW_KEY_SECRET=%s\n' "$KEY" > "$W/keys/only-main-key"; chmod 0600 "$W/keys/only-main-key"
cp "$W/keys/tw-keys" "$W/keys/loose-keys"; chmod 0644 "$W/keys/loose-keys"
printf '%s\n' "$DEMO_PW" > "$W/keys/demo-password"; chmod 0600 "$W/keys/demo-password"
mig_id="$(docker image inspect --format '{{.Id}}' "$MIGRATOR_IMAGE")"
printf '{"schema":"truewealth-deploy/2","commit":"synthetic","loadedIds":{"migrator":"%s"}}\n' "$mig_id" > "$ROOT/DEPLOYMENT_MANIFEST.json"

cat > "$W/vars.yml" <<EOF
truewealth_project: $PROJECT
truewealth_root: $ROOT
truewealth_backup_dir: $ROOT/backups
truewealth_env_file: $ROOT/env/truewealth.env
truewealth_deployment_manifest: $ROOT/DEPLOYMENT_MANIFEST.json
truewealth_compose_cmd: "${COMPOSE[*]}"
truewealth_backup_age_recipients: ['$PUB']
truewealth_backup_offhost_target: $W/offhost
truewealth_backup_offhost_ssh_key: $W/keys/offhost_ssh_key
truewealth_backup_lock_wait_seconds: 2
EOF
for t in backup restore-verify; do
  ansible localhost -c local -m ansible.builtin.template -a "src=/repo/roles/truewealth/templates/truewealth-$t.sh.j2 dest=$W/sbin/truewealth-$t mode=0700" \
    -e @/repo/roles/truewealth/defaults/main.yml -e @"$W/vars.yml" -e ansible_become=false > "$W/render-$t.log" 2>&1 </dev/null \
    || { echo "render $t failed"; tail -5 "$W/render-$t.log"; exit 1; }
done
export TW_RESTORE_SOURCE_CONTAINER="$PROJECT-postgres-1"
ALL_OUT="$W/all-output.log"; : > "$ALL_OUT"
rv() { "$W/sbin/truewealth-restore-verify" "$@" > "$W/rv.log" 2>&1; local rc=$?; cat "$W/rv.log" >> "$ALL_OUT"; return $rc; }
psq() { "${COMPOSE[@]}" exec -T postgres psql -U truewealth -d truewealth -AtX -c "$1"; }

echo "── backup under concurrent writes ──"
before="$(psq 'SELECT count(*) FROM core.users')"
"${COMPOSE[@]}" exec -T postgres psql -U truewealth -d truewealth -q -c "
DO \$\$ BEGIN FOR i IN 1..400 LOOP
  INSERT INTO core.users (id, email, password_hash, mfa_enabled, created_at, updated_at)
  VALUES ('w_' || md5(random()::text), 'writer-' || md5(random()::text) || '@example.test', NULL, false, now()::text, now()::text);
  COMMIT; PERFORM pg_sleep(0.02);
END LOOP; END \$\$;" > /dev/null 2>&1 &
WRITER=$!
sleep 1.5
"$W/sbin/truewealth-backup" --reason manual > "$W/backup1.log" 2>&1; brc=$?
cat "$W/backup1.log" >> "$ALL_OUT"
wait "$WRITER"
after="$(psq 'SELECT count(*) FROM core.users')"
B="$(ls -1d "$ROOT"/backups/[0-9]*Z | tail -1)"
snap_users="$(jq -r .snapshot.users "$B/manifest.json")"
[ $brc -eq 0 ] && [ -f "$B/db.dump" ] && ok "backup succeeded while ~400 synthetic writes ran ($before users before, $snap_users in the snapshot, $after after)" \
  || bad "backup under writes" "rc=$brc $(tail -3 "$W/backup1.log")"
[ "$snap_users" -gt "$before" ] && [ "$snap_users" -lt "$after" ] \
  && ok "the snapshot is a point in the middle of the writes (not before, not after)" || bad "snapshot during writes" "$before < $snap_users < $after ?"
[ "$(jq -r .metadataSource "$B/manifest.json")" = "schema state and counts read in the same exported snapshot as the dump" ] \
  && [ "$(jq -r '.snapshot.representative | length' "$B/manifest.json")" -ge 6 ] \
  && ok "manifest: counts and representative tables from the dump's own snapshot" || bad "manifest metadata" "$(jq -c .snapshot "$B/manifest.json" | head -c 300)"

echo "── restore verification of that backup ──"
if rv --key-file "$W/keys/tw-keys" --check-email demo@truewealth.local --check-password-file "$W/keys/demo-password" "$B"; then
  ok "restore-verify PASSED: $(grep -c '  ok ' "$W/rv.log") checks incl. users == snapshot ($snap_users) under concurrent writes"
else
  bad "restore-verify of a backup taken under writes" "$(grep -E 'FAIL|NOT|key' "$W/rv.log" | head -6)"
fi
grep -q "ok    users ($snap_users)" "$W/rv.log" && grep -q 'ok    rows in wealth.account_balances' "$W/rv.log" \
  && ok "restored users equal the snapshot count; representative tables match" || bad "counts" "$(grep -E 'users|rows in' "$W/rv.log" | head -4)"
grep -q '"result":"all-encrypted-values-decrypt"' "$W/rv.log" && grep -q '"passwordCheck":"verified"' "$W/rv.log" \
  && grep -q '"field":"ai.providers.api_key_encrypted","key":"TW_SECRET_KEY","total":1,"decrypted":1' "$W/rv.log" \
  && ok "the application decrypts MFA secrets, provider credentials and LLM keys with the held keys; the demo password verifies" \
  || bad "application-level key check" "$(grep -E 'key|application' "$W/rv.log" | head -4)"
grep -q 'presence only, not proof of sign-in' "$W/rv.log" && ! grep -qi 'can sign in' "$W/rv.log" \
  && ok "hash presence is reported as presence, never as proof of authentication" || bad "honest hash wording" "check"

echo "── encrypted off-host copy and recovery with separately held keys ──"
O="$W/offhost/$(basename "$B")"
[ -f "$O/db.dump.age" ] && [ -f "$O/manifest.json" ] && [ -f "$O/COMPLETE" ] && [ ! -e "$O/db.dump" ] \
  && ok "the off-host copy holds only ciphertext, the manifest and COMPLETE" || bad "off-host content" "$(ls "$O" 2>&1)"
! grep -qF -- "$KEY" "$O/manifest.json" && ! grep -qF -- "$LLM" "$O/manifest.json" \
  && [ "$(jq -r .keys.TW_KEY_SECRET.fingerprint "$O/manifest.json" | wc -c)" -eq 17 ] \
  && ok "the manifest carries key fingerprints only" || bad "manifest key material" "!"
cp -R "$O" "$W/recover"
if rv --identity "$W/keys/age-identity" --key-file "$W/keys/tw-keys" --check-email demo@truewealth.local --check-password-file "$W/keys/demo-password" "$W/recover"; then
  ok "recovered from the ENCRYPTED copy + separately held identity and keys: PASSED"
else
  bad "encrypted recovery" "$(grep -E 'FAIL|NOT|restore-verify' "$W/rv.log" | head -5)"
fi

echo "── failure paths ──"
cp -R "$O" "$W/partial"; rm -f "$W/partial/COMPLETE"
rv --identity "$W/keys/age-identity" --key-file "$W/keys/tw-keys" "$W/partial"; rc=$?
[ $rc -eq 4 ] && ok "a copy without COMPLETE (interrupted transfer) is refused (exit 4)" || bad "partial copy" "rc=$rc"
cp -R "$O" "$W/tampered"; printf 'x' >> "$W/tampered/db.dump.age"
rv --identity "$W/keys/age-identity" --key-file "$W/keys/tw-keys" "$W/tampered"; rc=$?
[ $rc -eq 4 ] && ok "a tampered ciphertext is refused before decryption (exit 4)" || bad "tampered copy" "rc=$rc"
rv --identity "$W/keys/other-identity" --key-file "$W/keys/tw-keys" "$W/recover"; rc=$?
[ $rc -eq 3 ] && grep -q 'cannot decrypt with this identity' "$W/rv.log" && ok "the wrong age identity cannot decrypt (exit 3)" || bad "wrong identity" "rc=$rc"
rv --key-file "$W/keys/wrong-keys" "$B"; rc=$?
[ $rc -eq 3 ] && grep -q 'does not match this backup (fingerprint' "$W/rv.log" && ok "the wrong TW_KEY_SECRET is caught by fingerprint (exit 3), data checks still reported" || bad "wrong key" "rc=$rc"
rv --key-file "$W/keys/no-main-key" "$B"; rc=$?
[ $rc -eq 3 ] && grep -q 'no TW_KEY_SECRET' "$W/rv.log" && ok "a missing TW_KEY_SECRET fails (exit 3)" || bad "missing key" "rc=$rc"
rv --key-file "$W/keys/only-main-key" "$B"; rc=$?
[ $rc -eq 0 ] && grep -q 'no TW_SECRET_KEY was supplied' "$W/rv.log" \
  && ok "without TW_SECRET_KEY the LLM keys are reported as unchecked (warning), not silently passed" || bad "missing LLM key" "rc=$rc"
rv --key-file "$W/keys/loose-keys" "$B"; rc=$?
[ $rc -eq 2 ] && grep -q 'must be owned by' "$W/rv.log" && ok "a key file readable by others is refused (exit 2)" || bad "loose key file" "rc=$rc"
cp -R "$B" "$W/wrongcount"; jq '.snapshot.users += 1' "$B/manifest.json" > "$W/wrongcount/manifest.json"
rv --key-file "$W/keys/tw-keys" "$W/wrongcount"; rc=$?
[ $rc -eq 1 ] && ok "a restore that does not match its manifest fails (exit 1)" || bad "count mismatch" "rc=$rc"

echo "── concurrency, failure reporting, retention ──"
# Hold the lock the way a running backup does, for longer than the wait.
flock "$ROOT/backups/.lock" sleep 6 &
HOLD=$!
sleep 0.5
"$W/sbin/truewealth-backup" --reason manual > "$W/bB.log" 2>&1; rcb=$?
[ "$rcb" -eq 75 ] && grep -q 'another backup still holds the lock' "$W/bB.log" \
  && [ "$(jq -r '.result + "@" + .stage' "$ROOT/backups/LAST_STATUS.json")" = failed@lock ] \
  && ok "a backup that cannot get the lock waits (bounded), then fails cleanly: exit 75, status failed@lock" || bad "backup lock" "B=$rcb"
wait "$HOLD"
# Two backups started together: the second waits for the first, then runs;
# both succeed with distinct directories (no reused stamp).
( "$W/sbin/truewealth-backup" --reason manual > "$W/bA.log" 2>&1; echo $? > "$W/bA.rc" ) &
PA=$!
( "$W/sbin/truewealth-backup" --reason manual > "$W/bC.log" 2>&1; echo $? > "$W/bC.rc" ) &
PC=$!
wait "$PA" "$PC"
[ "$(cat "$W/bA.rc")" -eq 0 ] && [ "$(cat "$W/bC.rc")" -eq 0 ] \
  && [ "$(ls -1d "$ROOT"/backups/[0-9]*Z | sort -u | wc -l)" -eq 3 ] \
  && ok "two simultaneous backups serialize on the lock and both complete, in distinct directories" || bad "serialized backups" "A=$(cat "$W/bA.rc") C=$(cat "$W/bC.rc") $(tail -2 "$W/bC.log")"
[ "$(jq -r .result "$ROOT/backups/LAST_STATUS.json")" = succeeded ] && ok "LAST_STATUS.json records the last completed run" || bad "last status" "$(cat "$ROOT/backups/LAST_STATUS.json")"
"${COMPOSE[@]}" stop postgres > /dev/null 2>&1
n_before="$(ls -1d "$ROOT"/backups/[0-9]*Z | wc -l)"
"$W/sbin/truewealth-backup" --reason manual > "$W/bF.log" 2>&1; rcf=$?
cat "$W/bF.log" >> "$ALL_OUT"
[ $rcf -ne 0 ] && [ "$(jq -r .result "$ROOT/backups/LAST_STATUS.json")" = failed ] && [ "$(jq -r .stage "$ROOT/backups/LAST_STATUS.json")" = snapshot ] \
  && [ -z "$(ls -1d "$ROOT"/backups/.*partial 2>/dev/null)" ] && [ "$(ls -1d "$ROOT"/backups/[0-9]*Z | wc -l)" = "$n_before" ] \
  && ok "a failed backup exits non-zero, records stage 'snapshot', and leaves no partial directory" || bad "failure reporting" "rc=$rcf $(cat "$ROOT/backups/LAST_STATUS.json")"
[ "$n_before" -eq 3 ] && ok "retention deleted nothing (all $n_before backups kept; deletion not approved)" || bad "retention" "$n_before"

echo "── nothing secret in any output ──"
leak=""
for s in "$KEY" "$LLM" "$DBPW" "$AGE_SECRET" "$DEMO_PW"; do grep -qF -- "$s" "$ALL_OUT" && leak="$leak [${s:0:10}…]"; done
for f in "$ROOT"/backups/*/manifest.json "$ROOT"/backups/LAST_STATUS.json; do
  for s in "$KEY" "$LLM" "$DBPW"; do grep -qF -- "$s" "$f" && leak="$leak [$f]"; done
done
[ -z "$leak" ] && ok "no key, password or identity in any backup/restore output, manifest or status file" || bad "leak" "$leak"
[ -z "$(docker ps -aq --filter label=io.truewealth.task=restore-verify)" ] && ok "no restore container left behind" || bad "restore cleanup" "left"

printf -- '── backup exercise: %d passed, %d failed ──\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
