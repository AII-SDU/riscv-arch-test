#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/board/spacemit_k1_bpi_f3/flash_k1_test_card.sh \
    [--fsbl <path-to-FSBL.bin>] \
    [--opensbi <path-to-fw_dynamic.itb>] \
    [--uboot-itb <path-to-u-boot.itb>] \
    [--env-bin <path-to-u-boot-env-default.bin>] \
    [--bootfs-tree <path-to-bootfs-tree>] \
    [--bootfs-verify-file <relative-path-under-bootfs-tree>] \
    [--bootfs-elf <path-to-test.elf>] \
    [--bootfs-dest <relative-path-under-bootfs>] \
    [--bootfs-purge-prefix <relative-prefix-under-bootfs>]

Environment:
  K1_LOWER_PASS         Optional local sudo password used for password-based sudo
  K1_LOWER_WORKDIR      Local work directory
                        (default: <workspace-root>/act_k1_bianbu22)
  K1_LOWER_FSBL_DEV     Local fsbl device (default: /dev/disk/by-partlabel/fsbl)
  K1_LOWER_OPENSBI_DEV  Local opensbi device (default: /dev/disk/by-partlabel/opensbi)
  K1_LOWER_UBOOT_DEV    Local uboot device (default: /dev/disk/by-partlabel/uboot)
  K1_LOWER_ENV_DEV      Local U-Boot env device (default: /dev/disk/by-partlabel/env)
  K1_LOWER_BOOTFS_DEV   Local bootfs device (default: /dev/disk/by-partlabel/bootfs)
  K1_LOWER_BOOTFS_MNT   Temporary local bootfs mountpoint
                        (default: <workspace-root>/act_k1_bianbu22/mnt/bootfs)

This script only supports local lower-host execution:
  lower Linux host -> local stage + local sudo write SD card
  all input artifacts must be readable directly on this host

At least one K1 board-test artifact must be specified.

Typical formal fake-u-boot FIT usage:
  --fsbl <FSBL.bin> --opensbi <fw_dynamic.itb> --uboot-itb <u-boot.itb> \
  --env-bin <u-boot-env-default.bin>

Optional bootfs staging:
  --bootfs-elf <I-add-00.elf> --bootfs-dest act-tests/I-add-00.elf

Optional batch campaign tree staging:
  --env-bin <u-boot-env-campaign.bin> --bootfs-tree <campaign-bootfs-dir> \
  --bootfs-purge-prefix act-campaign --bootfs-purge-prefix act-tests

Optional bootfs FIT suite staging:
  --env-bin <u-boot-env-suite.bin> --bootfs-tree <suite-bootfs-dir> \
  --bootfs-purge-prefix act-suite/<suite-name> \
  --bootfs-verify-file act-suite/<suite-name>/sha256.txt
EOF
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd "${REPO_ROOT}/.." && pwd)"

FSBL_INPUT=""
OPENSBI_INPUT=""
UBOOT_ITB_INPUT=""
ENV_BIN_INPUT=""
BOOTFS_TREE_INPUT=""
BOOTFS_VERIFY_FILE_INPUT=""
BOOTFS_ELF_INPUT=""
BOOTFS_DEST_INPUT=""
BOOTFS_PURGE_PREFIXES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --opensbi)
      OPENSBI_INPUT="${2:-}"
      shift 2
      ;;
    --fsbl)
      FSBL_INPUT="${2:-}"
      shift 2
      ;;
    --uboot-itb)
      UBOOT_ITB_INPUT="${2:-}"
      shift 2
      ;;
    --env-bin)
      ENV_BIN_INPUT="${2:-}"
      shift 2
      ;;
    --bootfs-tree)
      BOOTFS_TREE_INPUT="${2:-}"
      shift 2
      ;;
    --bootfs-verify-file)
      BOOTFS_VERIFY_FILE_INPUT="${2:-}"
      shift 2
      ;;
    --bootfs-elf)
      BOOTFS_ELF_INPUT="${2:-}"
      shift 2
      ;;
    --bootfs-dest)
      BOOTFS_DEST_INPUT="${2:-}"
      shift 2
      ;;
    --bootfs-purge-prefix)
      BOOTFS_PURGE_PREFIXES+=("${2:-}")
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

if [[ -z "${FSBL_INPUT}" && -z "${OPENSBI_INPUT}" && -z "${UBOOT_ITB_INPUT}" && -z "${ENV_BIN_INPUT}" && -z "${BOOTFS_TREE_INPUT}" && -z "${BOOTFS_ELF_INPUT}" ]]; then
  usage
  exit 1
