#!/usr/bin/env bash
# Runs INSIDE a throwaway Linux container (tests/run-ci-runner-truewealth.sh
# section 9 starts it) as root, with the repository mounted read-only at /repo.
#
# Proves, with SYNTHETIC tokens, where a runner registration/removal token
# travels through roles/ci_runner — and where it does not:
#   - never in ANY process's argv (every process is sampled while each
#     scenario runs: ansible-playbook, the module, lxc, the guest script,
#     runuser, config.sh, svc.sh);
#   - never in Ansible's output (-vvv), the stub lxc's argv log, the staged or
#     guest files left behind, or Ansible's temp directory (sampled
#     continuously; a negative control with pipelining forced OFF shows the
#     sampler does catch a token written there);
#   - reaches config.sh only as ACTIONS_RUNNER_INPUT_TOKEN, and never the
#     runner service (svc.sh);
#   - refused on the command line (-e), with ANSIBLE_KEEP_REMOTE_FILES, with
#     pipelining disabled, when missing or malformed;
#   - after a failed registration the guest and staged scripts are still
#     removed, and the output names the failure without the token.
set -uo pipefail

pass=0; fail=0
ok()  { printf '  \033[32mpass\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n         %s\n' "$1" "$2"; fail=$((fail + 1)); }

export ANSIBLE_CONFIG=/repo/ansible.cfg ANSIBLE_ROLES_PATH=/repo/roles ANSIBLE_NOCOLOR=1
export ANSIBLE_REMOTE_TMP=/work/rtmp ANSIBLE_LOCAL_TEMP=/work/ltmp
id ghrunner >/dev/null 2>&1 || useradd -m ghrunner
# The fake config.sh runs as ghrunner (through the real runuser) and records into /work.
mkdir -p /work && chmod 1777 /work

