#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/board/spacemit_k1_bpi_f3/prepare_k1_bianbu_buildroot_2_2.sh \
    [--sdk-root <path>] \
    [--sync-jobs <n>] \
    [--skip-sync] \
    [--verify-only]

Purpose:
  Prepare a fresh official K1 Buildroot SDK checkout so it matches the current
  ACT4 workspace baseline used by this project.

Behavior:
  - Initializes the official repo manifest when the target SDK directory does
    not exist yet.
  - Optionally runs repo sync.
  - Replays the patch series stored in this repository onto:
      * bsp-src/opensbi
      * bsp-src/uboot-2022.10
      * buildroot-ext
  - Leaves the SDK in a clean state on local prepared branches
    named act4-k1-sdk-prepared.

Options:
  --sdk-root <path>   Target SDK root. Default: <workspace-root>/buildroot-sdk-2.2
  --sync-jobs <n>     repo sync parallel jobs. Default: nproc or 8
  --skip-sync         Skip repo sync when the SDK is already initialized.
  --verify-only       Check whether the SDK already matches the expected state.

Notes:
  - This script prepares source changes only. It does not build or flash.
  - Run this on the Linux host, not inside the rvtest container.
  - The target SDK tree must be clean before patches are applied.
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd -- "${REPO_ROOT}/.." && pwd)"
PATCH_ROOT="${SCRIPT_DIR}/buildroot_sdk_2_2_patch_series"
DEFAULT_SDK_ROOT="${WORKSPACE_ROOT}/buildroot-sdk-2.2"

MANIFEST_URL="git@github.com:spacemit-com/manifests.git"
MANIFEST_BRANCH="main"
MANIFEST_FILE="k1-bl-v2.2.y.xml"
PREPARED_BRANCH="act4-k1-sdk-prepared"
PREPARE_GIT_NAME="ACT4 K1 SDK Prepare Script"
PREPARE_GIT_EMAIL="act4-k1-sdk-prepare@local"

SDK_ROOT="${DEFAULT_SDK_ROOT}"
SYNC_JOBS="$(command -v nproc >/dev/null 2>&1 && nproc || echo 8)"
SKIP_SYNC=0
VERIFY_ONLY=0

log() {
  printf '[prepare-k1-sdk] %s\n' "$*"
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_tool() {
  local tool="$1"
  command -v "${tool}" >/dev/null 2>&1 || die "required tool not found: ${tool}"
}

abs_path() {
  python3 - "$1" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
}

patch_file() {
  printf '%s/%s\n' "${PATCH_ROOT}" "$1"
}

ensure_patch_input() {
  local path="$1"
  [[ -f "${path}" ]] || die "patch input not found: ${path}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sdk-root)
      SDK_ROOT="${2:-}"
      shift 2
      ;;
    --sync-jobs)
      SYNC_JOBS="${2:-}"
      shift 2
      ;;
    --skip-sync)
      SKIP_SYNC=1
      shift
      ;;
    --verify-only)
      VERIFY_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ "${SYNC_JOBS}" =~ ^[0-9]+$ ]] || die "invalid --sync-jobs value: ${SYNC_JOBS}"

require_tool repo
require_tool git
require_tool python3

SDK_ROOT="$(abs_path "${SDK_ROOT}")"

OPENSBI_PATCHES=(
  "$(patch_file "opensbi/0001-opensbi-support-k1-scheduler-m-mode-handoff.patch")"
  "$(patch_file "opensbi/0002-opensbi-stop-forcing-scheduler-next-mode.patch")"
  "$(patch_file "opensbi/0003-opensbi-enable-logging-in-k1-defconfig.patch")"
)

UBOOT_MBOX_PATCHES=(
  "$(patch_file "uboot-2022.10/0001-k1-add-scheduler-m-mode-handoff-support.patch")"
)
UBOOT_LOCAL_PATCH="$(patch_file "uboot-2022.10/0002-k1-local-highaddr-secondary-image-followups.patch")"
UBOOT_LOCAL_MSG="$(patch_file "uboot-2022.10/0002-k1-local-highaddr-secondary-image-followups.commitmsg")"

BUILDROOT_EXT_MBOX_PATCHES=(
  "$(patch_file "buildroot-ext/0001-k1-enlarge-uboot-partition-in-sd-image.patch")"
  "$(patch_file "buildroot-ext/0002-k1-v2-enable-scheduler-m-mode-boot-flags.patch")"
)
BUILDROOT_EXT_LOCAL_PATCH="$(patch_file "buildroot-ext/0003-k1-local-sdk-alignment.patch")"
BUILDROOT_EXT_LOCAL_MSG="$(patch_file "buildroot-ext/0003-k1-local-sdk-alignment.commitmsg")"

