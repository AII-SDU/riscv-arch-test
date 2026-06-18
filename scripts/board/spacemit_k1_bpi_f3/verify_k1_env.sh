#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/board/spacemit_k1_bpi_f3/verify_k1_env.sh \
    [--workspace-root <path>] \
    [--sdk-root <path>] \
    [--package-dir <path>]

Purpose:
  Verify whether the current host-native K1 environment is ready for the
  scheduler board-test flow without relying on the rvtest container model.

Defaults:
  --workspace-root  <repo-parent of this script checkout>
  --sdk-root        <workspace-root>/buildroot-sdk-2.2 (legacy fallback)
  --package-dir     <unset>

Checks:
  - host execution mode (must not run inside a container)
  - local workspace / repo layout
  - local toolchain and helper tools used by make elfs / scheduler packaging
  - bundled K1 components under scripts/board/spacemit_k1_bpi_f3/tools
  - local sudo write-card readiness
  - local serial access
  - optional scheduler package directory completeness

Notes:
  - This script is static verification only.
  - It does not build, flash, or parse logs.
  - It does not check Docker, container images, or /workspace mounts.
  - K1_LOWER_PASS may be exported to satisfy password-based sudo checks.
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT_DEFAULT="$(cd -- "${REPO_ROOT}/.." && pwd)"
TOOLS_DIR="${SCRIPT_DIR}/tools"

WORKSPACE_ROOT="${WORKSPACE_ROOT_DEFAULT}"
SDK_ROOT=""
PACKAGE_DIR=""

cd $WORKSPACE_ROOT
cd riscv-arch-test
mise trust .mise.toml

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-root)
      WORKSPACE_ROOT="${2:-}"
      shift 2
      ;;
    --sdk-root)
      SDK_ROOT="${2:-}"
      shift 2
      ;;
    --package-dir)
      PACKAGE_DIR="${2:-}"
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

WORKSPACE_ROOT="${WORKSPACE_ROOT%/}"
[[ -n "${WORKSPACE_ROOT}" ]] || WORKSPACE_ROOT="/"
if [[ -z "${SDK_ROOT}" ]]; then
  SDK_ROOT="${WORKSPACE_ROOT}/buildroot-sdk-2.2"
fi
SDK_ROOT="${SDK_ROOT%/}"
[[ -n "${SDK_ROOT}" ]] || SDK_ROOT="/"
if [[ -n "${PACKAGE_DIR}" ]]; then
  PACKAGE_DIR="${PACKAGE_DIR%/}"
  [[ -n "${PACKAGE_DIR}" ]] || PACKAGE_DIR="/"
fi

LOWER_REPO_ROOT="${WORKSPACE_ROOT}/riscv-arch-test"
SERIAL_ROOT="/dev/serial/by-id"

FAILURES=0
SHOULD_HINT_TOOLS=0
SHOULD_HINT_PACKAGE=0
SHOULD_HINT_SUDO=0
SHOULD_HINT_SERIAL=0

section() {
  printf '\n[%s]\n' "$1"
}

pass() {
  local label="$1"
  local detail="${2:-}"
  if [[ -n "${detail}" ]]; then
    printf 'PASS  %s: %s\n' "${label}" "${detail}"
  else
    printf 'PASS  %s\n' "${label}"
  fi
}

fail() {
  local label="$1"
  local detail="${2:-}"
  FAILURES=$((FAILURES + 1))
  if [[ -n "${detail}" ]]; then
    printf 'FAIL  %s: %s\n' "${label}" "${detail}"
  else
    printf 'FAIL  %s\n' "${label}"
  fi
}

running_in_container() {
  [[ -f /.dockerenv ]] && return 0
  grep -qaE '/(docker|containers)/' /proc/1/cgroup 2>/dev/null
}

check_tool() {
  local tool="$1"
  if command -v "${tool}" >/dev/null 2>&1; then
    pass "${tool}" "$(command -v "${tool}")"
  else
    fail "${tool}" "not found in PATH"
  fi
}

check_mkimage() {
  local local_mkimage="${TOOLS_DIR}/mkimage"
  local sdk_mkimage
  local sdk_candidates=(
    "${SDK_ROOT}/output/k1_v2/build/host-uboot-tools-2021.07/tools/mkimage"
    "${SDK_ROOT}/output/k1_v2/build/uboot-custom/tools/mkimage"
    "${SDK_ROOT}/output/k1_v2/build/opensbi-custom/tools/mkimage"
  )

  if [[ -e "${local_mkimage}" ]]; then
    if [[ -x "${local_mkimage}" ]]; then
      pass "mkimage" "${local_mkimage}"
    else
      fail "mkimage" "found but not executable: ${local_mkimage}"
      SHOULD_HINT_TOOLS=1
    fi
    return
  fi

  if command -v mkimage >/dev/null 2>&1; then
    pass "mkimage" "$(command -v mkimage)"
    return
  fi

  for sdk_mkimage in "${sdk_candidates[@]}"; do
    if [[ -e "${sdk_mkimage}" ]]; then
      if [[ -x "${sdk_mkimage}" ]]; then
        pass "mkimage" "${sdk_mkimage}"
      else
        fail "mkimage" "found but not executable: ${sdk_mkimage}"
        SHOULD_HINT_TOOLS=1
      fi
      return
    fi
  done

  fail "mkimage" "missing: ${local_mkimage}"
  SHOULD_HINT_TOOLS=1
}

