#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/board/spacemit_k1_bpi_f3/build_k1_scheduler_image_custom.sh \
    [--base-scope <family/ext> ... | --base-scope-set <preset-name> | --base-scopes-file <path> | \
     --base-extension <ext> ... | --base-extension-set <preset-name> | --base-extensions-file <path>] \
    [--include-scope <family/ext> ...] \
    [--exclude-scope <family/ext> ...] \
    [--include-extension <ext> ...] \
    [--exclude-extension <ext> ...] \
    [--suite-name <name>] \
    [--only <test-name>] \
    [--timeout-ms <ms>] \
    [--fsbl <path-to-FSBL.bin>] \
    [--opensbi <path-to-fw_dynamic.itb>] \
    [--sdk-dtb <path-to-k1-x_deb1.dtb>] \
    [--output-root <path>]

Purpose:
  Build a K1 scheduler image from a filtered scope list without editing the
  committed preset files. This wrapper generates a scopes file, then calls
  build_k1_scheduler_image.sh.

Base scope selection:
  Exactly one base input must be used:
    --base-scope <family/ext>         One or more base scopes
    --base-scope-set <preset-name>    Preset from scripts/.../scope_sets/
    --base-scopes-file <path>         Newline-delimited file
    --base-extension <ext>            One or more extensions, resolved to scopes
    --base-extension-set <name>       Preset from scripts/.../extension_sets/
    --base-extensions-file <path>     Newline-delimited file

Filtering:
  --exclude-scope <family/ext>        Remove a scope from the base list
  --include-scope <family/ext>        Append a scope if it is not already present
  --exclude-extension <ext>           Remove all scopes resolved from an extension
  --include-extension <ext>           Append all scopes resolved from an extension

  Scope list files may contain blank lines and '#' comments.
  Extension list files may contain blank lines and '#' comments.
  Duplicate scopes are removed while preserving order.
  If the same scope is both included and excluded, exclude wins.

Extension resolution:
  The wrapper resolves extension names against the currently generated K1
  scheduler ELF tree under work/spacemit-k1-bpi-f3-scheduler/elfs/.
  Useful aliases:
    RV64I -> rv64i/I
    A     -> rv64i/Zaamo + rv64i/Zalrsc
    C     -> rv64i/Zca + rv64i/Zcd

Generated files:
  work/spacemit-k1-bpi-f3-scheduler/generated-scopes/<suite-name>.txt
  work/spacemit-k1-bpi-f3-scheduler/<suite-name>/

Examples:
  bash scripts/board/spacemit_k1_bpi_f3/build_k1_scheduler_image_custom.sh \
    --base-scope-set k1-qemu-rv64-max-v1 \
    --exclude-scope priv/ZicntrS \
    --suite-name k1-qemu-rv64-max-v1-no-zicntrs

  bash scripts/board/spacemit_k1_bpi_f3/build_k1_scheduler_image_custom.sh \
    --base-extension-set k1-smode-packable-v1 \
    --suite-name k1-smode-packable-v1-scheduler

  bash scripts/board/spacemit_k1_bpi_f3/build_k1_scheduler_image_custom.sh \
    --base-extension RV64I --base-extension M --base-extension A --base-extension Zicsr \
    --include-extension Zbb \
    --exclude-extension Zicntr
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
SCOPE_SET_ROOT="${SCRIPT_DIR}/scope_sets"
EXTENSION_SET_ROOT="${SCRIPT_DIR}/extension_sets"
DEFAULT_OUTPUT_ROOT="${REPO_ROOT}/work/spacemit-k1-bpi-f3-scheduler"
DEFAULT_ELF_ROOT="${REPO_ROOT}/work/spacemit-k1-bpi-f3-scheduler/elfs"
MAIN_BUILD_SCRIPT="${SCRIPT_DIR}/build_k1_scheduler_image.sh"

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

read_list_file() {
  local path="$1"
  python3 - "${path}" <<'PY'
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
}