for patch in \
  "${OPENSBI_PATCHES[@]}" \
  "${UBOOT_MBOX_PATCHES[@]}" \
  "${UBOOT_LOCAL_PATCH}" \
  "${UBOOT_LOCAL_MSG}" \
  "${BUILDROOT_EXT_MBOX_PATCHES[@]}" \
  "${BUILDROOT_EXT_LOCAL_PATCH}" \
  "${BUILDROOT_EXT_LOCAL_MSG}"
do
  ensure_patch_input "${patch}"
done

ensure_sdk_checkout() {
  local need_sync=0

  mkdir -p "${SDK_ROOT}"
  if [[ ! -d "${SDK_ROOT}/.repo" ]]; then
    log "Initializing SDK manifest in ${SDK_ROOT}"
    (
      cd "${SDK_ROOT}"
      repo init -u "${MANIFEST_URL}" -b "${MANIFEST_BRANCH}" -m "${MANIFEST_FILE}"
    )
    need_sync=1
  fi

  if [[ "${SKIP_SYNC}" -eq 0 || "${need_sync}" -eq 1 ]]; then
    log "Syncing SDK sources"
    (
      cd "${SDK_ROOT}"
      repo sync -j "${SYNC_JOBS}"
    )
  else
    log "Skipping repo sync as requested"
  fi
}

ensure_clean_repo() {
  local repo_dir="$1"
  if [[ -n "$(git -C "${repo_dir}" status --porcelain)" ]]; then
    die "target repo is not clean: ${repo_dir}"
  fi
}