check_gcc_version() {
  local tool="riscv64-unknown-elf-gcc"
  local version
  local major

  if ! command -v "${tool}" >/dev/null 2>&1; then
    fail "${tool}" "not found in PATH"
    return
  fi

  version="$("${tool}" -dumpversion 2>/dev/null || true)"
  major="${version%%.*}"
  if [[ -z "${version}" || ! "${major}" =~ ^[0-9]+$ ]]; then
    fail "${tool}" "unable to parse -dumpversion output: ${version:-<empty>}"
    return
  fi

  if (( major < 15 )); then
    fail "${tool}" "version ${version} found, need GCC 15 or later"
  else
    pass "${tool}" "$(command -v "${tool}") (version ${version})"
  fi
}

check_sail_version() {
  local tool="sail_riscv_sim"
  local version

  if ! command -v "${tool}" >/dev/null 2>&1; then
    fail "${tool}" "not found in PATH"
    return
  fi

  version="$("${tool}" --version 2>/dev/null || true)"
  if [[ "${version}" != "0.12" ]]; then
    fail "${tool}" "version ${version:-<empty>} found, need 0.11"
  else
    pass "${tool}" "$(command -v "${tool}") (version ${version})"
  fi
}

LOCAL_SUDO_MODE=""
detect_sudo_mode() {
  if ! command -v sudo >/dev/null 2>&1; then
    return 1
  fi

  if sudo -n true >/dev/null 2>&1; then
    LOCAL_SUDO_MODE="nopass"
    return 0
  fi

  if [[ -n "${K1_LOWER_PASS:-}" ]]; then
    LOCAL_SUDO_MODE="password"
    return 0
  fi

  if [[ -t 0 && -t 1 ]]; then
    if sudo -v >/dev/null 2>&1; then
      LOCAL_SUDO_MODE="tty"
      return 0
    fi
  fi

  return 1
}

host_sudo() {
  local cmd="$1"
  if [[ "${LOCAL_SUDO_MODE}" == "password" ]]; then
    printf '%s\n' "${K1_LOWER_PASS}" | sudo -S -p '' bash -lc "${cmd}"
  else
    sudo bash -lc "${cmd}"
  fi
}

check_k1_component() {
  local label="$1"
  shift
  local candidate

  for candidate in "$@"; do
    if [[ -f "${candidate}" ]]; then
      pass "${label}" "${candidate}"
      return
    fi
  done

  fail "${label}" "missing: ${TOOLS_DIR}/${label}"
  SHOULD_HINT_TOOLS=1
}

check_package_artifact() {
  local rel_path="$1"
  local abs_path="${PACKAGE_DIR}/${rel_path}"

  if [[ -s "${abs_path}" ]]; then
    pass "${rel_path}" "${abs_path}"
  else
    fail "${rel_path}" "missing or empty: ${abs_path}"
    SHOULD_HINT_PACKAGE=1
  fi
}

section "Execution Mode"
if running_in_container; then
  fail "host execution" "verify_k1_env.sh must run on the host, not inside a container"
  printf '\n[Summary]\n'
  echo "FAIL  host-native K1 environment has ${FAILURES} failing check(s)"
  exit "${FAILURES}"
else
  pass "host execution" "running on the host"
fi

section "Workspace"
if [[ -d "${WORKSPACE_ROOT}" ]]; then
  pass "workspace root" "${WORKSPACE_ROOT}"
else
  fail "workspace root" "missing: ${WORKSPACE_ROOT}"
fi

if [[ -d "${LOWER_REPO_ROOT}" ]]; then
  pass "repo root" "${LOWER_REPO_ROOT}"
else
  fail "repo root" "missing: ${LOWER_REPO_ROOT}"
fi

for rel_path in \
  "config/cores/spacemit-k1-bpi-f3-scheduler/test_config.yaml" \
  "scripts/board/spacemit_k1_bpi_f3/build_k1_scheduler_image.sh" \
  "scripts/board/spacemit_k1_bpi_f3/flash_k1_test_card.sh"
do
  repo_path="${LOWER_REPO_ROOT}/${rel_path}"
  if [[ -f "${repo_path}" ]]; then
    pass "${rel_path}" "${repo_path}"
  else
    fail "${rel_path}" "missing: ${repo_path}"
  fi
