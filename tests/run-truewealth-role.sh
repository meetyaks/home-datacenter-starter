#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# roles/truewealth — proof on this machine, no datacenter host involved.
#
#   TW_APP_REPO=~/Projects/truewealth tests/run-truewealth-role.sh
#   (sections 4 and 6 need Docker; 4 also needs the TrueWealth node_modules)
#
#   1. static contract: never build/pull/down/--remove-orphans, no Docker
#      socket, loopback-only publication; secrets file-based, no_log AND
#      diff: false, never a process argument (no docker -e secrets; the admin
#      password via hidden prompt + pipelined stdin); a changed deployment
#      runs recovery point → migrate → start → verify → record
#   2. templates render; the real controller.yml accepts a correct bundle
#      and refuses 15 wrong ones (incl. dev-local evidence, another run or
#      attempt, not API-verified, another workflow/head, failed run, changed
#      evidence); compose.yml refuses a LAN-published variant
#   3. a real caddy validates the COMPOSED configuration
#   4. backup/restore integrity with the REAL migrator image and synthetic
#      data: snapshot-consistent manifest under concurrent writes, app-level
#      key checks, encrypted off-host recovery, failure paths, locking
#   5. (optional, TW_TRANSFER_BUNDLE) images.yml with a real verified bundle
#   6. the real role end to end with stand-in images: unchanged re-runs,
#      a migration behind a recovery point, a failing migration, a failed
#      post-start verification, a stray container, a crashing web
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
grep -q "stdin: \"{{ truewealth_admin_password_input }}\"" "$tasks/enroll-admin.yml" && ! grep -qE "argv:.*admin_password" "$tasks/enroll-admin.yml" \
  && grep -q "include_tasks: pipelining-probe.yml" "$tasks/enroll-admin.yml" && grep -q "ansible_pipelining: true" "$tasks/enroll-admin.yml" \
  && grep -q "lookup('ansible.builtin.vars', 'truewealth_admin_password', default='__absent__')" "$tasks/enroll-admin.yml" \
  && ok "the admin password: hidden prompt, stdin on a pipelined task (probed), never -e or an argument" || bad "password handling" "check enroll-admin.yml"
if code | grep -E "docker (run|exec)|\-e " | grep -qE "\-e [A-Z_]*(PASS|SECRET|TOKEN|KEY)[A-Z_]*="; then
  bad "no secret in a docker -e argument" "$(code | grep -nE "\-e [A-Z_]*(PASS|SECRET|TOKEN|KEY)[A-Z_]*=" | head -2)"
else
  ok "no secret is passed as a docker -e argument anywhere in the role (restore-verify uses --env-file)"
fi
grep -q -- "'--remove-orphans'" "$tasks/deploy.yml" && bad "no --remove-orphans in a routine deploy" "found" \
  || ok "no --remove-orphans: unexpected containers are reported, never removed"
