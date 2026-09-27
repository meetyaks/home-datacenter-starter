#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# roles/truewealth — controller-side proof, no host involved.
#
#   tests/run-truewealth-role.sh
#   TW_APP_REPO=~/Projects/truewealth tests/run-truewealth-role.sh
#   TW_BACKUP_LIVE='docker compose -p <proj> -f … --env-file …' \
#   TW_BACKUP_LIVE_ENV=<env file> tests/run-truewealth-role.sh
#
#   1. static contract: deploys never build, never pull TrueWealth images,
#      never `compose down`, never mount the Docker socket, never publish
#      beyond loopback; secrets are no_log and file-based; migrations run
#      before `up` and stop on failure; not in site.yml; no host-bootstrap
#      roles; the Caddy drop-in adds no forwarding-header trust
#   2. templates render; tasks/controller.yml and tasks/compose.yml (the real
#      task files) accept correct inputs and refuse wrong ones
#   3. a real caddy validates the COMPOSED configuration (main Caddyfile +
#      Keel's drop-in + TrueWealth's) and a broken drop-in is refused
#   4. (optional, TW_BACKUP_LIVE) the rendered backup script and restore
#      verifier run against a disposable running stack
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.."
R="${TMPDIR:-/tmp}/tw-role.$$"
mkdir -p "$R"
trap '[ -n "${KEEP_TW_ROLE_TMP:-}" ] || rm -rf "$R"' EXIT
pass=0; fail=0
ok()   { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }
skip() { printf '  \033[33mskip\033[0m  %s\n         %s\n' "$1" "$2"; }
ROLE=roles/truewealth
CADDY_IMAGE="${CADDY_TEST_IMAGE:-caddy:2.10-alpine@sha256:4c6e91c6ed0e2fa03efd5b44747b625fec79bc9cd06ac5235a779726618e530d}"

echo "── 1. static contract ──"
ansible-playbook --syntax-check playbooks/truewealth.yml > "$R/s1" 2>&1 && ok "playbooks/truewealth.yml parses" || bad "truewealth.yml parses" "$(tail -3 "$R/s1")"
ansible-playbook --syntax-check playbooks/truewealth-enroll-admin.yml > "$R/s2" 2>&1 && ok "playbooks/truewealth-enroll-admin.yml parses" || bad "enroll playbook parses" "$(tail -3 "$R/s2")"

