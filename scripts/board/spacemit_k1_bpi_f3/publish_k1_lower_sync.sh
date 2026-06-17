#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/board/spacemit_k1_bpi_f3/publish_k1_lower_sync.sh \
    [--state-dir <path>] \
    [--message <commit-message>]

Purpose:
  Publish source edits pulled back from the lower-machine workspace. This
  script must run on the server-side Git working tree.

Defaults:
  --state-dir  <workspace-root>/logs/k1-lower-sync/latest
  --message    sync lower K1 workspace updates

Safety:
  - Refuses to publish when lower pulled paths overlap with pre-existing server
    dirty paths recorded before the pull.
  - Only stages paths listed in pulled_paths.txt.
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../../.." && pwd)"
WORKSPACE_ROOT="$(cd -- "${REPO_ROOT}/.." && pwd)"
STATE_DIR="${WORKSPACE_ROOT}/logs/k1-lower-sync/latest"
COMMIT_MESSAGE="sync lower K1 workspace updates"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --state-dir)
      STATE_DIR="${2:-}"
      shift 2
      ;;
    --message)
      COMMIT_MESSAGE="${2:-}"
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

require_tool() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: required tool not found: $1" >&2
    exit 1
  }
}

require_tool git
require_tool python3

STATE_DIR="$(python3 - "$STATE_DIR" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
)"

PRE_PULL_FILE="${STATE_DIR}/pre_pull_dirty.txt"
PULLED_FILE="${STATE_DIR}/pulled_paths.txt"

[[ -d "${STATE_DIR}" ]] || {
  echo "error: sync state directory not found: ${STATE_DIR}" >&2
  exit 1
}
[[ -f "${PRE_PULL_FILE}" ]] || {
  echo "error: missing pre-pull dirty record: ${PRE_PULL_FILE}" >&2
  exit 1
}
[[ -f "${PULLED_FILE}" ]] || {
  echo "error: missing pulled-path record: ${PULLED_FILE}" >&2
  exit 1
}

mapfile -t PRE_PULL_DIRTY < "${PRE_PULL_FILE}"
mapfile -t PULLED_PATHS < "${PULLED_FILE}"

if [[ "${#PULLED_PATHS[@]}" -eq 0 ]]; then
  echo "error: pulled_paths.txt is empty; nothing to publish." >&2
  exit 1
fi

python3 - "${PRE_PULL_FILE}" "${PULLED_FILE}" <<'PY'
import sys
from pathlib import Path

pre = {line.strip() for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()}
pulled = {line.strip() for line in Path(sys.argv[2]).read_text(encoding="utf-8").splitlines() if line.strip()}
overlap = sorted(pre & pulled)
if overlap:
    print("error: lower pulled paths overlap with existing server dirty paths:", file=sys.stderr)
    for item in overlap:
        print(f"  {item}", file=sys.stderr)
    sys.exit(1)
PY

BRANCH="$(git -C "${REPO_ROOT}" branch --show-current)"
[[ -n "${BRANCH}" ]] || {
  echo "error: unable to resolve current Git branch." >&2
  exit 1
}

git -C "${REPO_ROOT}" add -A -- "${PULLED_PATHS[@]}"

if git -C "${REPO_ROOT}" diff --cached --quiet; then
  echo "No staged lower-workspace changes to publish."
  exit 0
fi

git -C "${REPO_ROOT}" commit -m "${COMMIT_MESSAGE}"
git -C "${REPO_ROOT}" push origin "${BRANCH}"

echo "Published lower-machine sync:"
echo "  branch: ${BRANCH}"
echo "  state:  ${STATE_DIR}"