[ "$(grep -c 'diff: false' "$tasks/secrets.yml")" -ge 2 ] && ok "secret files are written with diff: false as well as no_log" || bad "diff suppressed" "missing"
ord=$(grep -oE "include_tasks: (premigrate|migrate|deploy|verify|record)\.yml" "$tasks/main.yml" | head -5 | sed 's/include_tasks: //' | tr '\n' ' ')
[ "$ord" = "premigrate.yml migrate.yml deploy.yml verify.yml record.yml " ] \
  && ok "a changed deployment: recovery point → migrate → start → verify → record (success recorded last)" || bad "deploy ordering" "$ord"
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

  mk_transfer() { # dir commit platform roles tagcommit [key=value …]
    # keys: class verified wf head conclusion schema run attempt
    local d="$1" c="$2" p="$3" roles="$4" tc="$5"; shift 5
    local class=ci verified=github-api wf=.github/workflows/release.yml head="$c" conclusion=success schema=truewealth-transfer/2 run=4242 attempt=1
    local kv; for kv in "$@"; do local "$kv"; done
    mkdir -p "$d"; local imgs=""
    for role in $roles; do
      head -c 4096 /dev/urandom > "$d/$role.tar"
      local sha; sha=$(shasum -a 256 "$d/$role.tar" | cut -d' ' -f1)
      local cfg; cfg=$(printf %s "$role$c" | shasum -a 256 | cut -d' ' -f1)
      imgs="$imgs{\"role\":\"$role\",\"title\":\"truewealth-$role\",\"archive\":\"$role.tar\",\"archiveSha256\":\"sha256:$sha\",\"configDigest\":\"sha256:$cfg\",\"manifestDigest\":\"sha256:$cfg\",\"acceptLoadedIds\":[\"sha256:$cfg\"],\"localTag\":\"truewealth/$role:${tc:0:12}-${cfg:0:12}\"},"
    done
    printf '{"synthetic":"evidence for %s"}\n' "$c" > "$d/evidence.json"
    local esha; esha=$(shasum -a 256 "$d/evidence.json" | cut -d' ' -f1)
    printf '{"schema":"%s","commit":"%s","source":"https://github.com/meetyaks/truewealth","evidenceClass":"%s","platform":"%s","run":{"id":%s,"attempt":%s,"workflowPath":"%s","workflowSha":"%s","headSha":"%s","headBranch":"main","event":"workflow_dispatch","conclusion":"%s","verifiedWith":"%s"},"artifact":{"name":"release-bundle-%s-%s","id":1,"digest":"sha256:%s"},"evidenceFile":"evidence.json","evidenceSha256":"sha256:%s","images":[%s]}\n' \
      "$schema" "$c" "$class" "$p" "$run" "$attempt" "$wf" "$head" "$head" "$conclusion" "$verified" "$run" "$attempt" \
      "$(printf a | shasum -a 256 | cut -d' ' -f1)" "$esha" "${imgs%,}" > "$d/transfer.json"
  }
  mk_transfer "$T" "$commit" linux/amd64 "web worker compute migrator" "$commit"
  cp -R "$T" "$T-tampered"; printf x >> "$T-tampered/web.tar"
  mk_transfer "$T-missing-role" "$commit" linux/amd64 "web worker compute" "$commit"
  mk_transfer "$T-arm64" "$commit" linux/arm64 "web worker compute migrator" "$commit"
  mk_transfer "$T-badtag" "$commit" linux/amd64 "web worker compute migrator" "0000000000000000000000000000000000000000"
  mk_transfer "$T-badcommit" "$bad_commit" linux/amd64 "web worker compute migrator" "$bad_commit"
  all="web worker compute migrator"
  mk_transfer "$T-devlocal" "$commit" linux/amd64 "$all" "$commit" class=dev-local verified=none
  mk_transfer "$T-otherrun" "$commit" linux/amd64 "$all" "$commit" run=9999
  mk_transfer "$T-otherattempt" "$commit" linux/amd64 "$all" "$commit" attempt=2
  mk_transfer "$T-unverified" "$commit" linux/amd64 "$all" "$commit" verified=none
  mk_transfer "$T-otherworkflow" "$commit" linux/amd64 "$all" "$commit" wf=.github/workflows/validate.yml
  mk_transfer "$T-otherhead" "$commit" linux/amd64 "$all" "$commit" head=$(printf 'o' | shasum -a 256 | cut -c1-40)
  mk_transfer "$T-failedrun" "$commit" linux/amd64 "$all" "$commit" conclusion=failure
  mk_transfer "$T-schema1" "$commit" linux/amd64 "$all" "$commit" schema=truewealth-transfer/1
  cp -R "$T" "$T-evidence-changed"; printf ' ' >> "$T-evidence-changed/evidence.json"
  printf 'syntheticRedisPassword000000000000\n' > "$R/work/redis_password"

  ansible-playbook tests/truewealth-role.yml -e render_dir="$R/render" -e fixture_transfer_dir="$T" \
    -e fixture_repo="$repo" -e fixture_commit="$commit" -e fixture_bad_commit="$bad_commit" \
    -e work_dir="$R/work" -e fixture_compose_file="$R/compose.ok.yml" -e compose_lan_file="$R/compose.lan.yml" \
    > "$R/role.log" 2>&1 </dev/null
  if grep -q 'failed=0' "$R/role.log" && ! grep -q 'MISSED' "$R/role.log"; then
    ok "templates render; shell templates pass bash -n"
    n=$(grep -c 'Refused: ' "$R/role.log")
    ok "controller.yml accepts the correct bundle and refuses $n wrong ones (commit, tampered archive, missing role, platform, tag, compose with build, dev-local evidence, another run, another attempt, not API-verified, another workflow, another head, failed run, old schema, evidence changed)"
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
echo "── 4. backup and restore integrity with the real migrator (synthetic data, concurrent writes, encrypted recovery) ──"
# Needs Docker, the TrueWealth checkout WITH node_modules (the seeder uses the
# application's own encryption code) and Node. Resources carry
# twtask=tw-backup-test / the twtest-backup compose project and are removed by
# exactly those labels afterwards.
backup_cleanup() {
  local ids
  ids=$(docker ps -aq --filter label=twtask=tw-backup-test; docker ps -aq --filter label=com.docker.compose.project=twtest-backup; docker ps -aq --filter label=io.truewealth.task=restore-verify)
  [ -n "$ids" ] && docker rm -f -v $ids > /dev/null 2>&1
  docker network ls -q --filter label=com.docker.compose.project=twtest-backup | xargs -r docker network rm > /dev/null 2>&1
  docker volume rm twtest-backup-work > /dev/null 2>&1
  true
}
NODE_BIN="${TW_NODE:-node}"
if [ -n "${SKIP_TW_BACKUP_EXERCISE:-}" ]; then
  skip "backup/restore exercise" "SKIP_TW_BACKUP_EXERCISE is set"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && [ -d "$APP/node_modules/tsx" ] && command -v "$NODE_BIN" >/dev/null 2>&1; then
  backup_cleanup
  BX_PORT="${TW_BACKUP_EXERCISE_PG_PORT:-55461}"
  GIT_NO_LAZY_FETCH=1 git -C "$APP" show "$(git -C "$APP" rev-parse HEAD):infra/dc1/compose.dc1.yml" > "$R/bx-compose.dc1.yml"
  if docker build -q --target migrator --label twtask=tw-backup-test -t twtest-real/migrator:exercise "$APP" > "$R/bx-build.log" 2>&1 \
     && docker build -q --label twtask=hds-test-tools -t hds-deploy-harness:local -f tests/tools/deploy-harness.Dockerfile tests/tools >> "$R/bx-build.log" 2>&1 \
     && docker volume create --label twtask=tw-backup-test twtest-backup-work > /dev/null; then
    BMP=$(docker volume inspect -f '{{.Mountpoint}}' twtest-backup-work)
    bx() {
      docker run --rm --label twtask=tw-backup-test --network host -v /var/run/docker.sock:/var/run/docker.sock \
        -v "twtest-backup-work:$BMP" -v "$PWD:/repo:ro" -v "$R/bx-compose.dc1.yml:/app/compose.dc1.yml:ro" \
        -e MIGRATOR_IMAGE=twtest-real/migrator:exercise -e PG_PORT="$BX_PORT" hds-deploy-harness:local \
        bash /repo/tests/truewealth-backup-exercise.sh "$1" "$BMP"
    }
    if bx up > "$R/bx-up.log" 2>&1; then
      # Seed with the application's own code: the demo household, then
      # encrypted MFA/provider/LLM fields (tests/fixtures/tw-backup-seed.ts).
      # The synthetic DB password and keys are read from the work volume into
      # this process's environment only.
      bxenv="$(docker run --rm -v twtest-backup-work:/w hds-deploy-harness:local cat /w/root/env/truewealth.env)"
      bxget() { printf '%s\n' "$bxenv" | sed -n "s/^$1=//p"; }
      if ( cd "$APP" && export TW_DB_HOST=127.0.0.1 TW_DB_PORT="$BX_PORT" TW_DB_USER=truewealth TW_DB_NAME=truewealth \
             TW_DB_PASSWORD="$(bxget TW_DB_PASSWORD)" TW_KEY_SECRET="$(bxget TW_KEY_SECRET)" TW_SECRET_KEY="$(bxget TW_SECRET_KEY)" \
           && "$NODE_BIN" node_modules/tsx/dist/cli.mjs db/seed-demo.ts \
           && TSX_TSCONFIG_PATH="$APP/tsconfig.json" NODE_PATH="$APP/node_modules" \
              "$NODE_BIN" node_modules/tsx/dist/cli.mjs "$OLDPWD/tests/fixtures/tw-backup-seed.ts" ) > "$R/bx-seed.log" 2>&1; then
        unset bxenv
        if bx exercise > "$R/bx-exercise.log" 2>&1; then
          ok "a backup taken during ~400 synthetic writes: manifest counts from the dump's own snapshot; restore matches it"
          ok "restore-verify: schema, representative tables, orphans, key fingerprint, app-level decryption of MFA/provider/LLM secrets, a known password verifies"
          ok "encrypted to a synthetic age key; the simulated off-host copy is ciphertext + manifest + COMPLETE; recovered with separately held identity and keys"
          ok "partial/tampered copies, wrong identity, wrong/missing key and loose key files fail with distinct exits; no secret in any output"
          ok "backups serialize on a lock, a failure leaves no partial directory and records its stage, retention deletes nothing ($(grep -o 'backup exercise: [0-9]* passed' "$R/bx-exercise.log"))"
        else
          bad "backup/restore exercise" "$(grep -A1 FAIL "$R/bx-exercise.log" | head -10)"
        fi
      else
        unset bxenv
        bad "seed the exercise database" "$(tail -4 "$R/bx-seed.log")"
      fi
    else
      bad "start the exercise database" "$(tail -6 "$R/bx-up.log")"
    fi
  else
    bad "exercise setup" "$(tail -3 "$R/bx-build.log")"
  fi
  backup_cleanup
  docker image rm twtest-real/migrator:exercise > /dev/null 2>&1