fi

if [[ -n "${BOOTFS_TREE_INPUT}" && -n "${BOOTFS_ELF_INPUT}" ]]; then
  echo "error: --bootfs-tree and --bootfs-elf are mutually exclusive." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "error: required tool not found: python3" >&2
  exit 1
fi

abs_path() {
  python3 - "$1" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
}

require_readable_file() {
  local label="$1"
  local path="$2"

  [[ -f "${path}" ]] || {
    echo "error: ${label} not found: ${path}" >&2
    exit 1
  }
  [[ -r "${path}" ]] || {
    echo "error: ${label} is not readable on this host: ${path}" >&2
    exit 1
  }
}

require_readable_dir() {
  local label="$1"
  local path="$2"

  [[ -d "${path}" ]] || {
    echo "error: ${label} not found: ${path}" >&2
    exit 1
  }
  [[ -r "${path}" && -x "${path}" ]] || {
    echo "error: ${label} is not readable on this host: ${path}" >&2
    exit 1
  }
}

running_in_container() {
  [[ -f /.dockerenv ]] && return 0
  grep -qaE '/(docker|containers)/' /proc/1/cgroup 2>/dev/null
}

if [[ -n "${FSBL_INPUT}" ]]; then
  FSBL_PATH="$(abs_path "${FSBL_INPUT}")"
  require_readable_file "FSBL image" "${FSBL_PATH}"
fi

if [[ -n "${OPENSBI_INPUT}" ]]; then
  OPENSBI_PATH="$(abs_path "${OPENSBI_INPUT}")"
  require_readable_file "opensbi image" "${OPENSBI_PATH}"
fi

if [[ -n "${UBOOT_ITB_INPUT}" ]]; then
  UBOOT_ITB_PATH="$(abs_path "${UBOOT_ITB_INPUT}")"
  require_readable_file "u-boot FIT" "${UBOOT_ITB_PATH}"
fi

if [[ -n "${ENV_BIN_INPUT}" ]]; then
  ENV_BIN_PATH="$(abs_path "${ENV_BIN_INPUT}")"
  require_readable_file "U-Boot env image" "${ENV_BIN_PATH}"
fi

if [[ -n "${BOOTFS_TREE_INPUT}" ]]; then
  BOOTFS_TREE_PATH="$(abs_path "${BOOTFS_TREE_INPUT}")"
  require_readable_dir "bootfs tree" "${BOOTFS_TREE_PATH}"
fi

