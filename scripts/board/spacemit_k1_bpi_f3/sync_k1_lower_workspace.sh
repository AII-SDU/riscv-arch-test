#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/board/spacemit_k1_bpi_f3/sync_k1_lower_workspace.sh push [--delete]
  bash scripts/board/spacemit_k1_bpi_f3/sync_k1_lower_workspace.sh pull [--suite-artifacts <suite-name>]

Purpose:
  Sync the active K1 lower-machine workspace between the server and the lower
  machine. The lower machine keeps a plain source tree without .git history.

Modes:
  push  Sync the server source tree and the minimal K1 SDK artifacts to the
        lower machine.
  pull  Pull lower-machine source edits and K1 logs back to the server.

Environment:
  K1_LOWER_HOST      Lower machine host (default: localhost)
  K1_LOWER_SSH_PORT  Lower machine SSH port (default: 2222)
  K1_LOWER_USER      Lower machine user (default: codex)
  K1_LOWER_SSH_KEY   SSH private key for lower-machine login
                     (default: ~/.ssh/k1_lower_ed25519)
  K1_LOWER_ROOT      Lower-machine workspace root (default: /home/codex/rvtest)
  K1_SYNC_STATE_ROOT Server-side sync state root
                     (default: <workspace-root>/logs/k1-lower-sync)

Notes:
  - This script runs on the server, not on the lower machine.
  - Source sync excludes .git, work/, logs/, delivery/, caches, and .trash.
  - SDK sync only includes:
      buildroot-sdk-2.2/output/k1_v2/images/FSBL.bin
      buildroot-sdk-2.2/output/k1_v2/images/fw_dynamic.itb
      buildroot-sdk-2.2/output/k1_v2/build/uboot-custom/arch/riscv/dts/k1-x_deb1.dtb
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd -- "${REPO_ROOT}/.." && pwd)"

K1_LOWER_HOST="${K1_LOWER_HOST:-localhost}"
K1_LOWER_SSH_PORT="${K1_LOWER_SSH_PORT:-2222}"
K1_LOWER_USER="${K1_LOWER_USER:-codex}"
K1_LOWER_SSH_KEY="${K1_LOWER_SSH_KEY:-${HOME}/.ssh/k1_lower_ed25519}"
K1_LOWER_ROOT="${K1_LOWER_ROOT:-/home/codex/rvtest}"
K1_SYNC_STATE_ROOT="${K1_SYNC_STATE_ROOT:-${WORKSPACE_ROOT}/logs/k1-lower-sync}"

MODE="${1:-}"
DELETE_PUSH=0
SUITE_ARTIFACTS_NAME=""

shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --delete)
      DELETE_PUSH=1
      shift
      ;;
    --suite-artifacts)
      SUITE_ARTIFACTS_NAME="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "${MODE}" != "push" && "${MODE}" != "pull" ]]; then
  usage
  exit 1
fi

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required tool not found: $1" >&2
    exit 1
  }
}

require_tool git
require_tool rsync
require_tool ssh
require_tool python3

[[ -f "${K1_LOWER_SSH_KEY}" ]] || {
  echo "error: lower-machine SSH key not found: ${K1_LOWER_SSH_KEY}" >&2
  exit 1
}

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
STATE_DIR="${K1_SYNC_STATE_ROOT}/${TIMESTAMP}"
LATEST_LINK="${K1_SYNC_STATE_ROOT}/latest"

SSH_TARGET="${K1_LOWER_USER}@${K1_LOWER_HOST}"
SSH_OPTS=(
  -i "${K1_LOWER_SSH_KEY}"
  -o IdentitiesOnly=yes
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o LogLevel=ERROR
  -p "${K1_LOWER_SSH_PORT}"
)
RSYNC_SSH=(ssh "${SSH_OPTS[@]}")
printf -v RSYNC_RSH '%q ' "${RSYNC_SSH[@]}"

LOWER_REPO_ROOT="${K1_LOWER_ROOT}/riscv-arch-test-act4"
LOWER_SDK_ROOT="${K1_LOWER_ROOT}/buildroot-sdk-2.2"
LOWER_LOG_ROOT="${K1_LOWER_ROOT}/logs/k1-board"
LOWER_TRASH_ROOT="${K1_LOWER_ROOT}/.trash/lower-sync/${TIMESTAMP}"