resolve_extensions_to_scopes() {
  local mode="$1"
  shift
  python3 - "${DEFAULT_ELF_ROOT}" "${mode}" "$@" <<'PY'
import sys
from collections import defaultdict
from pathlib import Path

elf_root = Path(sys.argv[1])
mode = sys.argv[2]
requested = [arg.strip() for arg in sys.argv[3:] if arg.strip()]

if not elf_root.is_dir():
    print(f"error: ELF root not found: {elf_root}", file=sys.stderr)
    sys.exit(1)

available_scopes = sorted(
    str(path.relative_to(elf_root))
    for path in elf_root.glob("*/*")
    if path.is_dir()
)

scopes_by_name = defaultdict(list)
for scope in available_scopes:
    scopes_by_name[scope.split("/", 1)[1].lower()].append(scope)

alias_map = {
    "rv64i": ["I"],
    "rv64i-base": ["I"],
    "a": ["Zaamo", "Zalrsc"],
    "c": ["Zca", "Zcd"],
}

resolved = []
seen = set()
missing = []

for extension in requested:
    target_names = alias_map.get(extension.lower(), [extension])
    matches = []
    for name in target_names:
        matches.extend(scopes_by_name.get(name.lower(), []))
    if not matches and extension in available_scopes:
        matches = [extension]
    if not matches:
        missing.append(extension)
        continue
    for scope in matches:
        if scope in seen:
            continue
        seen.add(scope)
        resolved.append(scope)

if missing:
    message = ", ".join(missing)
    if mode == "strict":
        print(f"error: no current K1 scheduler ELF scope matches extension(s): {message}", file=sys.stderr)
        print(f"hint: available scope names are discovered from {elf_root}", file=sys.stderr)
        sys.exit(1)
    print(f"warning: ignored unresolved extension(s): {message}", file=sys.stderr)

for scope in resolved:
    print(scope)
PY
}

declare -a BASE_SCOPES=()
BASE_SCOPES_FILE_INPUT=""
BASE_SCOPE_SET_INPUT=""
declare -a BASE_EXTENSIONS=()
BASE_EXTENSIONS_FILE_INPUT=""
BASE_EXTENSION_SET_INPUT=""
declare -a INCLUDE_SCOPES=()
declare -a EXCLUDE_SCOPES=()
declare -a INCLUDE_EXTENSIONS=()
declare -a EXCLUDE_EXTENSIONS=()
SUITE_NAME_INPUT=""
ONLY_TEST_NAME=""
TIMEOUT_MS_INPUT=""
FSBL_INPUT=""
OPENSBI_INPUT=""
SDK_DTB_INPUT=""
OUTPUT_ROOT_INPUT="${DEFAULT_OUTPUT_ROOT}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-scope)
      BASE_SCOPES+=("${2:-}")
      shift 2
      ;;
    --base-scopes-file)
      BASE_SCOPES_FILE_INPUT="${2:-}"
      shift 2
      ;;
    --base-scope-set)
      BASE_SCOPE_SET_INPUT="${2:-}"
      shift 2
      ;;
    --base-extension)
      BASE_EXTENSIONS+=("${2:-}")
      shift 2
      ;;
    --base-extensions-file)
      BASE_EXTENSIONS_FILE_INPUT="${2:-}"
      shift 2
      ;;
    --base-extension-set)
      BASE_EXTENSION_SET_INPUT="${2:-}"
      shift 2
      ;;
    --include-scope)
      INCLUDE_SCOPES+=("${2:-}")
      shift 2
      ;;
    --exclude-scope)
      EXCLUDE_SCOPES+=("${2:-}")
      shift 2
      ;;
    --include-extension)
      INCLUDE_EXTENSIONS+=("${2:-}")
      shift 2
      ;;
    --exclude-extension)
      EXCLUDE_EXTENSIONS+=("${2:-}")
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

command -v python3 >/dev/null 2>&1 || {
  echo "error: python3 not found" >&2
  exit 1
}

