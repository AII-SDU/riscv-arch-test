#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/board/spacemit_k1_bpi_f3/build_k1_scheduler_image.sh \
    --scope <family/ext> [--scope <family/ext> ...] \
    [--scope-set <preset-name>] \
    [--scopes-file <path>] \
    [--suite-name <name>] \
    [--only <test-name>] \
    [--timeout-ms <ms>] \
    [--fsbl <path-to-FSBL.bin>] \
    [--opensbi <path-to-fw_dynamic.itb>] \
    [--sdk-dtb <path-to-k1-x_deb1.dtb>] \
    [--output-root <path>]

Purpose:
  Build a single S-mode scheduler image for the K1 board. The scheduler embeds
  one or more scopes worth of standard ACT ELF files and runs them sequentially
  in one boot.

Default ELF input:
  work/spacemit-k1-bpi-f3-scheduler/elfs/<scope>/

Default output:
  work/spacemit-k1-bpi-f3-scheduler/<suite-name>/

Scope selection:
  Exactly one of the following must be used:
    --scope <family/ext>          Select one or more scopes explicitly
    --scope-set <preset-name>     Use a preset scope list from scripts/.../scope_sets/
    --scopes-file <path>          Read scopes from a newline-delimited file

  Scope list files may contain blank lines and '#' comments.

Generated files:
  selected-scopes.txt
  manifest.tsv
  scheduler.elf
  scheduler.bin
  u-boot.itb
  flash-command.sh

Smoke mode:
  --only I-addi-00 embeds just one ELF from a single selected scope while
  keeping the same scheduler entry and FIT contract. Use this first to validate
  trap recovery before building a full scope image.

Environment:
  CC                Override scheduler C compiler
  OBJCOPY           Override objcopy tool
  MKIMAGE           Override mkimage tool

Bundled K1 components:
  scripts/board/spacemit_k1_bpi_f3/tools/FSBL.bin
  scripts/board/spacemit_k1_bpi_f3/tools/fw_dynamic.itb
  scripts/board/spacemit_k1_bpi_f3/tools/k1-x_deb1.dtb
  scripts/board/spacemit_k1_bpi_f3/tools/mkimage

Host-only execution:
  This script must run directly on the host. It no longer auto-enters the
  rvtest container.

Scheduler timeout:
  --timeout-ms <ms>  Supervisor-timer (Sstc) timeout per case. Default: 10000.
                     Use 0 to disable timeout recovery.

This image keeps the proven K1 FIT contract:
  SPL -> OpenSBI (opensbi partition) -> S-mode scheduler FIT (uboot partition)
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd -- "${REPO_ROOT}/.." && pwd)"
TOOLS_DIR="${SCRIPT_DIR}/tools"
RVTEST_TRASH_ROOT="${WORKSPACE_ROOT}/.trash"
SDK_ROOT_DEFAULT="${WORKSPACE_ROOT}/buildroot-sdk-2.2"
SCOPE_SET_ROOT="${SCRIPT_DIR}/scope_sets"
SCHEDULER_LOAD_ADDR_HEX="0x00200000"
SCHEDULER_LOAD_ADDR_FDT="0x0 0x00200000"
TEST_WINDOW_START_HEX="0x60000000"
TEST_WINDOW_END_HEX="0x78000000"

tool_present() {
  local tool="$1"
  command -v "${tool}" >/dev/null 2>&1 || [[ -x "${tool}" ]]
}

abs_path() {
  python3 - "$1" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
}

sanitize_name() {
  printf '%s' "$1" | sed 's#[^A-Za-z0-9._-]#-#g'
}

running_in_container() {
  [[ -f /.dockerenv ]] && return 0
  grep -qaE '/(docker|containers)/' /proc/1/cgroup 2>/dev/null
}

