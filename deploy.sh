#!/usr/bin/env bash
# Commit one image version to alchemmist/homelab.
#
# actions/checkout@v4 (tag v4, 11d5960) writes a 0600 key and persists
# core.sshCommand. It does not set IdentitiesOnly, BatchMode, or ConnectTimeout,
# and it retries only its own fetch. LMS run 41811725828 reached GitHub SSH:
# ls-remote returned publickey, the built-in retry fetched main, then
# git pull --rebase failed the same way with no retry. Port 22 was not blocked,
# so this step does not switch to ssh.github.com:443. It uses the deploy key
# file directly, ignores ssh-agent, and retries transport failures. A rejected
# push rebases that same commit. A commit that is already on main is left there.
set -euo pipefail

key_dir=""
key_file=""
known_hosts_file=""
homelab_dir=""
connect_timeout="${SOCRAT_CONNECT_TIMEOUT:-15}"
max_attempts="${SOCRAT_MAX_ATTEMPTS:-3}"
retry_sleep="${SOCRAT_RETRY_SLEEP:-5}"
git_timeout="${SOCRAT_GIT_TIMEOUT:-90}"

remove_secrets() {
  if [[ -n ${homelab_dir} && -d ${homelab_dir}/.git ]]; then
    git -C "$homelab_dir" config --unset-all core.sshCommand >/dev/null 2>&1 || true
  fi
  case "$key_dir" in
    */socrat-deploy-key.*)
      rm -rf -- "$key_dir"
      ;;
    "")
      ;;
    *)
      echo "Refusing to remove unexpected key directory." >&2
      ;;
  esac
  key_dir=""
  key_file=""
  known_hosts_file=""
}

cleanup() {
  local status=$?
  remove_secrets
  exit "$status"
}

run_bounded() {
  local seconds="$1"
  shift
  if [[ -z ${SOCRAT_DISABLE_TIMEOUT:-} ]] && command -v timeout >/dev/null 2>&1; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

transport_failure() {
  local status="$1"
  local text="$2"
  if [[ "$status" -eq 124 ]]; then
    return 0
  fi
  printf '%s\n' "$text" | grep -E -q \
    'Permission denied \(publickey\)|Could not read from remote repository|Connection timed out|Operation timed out|Connection reset by peer|Connection refused|kex_exchange_identification|Connection closed by|ssh: connect to host|Network is unreachable|Could not resolve hostname|Name or service not known|Temporary failure in name resolution|the remote end hung up unexpectedly|early EOF|Broken pipe|No route to host|unable to access|Could not resolve host|Recv failure|transfer closed|RPC failed|SSL connection|TLS'
}

classify_push_failure() {
  local text="$1"
  local status="$2"
  if [[ "$status" -eq 124 ]]; then
    printf 'transport\n'
    return 0
  fi
  if printf '%s\n' "$text" | grep -E -q 'non-fast-forward|\(fetch first\)|Updates were rejected because'; then
    printf 'rejected\n'
    return 0
  fi
  if transport_failure "$status" "$text"; then
    printf 'transport\n'
    return 0
  fi
  printf 'fatal\n'
}

retry_transport() {
  local attempt=1
  local delay="$retry_sleep"
  local out status
  while true; do
    set +e
    out=$(run_bounded "$git_timeout" "$@" 2>&1)
    status=$?
    set -e
    if [[ "$status" -eq 0 ]]; then
      printf '%s\n' "$out"
      return 0
    fi
    printf '%s\n' "$out" >&2
    if [[ "$attempt" -ge "$max_attempts" ]] || ! transport_failure "$status" "$out"; then
      return "$status"
    fi
    echo "Transient git transport error (attempt ${attempt}/${max_attempts}). Retrying in ${delay}s." >&2
    sleep "$delay"
    if [[ "$delay" -lt 20 ]]; then
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done
}

install_deploy_key() {
  local base="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
  key_dir=$(mktemp -d "${base}/socrat-deploy-key.XXXXXX")
  chmod 700 "$key_dir"
  key_file="${key_dir}/id"
  known_hosts_file="${key_dir}/known_hosts"
  python3 - "$key_file" <<'PY'
import os
import sys

path = sys.argv[1]
text = os.environ["HOMELAB_DEPLOY_KEY"].replace("\r", "").strip() + "\n"
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as handle:
    handle.write(text)
os.chmod(path, 0o600)
PY
  chmod 600 "$key_file"
  cp "${GITHUB_ACTION_PATH}/github_known_hosts" "$known_hosts_file"
  chmod 644 "$known_hosts_file"
  if ! grep -q 'PRIVATE KEY' "$key_file"; then
    echo "Deploy key is not a private key." >&2
    return 1
  fi
}

ssh_command_string() {
  case "$key_file" in
    *\'* | *[[:space:]]*)
      echo "Refusing unusual deploy key path." >&2
      return 1
      ;;
  esac
  case "$known_hosts_file" in
    *\'* | *[[:space:]]*)
      echo "Refusing unusual known_hosts path." >&2
      return 1
      ;;
  esac
  case "$connect_timeout" in
    '' | *[!0-9]*)
      echo "ConnectTimeout must be a whole number of seconds." >&2
      return 1
      ;;
  esac
  printf "ssh -i '%s' -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes -o ConnectTimeout=%s -o ConnectionAttempts=1 -o StrictHostKeyChecking=yes -o CheckHostIP=no -o UserKnownHostsFile='%s' -o GlobalKnownHostsFile=/dev/null -o UpdateHostKeys=no -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o NumberOfPasswordPrompts=0 -o GSSAPIAuthentication=no" \
    "$key_file" "$connect_timeout" "$known_hosts_file"
}