if [[ -n "${BOOTFS_VERIFY_FILE_INPUT}" ]]; then
  if [[ "${BOOTFS_VERIFY_FILE_INPUT}" = /* ]]; then
    echo "error: --bootfs-verify-file must be a relative path under the bootfs tree." >&2
    exit 1
  fi
  BOOTFS_VERIFY_FILE_REL="${BOOTFS_VERIFY_FILE_INPUT#/}"
else
  BOOTFS_VERIFY_FILE_REL=""
fi

if [[ -n "${BOOTFS_TREE_INPUT}" ]]; then
  if [[ -z "${BOOTFS_VERIFY_FILE_REL}" ]]; then
    if [[ -f "${BOOTFS_TREE_PATH}/act-campaign/sha256.txt" ]]; then
      BOOTFS_VERIFY_FILE_REL="act-campaign/sha256.txt"
    else
      echo "error: bootfs tree verification file not specified." >&2
      echo "hint: pass --bootfs-verify-file <relative-path>." >&2
      echo "hint: legacy campaign trees may omit this option if act-campaign/sha256.txt exists." >&2
      exit 1
    fi
  fi

  [[ -f "${BOOTFS_TREE_PATH}/${BOOTFS_VERIFY_FILE_REL}" ]] || {
    echo "error: bootfs verify file not found in tree: ${BOOTFS_TREE_PATH}/${BOOTFS_VERIFY_FILE_REL}" >&2
    exit 1
  }
  [[ -r "${BOOTFS_TREE_PATH}/${BOOTFS_VERIFY_FILE_REL}" ]] || {
    echo "error: bootfs verify file is not readable on this host: ${BOOTFS_TREE_PATH}/${BOOTFS_VERIFY_FILE_REL}" >&2
    exit 1
  }
fi

if [[ -n "${BOOTFS_ELF_INPUT}" ]]; then
  BOOTFS_ELF_PATH="$(abs_path "${BOOTFS_ELF_INPUT}")"
  require_readable_file "bootfs ELF" "${BOOTFS_ELF_PATH}"
fi

K1_LOWER_WORKDIR="${K1_LOWER_WORKDIR:-${WORKSPACE_ROOT}/act_k1_bianbu22}"
K1_LOWER_FSBL_DEV="${K1_LOWER_FSBL_DEV:-/dev/disk/by-partlabel/fsbl}"
K1_LOWER_OPENSBI_DEV="${K1_LOWER_OPENSBI_DEV:-/dev/disk/by-partlabel/opensbi}"
K1_LOWER_UBOOT_DEV="${K1_LOWER_UBOOT_DEV:-/dev/disk/by-partlabel/uboot}"
K1_LOWER_ENV_DEV="${K1_LOWER_ENV_DEV:-/dev/disk/by-partlabel/env}"
K1_LOWER_BOOTFS_DEV="${K1_LOWER_BOOTFS_DEV:-/dev/disk/by-partlabel/bootfs}"
K1_LOWER_BOOTFS_MNT="${K1_LOWER_BOOTFS_MNT:-${K1_LOWER_WORKDIR}/mnt/bootfs}"

if running_in_container; then
  echo "error: flash_k1_test_card.sh must run on the local host, not inside a container." >&2
  exit 1
fi

TEMP_HOST_FILES=()
cleanup_temp_host_files() {
  local path
  for path in "${TEMP_HOST_FILES[@]}"; do
    rm -f -- "${path}"
  done
}
trap cleanup_temp_host_files EXIT

if [[ -n "${BOOTFS_TREE_INPUT}" ]]; then
  command -v tar >/dev/null 2>&1 || {
    echo "error: tar not found" >&2
    exit 1
  }
fi

local_run() {
  local cmd="$1"
  bash -lc "${cmd}"
}

LOCAL_SUDO_MODE="nopass"
if sudo -n true >/dev/null 2>&1; then
  LOCAL_SUDO_MODE="nopass"
elif [[ -n "${K1_LOWER_PASS:-}" ]]; then
  LOCAL_SUDO_MODE="password"
elif [[ -t 0 && -t 1 ]]; then
  sudo -v >/dev/null
  LOCAL_SUDO_MODE="tty"
else
  echo "error: local sudo requires either an interactive TTY or K1_LOWER_PASS." >&2
  exit 1
fi

host_sudo() {
  local cmd="$1"
  if [[ "${LOCAL_SUDO_MODE}" == "password" ]]; then
    printf '%s\n' "${K1_LOWER_PASS}" | sudo -S -p '' bash -lc "${cmd}"
  else
    sudo bash -lc "${cmd}"
  fi
}

stage_file_to_target() {
  local src="$1"
  local dest="$2"
  mkdir -p "$(dirname "${dest}")"
  cp "${src}" "${dest}"
}

require_target_device() {
  local label="$1"
  local path="$2"
  if [[ ! -e "${path}" ]]; then
    echo "error: required local ${label} device not found: ${path}" >&2
    echo "hint: confirm the SD card is attached to this host and the partition label exists." >&2
    exit 1
  fi
}

TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REMOTE_BACKUP_DIR="${K1_LOWER_WORKDIR}/backup"
REMOTE_CHECK_DIR="${K1_LOWER_WORKDIR}/check"
REMOTE_STAGE_DIR="${K1_LOWER_WORKDIR}/staging"

local_run "mkdir -p '${K1_LOWER_WORKDIR}' '${REMOTE_BACKUP_DIR}' '${REMOTE_CHECK_DIR}' '${REMOTE_STAGE_DIR}'"

echo "Target local host:"
echo "  mode: local"
echo "  workdir: ${K1_LOWER_WORKDIR}"
echo "  sudo mode -> ${LOCAL_SUDO_MODE}"
echo "  fsbl    -> ${K1_LOWER_FSBL_DEV}"
echo "  opensbi -> ${K1_LOWER_OPENSBI_DEV}"
echo "  uboot   -> ${K1_LOWER_UBOOT_DEV}"
echo "  env     -> ${K1_LOWER_ENV_DEV}"
echo "  bootfs  -> ${K1_LOWER_BOOTFS_DEV}"

if [[ -n "${FSBL_INPUT}" ]]; then
  require_target_device "fsbl" "${K1_LOWER_FSBL_DEV}"
  FSBL_BASENAME="$(basename "${FSBL_PATH}")"
  REMOTE_FSBL="${REMOTE_STAGE_DIR}/${FSBL_BASENAME}"
  REMOTE_FSBL_BACKUP="${REMOTE_BACKUP_DIR}/fsbl.before_flash.${TIMESTAMP}.bin"
  FSBL_SIZE="$(wc -c < "${FSBL_PATH}")"

  stage_file_to_target "${FSBL_PATH}" "${REMOTE_FSBL}"

  FSBL_DEV_REAL="$(local_run "readlink -f '${K1_LOWER_FSBL_DEV}'")"
  FSBL_BYTES="$(host_sudo "blockdev --getsize64 '${FSBL_DEV_REAL}'")"
  FSBL_BACKUP_MIB="$(( (FSBL_BYTES + 1024 * 1024 - 1) / (1024 * 1024) ))"

  host_sudo "dd if='${K1_LOWER_FSBL_DEV}' of='${REMOTE_FSBL_BACKUP}' bs=1M count=${FSBL_BACKUP_MIB} status=none"
  host_sudo "dd if='${REMOTE_FSBL}' of='${K1_LOWER_FSBL_DEV}' bs=1M conv=fsync status=none"
  host_sudo "cmp -n ${FSBL_SIZE} '${REMOTE_FSBL}' '${K1_LOWER_FSBL_DEV}'"

  echo "  flashed fsbl    from ${REMOTE_FSBL}"
  echo "  backup  fsbl    -> ${REMOTE_FSBL_BACKUP}"
fi

if [[ -n "${OPENSBI_INPUT}" ]]; then
  require_target_device "opensbi" "${K1_LOWER_OPENSBI_DEV}"
  OPENSBI_BASENAME="$(basename "${OPENSBI_PATH}")"
  REMOTE_OPENSBI="${REMOTE_STAGE_DIR}/${OPENSBI_BASENAME}"
  REMOTE_OPENSBI_BACKUP="${REMOTE_BACKUP_DIR}/opensbi.before_flash.${TIMESTAMP}.itb"
  OPENSBI_SIZE="$(wc -c < "${OPENSBI_PATH}")"

  stage_file_to_target "${OPENSBI_PATH}" "${REMOTE_OPENSBI}"

  OPENSBI_DEV_REAL="$(local_run "readlink -f '${K1_LOWER_OPENSBI_DEV}'")"
  OPENSBI_BYTES="$(host_sudo "blockdev --getsize64 '${OPENSBI_DEV_REAL}'")"
  OPENSBI_BACKUP_MIB="$(( (OPENSBI_BYTES + 1024 * 1024 - 1) / (1024 * 1024) ))"

  host_sudo "dd if='${K1_LOWER_OPENSBI_DEV}' of='${REMOTE_OPENSBI_BACKUP}' bs=1M count=${OPENSBI_BACKUP_MIB} status=none"
  host_sudo "dd if='${REMOTE_OPENSBI}' of='${K1_LOWER_OPENSBI_DEV}' bs=1M conv=fsync status=none"
  host_sudo "cmp -n ${OPENSBI_SIZE} '${REMOTE_OPENSBI}' '${K1_LOWER_OPENSBI_DEV}'"

  echo "  flashed opensbi from ${REMOTE_OPENSBI}"
  echo "  backup  opensbi -> ${REMOTE_OPENSBI_BACKUP}"
fi

if [[ -n "${UBOOT_ITB_INPUT}" ]]; then
  require_target_device "uboot" "${K1_LOWER_UBOOT_DEV}"
  UBOOT_BASENAME="$(basename "${UBOOT_ITB_PATH}")"
  REMOTE_UBOOT="${REMOTE_STAGE_DIR}/${UBOOT_BASENAME}"
  REMOTE_UBOOT_BACKUP="${REMOTE_BACKUP_DIR}/uboot.before_flash.${TIMESTAMP}.itb"
  UBOOT_SIZE="$(wc -c < "${UBOOT_ITB_PATH}")"

  stage_file_to_target "${UBOOT_ITB_PATH}" "${REMOTE_UBOOT}"

  UBOOT_DEV_REAL="$(local_run "readlink -f '${K1_LOWER_UBOOT_DEV}'")"
  UBOOT_BYTES="$(host_sudo "blockdev --getsize64 '${UBOOT_DEV_REAL}'")"
  UBOOT_BACKUP_MIB="$(( (UBOOT_BYTES + 1024 * 1024 - 1) / (1024 * 1024) ))"

  host_sudo "dd if='${K1_LOWER_UBOOT_DEV}' of='${REMOTE_UBOOT_BACKUP}' bs=1M count=${UBOOT_BACKUP_MIB} status=none"
  host_sudo "dd if='${REMOTE_UBOOT}' of='${K1_LOWER_UBOOT_DEV}' bs=1M conv=fsync status=none"
  host_sudo "cmp -n ${UBOOT_SIZE} '${REMOTE_UBOOT}' '${K1_LOWER_UBOOT_DEV}'"

  echo "  flashed uboot   from ${REMOTE_UBOOT}"
  echo "  backup  uboot   -> ${REMOTE_UBOOT_BACKUP}"
fi

if [[ -n "${ENV_BIN_INPUT}" ]]; then
  require_target_device "env" "${K1_LOWER_ENV_DEV}"
  ENV_BASENAME="$(basename "${ENV_BIN_PATH}")"
  REMOTE_ENV_BIN="${REMOTE_STAGE_DIR}/${ENV_BASENAME}"
  REMOTE_ENV_BACKUP="${REMOTE_BACKUP_DIR}/env.before_flash.${TIMESTAMP}.bin"
  ENV_SIZE="$(wc -c < "${ENV_BIN_PATH}")"

  stage_file_to_target "${ENV_BIN_PATH}" "${REMOTE_ENV_BIN}"

  ENV_DEV_REAL="$(local_run "readlink -f '${K1_LOWER_ENV_DEV}'")"
  ENV_BYTES="$(host_sudo "blockdev --getsize64 '${ENV_DEV_REAL}'")"
  ENV_BACKUP_MIB="$(( (ENV_BYTES + 1024 * 1024 - 1) / (1024 * 1024) ))"

  host_sudo "dd if='${K1_LOWER_ENV_DEV}' of='${REMOTE_ENV_BACKUP}' bs=1M count=${ENV_BACKUP_MIB} status=none"
  host_sudo "dd if='${REMOTE_ENV_BIN}' of='${K1_LOWER_ENV_DEV}' bs=1M conv=fsync status=none"
  host_sudo "cmp -n ${ENV_SIZE} '${REMOTE_ENV_BIN}' '${K1_LOWER_ENV_DEV}'"

  echo "  flashed env     from ${REMOTE_ENV_BIN}"
  echo "  backup  env     -> ${REMOTE_ENV_BACKUP}"
fi

if [[ -n "${BOOTFS_ELF_INPUT}" ]]; then
  require_target_device "bootfs" "${K1_LOWER_BOOTFS_DEV}"
  BOOTFS_BASENAME="$(basename "${BOOTFS_ELF_PATH}")"
  REMOTE_BOOTFS_STAGE="${REMOTE_STAGE_DIR}/${BOOTFS_BASENAME}"
  BOOTFS_DEST_REL="${BOOTFS_DEST_INPUT:-act-tests/${BOOTFS_BASENAME}}"
  BOOTFS_DEST_REL="${BOOTFS_DEST_REL#/}"
  BOOTFS_TARGET="$(host_sudo "findmnt -n -o TARGET '${K1_LOWER_BOOTFS_DEV}' || true")"
  BOOTFS_MOUNTED_HERE=0

  stage_file_to_target "${BOOTFS_ELF_PATH}" "${REMOTE_BOOTFS_STAGE}"

  if [[ -z "${BOOTFS_TARGET}" ]]; then
    BOOTFS_TARGET="${K1_LOWER_BOOTFS_MNT}"
    host_sudo "mkdir -p '${BOOTFS_TARGET}' && mount '${K1_LOWER_BOOTFS_DEV}' '${BOOTFS_TARGET}'"
    BOOTFS_MOUNTED_HERE=1
  fi

  REMOTE_BOOTFS_DEST="${BOOTFS_TARGET}/${BOOTFS_DEST_REL}"
  REMOTE_BOOTFS_BACKUP="${REMOTE_BACKUP_DIR}/bootfs.${TIMESTAMP}.$(basename "${BOOTFS_DEST_REL}")"

  host_sudo "mkdir -p '$(dirname "${REMOTE_BOOTFS_DEST}")'"
  host_sudo "if [[ -f '${REMOTE_BOOTFS_DEST}' ]]; then cp '${REMOTE_BOOTFS_DEST}' '${REMOTE_BOOTFS_BACKUP}'; fi"
  host_sudo "cp '${REMOTE_BOOTFS_STAGE}' '${REMOTE_BOOTFS_DEST}'"
  host_sudo "cmp '${REMOTE_BOOTFS_STAGE}' '${REMOTE_BOOTFS_DEST}'"

  if [[ "${BOOTFS_MOUNTED_HERE}" -eq 1 ]]; then
    host_sudo "sync && umount '${BOOTFS_TARGET}'"
  else
    host_sudo "sync"
  fi

  echo "  staged bootfs ELF -> ${REMOTE_BOOTFS_DEST}"
  if local_run "test -f '${REMOTE_BOOTFS_BACKUP}'"; then
    echo "  backup  bootfs    -> ${REMOTE_BOOTFS_BACKUP}"
  fi
fi

if [[ -n "${BOOTFS_TREE_INPUT}" ]]; then
  require_target_device "bootfs" "${K1_LOWER_BOOTFS_DEV}"
  LOCAL_BOOTFS_TAR="$(mktemp "${TMPDIR:-/tmp}/k1-bootfs-tree.XXXXXX.tar")"
  BOOTFS_TREE_ARCHIVE_NAME="$(basename "${LOCAL_BOOTFS_TAR}")"
  REMOTE_BOOTFS_TREE_TAR="${REMOTE_STAGE_DIR}/${BOOTFS_TREE_ARCHIVE_NAME}"
  BOOTFS_TARGET="$(host_sudo "findmnt -n -o TARGET '${K1_LOWER_BOOTFS_DEV}' || true")"
  BOOTFS_MOUNTED_HERE=0

  tar -C "${BOOTFS_TREE_PATH}" -cf "${LOCAL_BOOTFS_TAR}" .
  TEMP_HOST_FILES+=("${LOCAL_BOOTFS_TAR}")

  stage_file_to_target "${LOCAL_BOOTFS_TAR}" "${REMOTE_BOOTFS_TREE_TAR}"

  if [[ -z "${BOOTFS_TARGET}" ]]; then
    BOOTFS_TARGET="${K1_LOWER_BOOTFS_MNT}"
    host_sudo "mkdir -p '${BOOTFS_TARGET}' && mount '${K1_LOWER_BOOTFS_DEV}' '${BOOTFS_TARGET}'"
    BOOTFS_MOUNTED_HERE=1
  fi

  for purge_prefix in "${BOOTFS_PURGE_PREFIXES[@]}"; do
    purge_rel="${purge_prefix#/}"
    [[ -n "${purge_rel}" ]] || continue
    backup_suffix="$(printf '%s' "${purge_rel}" | tr '/ ' '__')"
    host_sudo "if [[ -e '${BOOTFS_TARGET}/${purge_rel}' ]]; then tar -C '${BOOTFS_TARGET}' -cf '${REMOTE_BACKUP_DIR}/bootfs.before_flash.${TIMESTAMP}.${backup_suffix}.tar' '${purge_rel}'; rm -rf '${BOOTFS_TARGET}/${purge_rel}'; fi"
  done

  host_sudo "tar -C '${BOOTFS_TARGET}' -xf '${REMOTE_BOOTFS_TREE_TAR}'"
  host_sudo "cd '${BOOTFS_TARGET}' && sha256sum -c '${BOOTFS_VERIFY_FILE_REL}'"

  if [[ "${BOOTFS_MOUNTED_HERE}" -eq 1 ]]; then
    host_sudo "sync && umount '${BOOTFS_TARGET}'"
  else
    host_sudo "sync"
  fi

  echo "  staged bootfs tree -> ${BOOTFS_TARGET}"
  echo "  verify file      -> ${BOOTFS_VERIFY_FILE_REL}"
  for purge_prefix in "${BOOTFS_PURGE_PREFIXES[@]}"; do
    purge_rel="${purge_prefix#/}"
    [[ -n "${purge_rel}" ]] || continue
    backup_suffix="$(printf '%s' "${purge_rel}" | tr '/ ' '__')"
    if local_run "test -f '${REMOTE_BACKUP_DIR}/bootfs.before_flash.${TIMESTAMP}.${backup_suffix}.tar'"; then
      echo "  backup  bootfs    -> ${REMOTE_BACKUP_DIR}/bootfs.before_flash.${TIMESTAMP}.${backup_suffix}.tar"
    fi
  done
fi

host_sudo "sync"

echo
echo "Flash/stage complete."
echo "You can now cold boot the BPI-F3 and capture the serial log on the lower machine."