SERVER_LOG_ROOT="${WORKSPACE_ROOT}/logs/k1-board"

SDK_FILES=(
  "buildroot-sdk-2.2/output/k1_v2/images/FSBL.bin"
  "buildroot-sdk-2.2/output/k1_v2/images/fw_dynamic.itb"
  "buildroot-sdk-2.2/output/k1_v2/build/uboot-custom/arch/riscv/dts/k1-x_deb1.dtb"
)

REPO_EXCLUDES=(
  ".git"
  ".git/"
  ".gitmodules"
  ".venv/"
  ".trash/"
  "work/"
  "logs/"
  "delivery/"
  "__pycache__/"
  ".pytest_cache/"
  ".ruff_cache/"
)

repo_rsync_args() {
  local mode="$1"
  local -a args=(
    -a
    --human-readable
    --itemize-changes
    --backup
    "--backup-dir=${2}"
  )
  if [[ "${mode}" == "mirror" ]]; then
    args+=(--delete)
  fi
  for pattern in "${REPO_EXCLUDES[@]}"; do
    args+=(--exclude="${pattern}")
  done
  printf '%s\n' "${args[@]}"
}

lower_run() {
  ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "bash -lc $(printf '%q' "$1")"
}

ensure_lower_layout() {
  lower_run "mkdir -p '${K1_LOWER_ROOT}' '${LOWER_LOG_ROOT}' '${LOWER_TRASH_ROOT}'"
}

write_sync_metadata() {
  mkdir -p "${STATE_DIR}"
  cat > "${STATE_DIR}/metadata.txt" <<EOF
mode=${MODE}
timestamp=${TIMESTAMP}
server_repo_root=${REPO_ROOT}
server_workspace_root=${WORKSPACE_ROOT}
lower_root=${K1_LOWER_ROOT}
lower_repo_root=${LOWER_REPO_ROOT}
lower_sdk_root=${LOWER_SDK_ROOT}
lower_log_root=${LOWER_LOG_ROOT}
EOF
}

record_pre_pull_dirty() {
  python3 - "${REPO_ROOT}" "${STATE_DIR}/pre_pull_dirty.txt" <<'PY'
import subprocess
import sys
from pathlib import Path

repo = Path(sys.argv[1])
out = Path(sys.argv[2])

def cmd(*args):
    return subprocess.check_output(args, cwd=repo, text=True).splitlines()

paths = set()
paths.update(p for p in cmd("git", "diff", "--name-only") if p)
paths.update(p for p in cmd("git", "diff", "--name-only", "--cached") if p)
paths.update(p for p in cmd("git", "ls-files", "--others", "--exclude-standard") if p)

out.write_text("".join(f"{p}\n" for p in sorted(paths)), encoding="utf-8")
PY
}

extract_pulled_paths() {
  python3 - "${STATE_DIR}/repo_rsync.log" "${STATE_DIR}/pulled_paths.txt" <<'PY'
import sys
from pathlib import Path

log_path = Path(sys.argv[1])
out_path = Path(sys.argv[2])

paths = set()
for raw in log_path.read_text(encoding="utf-8").splitlines():
    line = raw.strip()
    if not line:
        continue
    if line.startswith("receiving incremental file list"):
        continue
    if line.startswith("sent ") or line.startswith("total size is "):
        continue
    if line.startswith("./"):
        continue
    if line.startswith("*deleting "):
        candidate = line[len("*deleting "):].strip()
    else:
        parts = line.split(maxsplit=1)
        if len(parts) != 2:
            continue
        candidate = parts[1].strip()
    if not candidate or candidate.endswith("/"):
        continue
    paths.add(candidate)

out_path.write_text("".join(f"{p}\n" for p in sorted(paths)), encoding="utf-8")
PY
}

push_repo_tree() {
  local backup_dir="${LOWER_TRASH_ROOT}/repo-backup"
  lower_run "mkdir -p '${LOWER_REPO_ROOT}' '${backup_dir}'"

  local -a args=()
  mapfile -t args < <(repo_rsync_args "$([[ ${DELETE_PUSH} -eq 1 ]] && echo mirror || echo copy)" "${backup_dir}")

  rsync \
    "${args[@]}" \
    -e "${RSYNC_RSH}" \
    "${REPO_ROOT}/" \
    "${SSH_TARGET}:${LOWER_REPO_ROOT}/"

  lower_run "find '${LOWER_REPO_ROOT}' \\( -name '.git' -o -name '.gitmodules' \\) -print0 | xargs -0r rm -rf --"
}