[[ -x "${MAIN_BUILD_SCRIPT}" ]] || {
  echo "error: main build script not found: ${MAIN_BUILD_SCRIPT}" >&2
  exit 1
}

BASE_SOURCE_COUNT=0
if [[ "${#BASE_SCOPES[@]}" -gt 0 ]]; then
  BASE_SOURCE_COUNT=$((BASE_SOURCE_COUNT + 1))
fi
if [[ -n "${BASE_SCOPES_FILE_INPUT}" ]]; then
  BASE_SOURCE_COUNT=$((BASE_SOURCE_COUNT + 1))
fi
if [[ -n "${BASE_SCOPE_SET_INPUT}" ]]; then
  BASE_SOURCE_COUNT=$((BASE_SOURCE_COUNT + 1))
fi
if [[ "${#BASE_EXTENSIONS[@]}" -gt 0 ]]; then
  BASE_SOURCE_COUNT=$((BASE_SOURCE_COUNT + 1))
fi
if [[ -n "${BASE_EXTENSIONS_FILE_INPUT}" ]]; then
  BASE_SOURCE_COUNT=$((BASE_SOURCE_COUNT + 1))
fi
if [[ -n "${BASE_EXTENSION_SET_INPUT}" ]]; then
  BASE_SOURCE_COUNT=$((BASE_SOURCE_COUNT + 1))
fi
if [[ "${BASE_SOURCE_COUNT}" -ne 1 ]]; then
  echo "error: select exactly one base source with scope or extension inputs" >&2
  usage
  exit 1
fi

if [[ -n "${BASE_SCOPE_SET_INPUT}" ]]; then
  BASE_SCOPES_FILE_INPUT="${SCOPE_SET_ROOT}/${BASE_SCOPE_SET_INPUT}.txt"
fi

if [[ -n "${BASE_EXTENSION_SET_INPUT}" ]]; then
  BASE_EXTENSIONS_FILE_INPUT="${EXTENSION_SET_ROOT}/${BASE_EXTENSION_SET_INPUT}.txt"
fi

if [[ -n "${BASE_SCOPES_FILE_INPUT}" ]]; then
  BASE_SCOPES_FILE_PATH="$(abs_path "${BASE_SCOPES_FILE_INPUT}")"
  [[ -f "${BASE_SCOPES_FILE_PATH}" ]] || {
    echo "error: base scopes file not found: ${BASE_SCOPES_FILE_PATH}" >&2
    exit 1
  }
  mapfile -t BASE_SCOPES < <(read_list_file "${BASE_SCOPES_FILE_PATH}")
fi

if [[ -n "${BASE_EXTENSIONS_FILE_INPUT}" ]]; then
  BASE_EXTENSIONS_FILE_PATH="$(abs_path "${BASE_EXTENSIONS_FILE_INPUT}")"
  [[ -f "${BASE_EXTENSIONS_FILE_PATH}" ]] || {
    echo "error: base extensions file not found: ${BASE_EXTENSIONS_FILE_PATH}" >&2
    exit 1
  }
  mapfile -t BASE_EXTENSIONS < <(read_list_file "${BASE_EXTENSIONS_FILE_PATH}")
fi

if [[ "${#BASE_EXTENSIONS[@]}" -gt 0 ]]; then
  mapfile -t BASE_SCOPES < <(resolve_extensions_to_scopes strict "${BASE_EXTENSIONS[@]}")
fi

if [[ "${#BASE_SCOPES[@]}" -eq 0 ]]; then
  echo "error: no base scopes selected" >&2
  exit 1
fi

declare -A EXCLUDED_SCOPES=()
for scope in "${EXCLUDE_SCOPES[@]}"; do
  if [[ -n "${scope}" ]]; then
    EXCLUDED_SCOPES["${scope}"]=1
  fi
done

if [[ "${#EXCLUDE_EXTENSIONS[@]}" -gt 0 ]]; then
  mapfile -t RESOLVED_EXCLUDE_SCOPES < <(resolve_extensions_to_scopes warn "${EXCLUDE_EXTENSIONS[@]}")
  for scope in "${RESOLVED_EXCLUDE_SCOPES[@]}"; do
    if [[ -n "${scope}" ]]; then
      EXCLUDED_SCOPES["${scope}"]=1
    fi
  done