configure_ssh() {
  # IdentityAgent=none and an explicit IdentityFile keep a stuck ssh-agent out
  # of authentication. IdentitiesOnly stops extra keys from being offered.
  unset SSH_AUTH_SOCK SSH_AGENT_PID || true
  export GIT_TERMINAL_PROMPT=0
  GIT_SSH_COMMAND=$(ssh_command_string)
  export GIT_SSH_COMMAND
}

use_safe_directory() {
  local index="${GIT_CONFIG_COUNT:-0}"
  export GIT_CONFIG_COUNT=$((index + 1))
  export "GIT_CONFIG_KEY_${index}=safe.directory"
  export "GIT_CONFIG_VALUE_${index}=${homelab_dir}"
}

prepare_homelab() {
  homelab_dir="${GITHUB_WORKSPACE}/.socrat-homelab"
  if [[ -z ${GITHUB_WORKSPACE} || "$homelab_dir" == "/.socrat-homelab" ]]; then
    echo "Refusing to prepare homelab checkout." >&2
    return 1
  fi
  rm -rf -- "$homelab_dir"
  use_safe_directory
  git init -b main "$homelab_dir"
  git -C "$homelab_dir" config user.name "socrat-releaser"
  git -C "$homelab_dir" config user.email "41898282+socrat-releaser@users.noreply.github.com"
  git -C "$homelab_dir" config commit.gpgsign false
  git -C "$homelab_dir" config core.sshCommand "$GIT_SSH_COMMAND"
  git -C "$homelab_dir" remote add origin git@github.com:alchemmist/homelab.git
  retry_transport git -C "$homelab_dir" fetch --no-tags --prune origin +refs/heads/main:refs/remotes/origin/main
  git -C "$homelab_dir" checkout -B main refs/remotes/origin/main
}

remote_contains_head() {
  git -C "$homelab_dir" merge-base --is-ancestor HEAD origin/main
}

fetch_origin_main() {
  run_bounded "$git_timeout" git -C "$homelab_dir" fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main
}

push_main() {
  local attempt=1
  local rebases=0
  local delay="$retry_sleep"
  local out status kind fetched
  while [[ "$attempt" -le "$max_attempts" ]]; do
    set +e
    out=$(run_bounded "$git_timeout" git -C "$homelab_dir" push origin HEAD:main 2>&1)
    status=$?
    set -e
    printf '%s\n' "$out"
    if [[ "$status" -eq 0 ]]; then
      return 0
    fi

    fetched=0
    if fetch_origin_main; then
      fetched=1
      if remote_contains_head; then
        echo "origin/main already contains this commit."
        return 0
      fi
    fi

    kind=$(classify_push_failure "$out" "$status")
    case "$kind" in
      fatal)
        echo "Push failed and will not be retried." >&2
        return "$status"
        ;;
      rejected)
        if [[ "$fetched" -ne 1 ]]; then
          echo "Could not fetch origin/main after a rejected push." >&2
          return 1
        fi
        if [[ "$rebases" -ge 2 ]]; then
          echo "origin/main kept moving. Not creating another commit." >&2
          return 1
        fi
        rebases=$((rebases + 1))
        echo "Push rejected because origin/main moved. Rebasing this commit." >&2
        if ! git -C "$homelab_dir" rebase origin/main; then
          git -C "$homelab_dir" rebase --abort || true
          echo "Rebase onto origin/main conflicted. Not creating another commit." >&2
          return 1
        fi
        if remote_contains_head; then
          echo "Change is already on origin/main."
          return 0
        fi
        continue
        ;;
      transport)
        echo "Transient git transport error while pushing (attempt ${attempt}/${max_attempts})." >&2
        ;;
    esac

    if [[ "$attempt" -ge "$max_attempts" ]]; then
      return "$status"
    fi
    sleep "$delay"
    if [[ "$delay" -lt 20 ]]; then
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done
  return 1
}