push_sdk_files() {
  local sdk_rel src dest_dir backup_dir
  for sdk_rel in "${SDK_FILES[@]}"; do
    src="${WORKSPACE_ROOT}/${sdk_rel}"
    [[ -f "${src}" ]] || {
      echo "error: required SDK artifact not found: ${src}" >&2
      exit 1
    }
    dest_dir="${K1_LOWER_ROOT}/$(dirname "${sdk_rel}")"
    backup_dir="${LOWER_TRASH_ROOT}/sdk-backup/$(dirname "${sdk_rel}")"
    lower_run "mkdir -p '${dest_dir}' '${backup_dir}'"
    rsync \
      -a \
      --human-readable \
      --itemize-changes \
      --backup \
      "--backup-dir=${backup_dir}" \
      -e "${RSYNC_RSH}" \
      "${src}" \
      "${SSH_TARGET}:${dest_dir}/"
  done
}

pull_repo_tree() {
  local backup_dir="${STATE_DIR}/repo-backup"
  mkdir -p "${backup_dir}"
  local -a args=()
  mapfile -t args < <(repo_rsync_args "mirror" "${backup_dir}")

  rsync \
    "${args[@]}" \
    -e "${RSYNC_RSH}" \
    "${SSH_TARGET}:${LOWER_REPO_ROOT}/" \
    "${REPO_ROOT}/" | tee "${STATE_DIR}/repo_rsync.log"
}

pull_logs() {
  mkdir -p "${SERVER_LOG_ROOT}"
  rsync \
    -a \
    --human-readable \
    --itemize-changes \
    -e "${RSYNC_RSH}" \
    "${SSH_TARGET}:${LOWER_LOG_ROOT}/" \
    "${SERVER_LOG_ROOT}/" | tee "${STATE_DIR}/logs_rsync.log"
}

pull_suite_artifacts() {
  local suite_name="$1"
  local server_artifacts_dir="${STATE_DIR}/suite-artifacts/${suite_name}"
  mkdir -p "${server_artifacts_dir}"
  rsync \
    -a \
    --human-readable \
    --itemize-changes \
    -e "${RSYNC_RSH}" \
    "${SSH_TARGET}:${LOWER_REPO_ROOT}/work/spacemit-k1-bpi-f3-scheduler/${suite_name}/" \
    "${server_artifacts_dir}/" | tee "${STATE_DIR}/suite_artifacts_rsync.log"
}

update_latest_link() {
  mkdir -p "${K1_SYNC_STATE_ROOT}"
  ln -sfn "${STATE_DIR}" "${LATEST_LINK}"
}

main_push() {
  ensure_lower_layout
  mkdir -p "${STATE_DIR}"
  write_sync_metadata
  push_repo_tree
  push_sdk_files
  update_latest_link
  echo "Lower workspace push complete:"
  echo "  lower repo root: ${LOWER_REPO_ROOT}"
  echo "  lower sdk root:  ${LOWER_SDK_ROOT}"
  echo "  state dir:       ${STATE_DIR}"
}

main_pull() {
  ensure_lower_layout
  mkdir -p "${STATE_DIR}"
  write_sync_metadata
  record_pre_pull_dirty
  pull_repo_tree
  extract_pulled_paths
  pull_logs
  if [[ -n "${SUITE_ARTIFACTS_NAME}" ]]; then
    pull_suite_artifacts "${SUITE_ARTIFACTS_NAME}"
  fi
  update_latest_link
  echo "Lower workspace pull complete:"
  echo "  pulled paths: ${STATE_DIR}/pulled_paths.txt"
  echo "  pre-pull dirty: ${STATE_DIR}/pre_pull_dirty.txt"
  echo "  logs synced to: ${SERVER_LOG_ROOT}"
  if [[ -n "${SUITE_ARTIFACTS_NAME}" ]]; then
    echo "  suite artifacts: ${STATE_DIR}/suite-artifacts/${SUITE_ARTIFACTS_NAME}"
  fi
}

case "${MODE}" in
  push)
    main_push
    ;;
  pull)
    main_pull
    ;;
esac