tasks="$ROLE/tasks"
code() { grep -rhvE '^\s*#' "$tasks" "$ROLE/templates" 2>/dev/null; }
code | grep -qE "'down'|compose.* down\b" && bad "no compose down in the role" "$(code | grep -nE "'down'|compose.* down\b" | head -2)" || ok "no 'compose down' anywhere in the role"
code | grep -qE "'build'|docker build|buildx" && bad "no image builds on the host" "found a build" || ok "the host never builds an image"
code | grep -qE "docker (image )?pull|'pull'\]" && bad "no pulls" "found a pull" || ok "the host never pulls TrueWealth images"
grep -q "'--pull', 'never'" "$tasks/deploy.yml" && ok "up runs with --pull never" || bad "--pull never" "missing from deploy.yml"
if code | grep 'docker\.sock' | grep -vqE "search\(|regex_findall\("; then
  bad "no Docker socket" "$(code | grep 'docker\.sock' | grep -vE "search\(|regex_findall\(" | head -2)"
else
  ok "no Docker socket is mounted (only the checks that refuse it mention it)"
fi
grep -q "published | unique == \['127.0.0.1'\]" "$tasks/compose.yml" && grep -q "published_services == \['web'\]" "$tasks/compose.yml" \
  && ok "the rendered config must publish only web, only on 127.0.0.1" || bad "loopback-only publication is enforced" "assertion missing"
for f in secrets.yml enroll-admin.yml; do
  n_secret=$(grep -cE "vault_|admin_password" "$tasks/$f"); n_nolog=$(grep -c "no_log: true" "$tasks/$f")
  [ "$n_nolog" -ge 2 ] && ok "$f: secret-bearing tasks are no_log ($n_nolog)" || bad "$f is no_log" "only $n_nolog no_log tasks"
done
grep -q "stdin: \"{{ truewealth_admin_password }}\"" "$tasks/enroll-admin.yml" && ! grep -qE "argv:.*admin_password" "$tasks/enroll-admin.yml" \
  && ok "the admin password reaches the CLI on stdin, never as an argument" || bad "password on stdin" "check enroll-admin.yml"
order=$(grep -nE "include_tasks: (migrate|deploy).yml" "$tasks/main.yml" | cut -d: -f1 | tr '\n' ' ')
set -- $order
[ "${1:-0}" -lt "${2:-0}" ] && grep -q "Stop when migrations failed" "$tasks/migrate.yml" \
  && ok "migrations run before up, and a failure stops the deploy" || bad "migration ordering" "$order"
grep -qE 'truewealth' playbooks/site.yml && bad "not in site.yml" "site.yml mentions truewealth" || ok "not part of site.yml"
grep -qE "name: (docker|common|storage)$" playbooks/truewealth.yml && bad "no host bootstrap roles" "found one" || ok "runs no host-bootstrap role (docker, common, storage)"
grep -qE "trusted_proxies|header_up|X-Real-IP" <(grep -vE '^\s*#' "$ROLE/templates/truewealth.caddy.j2") \
  && bad "the drop-in trusts no forwarding header" "found one" || ok "the Caddy drop-in adds no forwarding-header trust"
grep -rq "Reload Caddy" "$ROLE/handlers" 2>/dev/null && bad "Reload Caddy belongs to roles/caddy" "defined in roles/truewealth" || ok "the reload is roles/caddy's (reload-and-verify)"
grep -q "validate: \"{{ caddy_binary_path" "$tasks/caddy.yml" && grep -q "tasks_from: reload-and-verify" "$tasks/caddy.yml" \
  && ok "drop-in validated alone, then the whole config before reload" || bad "Caddy validation" "missing"

echo
echo "── 2. templates, controller and compose checks ──"
APP="${TW_APP_REPO:-$HOME/Projects/truewealth}"
if [ -d "$APP/.git" ] || git -C "$APP" rev-parse >/dev/null 2>&1; then
  T="$R/transfer"; mkdir -p "$T" "$R/render" "$R/work/ok" "$R/work/lan"
  repo="$R/repo"; git init -q "$repo"
  mkdir -p "$repo/infra/dc1"
  GIT_NO_LAZY_FETCH=1 git -C "$APP" show "$(git -C "$APP" rev-parse HEAD):infra/dc1/compose.dc1.yml" > "$repo/infra/dc1/compose.dc1.yml"
  git -C "$repo" add -A && git -C "$repo" -c user.email=t@t -c user.name=t commit -qm fixture
  commit=$(git -C "$repo" rev-parse HEAD)
  awk '{ print } /^  web:$/ { print "    build: ." }' "$repo/infra/dc1/compose.dc1.yml" > "$R/with-build.yml"
  cp "$R/with-build.yml" "$repo/infra/dc1/compose.dc1.yml"
  git -C "$repo" -c user.email=t@t -c user.name=t commit -qam "with build"
  bad_commit=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" show "$commit:infra/dc1/compose.dc1.yml" > "$R/compose.ok.yml"
  sed "s/'127.0.0.1:\${TW_WEB_PORT/'0.0.0.0:\${TW_WEB_PORT/" "$R/compose.ok.yml" > "$R/compose.lan.yml"

  mk_transfer() { # dir commit platform roles tagcommit
    local d="$1" c="$2" p="$3" roles="$4" tc="$5"
    mkdir -p "$d"; local imgs=""
    for role in $roles; do
      head -c 4096 /dev/urandom > "$d/$role.tar"
      local sha; sha=$(shasum -a 256 "$d/$role.tar" | cut -d' ' -f1)
      local cfg; cfg=$(printf %s "$role$c" | shasum -a 256 | cut -d' ' -f1)
      imgs="$imgs{\"role\":\"$role\",\"title\":\"truewealth-$role\",\"archive\":\"$role.tar\",\"archiveSha256\":\"sha256:$sha\",\"configDigest\":\"sha256:$cfg\",\"manifestDigest\":\"sha256:$cfg\",\"acceptLoadedIds\":[\"sha256:$cfg\"],\"localTag\":\"truewealth/$role:${tc:0:12}-${cfg:0:12}\"},"
    done
    printf '{"schema":"truewealth-transfer/1","commit":"%s","source":"https://github.com/meetyaks/truewealth","runId":"1","runAttempt":"1","workflowSha":"%s","platform":"%s","evidenceSha256":"sha256:%s","images":[%s]}\n' \
      "$c" "$(printf 'w' | shasum -a 256 | cut -c1-40)" "$p" "$(printf e | shasum -a 256 | cut -d' ' -f1)" "${imgs%,}" > "$d/transfer.json"
  }
  mk_transfer "$T" "$commit" linux/amd64 "web worker compute migrator" "$commit"
  cp -R "$T" "$T-tampered"; printf x >> "$T-tampered/web.tar"
  mk_transfer "$T-missing-role" "$commit" linux/amd64 "web worker compute" "$commit"
  mk_transfer "$T-arm64" "$commit" linux/arm64 "web worker compute migrator" "$commit"
  mk_transfer "$T-badtag" "$commit" linux/amd64 "web worker compute migrator" "0000000000000000000000000000000000000000"
  mk_transfer "$T-badcommit" "$bad_commit" linux/amd64 "web worker compute migrator" "$bad_commit"
  printf 'syntheticRedisPassword000000000000\n' > "$R/work/redis_password"

  ansible-playbook tests/truewealth-role.yml -e render_dir="$R/render" -e fixture_transfer_dir="$T" \
    -e fixture_repo="$repo" -e fixture_commit="$commit" -e fixture_bad_commit="$bad_commit" \
    -e work_dir="$R/work" -e fixture_compose_file="$R/compose.ok.yml" -e compose_lan_file="$R/compose.lan.yml" \
    > "$R/role.log" 2>&1 </dev/null
  if grep -q 'failed=0' "$R/role.log" && ! grep -q 'MISSED' "$R/role.log"; then
    ok "templates render; shell templates pass bash -n"
    n=$(grep -c 'Refused: ' "$R/role.log")
    ok "controller.yml accepts the correct bundle and refuses $n wrong ones (commit, tampered archive, missing role, platform, tag, compose with build)"
    ok "compose.yml renders the real compose file and refuses a LAN-published variant"
  else
    bad "role task files behave" "$(grep -E 'FAILED|MISSED|msg' "$R/role.log" | head -5)"
  fi
  env="$R/render/truewealth.env"
  grep -q "^TW_WEB_IMAGE=truewealth/web:" "$env" && grep -q '^TW_PUBLIC_URL=https://tw.dc1.lan$' "$env" \
    && grep -q '^TW_REDIS_PASSWORD_FILE=' "$env" && ! grep -q '^TW_REDIS_PASSWORD=' "$env" \
    && ok "env: verified local image tags, the public URL, the Redis password as a FILE" || bad "env content" "$(cut -d= -f1 "$env" | tr '\n' ' ')"
  ! grep -q 'syntheticRedisPassword' "$R/render/truewealth-backup.sh" "$R/render/truewealth.caddy" 2>/dev/null \
    && ok "no secret in the rendered drop-in or backup script" || bad "secret leak" "found in a non-secret file"
else
  skip "role task files behave" "TW_APP_REPO ($APP) is not a TrueWealth checkout; the compose file comes from it"
fi

echo
echo "── 3. a real caddy validates the composed configuration ──"
if [ -f "$R/render/caddy/Caddyfile" ] && command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  run_caddy() { docker run --rm --network none --tmpfs /var/log/caddy -v "$1:/etc/caddy:ro" "$CADDY_IMAGE" caddy "${@:2}"; }
  if run_caddy "$R/render/caddy" validate --adapter caddyfile --config /etc/caddy/Caddyfile > "$R/caddy.log" 2>&1; then
    ok "main Caddyfile + Keel's drop-in + TrueWealth's drop-in validate together"
  else
    bad "composed Caddy configuration validates" "$(tail -3 "$R/caddy.log")"
  fi
  run_caddy "$R/render/caddy" adapt --adapter caddyfile --config /etc/caddy/Caddyfile > "$R/adapted.json" 2>/dev/null
  grep -q '"tw.dc1.lan"' "$R/adapted.json" && grep -q '"keel.dc1.lan"' "$R/adapted.json" && grep -q '127.0.0.1:3100' "$R/adapted.json" \
    && ok "both routes are in the adapted config; TrueWealth proxies to 127.0.0.1:3100" || bad "routes adapted" "missing"
  ! grep -q 'trusted_proxies' "$R/adapted.json" && ok "no trusted_proxies anywhere in the composed config" || bad "no trusted_proxies" "present"
  cp -R "$R/render/caddy" "$R/caddy-bad"; printf 'tw.dc1.lan {\n  reverse_proxy {\n' >> "$R/caddy-bad/conf.d/truewealth.caddy"
  if run_caddy "$R/caddy-bad" validate --adapter caddyfile --config /etc/caddy/Caddyfile > /dev/null 2>&1; then
    bad "a broken drop-in is refused" "validate accepted it"
  else
    ok "a broken TrueWealth drop-in fails whole-config validation (so no reload would happen)"
  fi
else
  skip "composed Caddy validation" "no rendered config or no Docker"
fi

echo
echo "── 4. backup and restore against a running stack ──"
if [ -n "${TW_BACKUP_LIVE:-}" ]; then
  B="$R/backups"; mkdir -p "$B"
  cat > "$R/live-vars.yml" <<YML
truewealth_compose_cmd: "${TW_BACKUP_LIVE}"
truewealth_backup_dir: "$B"
truewealth_env_file: "${TW_BACKUP_LIVE_ENV}"
truewealth_root: "$R"
truewealth_deployment_manifest: "$R/none.json"
YML
  ansible localhost -c local -m template -a "src=$ROLE/templates/truewealth-backup.sh.j2 dest=$R/backup.sh mode=0700" \
    -e @"$ROLE/defaults/main.yml" -e @"$R/live-vars.yml" -e ansible_become=false </dev/null > "$R/render-live.log" 2>&1
  ansible localhost -c local -m template -a "src=$ROLE/templates/truewealth-restore-verify.sh.j2 dest=$R/restore.sh mode=0700" \
    -e @"$ROLE/defaults/main.yml" -e @"$R/live-vars.yml" -e ansible_become=false </dev/null > "$R/render-live.log" 2>&1
  if bash "$R/backup.sh" > "$R/backup.log" 2>&1; then
    d=$(ls -1d "$B"/[0-9]*Z | tail -1)
    ok "backup: $(tail -1 "$R/backup.log" | sed 's/^backup: //')"
    python3 -c 'import json,sys; m=json.load(open(sys.argv[1])); assert m["redis"]["policy"]=="not-restored"; assert len(m["keys"]["TW_KEY_SECRET"]["fingerprint"])==16' "$d/manifest.json" \
      && ok "manifest: schema, counts, key fingerprint only, Redis policy recorded" || bad "manifest content" "incomplete"
    ! grep -q "$(sed -n 's/^TW_KEY_SECRET=//p' "$TW_BACKUP_LIVE_ENV")" "$d/manifest.json" && ok "manifest holds no key material" || bad "manifest leaks the key" "!"
    if TW_RESTORE_SOURCE_CONTAINER="${TW_BACKUP_LIVE_PG:-}" bash "$R/restore.sh" "$d" > "$R/restore.log" 2>&1; then
      ok "restore-verify: $(tail -1 "$R/restore.log")"
    else
      bad "restore-verify passes" "$(tail -6 "$R/restore.log")"
    fi
    cp -R "$d" "$R/tampered"; printf 'x' >> "$R/tampered/db.dump"
    TW_RESTORE_SOURCE_CONTAINER="${TW_BACKUP_LIVE_PG:-}" bash "$R/restore.sh" "$R/tampered" > /dev/null 2>&1 \
      && bad "a tampered dump is refused" "accepted" || ok "a tampered dump is refused before restore"
    cp -R "$d" "$R/wrongcount"; python3 -c 'import json,sys; p=sys.argv[1]; m=json.load(open(p)); m["counts"]["users"]+=1; json.dump(m,open(p,"w"))' "$R/wrongcount/manifest.json"
    TW_RESTORE_SOURCE_CONTAINER="${TW_BACKUP_LIVE_PG:-}" bash "$R/restore.sh" "$R/wrongcount" > /dev/null 2>&1 \
      && bad "a count mismatch fails verification" "accepted" || ok "a restore that does not match its manifest fails verification"
    [ -z "$(docker ps -aq --filter label=io.truewealth.task=restore-verify)" ] && ok "no restore container is left behind" || bad "restore cleanup" "containers remain"
  else
    bad "backup runs" "$(tail -5 "$R/backup.log")"
  fi
else
  skip "backup/restore against a running stack" "set TW_BACKUP_LIVE (compose command), TW_BACKUP_LIVE_ENV and TW_BACKUP_LIVE_PG"
fi

echo
echo "── 5. loading a real verified bundle (tasks/images.yml) ──"
if [ -n "${TW_TRANSFER_BUNDLE:-}" ] && [ -f "$TW_TRANSFER_BUNDLE/transfer.json" ]; then
  bc=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["commit"])' "$TW_TRANSFER_BUNDLE/transfer.json")
  bp=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["platform"])' "$TW_TRANSFER_BUNDLE/transfer.json")
  tags=$(python3 -c 'import json,sys; print(" ".join(i["localTag"] for i in json.load(open(sys.argv[1]))["images"]))' "$TW_TRANSFER_BUNDLE/transfer.json")
  # Exactly the tags this bundle defines; nothing else is touched.
  for t in $tags; do docker image rm "$t" >/dev/null 2>&1 || true; done
  mkdir -p "$R/imgwork/images"
  ansible-playbook tests/truewealth-images.yml -e bundle_dir="$TW_TRANSFER_BUNDLE" -e bundle_commit="$bc" \
    -e bundle_platform="$bp" -e work_dir="$R/imgwork" \
    -e foreign_image="${FOREIGN_TEST_IMAGE:-redis:7-alpine@sha256:858f009f9709ce576febc734aa78b8f6d624b82571f9ddb6bda4377c833b3499}" \
    > "$R/images.log" 2>&1 </dev/null
  if grep -q 'failed=0' "$R/images.log" && ! grep -q MISSED "$R/images.log"; then
    ok "images.yml loads a real bundle ($bp) and accepts only the recorded identities"
    ok "a second run transfers and loads nothing"
    ok "a foreign image under an expected tag is refused"
  else
    bad "images.yml with a real bundle" "$(grep -E 'FAILED|MISSED|msg' "$R/images.log" | head -4)"
  fi
  for t in $tags; do docker image rm "$t" >/dev/null 2>&1 || true; done
else
  skip "loading a real bundle" "set TW_TRANSFER_BUNDLE to a fetch-verify.mjs output directory"
fi

echo
printf '── %d passed, %d failed ──\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