fi

declare -A SEEN_SCOPES=()
declare -a FINAL_SCOPES=()
for scope in "${BASE_SCOPES[@]}"; do
  if [[ -z "${scope}" || -n "${SEEN_SCOPES[${scope}]+x}" ]]; then
    continue
  fi
  SEEN_SCOPES["${scope}"]=1
  if [[ -n "${EXCLUDED_SCOPES[${scope}]+x}" ]]; then
    continue
  fi
  FINAL_SCOPES+=("${scope}")
done

declare -a RESOLVED_INCLUDE_SCOPES=()
if [[ "${#INCLUDE_EXTENSIONS[@]}" -gt 0 ]]; then
  mapfile -t RESOLVED_INCLUDE_SCOPES < <(resolve_extensions_to_scopes strict "${INCLUDE_EXTENSIONS[@]}")
fi

for scope in "${INCLUDE_SCOPES[@]}" "${RESOLVED_INCLUDE_SCOPES[@]}"; do
  if [[ -z "${scope}" || -n "${EXCLUDED_SCOPES[${scope}]+x}" || -n "${SEEN_SCOPES[${scope}]+x}" ]]; then
    continue
  fi
  FINAL_SCOPES+=("${scope}")
  SEEN_SCOPES["${scope}"]=1
done

if [[ "${#FINAL_SCOPES[@]}" -eq 0 ]]; then
  echo "error: no scopes remain after filtering" >&2
  exit 1
fi

if [[ -n "${ONLY_TEST_NAME}" && "${#FINAL_SCOPES[@]}" -ne 1 ]]; then
  echo "error: --only requires exactly one scope after filtering" >&2
  exit 1
fi

if [[ -n "${BASE_SCOPE_SET_INPUT}" ]]; then
  BASE_LABEL="${BASE_SCOPE_SET_INPUT}"
elif [[ -n "${BASE_EXTENSION_SET_INPUT}" ]]; then
  BASE_LABEL="${BASE_EXTENSION_SET_INPUT}"
elif [[ -n "${BASE_SCOPES_FILE_INPUT}" ]]; then
  BASE_LABEL="$(basename "${BASE_SCOPES_FILE_INPUT}")"
  BASE_LABEL="${BASE_LABEL%.*}"
elif [[ -n "${BASE_EXTENSIONS_FILE_INPUT}" ]]; then
  BASE_LABEL="$(basename "${BASE_EXTENSIONS_FILE_INPUT}")"
  BASE_LABEL="${BASE_LABEL%.*}"
elif [[ "${#BASE_SCOPES[@]}" -eq 1 ]]; then
  BASE_LABEL="${BASE_SCOPES[0]}"
elif [[ "${#BASE_EXTENSIONS[@]}" -eq 1 ]]; then
  BASE_LABEL="${BASE_EXTENSIONS[0]}"
elif [[ "${#BASE_EXTENSIONS[@]}" -gt 1 ]]; then
  BASE_LABEL="multi-extension"
else
  BASE_LABEL="multi-scope"
fi

SUITE_NAME_DEFAULT="$(sanitize_name "${BASE_LABEL}")-custom-scheduler"
SUITE_NAME_RAW="${SUITE_NAME_INPUT:-${SUITE_NAME_DEFAULT}}"
SUITE_NAME="$(sanitize_name "${SUITE_NAME_RAW}")"
OUTPUT_ROOT="$(abs_path "${OUTPUT_ROOT_INPUT}")"
GENERATED_SCOPE_ROOT="${OUTPUT_ROOT}/generated-scopes"
GENERATED_SCOPES_FILE="${GENERATED_SCOPE_ROOT}/${SUITE_NAME}.txt"
mkdir -p "${GENERATED_SCOPE_ROOT}"