done

section "Toolchain"
check_tool python3
check_gcc_version
check_tool riscv64-unknown-elf-objdump
check_sail_version
check_mkimage

section "Host Tools"
for tool in dd cmp stty mount umount tar sha256sum blockdev findmnt readlink sudo; do
  check_tool "${tool}"
done

section "K1 Components"
if [[ -d "${TOOLS_DIR}" ]]; then
  pass "tools dir" "${TOOLS_DIR}"
else
  fail "tools dir" "missing: ${TOOLS_DIR}"
  SHOULD_HINT_TOOLS=1
fi

check_k1_component \
  "FSBL.bin" \
  "${TOOLS_DIR}/FSBL.bin" \
  "${SDK_ROOT}/output/k1_v2/images/FSBL.bin" \
  "${SDK_ROOT}/output/k1_v2/build/uboot-custom/FSBL.bin"
check_k1_component \
  "fw_dynamic.itb" \
  "${TOOLS_DIR}/fw_dynamic.itb" \
  "${SDK_ROOT}/output/k1_v2/images/fw_dynamic.itb" \
  "${SDK_ROOT}/output/k1_v2/build/opensbi-custom/build/platform/generic/firmware/fw_dynamic.itb"
check_k1_component \
  "k1-x_deb1.dtb" \
  "${TOOLS_DIR}/k1-x_deb1.dtb" \
  "${SDK_ROOT}/output/k1_v2/build/uboot-custom/arch/riscv/dts/k1-x_deb1.dtb" \
  "${SDK_ROOT}/output/k1_v2/build/uboot-custom/u-boot.dtb" \
  "${SDK_ROOT}/output/k1_v2/images/k1-x_deb1.dtb"

section "Write-Card Access"
if detect_sudo_mode; then
  pass "sudo mode" "${LOCAL_SUDO_MODE}"
else
  fail "sudo mode" "need passwordless sudo, interactive sudo, or K1_LOWER_PASS"
  SHOULD_HINT_SUDO=1
fi

section "Physical Links"
shopt -s nullglob
serial_candidates=("${SERIAL_ROOT}"/*)
shopt -u nullglob
if [[ "${#serial_candidates[@]}" -gt 0 ]]; then
  pass "serial by-id" "${serial_candidates[0]}"
else
  fail "serial by-id" "no serial device found under ${SERIAL_ROOT}"
  SHOULD_HINT_SERIAL=1
fi

section "Scheduler Package"
if [[ -n "${PACKAGE_DIR}" ]]; then
  if [[ -d "${PACKAGE_DIR}" ]]; then
    pass "package dir" "${PACKAGE_DIR}"
  else
    fail "package dir" "missing: ${PACKAGE_DIR}"
    SHOULD_HINT_PACKAGE=1
  fi

  if [[ -d "${PACKAGE_DIR}" ]]; then
    for rel_path in \
      "selected-scopes.txt" \
      "manifest.tsv" \
      "scheduler.elf" \
      "scheduler.bin" \
      "u-boot.itb" \
      "flash-command.sh" \
      "README.txt"
    do
      check_package_artifact "${rel_path}"
    done

    if [[ -e "${PACKAGE_DIR}/flash-command.sh" ]]; then
      if [[ -x "${PACKAGE_DIR}/flash-command.sh" ]]; then
        pass "flash-command.sh executable" "${PACKAGE_DIR}/flash-command.sh"
      else
        fail "flash-command.sh executable" "not executable: ${PACKAGE_DIR}/flash-command.sh"
        SHOULD_HINT_PACKAGE=1
      fi
    fi
  fi
else
  pass "package dir" "not requested"
fi

printf '\n[Summary]\n'
if [[ "${FAILURES}" -eq 0 ]]; then
  echo "PASS  host-native K1 environment looks ready"
else
  echo "FAIL  host-native K1 environment has ${FAILURES} failing check(s)"
  if [[ "${SHOULD_HINT_TOOLS}" -eq 1 ]]; then
    echo "hint: ensure FSBL.bin, fw_dynamic.itb, k1-x_deb1.dtb, and mkimage exist under ${TOOLS_DIR}"
  fi
  if [[ "${SHOULD_HINT_SUDO}" -eq 1 ]]; then
    echo "hint: enable sudo for this host user or export K1_LOWER_PASS before re-running verify_k1_env.sh"
  fi
  if [[ "${SHOULD_HINT_SERIAL}" -eq 1 ]]; then
    echo "hint: attach the serial adapter so a device appears under ${SERIAL_ROOT}"
  fi
  if [[ "${SHOULD_HINT_PACKAGE}" -eq 1 ]]; then
    echo "hint: rebuild or re-copy the scheduler suite output so ${PACKAGE_DIR} contains the expected artifacts"
  fi
fi

exit "${FAILURES}"