commit_image_version() {
  python3 "${GITHUB_ACTION_PATH}/deploy.py" "$homelab_dir" "$APP" "$IMAGE_VERSION" "$GITHUB_SHA" "$COMPONENT"
  if git -C "$homelab_dir" diff --quiet; then
    echo "No values change."
    return 0
  fi
  git -C "$homelab_dir" add -- "deploy/${APP}/values.yaml"
  if [[ -f "${homelab_dir}/charts/${APP}/values.yaml" ]]; then
    git -C "$homelab_dir" add -- "charts/${APP}/values.yaml"
  fi
  git -C "$homelab_dir" commit \
    -m "chore(${APP}): deploy ${IMAGE_VERSION}" \
    -m "Source: ${GITHUB_REPOSITORY}@${GITHUB_SHA}"
  push_main
}

require_number() {
  local name="$1"
  local value="$2"
  local max="$3"
  case "$value" in
    '' | *[!0-9]*)
      echo "${name} must be a whole number." >&2
      exit 1
      ;;
  esac
  if [[ "$value" -lt 1 || "$value" -gt "$max" ]]; then
    echo "${name} must be from 1 to ${max}." >&2
    exit 1
  fi
}

main() {
  : "${APP:?missing app}"
  : "${IMAGE_VERSION:?missing image_version}"
  : "${GITHUB_SHA:?missing GITHUB_SHA}"
  : "${GITHUB_REPOSITORY:?missing GITHUB_REPOSITORY}"
  : "${GITHUB_REF_NAME:?missing GITHUB_REF_NAME}"
  : "${GITHUB_WORKSPACE:?missing GITHUB_WORKSPACE}"
  : "${GITHUB_ACTION_PATH:?missing GITHUB_ACTION_PATH}"
  : "${HOMELAB_DEPLOY_KEY:?missing deploy key}"
  COMPONENT="${COMPONENT:-}"
  require_number SOCRAT_MAX_ATTEMPTS "$max_attempts" 5
  require_number SOCRAT_CONNECT_TIMEOUT "$connect_timeout" 60
  require_number SOCRAT_GIT_TIMEOUT "$git_timeout" 180
  case "$retry_sleep" in
    '' | *[!0-9]*)
      echo "SOCRAT_RETRY_SLEEP must be a whole number." >&2
      exit 1
      ;;
  esac
  if [[ "$retry_sleep" -gt 30 ]]; then
    echo "SOCRAT_RETRY_SLEEP must be from 0 to 30." >&2
    exit 1
  fi

  trap cleanup EXIT

  local latest raw
  if ! raw=$(retry_transport git ls-remote "https://github.com/${GITHUB_REPOSITORY}.git" "refs/heads/${GITHUB_REF_NAME}"); then
    echo "Could not read ${GITHUB_REF_NAME} from ${GITHUB_REPOSITORY}." >&2
    exit 1
  fi
  latest=$(printf '%s\n' "$raw" | awk 'NR == 1 { print $1 }')
  if [[ -n "$latest" && "$GITHUB_SHA" != "$latest" ]]; then
    echo "Skipping stale build ${GITHUB_SHA}; ${GITHUB_REF_NAME} is ${latest}."
    exit 0
  fi

  install_deploy_key
  configure_ssh
  prepare_homelab
  export GIT_AUTHOR_NAME="socrat-releaser"
  export GIT_AUTHOR_EMAIL="41898282+socrat-releaser@users.noreply.github.com"
  export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
  export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"
  commit_image_version
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