path_expr_for_flash_command() {
  local path="$1"

  case "${path}" in
    "${REPO_ROOT}"/*)
      printf '%s%s\n' '${REPO_ROOT}' "${path#"${REPO_ROOT}"}"
      ;;
    "${WORKSPACE_ROOT}"/*)
      printf '%s%s\n' '${WORKSPACE_ROOT}' "${path#"${WORKSPACE_ROOT}"}"
      ;;
    *)
      printf '%s\n' "${path}"
      ;;
  esac
}

find_first_existing() {
  local candidate
  for candidate in "$@"; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      command -v "${candidate}"
      return 0
    fi
    if [[ -e "${candidate}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

declare -a SCOPES=()
SCOPES_FILE_INPUT=""
SCOPE_SET_INPUT=""
SUITE_NAME_INPUT=""
ONLY_TEST_NAME=""
SDK_DTB_INPUT=""
FSBL_INPUT=""
OPENSBI_INPUT=""
OUTPUT_ROOT_INPUT="${REPO_ROOT}/work/spacemit-k1-bpi-f3-scheduler"
TIMEOUT_MS_INPUT="10000"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scope)
      SCOPES+=("${2:-}")
      shift 2
      ;;
    --scopes-file)
      SCOPES_FILE_INPUT="${2:-}"
      shift 2
      ;;
    --scope-set)
      SCOPE_SET_INPUT="${2:-}"
      shift 2
      ;;
    --suite-name)
      SUITE_NAME_INPUT="${2:-}"
      shift 2
      ;;
    --only)
      ONLY_TEST_NAME="${2:-}"
      shift 2
      ;;
    --timeout-ms)
      TIMEOUT_MS_INPUT="${2:-}"
      shift 2
      ;;
    --fsbl)
      FSBL_INPUT="${2:-}"
      shift 2
      ;;
    --opensbi)
      OPENSBI_INPUT="${2:-}"
      shift 2
      ;;
    --sdk-dtb)
      SDK_DTB_INPUT="${2:-}"
      shift 2
      ;;
    --output-root)
      OUTPUT_ROOT_INPUT="${2:-}"
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

if running_in_container; then
  echo "error: build_k1_scheduler_image.sh must run on the host, not inside a container." >&2
  exit 1
fi

command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 not found" >&2
  exit 1
}

SCOPE_SOURCE_COUNT=0
if [[ "${#SCOPES[@]}" -gt 0 ]]; then
  SCOPE_SOURCE_COUNT=$((SCOPE_SOURCE_COUNT + 1))
fi
if [[ -n "${SCOPES_FILE_INPUT}" ]]; then
  SCOPE_SOURCE_COUNT=$((SCOPE_SOURCE_COUNT + 1))
fi
if [[ -n "${SCOPE_SET_INPUT}" ]]; then
  SCOPE_SOURCE_COUNT=$((SCOPE_SOURCE_COUNT + 1))
fi
if [[ "${SCOPE_SOURCE_COUNT}" -ne 1 ]]; then
  echo "error: select scopes with exactly one of --scope, --scope-set, or --scopes-file" >&2
  usage
  exit 1
fi

if [[ -n "${SCOPE_SET_INPUT}" ]]; then
  SCOPES_FILE_INPUT="${SCOPE_SET_ROOT}/${SCOPE_SET_INPUT}.txt"
fi

if [[ -n "${SCOPES_FILE_INPUT}" ]]; then
  SCOPES_FILE_PATH="$(abs_path "${SCOPES_FILE_INPUT}")"
  [[ -f "${SCOPES_FILE_PATH}" ]] || {
    echo "error: scope list file not found: ${SCOPES_FILE_PATH}" >&2
    exit 1
  }

  mapfile -t SCOPES < <(python3 - "${SCOPES_FILE_PATH}" <<'PY'
import sys
from pathlib import Path

seen = set()
for raw_line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    line = raw_line.split("#", 1)[0].strip()
    if not line or line in seen:
        continue
    seen.add(line)
    print(line)
PY
  )
fi

if [[ "${#SCOPES[@]}" -eq 0 ]]; then
  echo "error: no scopes selected" >&2
  exit 1
fi

declare -A SEEN_SCOPES=()
UNIQUE_SCOPES=()
for scope in "${SCOPES[@]}"; do
  if [[ -z "${scope}" || -n "${SEEN_SCOPES[${scope}]+x}" ]]; then
    continue
  fi
  UNIQUE_SCOPES+=("${scope}")
  SEEN_SCOPES["${scope}"]=1
done
unset SEEN_SCOPES
SCOPES=("${UNIQUE_SCOPES[@]}")
unset UNIQUE_SCOPES

if [[ -n "${ONLY_TEST_NAME}" && "${#SCOPES[@]}" -ne 1 ]]; then
  echo "error: --only requires selecting exactly one scope" >&2
  exit 1
fi

[[ "${TIMEOUT_MS_INPUT}" =~ ^[0-9]+$ ]] || {
  echo "error: --timeout-ms must be a non-negative integer: ${TIMEOUT_MS_INPUT}" >&2
  exit 1
}

if [[ -n "${SCOPE_SET_INPUT}" ]]; then
  SCOPE_LABEL="scope-set/${SCOPE_SET_INPUT}"
  SUITE_NAME_DEFAULT="${SCOPE_SET_INPUT}-scheduler"
elif [[ -n "${SCOPES_FILE_INPUT}" ]]; then
  SCOPES_FILE_BASENAME="$(basename "${SCOPES_FILE_INPUT}")"
  SCOPES_FILE_STEM="${SCOPES_FILE_BASENAME%.*}"
  SCOPE_LABEL="scope-file/${SCOPES_FILE_STEM}"
  SUITE_NAME_DEFAULT="${SCOPES_FILE_STEM}-scheduler"
elif [[ "${#SCOPES[@]}" -eq 1 ]]; then
  SCOPE_LABEL="${SCOPES[0]}"
  SUITE_NAME_DEFAULT="${SCOPES[0]}-scheduler"
else
  SCOPE_LABEL="multi-scope"
  SUITE_NAME_DEFAULT="multi-scope-scheduler"
fi

SUITE_NAME_RAW="${SUITE_NAME_INPUT:-${SUITE_NAME_DEFAULT}}"
SUITE_NAME="$(sanitize_name "${SUITE_NAME_RAW}")"
OUTPUT_ROOT="$(abs_path "${OUTPUT_ROOT_INPUT}")"
OUTPUT_DIR="${OUTPUT_ROOT}/${SUITE_NAME}"
SDK_ROOT="${SDK_ROOT_DEFAULT}"

DEFAULT_OPENSBI="$(
  find_first_existing \
    "${TOOLS_DIR}/fw_dynamic.itb" \
    "${SDK_ROOT}/output/k1_v2/images/fw_dynamic.itb" \
    "${SDK_ROOT}/output/k1_v2/build/opensbi-custom/build/platform/generic/firmware/fw_dynamic.itb" \
    || true
)"
DEFAULT_FSBL="$(
  find_first_existing \
    "${TOOLS_DIR}/FSBL.bin" \
    "${SDK_ROOT}/output/k1_v2/images/FSBL.bin" \
    "${SDK_ROOT}/output/k1_v2/build/uboot-custom/FSBL.bin" \
    || true
)"
if [[ -n "${FSBL_INPUT:-}" ]]; then
  FSBL_PATH="$(abs_path "${FSBL_INPUT}")"
elif [[ -n "${DEFAULT_FSBL}" ]]; then
  FSBL_PATH="$(abs_path "${DEFAULT_FSBL}")"
else
  FSBL_PATH=""
fi
[[ -f "${FSBL_PATH}" ]] || {
  echo "error: FSBL image not found: ${FSBL_PATH}" >&2
  exit 1
}
if [[ -n "${OPENSBI_INPUT:-}" ]]; then
  OPENSBI_PATH="$(abs_path "${OPENSBI_INPUT}")"
elif [[ -n "${DEFAULT_OPENSBI}" ]]; then
  OPENSBI_PATH="$(abs_path "${DEFAULT_OPENSBI}")"
else
  OPENSBI_PATH=""
fi
[[ -f "${OPENSBI_PATH}" ]] || {
  echo "error: OpenSBI image not found: ${OPENSBI_PATH}" >&2
  exit 1
}

DEFAULT_SDK_DTB="$(
  find_first_existing \
    "${TOOLS_DIR}/k1-x_deb1.dtb" \
    "${SDK_ROOT}/output/k1_v2/build/uboot-custom/arch/riscv/dts/k1-x_deb1.dtb" \
    "${SDK_ROOT}/output/k1_v2/build/uboot-custom/u-boot.dtb" \
    "${SDK_ROOT}/output/k1_v2/images/k1-x_deb1.dtb" \
    || true
)"
if [[ -n "${SDK_DTB_INPUT:-}" ]]; then
  SDK_DTB_PATH="$(abs_path "${SDK_DTB_INPUT}")"
elif [[ -n "${DEFAULT_SDK_DTB}" ]]; then
  SDK_DTB_PATH="$(abs_path "${DEFAULT_SDK_DTB}")"
else
  SDK_DTB_PATH=""
fi
[[ -f "${SDK_DTB_PATH}" ]] || {
  echo "error: SDK DTB not found: ${SDK_DTB_PATH}" >&2
  exit 1
}
SDK_DTB_SIZE_BYTES="$(stat -c '%s' "${SDK_DTB_PATH}")"

CC="${CC:-}"
if [[ -z "${CC}" ]]; then
  for candidate in \
    "/usr/local/bin/riscv64-unknown-elf-gcc" \
    "riscv64-unknown-elf-gcc" \
    "/opt/riscv/bin/riscv64-unknown-elf-gcc"
  do
    if tool_present "${candidate}"; then
      CC="${candidate}"
      break
    fi
  done
fi

OBJCOPY="${OBJCOPY:-}"
if [[ -z "${OBJCOPY}" ]]; then
  for candidate in \
    "/usr/local/bin/riscv64-unknown-elf-objcopy" \
    "riscv64-unknown-elf-objcopy" \
    "/opt/riscv/bin/riscv64-unknown-elf-objcopy"
  do
    if tool_present "${candidate}"; then
      OBJCOPY="${candidate}"
      break
    fi
  done
fi

DEFAULT_MKIMAGE="$(
  find_first_existing \
    "${TOOLS_DIR}/mkimage" \
    "mkimage" \
    "${SDK_ROOT}/output/k1_v2/build/host-uboot-tools-2021.07/tools/mkimage" \
    "${SDK_ROOT}/output/k1_v2/build/uboot-custom/tools/mkimage" \
    "${SDK_ROOT}/output/k1_v2/build/opensbi-custom/tools/mkimage" \
    || true
)"
MKIMAGE="${MKIMAGE:-${DEFAULT_MKIMAGE}}"

tool_present "${CC}" || {
  echo "error: scheduler compiler not found: ${CC}" >&2
  exit 1
}
tool_present "${OBJCOPY}" || {
  echo "error: objcopy not found: ${OBJCOPY}" >&2
  exit 1
}
tool_present "${MKIMAGE}" || {
  echo "error: mkimage not found: ${MKIMAGE}" >&2
  exit 1
}

TRASH_ROOT="${RVTEST_TRASH_ROOT}/build-cleanups/k1-scheduler-image"
if [[ -e "${OUTPUT_DIR}" ]]; then
  mkdir -p "${TRASH_ROOT}"
  mv "${OUTPUT_DIR}" "${TRASH_ROOT}/${SUITE_NAME}.$(date +%Y%m%d-%H%M%S)"
fi

mkdir -p "${OUTPUT_DIR}/generated" "${OUTPUT_DIR}/obj"

SCOPE_LIST_PATH="${OUTPUT_DIR}/selected-scopes.txt"
MANIFEST_PATH="${OUTPUT_DIR}/manifest.tsv"
SUITE_INPUT_PATH="${OUTPUT_DIR}/generated/suite_inputs.tsv"
SUITE_DATA_PATH="${OUTPUT_DIR}/generated/suite_data.S"
SCHEDULER_ELF="${OUTPUT_DIR}/scheduler.elf"
SCHEDULER_BIN="${OUTPUT_DIR}/scheduler.bin"
SCHEDULER_MAP="${OUTPUT_DIR}/scheduler.map"
FIT_ITS="${OUTPUT_DIR}/${SUITE_NAME}.its"
SCHEDULER_ITB="${OUTPUT_DIR}/u-boot.itb"
DTB_COPY="${OUTPUT_DIR}/$(basename "${SDK_DTB_PATH}")"
FLASH_COMMAND="${OUTPUT_DIR}/flash-command.sh"
README_PATH="${OUTPUT_DIR}/README.txt"

: >"${SCOPE_LIST_PATH}"
: >"${SUITE_INPUT_PATH}"

TOTAL_ELF_COUNT=0
for scope in "${SCOPES[@]}"; do
  ELF_DIR="${REPO_ROOT}/work/spacemit-k1-bpi-f3-scheduler/elfs/${scope}"
  [[ -d "${ELF_DIR}" ]] || {
    echo "error: scheduler ELF directory not found: ${ELF_DIR}" >&2
    echo "hint: build the scheduler-specific ACT ELFs first:" >&2
    echo "  EXTENSIONS=\"\$(sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' scripts/board/spacemit_k1_bpi_f3/extension_sets/k1-smode-packable-v1.txt | paste -sd, -)\" CONFIG_FILES=config/cores/spacemit-k1-bpi-f3-scheduler/test_config.yaml make elfs" >&2
    echo "  # for the capability-superset preset such as k1-supported-v1:" >&2
    echo "  CONFIG_FILES=config/cores/spacemit-k1-bpi-f3-scheduler/test_config.yaml EXCLUDE_EXTENSIONS= make elfs" >&2
    exit 1
  }

  mapfile -t SCOPE_ELF_FILES < <(find "${ELF_DIR}" -type f -name '*.elf' | sort)
  if [[ "${#SCOPE_ELF_FILES[@]}" -eq 0 ]]; then
    echo "error: no ELF files found in ${ELF_DIR}" >&2
    exit 1
  fi

  if [[ -n "${ONLY_TEST_NAME}" ]]; then
    mapfile -t ONLY_ELF_MATCHES < <(find "${ELF_DIR}" -type f -name "${ONLY_TEST_NAME}.elf" | sort)
    if [[ "${#ONLY_ELF_MATCHES[@]}" -eq 0 ]]; then
      echo "error: requested --only test not found under ${ELF_DIR}: ${ONLY_TEST_NAME}.elf" >&2
      exit 1
    fi
    if [[ "${#ONLY_ELF_MATCHES[@]}" -ne 1 ]]; then
      echo "error: requested --only test is ambiguous under ${ELF_DIR}: ${ONLY_TEST_NAME}.elf" >&2
      printf '  %s\n' "${ONLY_ELF_MATCHES[@]}" >&2
      exit 1
    fi
    SCOPE_ELF_FILES=("${ONLY_ELF_MATCHES[0]}")
  fi

  printf '%s\n' "${scope}" >>"${SCOPE_LIST_PATH}"
  for elf_file in "${SCOPE_ELF_FILES[@]}"; do
    rel_under_scope="${elf_file#"${ELF_DIR}/"}"
    if [[ "${rel_under_scope}" == "${elf_file}" ]]; then
      echo "error: failed to derive relative path for ${elf_file}" >&2
      exit 1
    fi
    printf '%s\t%s\t%s\n' "${scope}" "${scope}/${rel_under_scope}" "${elf_file}" >>"${SUITE_INPUT_PATH}"
    TOTAL_ELF_COUNT=$((TOTAL_ELF_COUNT + 1))
  done
done

if [[ "${TOTAL_ELF_COUNT}" -eq 0 ]]; then
  echo "error: no ELF files selected" >&2
  exit 1
fi

cp "${SDK_DTB_PATH}" "${DTB_COPY}"

python3 - "${SUITE_NAME}" "${SCOPE_LABEL}" "${MANIFEST_PATH}" "${SUITE_DATA_PATH}" "${SUITE_INPUT_PATH}" <<'PY'
import csv
import sys
from pathlib import Path

suite_name = sys.argv[1]
scope_label = sys.argv[2]
manifest_path = Path(sys.argv[3])
suite_data_path = Path(sys.argv[4])
suite_input_path = Path(sys.argv[5])

rows = []
with suite_input_path.open("r", encoding="utf-8") as handle:
    for index, raw_line in enumerate(handle):
        raw_line = raw_line.rstrip("\n")
        if not raw_line:
            continue
        scope, relpath, elf_path_str = raw_line.split("\t", 2)
        elf_path = Path(elf_path_str).resolve()
        rows.append(
            {
                "index": str(index),
                "scope": scope,
                "name": Path(relpath).stem,
                "relpath": relpath,
                "elf_bytes": str(elf_path.stat().st_size),
                "abspath": str(elf_path),
            }
        )

with manifest_path.open("w", encoding="utf-8", newline="") as handle:
    writer = csv.DictWriter(
        handle,
        fieldnames=["index", "scope", "name", "relpath", "elf_bytes"],
        delimiter="\t",
    )
    writer.writeheader()
    for row in rows:
        writer.writerow({k: row[k] for k in ("index", "scope", "name", "relpath", "elf_bytes")})

with suite_data_path.open("w", encoding="utf-8") as handle:
    handle.write('.section .rodata.suite, "a", @progbits\n')
    handle.write('.balign 8\n')
    handle.write('.globl k1_suite_name\n')
    handle.write('k1_suite_name:\n')
    handle.write(f'  .asciz "{suite_name}"\n')
    handle.write('.globl k1_suite_scope\n')
    handle.write('k1_suite_scope:\n')
    handle.write(f'  .asciz "{scope_label}"\n')
    handle.write('.balign 8\n')
    handle.write('.globl k1_suite_cases\n')
    handle.write('k1_suite_cases:\n')
    for row in rows:
        index = row["index"]
        handle.write(
            f'  .dword case_{index}_name, case_{index}_path, case_{index}_elf_start, case_{index}_elf_end\n'
        )
    handle.write('.globl k1_suite_cases_end\n')
    handle.write('k1_suite_cases_end:\n')
    for row in rows:
        index = row["index"]
        handle.write(f'case_{index}_name:\n')
        handle.write(f'  .asciz "{row["name"]}"\n')
        handle.write(f'case_{index}_path:\n')
        handle.write(f'  .asciz "{row["relpath"]}"\n')
        handle.write('  .balign 8\n')
        handle.write(f'case_{index}_elf_start:\n')
        handle.write(f'  .incbin "{row["abspath"]}"\n')
        handle.write(f'case_{index}_elf_end:\n')
        handle.write('  .balign 8\n')
PY

SCHEDULER_SRC_DIR="${SCRIPT_DIR}/scheduler"
START_OBJ="${OUTPUT_DIR}/obj/start.o"
CORE_OBJ="${OUTPUT_DIR}/obj/scheduler.o"
SUITE_OBJ="${OUTPUT_DIR}/obj/suite_data.o"

COMMON_FLAGS=(
  -march=rv64imac_zicsr_zifencei
  -mabi=lp64
  -mcmodel=medany
  -mno-relax
  -msmall-data-limit=0
  -ffreestanding
  -fno-builtin
  -fno-pic
  -fno-stack-protector
  -fno-omit-frame-pointer
  -Wall
  -Wextra
  -O2
  -DSCHEDULER_TIMEOUT_MS=${TIMEOUT_MS_INPUT}
)

"${CC}" "${COMMON_FLAGS[@]}" -c "${SCHEDULER_SRC_DIR}/start.S" -o "${START_OBJ}"
"${CC}" "${COMMON_FLAGS[@]}" -std=c11 -c "${SCHEDULER_SRC_DIR}/scheduler.c" -o "${CORE_OBJ}"
"${CC}" "${COMMON_FLAGS[@]}" -c "${SUITE_DATA_PATH}" -o "${SUITE_OBJ}"
"${CC}" \
  "${COMMON_FLAGS[@]}" \
  -nostdlib \
  -nostartfiles \
  -static \
  -Wl,--build-id=none \
  -Wl,-Map,"${SCHEDULER_MAP}" \
  -T "${SCHEDULER_SRC_DIR}/link.ld" \
  "${START_OBJ}" "${CORE_OBJ}" "${SUITE_OBJ}" \
  -o "${SCHEDULER_ELF}"

"${OBJCOPY}" -O binary "${SCHEDULER_ELF}" "${SCHEDULER_BIN}"

cat >"${FIT_ITS}" <<EOF
/dts-v1/;

/ {
    description = "K1 scheduler FIT image";
    #address-cells = <2>;
    fit,fdt-list = "of-list";

    images {
        uboot {
            description = "K1 ACT scheduler image";
            type = "standalone";
            os = "U-Boot";
            arch = "riscv";
            compression = "none";
            load = <${SCHEDULER_LOAD_ADDR_FDT}>;
            entry = <${SCHEDULER_LOAD_ADDR_FDT}>;
            data = /incbin/("${SCHEDULER_BIN}");
            hash-1 {
                algo = "crc32";
            };
        };

        fdt_1 {
            description = "k1-x_deb1";
            type = "flat_dt";
            compression = "none";
            data = /incbin/("${DTB_COPY}");
            hash-1 {
                algo = "crc32";
            };
        };
    };

    configurations {
        default = "conf_1";
        conf_1 {
            description = "k1-x_deb1 scheduler payload";
            loadables = "uboot";
            fdt = "fdt_1";
        };
    };
};
EOF

(
  cd "${OUTPUT_DIR}"
  "${MKIMAGE}" -f "${FIT_ITS}" "${SCHEDULER_ITB}"
)

FLASH_FSBL_PATH="$(path_expr_for_flash_command "${FSBL_PATH}")"
FLASH_OPENSBI_PATH="$(path_expr_for_flash_command "${OPENSBI_PATH}")"
FLASH_UBOOT_ITB_PATH="$(path_expr_for_flash_command "${SCHEDULER_ITB}")"

cat >"${FLASH_COMMAND}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="\$(cd -- "\$(dirname -- "\${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="\$(cd -- "\${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="\$(cd -- "\${REPO_ROOT}/.." && pwd)"

cd "\${REPO_ROOT}"
bash scripts/board/spacemit_k1_bpi_f3/flash_k1_test_card.sh \\
  --fsbl "${FLASH_FSBL_PATH}" \\
  --opensbi "${FLASH_OPENSBI_PATH}" \\
  --uboot-itb "${FLASH_UBOOT_ITB_PATH}"
EOF
chmod +x "${FLASH_COMMAND}"

cat >"${README_PATH}" <<EOF
K1 scheduler image for scope label:
  ${SCOPE_LABEL}

Suite name:
  ${SUITE_NAME}

Selected scopes:
  ${SCOPE_LIST_PATH}

Selected test filter:
  ${ONLY_TEST_NAME:-<all tests in selected scopes>}

Generated artifacts:
  ${SCOPE_LIST_PATH}
  ${MANIFEST_PATH}
  ${SCHEDULER_ELF}
  ${SCHEDULER_BIN}
  ${SCHEDULER_ITB}
  ${FLASH_COMMAND}

Board handoff:
  fsbl    partition <- ${FSBL_PATH}
  opensbi partition <- ${OPENSBI_PATH}
  uboot   partition <- ${SCHEDULER_ITB}
  flash-command.sh always writes the SD card on the local host.
  Default staging/backup/check directory:
    <workspace-root>/act_k1_bianbu22

Selected SDK DTB:
  path: ${SDK_DTB_PATH}
  size: ${SDK_DTB_SIZE_BYTES} bytes

Scheduler handoff:
  load/entry = ${SCHEDULER_LOAD_ADDR_HEX}

Allowed ACT ELF runtime window:
  [${TEST_WINDOW_START_HEX}, ${TEST_WINDOW_END_HEX})

Expected serial markers:
  ACT-SCHED: BOOT
  ACT-SCHED: CASE
  ACT-SCHED: RESULT
  ACT-SCHED: COMPLETE
EOF

echo "Built K1 scheduler image:"
echo "  scopes:        ${SCOPE_LIST_PATH}"
echo "  manifest:      ${MANIFEST_PATH}"
echo "  scheduler ELF: ${SCHEDULER_ELF}"
echo "  scheduler BIN: ${SCHEDULER_BIN}"
echo "  scheduler FIT: ${SCHEDULER_ITB}"
echo "  sdk dtb:       ${SDK_DTB_PATH} (${SDK_DTB_SIZE_BYTES} bytes)"
echo "  flash helper:  ${FLASH_COMMAND}"