# ── the stub lxc: emulates `lxc exec`/`lxc file push` into /work/guest ──────
cat > /usr/local/bin/lxc <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> /work/lxc-argv.log
case "$1" in
  file)  # lxc file push SRC VM/PATH …
    dest="/work/guest/${4#*/}"; mkdir -p "$(dirname "$dest")"; cp "$3" "$dest"; chmod 0700 "$dest"; exit 0 ;;
  exec)  # lxc exec VM -T -- CMD…   (the guest boundary: a clean environment)
    shift 4
    case "$1" in
      /root/*) exec env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root bash "/work/guest$1" ;;
      rm)      shift; [ "$1" = -f ] && shift; rm -f "/work/guest$1"; exit 0 ;;
      test)    exec "$@" ;;
      /bin/sh) case "$3" in *is-active*) echo active ;; *list-units*) echo 0 ;; esac; exit 0 ;;
      *)       echo "stub lxc: unexpected exec $*" >&2; exit 97 ;;
    esac ;;
esac
echo "stub lxc: unexpected $*" >&2; exit 98
STUB
chmod 0755 /usr/local/bin/lxc

reset_state() {
  rm -rf /work/guest /work/stage /work/rtmp /work/ltmp /root/.ansible /work/*.log /work/*.sha /work/rtmp-hits /work/fail-config
  mkdir -p /work/guest/home/ghrunner/actions-runner /work/guest/root /work/rtmp /work/ltmp
  local d=/work/guest/home/ghrunner/actions-runner
  cat > "$d/config.sh" <<'CFG'
#!/usr/bin/env bash
# Fake actions/runner config.sh: records what it was GIVEN, never the value.
printf '%s\n' "$0 $*" >> /work/config-argv.log
[ -n "${ACTIONS_RUNNER_INPUT_TOKEN:-}" ] || { echo "fake config: no ACTIONS_RUNNER_INPUT_TOKEN" >&2; exit 3; }
printf '%s' "$ACTIONS_RUNNER_INPUT_TOKEN" | sha256sum | cut -c1-64 > /work/config-token.sha
sleep 0.5   # long enough for the argv sampler to see this process
if [ -f /work/fail-config ]; then
  echo "Http response code: Unauthorized from 'POST https://api.github.com/actions/runner-registration' (token ***)" >&2
  exit 1
fi
if [ "${1:-}" = remove ]; then rm -f .runner; else echo '{"agentName":"dc1-ci-synthetic"}' > .runner; fi
CFG
  cat > "$d/svc.sh" <<'SVC'
#!/usr/bin/env bash
env > /work/svc-env.log
SVC
  chmod 0755 "$d/config.sh" "$d/svc.sh"
  chown -R ghrunner "$d"
}

sample_start() {
  local token="$1"
  ( while :; do ps -eww -o args= >> /work/ps.log 2>/dev/null
                grep -rlF -- "$token" /work/rtmp /work/ltmp /root/.ansible >> /work/rtmp-hits 2>/dev/null
                sleep 0.02; done ) &
  SAMPLER=$!
}
sample_stop() { kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null; }

# Every place the token must not be, after a scenario.
leaks() { # token → prints the leak sites
  local t="$1"
  grep -qF -- "$t" /work/ps.log            && echo "process argv"
  grep -qF -- "$t" /work/out.log           && echo "ansible output"
  grep -qF -- "$t" /work/lxc-argv.log 2>/dev/null && echo "lxc argv"
  grep -qF -- "$t" /work/config-argv.log 2>/dev/null && echo "config.sh argv"
  [ -s /work/rtmp-hits ]                   && echo "ansible temp files: $(sort -u /work/rtmp-hits | head -2 | tr '\n' ' ')"
  grep -rqF -- "$t" /work/guest /work/stage 2>/dev/null && echo "files left behind"
  grep -qF -- "$t" /work/svc-env.log 2>/dev/null && echo "runner service environment"
  return 0
}

run_play() { # entry, extra args… ; env comes from the caller
  ( cd /repo && ansible-playbook -vvv tests/ci-runner-token.yml -e entry="$1" "${@:2}" ) > /work/out.log 2>&1 </dev/null
}

T1="SYNTHETICregTOKEN$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
sha_of() { printf '%s' "$1" | sha256sum | cut -c1-64; }

echo "── a. registration, token from the controller environment ──"
reset_state; sample_start "$T1"
CI_RUNNER_TOKEN="$T1" run_play register; rc=$?; sample_stop
L=$(leaks "$T1")
[ $rc -eq 0 ] && ok "the real register.yml succeeds" || bad "register.yml succeeds" "$(grep -E 'fatal|FAILED|msg' /work/out.log | head -4)"
[ -z "$L" ] && ok "the token is in no argv, output, temp file, left-over file or service env" || bad "no leak" "$L"
[ "$(cat /work/config-token.sha 2>/dev/null)" = "$(sha_of "$T1")" ] \
  && ok "config.sh received exactly the token, as ACTIONS_RUNNER_INPUT_TOKEN" || bad "config.sh got the token by env" "recorded=$(cat /work/config-token.sha 2>&1) expected=$(sha_of "$T1")"
! grep -q -- '--token' /work/config-argv.log && ok "config.sh was never given --token" || bad "no --token" "$(cat /work/config-argv.log)"
! grep -q ACTIONS_RUNNER_INPUT_TOKEN /work/svc-env.log 2>/dev/null && [ -f /work/svc-env.log ] \
  && ok "the runner service is installed without the token variable" || bad "svc.sh env" "variable present or svc.sh not run"
[ ! -e /work/guest/root/register.sh ] && [ ! -e /work/stage/register.sh ] \
  && ok "no registration script is left in the guest or the staging directory" || bad "scripts removed" "$(ls /work/guest/root /work/stage 2>&1)"
grep -q 'ghrunner' /work/ps.log && grep -q 'config.sh' /work/ps.log \
  && ok "the sampler observed the guest processes (the absence above is meaningful)" || bad "sampler coverage" "config.sh never sampled"

echo "── b. registration, token typed at the hidden prompt ──"
reset_state; T2="SYNTHETICpromptTOKEN$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
rm -f /work/in.fifo; mkfifo /work/in.fifo; sample_start "$T2"
( cd /repo && script -qfec "ansible-playbook tests/ci-runner-token.yml -e entry=register" /work/typescript ) < /work/in.fifo > /dev/null 2>&1 &
SPID=$!
exec 7>/work/in.fifo
for _ in $(seq 1 150); do grep -q 'input is hidden' /work/typescript 2>/dev/null && break; sleep 0.2; done
sleep 0.5; printf '%s\r' "$T2" >&7
wait "$SPID"; rc=$?; exec 7>&-; sample_stop
cp /work/typescript /work/out.log
L=$(leaks "$T2")
[ $rc -eq 0 ] && ok "the prompt path registers" || bad "prompt path" "$(tail -5 /work/typescript)"
[ -z "$L" ] && ok "the typed token is not echoed or leaked anywhere (terminal transcript included)" || bad "no leak (prompt)" "$L"
[ "$(cat /work/config-token.sha 2>/dev/null)" = "$(sha_of "$T2")" ] && ok "config.sh received the prompted token" || bad "prompted token delivered" "sha mismatch"

echo "── c. refusals, before anything reaches the host ──"
reset_state; T3="SYNTHETICcliTOKEN$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
run_play register -e ci_runner_token="$T3"; rc=$?
[ $rc -ne 0 ] && grep -q 'exposes the token in process arguments' /work/out.log \
  && ok "-e ci_runner_token is refused with a disclose-and-regenerate message" || bad "-e refused" "rc=$rc"
( grep -F -- "$T3" /work/out.log | grep -v '^Using\|ansible-playbook' ) >/dev/null \
  && bad "refusal does not print the token" "$(grep -nF -- "$T3" /work/out.log | head -2)" || ok "the refusal does not print the token"
[ ! -e /work/config-token.sha ] && [ ! -e /work/lxc-argv.log ] && ok "nothing was sent to the guest" || bad "nothing sent" "lxc was called"

reset_state
ANSIBLE_KEEP_REMOTE_FILES=1 CI_RUNNER_TOKEN="$T1" run_play register; rc=$?
[ $rc -ne 0 ] && grep -q 'ANSIBLE_KEEP_REMOTE_FILES is set' /work/out.log && [ ! -e /work/lxc-argv.log ] \
  && ok "ANSIBLE_KEEP_REMOTE_FILES is refused before sending" || bad "keep-remote-files refused" "rc=$rc"

reset_state
CI_RUNNER_TOKEN="$T1" run_play register -e ansible_pipelining=false; rc=$?
[ $rc -ne 0 ] && grep -q 'Modules are not being pipelined' /work/out.log && [ ! -e /work/lxc-argv.log ] \
  && ok "-e ansible_pipelining=false is refused before sending" || bad "pipelining-off refused" "rc=$rc"

reset_state
run_play register; rc=$?
[ $rc -ne 0 ] && grep -q 'No usable registration token' /work/out.log && [ ! -e /work/lxc-argv.log ] \
  && ok "no token (non-interactive) is refused" || bad "missing token refused" "rc=$rc $(grep msg /work/out.log | head -2)"

reset_state; T4="bad token with spaces $(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n')"
CI_RUNNER_TOKEN="$T4" run_play register; rc=$?
[ $rc -ne 0 ] && ! grep -qF -- "$T4" /work/out.log && [ ! -e /work/lxc-argv.log ] \
  && ok "a malformed token is refused without being printed" || bad "malformed refused" "rc=$rc"

echo "── d. a failed registration still cleans up, and says so safely ──"
reset_state; touch /work/fail-config; sample_start "$T1"
CI_RUNNER_TOKEN="$T1" run_play register; rc=$?; sample_stop
L=$(leaks "$T1")
[ $rc -ne 0 ] && grep -q 'Registration failed (exit 1)' /work/out.log \
  && ok "the failure is reported with its exit code and the runner's (masked) message" || bad "failure reported" "rc=$rc"
grep -q 'Unauthorized' /work/out.log && ok "the runner's own error text reaches the operator" || bad "error text shown" "missing"
[ ! -e /work/guest/root/register.sh ] && [ ! -e /work/stage/register.sh ] \
  && ok "the scripts are removed after the failure" || bad "cleanup after failure" "$(ls /work/guest/root /work/stage 2>&1)"
[ -z "$L" ] && ok "no leak on the failure path" || bad "no leak (failure)" "$L"

echo "── e. removal ──"
reset_state; echo '{"agentName":"dc1-ci-synthetic"}' > /work/guest/home/ghrunner/actions-runner/.runner
T5="SYNTHETICremovalTOKEN$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"; sample_start "$T5"
CI_RUNNER_REMOVAL_TOKEN="$T5" run_play unregister; rc=$?; sample_stop
L=$(leaks "$T5")
[ $rc -eq 0 ] && grep -q ' remove$' /work/config-argv.log \
  && ok "the real unregister.yml removes the runner (config.sh remove, no --token)" || bad "unregister" "rc=$rc $(cat /work/config-argv.log 2>/dev/null)"
[ "$(cat /work/config-token.sha 2>/dev/null)" = "$(sha_of "$T5")" ] && ok "the removal token arrived by environment only" || bad "removal token delivered" "sha mismatch"
[ -z "$L" ] && ok "no leak on removal" || bad "no leak (removal)" "$L"
reset_state
run_play unregister -e ci_runner_removal_token="$T5"; rc=$?
[ $rc -ne 0 ] && grep -q 'exposes the token in process arguments' /work/out.log \
  && ok "-e ci_runner_removal_token is refused" || bad "-e removal refused" "rc=$rc"

echo "── f. the temp-file sampler is sensitive (negative control) ──"
# Configuration-level ANSIBLE_PIPELINING=False is outranked by the task's own
# ansible_pipelining: the registration still streams the module.
reset_state; sample_start "$T1"
ANSIBLE_PIPELINING=False CI_RUNNER_TOKEN="$T1" run_play register; rc=$?; sample_stop
[ $rc -eq 0 ] && [ ! -s /work/rtmp-hits ] \
  && ok "ANSIBLE_PIPELINING=False in the environment is overridden by the task (no module file holds the token)" \
  || bad "config-level pipelining off" "rc=$rc hits=$(head -1 /work/rtmp-hits 2>/dev/null)"
# Control: a module carrying the same value WITHOUT pipelining is written to
# the temp directory, and the same sampler sees it. Without this, "no hits"
# above could just mean the sampler looks in the wrong place.
reset_state; sample_start "$T1"
( cd /repo && ansible localhost -c local -e ansible_pipelining=false -e ansible_become=false \
    -m ansible.builtin.command -a "argv=['sleep','1'] stdin=$T1" ) > /dev/null 2>&1 </dev/null
sample_stop
[ -s /work/rtmp-hits ] && ok "control: without pipelining the sampler DOES find the value in a module file" \
  || bad "control sensitivity" "sampler found nothing with pipelining off; the absence checks above would prove less"

printf '── token handling: %d passed, %d failed ──\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
