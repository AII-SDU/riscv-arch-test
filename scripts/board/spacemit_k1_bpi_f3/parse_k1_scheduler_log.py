#!/usr/bin/env python3
"""Parse K1 scheduler serial logs into per-test results."""

from __future__ import annotations

import argparse
import csv
import re
import sys
from collections import Counter
from pathlib import Path


CASE_RE = re.compile(
    r"ACT-SCHED: CASE index=(?P<index>\d+) total=(?P<total>\d+) "
    r"name=(?P<name>\S+) path=(?P<path>\S+)"
)
RESULT_RE = re.compile(
    r"ACT-SCHED: RESULT index=(?P<index>\d+) total=(?P<total>\d+) "
    r"name=(?P<name>\S+) status=(?P<status>\S+)"
)
LOAD_ERROR_RE = re.compile(r"ACT-SCHED: LOAD_ERROR .*")
UNEXPECTED_RETURN_RE = re.compile(r"ACT-SCHED: UNEXPECTED_RETURN .*")
TIMEOUT_RE = re.compile(r"ACT-SCHED: TIMEOUT .*")
SUMMARY_RE = re.compile(
    r'RVCP-SUMMARY: TEST (?P<status>PASSED|FAILED) - Test File "(?P<test_file>[^"]+)"'
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", required=True, help="Path to manifest.tsv")
    parser.add_argument("--serial-log", required=True, help="Path to captured serial log")
    parser.add_argument(
        "--output",
        help="Optional TSV output path. Defaults to stdout only when omitted.",
    )
    return parser.parse_args()


def load_manifest(path: Path) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with path.open("r", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            row["status"] = "NOT_RUN"
            row["summary_test"] = ""
            row["notes"] = ""
            rows.append(row)
    return rows


def write_tsv(rows: list[dict[str, str]], output_path: Path | None) -> None:
    fieldnames = ["index", "name", "relpath", "status", "summary_test", "notes"]
    output_rows = [{field: row.get(field, "") for field in fieldnames} for row in rows]
    if output_path is None:
        writer = csv.DictWriter(sys.stdout, fieldnames=fieldnames, delimiter="\t")
        writer.writeheader()
        writer.writerows(output_rows)
        return

    with output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter="\t")
        writer.writeheader()
        writer.writerows(output_rows)


def main() -> int:
    args = parse_args()
    manifest_path = Path(args.manifest).resolve()
    serial_log_path = Path(args.serial_log).resolve()
    output_path = Path(args.output).resolve() if args.output else None

    rows = load_manifest(manifest_path)
    row_by_index = {int(row["index"]): row for row in rows}
    current: dict[str, str] | None = None

    with serial_log_path.open("r", encoding="utf-8", errors="replace") as handle:
        for line in handle:
            case_match = CASE_RE.search(line)
            if case_match:
                current = row_by_index.get(int(case_match.group("index")))
                if current is None:
                    continue
                current["status"] = "PENDING"
                current["notes"] = ""
                current["summary_test"] = ""
                expected_name = current["name"]
                expected_path = current["relpath"]
                actual_name = case_match.group("name")
                actual_path = case_match.group("path")
                if expected_name != actual_name or expected_path != actual_path:
                    current["notes"] = (
                        f"Manifest mismatch: expected {expected_name} {expected_path}, "
                        f"saw {actual_name} {actual_path}"
                    )
                continue

            if current is not None:
                summary_match = SUMMARY_RE.search(line)
                if summary_match:
                    current["summary_test"] = summary_match.group("test_file")
                    continue

                if LOAD_ERROR_RE.search(line):
                    current["notes"] = line.strip()
                    continue
                if UNEXPECTED_RETURN_RE.search(line):
                    current["notes"] = line.strip()
                    continue
                if TIMEOUT_RE.search(line):
                    current["notes"] = line.strip()
                    continue

            result_match = RESULT_RE.search(line)
            if result_match:
                row = row_by_index.get(int(result_match.group("index")))
                if row is None:
                    continue
                row["status"] = result_match.group("status")
                current = row
                continue

    for row in rows:
        if row["status"] == "PENDING":
            row["status"] = "INCOMPLETE"
            if not row["notes"]:
                row["notes"] = "Saw CASE but no final RESULT line"

    counts = Counter(row["status"] for row in rows)
    summary = ", ".join(f"{key}={counts[key]}" for key in sorted(counts))
    print(f"Parsed {len(rows)} manifest cases from {serial_log_path}", file=sys.stderr)
    print(f"Status summary: {summary}", file=sys.stderr)
    if output_path is not None:
        print(f"Results TSV: {output_path}", file=sys.stderr)

    write_tsv(rows, output_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