else
  skip "backup/restore exercise" "needs Docker, TW_APP_REPO with node_modules, and Node"
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
echo "── 6. the real role, end to end, with stand-in images (deploy, re-run, migrate, fail, recover) ──"
# Needs Docker and the TrueWealth checkout (its dc1 compose file). Everything
# it creates carries twtask=tw-deploy-test or the twtest-deploy compose
# project, and is removed by exactly those labels/names afterwards.
deploy_cleanup() {
  local ids
  ids=$(docker ps -aq --filter label=twtask=tw-deploy-test; docker ps -aq --filter label=com.docker.compose.project=twtest-deploy)
  [ -n "$ids" ] && docker rm -f -v $ids > /dev/null 2>&1
  docker network ls -q --filter label=com.docker.compose.project=twtest-deploy | xargs -r docker network rm > /dev/null 2>&1
  docker volume rm twtest-deploy-work > /dev/null 2>&1
  # Stand-in images: built with the label; their truewealth/* tags point at them.
  for img in $(docker images -q --filter label=io.truewealth.test.standin=true | sort -u); do
    docker image rm -f "$img" > /dev/null 2>&1
  done
  true
}
if [ -n "${SKIP_TW_DEPLOY_HARNESS:-}" ]; then
  skip "end-to-end deploy scenarios" "SKIP_TW_DEPLOY_HARNESS is set"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1 && git -C "$APP" rev-parse >/dev/null 2>&1; then
  deploy_cleanup
  GIT_NO_LAZY_FETCH=1 git -C "$APP" show "$(git -C "$APP" rev-parse HEAD):infra/dc1/compose.dc1.yml" > "$R/app-compose.dc1.yml"
  if docker build -q --label twtask=hds-test-tools -t hds-deploy-harness:local -f tests/tools/deploy-harness.Dockerfile tests/tools > "$R/harness-build.log" 2>&1 \
     && docker volume create --label twtask=tw-deploy-test twtest-deploy-work > /dev/null; then
    MP=$(docker volume inspect -f '{{.Mountpoint}}' twtest-deploy-work)
    docker run --rm --name twtest-harness --label twtask=tw-deploy-test --network host --add-host tw.dc1.test:127.0.0.1 \
      -v /var/run/docker.sock:/var/run/docker.sock -v "twtest-deploy-work:$MP" -v "$PWD:/repo:ro" \
      -v "$R/app-compose.dc1.yml:/app/compose.dc1.yml:ro" -e CADDY_IMAGE="$CADDY_IMAGE" \
      hds-deploy-harness:local bash /repo/tests/truewealth-deploy-harness.sh "$MP" > "$R/deploy-harness.log" 2>&1
    hrc=$?
    n=$(grep -o 'deploy harness: [0-9]* passed' "$R/deploy-harness.log" | grep -o '[0-9]*')
    if [ "$hrc" -eq 0 ]; then
      ok "unchanged re-runs change nothing; a changed release migrates behind a recovery point and a stopped worker; rollback target = last distinct success"
      ok "a failing migration, a failed post-start verification and a crashing web each leave the success record and rollback target untouched"
      ok "stray containers are reported, not removed; failure diagnostics are bounded and leak no synthetic secret ($n checks, tests/truewealth-deploy-harness.sh)"
    else
      bad "end-to-end deploy scenarios" "$(grep -A1 FAIL "$R/deploy-harness.log" | head -10)"
    fi
  else
    bad "deploy harness setup" "$(tail -3 "$R/harness-build.log")"
  fi
  deploy_cleanup
else
  skip "end-to-end deploy scenarios" "needs Docker and TW_APP_REPO"
fi
echo
printf '── %d passed, %d failed ──\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
