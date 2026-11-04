#!/usr/bin/env bash
# Static and unit checks for the homelab deploy action. No deploy key is used.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
cd "$root"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n deploy.sh
shellcheck deploy.sh test_static.sh

python3 - <<'PY'
import pathlib
import sys

text = pathlib.Path("action.yml").read_text()
steps = [line for line in text.splitlines() if line.startswith("    - ")]
if steps != ["    - name: Commit the image version"]:
    sys.exit(f"action.yml must have one composite step, found {steps!r}")
for forbidden in ("uses:", "actions/checkout", "ssh-agent", "persist-credentials"):
    if forbidden in text:
        sys.exit(f"action.yml still contains {forbidden}")
for required in (
    "token:",
    "image_version:",
    "app:",
    "component:",
    'default: ""',
    "HOMELAB_DEPLOY_KEY: ${{ inputs.token }}",
    'bash "$GITHUB_ACTION_PATH/deploy.sh"',
):
    if required not in text:
        sys.exit(f"action.yml missing {required}")
print("action.yml is one composite step")
PY

python3 - <<'PY'
import json
import os
import pathlib
import sys
import urllib.request

script = "\n".join(line for line in pathlib.Path("deploy.sh").read_text().splitlines() if not line.lstrip().startswith("#"))
if script.count('git -C "$homelab_dir" commit ' ) != 1:
    sys.exit("deploy.sh must create exactly one commit")
for required in (
    "IdentitiesOnly=yes",
    "IdentityAgent=none",
    "BatchMode=yes",
    "ConnectTimeout=",
    "GlobalKnownHostsFile=/dev/null",
    "StrictHostKeyChecking=yes",
    "chmod 600",
    "chmod 700",
    "unset SSH_AUTH_SOCK",
    "trap cleanup EXIT",
    "merge-base --is-ancestor",
    'git -C "$homelab_dir" rebase origin/main',
    "Not creating another commit.",
    "refs/heads/${GITHUB_REF_NAME}",
    '"$COMPONENT"',
    "socrat-releaser",
):
    if required not in script:
        sys.exit(f"deploy.sh missing {required}")
for forbidden in ("eval $(ssh-agent", "ssh.github.com", "Port 443", "uses: actions/checkout"):
    if forbidden in script:
        sys.exit(f"deploy.sh contains {forbidden}")

meta = json.load(urllib.request.urlopen("https://api.github.com/meta", timeout=30))
official = set()
for key in meta["ssh_keys"]:
    kind, blob = key.split()[:2]
    official.add(f"github.com {kind} {blob}")
pinned = set(pathlib.Path("github_known_hosts").read_text().strip().splitlines())
if pinned != official:
    sys.exit("pinned known_hosts does not match api.github.com/meta ssh_keys")
fingerprints = meta["ssh_key_fingerprints"]
expected = {
    "SHA256_ED25519": "+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU",
    "SHA256_ECDSA": "p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM",
    "SHA256_RSA": "uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s",
}
if fingerprints != expected:
    sys.exit(f"GitHub published unexpected host key fingerprints: {fingerprints}")
print("pinned known_hosts matches the official GitHub meta keys")
PY

ssh-keygen -lf github_known_hosts >/dev/null

# shellcheck source=deploy.sh
source deploy.sh

[[ $(classify_push_failure $'git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.' 128) == transport ]]
[[ $(classify_push_failure $'! [rejected] HEAD -> main (non-fast-forward)\nUpdates were rejected because the remote contains work that you do not have locally.' 1) == rejected ]]
[[ $(classify_push_failure $'! [rejected] HEAD -> main (fetch first)' 1) == rejected ]]
[[ $(classify_push_failure $'remote: error: GH006: Protected branch update failed\n! [remote rejected] HEAD -> main (protected branch hook declined)' 1) == fatal ]]
[[ $(classify_push_failure 'timed out waiting for lock' 124) == transport ]]

file_mode() {
  if stat -c '%a' "$1" >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%OLp' "$1"
  fi
}

export GITHUB_ACTION_PATH="$root"
export HOMELAB_DEPLOY_KEY=$'-----BEGIN OPENSSH PRIVATE KEY-----\nTESTKEYMATERIAL-not-a-real-key\n-----END OPENSSH PRIVATE KEY-----\n'
key_log=$(mktemp)
install_deploy_key > "$key_log"
key_output=$(cat "$key_log")
rm -f "$key_log"
if [[ "$key_output" == *TESTKEYMATERIAL* ]]; then
  fail "install_deploy_key printed the key"