verify_repo_state() {
  local repo_dir="$1"
  local base_ref="$2"
  shift 2
  local expected=("$@")
  local actual=()
  local i

  if [[ -n "$(git -C "${repo_dir}" status --porcelain)" ]]; then
    return 1
  fi

  if ! git -C "${repo_dir}" merge-base --is-ancestor "${base_ref}" HEAD >/dev/null 2>&1; then
    return 1
  fi

  mapfile -t actual < <(git -C "${repo_dir}" log --reverse --format=%s "${base_ref}..HEAD")

  if [[ "${#actual[@]}" -ne "${#expected[@]}" ]]; then
    return 1
  fi

  for ((i = 0; i < ${#expected[@]}; ++i)); do
    [[ "${actual[i]}" == "${expected[i]}" ]] || return 1
  done

  return 0
}

prepare_repo_branch() {
  local repo_dir="$1"
  local base_ref="$2"
  local current_head
  local base_head
  local current_branch

  current_head="$(git -C "${repo_dir}" rev-parse HEAD)"
  base_head="$(git -C "${repo_dir}" rev-parse "${base_ref}")"
  current_branch="$(git -C "${repo_dir}" branch --show-current || true)"

  if [[ "${current_head}" != "${base_head}" ]]; then
    die "repo is not at the expected base ref ${base_ref}: ${repo_dir}"
  fi

  if git -C "${repo_dir}" show-ref --verify --quiet "refs/heads/${PREPARED_BRANCH}" &&
     [[ "${current_branch}" != "${PREPARED_BRANCH}" ]]; then
    die "prepared branch already exists in ${repo_dir}; use a fresh SDK tree or remove it manually"
  fi

  if [[ "${current_branch}" != "${PREPARED_BRANCH}" ]]; then
    git -C "${repo_dir}" checkout -b "${PREPARED_BRANCH}"
  fi
}

apply_mbox_series() {
  local repo_dir="$1"
  shift
  local patch
  for patch in "$@"; do
    git -C "${repo_dir}" \
      -c user.name="${PREPARE_GIT_NAME}" \
      -c user.email="${PREPARE_GIT_EMAIL}" \
      am "${patch}"
  done
}

apply_local_diff_commit() {
  local repo_dir="$1"
  local patch_path="$2"
  local msg_path="$3"

  if [[ ! -s "${patch_path}" ]]; then
    return 0
  fi

  git -C "${repo_dir}" apply --index "${patch_path}"
  git -C "${repo_dir}" \
    -c user.name="${PREPARE_GIT_NAME}" \
    -c user.email="${PREPARE_GIT_EMAIL}" \
    commit -m "$(<"${msg_path}")"
}

print_repo_summary() {
  local label="$1"
  local repo_dir="$2"
  printf '  %-14s branch=%s head=%s\n' \
    "${label}" \
    "$(git -C "${repo_dir}" branch --show-current || echo detached)" \
    "$(git -C "${repo_dir}" rev-parse --short HEAD)"
}

prepare_opensbi() {
  local repo_dir="${SDK_ROOT}/bsp-src/opensbi"
  local base_ref="origin/k1-bl-v2.2.y"
  local expected=(
    "opensbi: support k1 scheduler m-mode handoff"
    "opensbi: stop forcing scheduler next mode"
    "opensbi: enable logging in k1 defconfig"
  )

  if verify_repo_state "${repo_dir}" "${base_ref}" "${expected[@]}"; then
    log "opensbi already matches the expected state"
    return 0
  fi

  [[ "${VERIFY_ONLY}" -eq 0 ]] || die "opensbi does not match the expected prepared state"

  ensure_clean_repo "${repo_dir}"
  prepare_repo_branch "${repo_dir}" "${base_ref}"
  apply_mbox_series "${repo_dir}" "${OPENSBI_PATCHES[@]}"
  verify_repo_state "${repo_dir}" "${base_ref}" "${expected[@]}" ||
    die "opensbi verification failed after patch replay"
}

prepare_uboot() {
  local repo_dir="${SDK_ROOT}/bsp-src/uboot-2022.10"
  local base_ref="origin/k1-bl-v2.2.y"
  local expected=(
    "k1: add scheduler m-mode handoff support"
    "k1: local highaddr secondary-image followups"
  )

  if verify_repo_state "${repo_dir}" "${base_ref}" "${expected[@]}"; then
    log "uboot-2022.10 already matches the expected state"
    return 0
  fi

  [[ "${VERIFY_ONLY}" -eq 0 ]] || die "uboot-2022.10 does not match the expected prepared state"

  ensure_clean_repo "${repo_dir}"
  prepare_repo_branch "${repo_dir}" "${base_ref}"
  apply_mbox_series "${repo_dir}" "${UBOOT_MBOX_PATCHES[@]}"
  apply_local_diff_commit "${repo_dir}" "${UBOOT_LOCAL_PATCH}" "${UBOOT_LOCAL_MSG}"
  verify_repo_state "${repo_dir}" "${base_ref}" "${expected[@]}" ||
    die "uboot-2022.10 verification failed after patch replay"
}

prepare_buildroot_ext() {
  local repo_dir="${SDK_ROOT}/buildroot-ext"
  local base_ref="origin/k1-bl-v2.2.y"
  local expected=(
    "k1: enlarge uboot partition in sd image"
    "k1_v2: enable scheduler m-mode boot flags"
    "k1_v2: local buildroot-ext scheduler image sizing followups"
  )

  if verify_repo_state "${repo_dir}" "${base_ref}" "${expected[@]}"; then
    log "buildroot-ext already matches the expected state"
    return 0
  fi

  [[ "${VERIFY_ONLY}" -eq 0 ]] || die "buildroot-ext does not match the expected prepared state"

  ensure_clean_repo "${repo_dir}"
  prepare_repo_branch "${repo_dir}" "${base_ref}"
  apply_mbox_series "${repo_dir}" "${BUILDROOT_EXT_MBOX_PATCHES[@]}"
  apply_local_diff_commit "${repo_dir}" "${BUILDROOT_EXT_LOCAL_PATCH}" "${BUILDROOT_EXT_LOCAL_MSG}"
  verify_repo_state "${repo_dir}" "${base_ref}" "${expected[@]}" ||
    die "buildroot-ext verification failed after patch replay"
}

main() {
  ensure_sdk_checkout

  prepare_opensbi
  prepare_uboot
  prepare_buildroot_ext

  log "SDK state is ready"
  print_repo_summary "opensbi" "${SDK_ROOT}/bsp-src/opensbi"
  print_repo_summary "uboot-2022.10" "${SDK_ROOT}/bsp-src/uboot-2022.10"
  print_repo_summary "buildroot-ext" "${SDK_ROOT}/buildroot-ext"

  log "repo status:"
  (
    cd "${SDK_ROOT}"
    repo status
  )

  if [[ "${VERIFY_ONLY}" -eq 1 ]]; then
    log "Verification succeeded."
  else
    cat <<EOF

Next:
  cd ${SDK_ROOT}
  make BATCH_MODE=1 k1_v2-build

Key output:
  ${SDK_ROOT}/output/k1_v2/images/FSBL.bin
  ${SDK_ROOT}/output/k1_v2/images/fw_dynamic.itb
  ${SDK_ROOT}/output/k1_v2/images/u-boot.itb
  ${SDK_ROOT}/output/k1_v2/images/buildroot-k1_v2-sdcard.img
EOF
  fi
}

main "$@"