{
  echo "# Generated by build_k1_scheduler_image_custom.sh"
  if [[ -n "${BASE_SCOPE_SET_INPUT}" ]]; then
    echo "# Base scope set: ${BASE_SCOPE_SET_INPUT}"
  elif [[ -n "${BASE_EXTENSION_SET_INPUT}" ]]; then
    echo "# Base extension set: ${BASE_EXTENSION_SET_INPUT}"
  elif [[ -n "${BASE_SCOPES_FILE_INPUT}" ]]; then
    echo "# Base scopes file: $(abs_path "${BASE_SCOPES_FILE_INPUT}")"
  elif [[ -n "${BASE_EXTENSIONS_FILE_INPUT}" ]]; then
    echo "# Base extensions file: $(abs_path "${BASE_EXTENSIONS_FILE_INPUT}")"
  elif [[ "${#BASE_EXTENSIONS[@]}" -gt 0 ]]; then
    printf '# Base extensions: %s\n' "$(IFS=,; echo "${BASE_EXTENSIONS[*]}")"
  else
    echo "# Base scopes: ${#BASE_SCOPES[@]}"
  fi
  if [[ "${#EXCLUDE_SCOPES[@]}" -gt 0 ]]; then
    printf '# Excluded scopes: %s\n' "$(IFS=,; echo "${EXCLUDE_SCOPES[*]}")"
  fi
  if [[ "${#EXCLUDE_EXTENSIONS[@]}" -gt 0 ]]; then
    printf '# Excluded extensions: %s\n' "$(IFS=,; echo "${EXCLUDE_EXTENSIONS[*]}")"
  fi
  if [[ "${#INCLUDE_SCOPES[@]}" -gt 0 ]]; then
    printf '# Included scopes: %s\n' "$(IFS=,; echo "${INCLUDE_SCOPES[*]}")"
  fi
  if [[ "${#INCLUDE_EXTENSIONS[@]}" -gt 0 ]]; then
    printf '# Included extensions: %s\n' "$(IFS=,; echo "${INCLUDE_EXTENSIONS[*]}")"
  fi
  for scope in "${FINAL_SCOPES[@]}"; do
    printf '%s\n' "${scope}"
  done
} > "${GENERATED_SCOPES_FILE}"

echo "Generated filtered scope list: ${GENERATED_SCOPES_FILE}"
echo "Final scope count: ${#FINAL_SCOPES[@]}"
if [[ "${#EXCLUDE_SCOPES[@]}" -gt 0 ]]; then
  echo "Excluded: ${EXCLUDE_SCOPES[*]}"
fi
if [[ "${#EXCLUDE_EXTENSIONS[@]}" -gt 0 ]]; then
  echo "Excluded extensions: ${EXCLUDE_EXTENSIONS[*]}"
fi

BUILD_CMD=(
  bash
  "${MAIN_BUILD_SCRIPT}"
  --scopes-file "${GENERATED_SCOPES_FILE}"
  --suite-name "${SUITE_NAME}"
  --output-root "${OUTPUT_ROOT}"
)

if [[ -n "${ONLY_TEST_NAME}" ]]; then
  BUILD_CMD+=(--only "${ONLY_TEST_NAME}")
fi
if [[ -n "${TIMEOUT_MS_INPUT}" ]]; then
  BUILD_CMD+=(--timeout-ms "${TIMEOUT_MS_INPUT}")
fi
if [[ -n "${FSBL_INPUT}" ]]; then
  BUILD_CMD+=(--fsbl "${FSBL_INPUT}")
fi
if [[ -n "${OPENSBI_INPUT}" ]]; then
  BUILD_CMD+=(--opensbi "${OPENSBI_INPUT}")
fi
if [[ -n "${SDK_DTB_INPUT}" ]]; then
  BUILD_CMD+=(--sdk-dtb "${SDK_DTB_INPUT}")
fi

printf 'Invoking:'
printf ' %q' "${BUILD_CMD[@]}"
printf '\n'

"${BUILD_CMD[@]}"