fi
[[ $(file_mode "$key_dir") == 700 ]]
[[ $(file_mode "$key_file") == 600 ]]
[[ -O "$key_file" ]]
ssh_line=$(ssh_command_string)
[[ "$ssh_line" == *"IdentitiesOnly=yes"* ]]
[[ "$ssh_line" == *"BatchMode=yes"* ]]
[[ "$ssh_line" == *"ConnectTimeout=${connect_timeout}"* ]]
[[ "$ssh_line" == *"IdentityAgent=none"* ]]
[[ "$ssh_line" != *TESTKEYMATERIAL* ]]
remove_secrets
[[ ! -e ${key_file:-} ]]

export SOCRAT_DISABLE_TIMEOUT=1
export SOCRAT_RETRY_SLEEP=0
export SOCRAT_MAX_ATTEMPTS=3
max_attempts=3
retry_sleep=0
homelab_dir="${TMPDIR:-/tmp}/socrat-not-a-repo"

stub_git() {
  if [[ "$1" == "-C" ]]; then
    shift 2
  fi
  git_calls+="$1 "
  case "$1" in
    push)
      push_count=$(cat "$counter_file")
      push_count=$((push_count + 1))
      echo "$push_count" > "$counter_file"
      if [[ "$push_count" -le "${push_fail_until}" ]]; then
        printf '%s\n' "$push_fail_text"
        return "$push_fail_status"
      fi
      printf 'ok\n'
      return 0
      ;;
    fetch)
      return 0
      ;;
    merge-base)
      return "$merge_base_status"
      ;;
    rebase)
      rebase_count=$((rebase_count + 1))
      if [[ "${2:-}" == "--abort" ]]; then
        return 0
      fi
      return "$rebase_status"
      ;;
    commit)
      fail "push retry created another commit"
      ;;
    *)
      echo "unexpected git $*" >&2
      return 97
      ;;
  esac
}

run_push_case() {
  local name="$1"
  git_calls=""
  push_count=0
  counter_file=$(mktemp)
  echo 0 > "$counter_file"
  rebase_count=0
  git() { stub_git "$@"; }
  local status=0
  if push_main >/dev/null; then
    status=0
  else
    status=$?
  fi
  unset -f git
  push_count=$(cat "$counter_file")
  rm -f "$counter_file"
  if [[ "$status" != "$expect_status" ]]; then
    fail "$name status $status, calls: $git_calls"
  fi
  if [[ "$rebase_count" != "$expect_rebases" ]]; then
    fail "$name rebases $rebase_count, calls: $git_calls"
  fi
  if [[ "$push_count" != "$expect_pushes" ]]; then
    fail "$name pushes $push_count, calls: $git_calls"
  fi
  echo "push case: $name"
}

push_fail_until=1
push_fail_status=128
push_fail_text=$'git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.'
merge_base_status=0
rebase_status=0
expect_status=0
expect_rebases=0
expect_pushes=1
run_push_case "already on main after a transport error"

push_fail_until=1
merge_base_status=1
expect_status=0
expect_rebases=0
expect_pushes=2
run_push_case "retries publickey without rebasing or committing"

push_fail_until=1
push_fail_status=1
push_fail_text=$'! [rejected] HEAD -> main (non-fast-forward)\nUpdates were rejected because the remote contains work that you do not have locally.'
merge_base_status=1
expect_status=0
expect_rebases=1
expect_pushes=2
run_push_case "rebases the same commit after a rejected push"

push_fail_until=99
rebase_status=1
expect_status=1
expect_rebases=2
expect_pushes=1
run_push_case "stops on rebase conflict without another commit"

push_fail_until=99
push_fail_status=1
push_fail_text=$'remote: error: GH006: Protected branch update failed\n! [remote rejected] HEAD -> main (protected branch hook declined)'
rebase_status=0
expect_status=1
expect_rebases=0
expect_pushes=1
run_push_case "does not retry a protected branch rejection"

PYTHONDONTWRITEBYTECODE=1 python3 test_deploy.py
echo "all static and unit checks passed"
