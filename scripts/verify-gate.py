#!/usr/bin/env python3
"""Validate compact JSON-lines evidence emitted by the standalone runner."""

import argparse
import json
from pathlib import Path


def load(path: Path):
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if not rows:
        raise AssertionError("runner emitted no JSON-lines results")
    return rows


def require_cleaned(row):
    assert row["context_destroyed"] is True, row
    assert row["sampler_reset"] is True, row
    assert row["sampler_destroyed"] is True, row
    assert row["kv_before"] == -1, row
    assert row["kv_after_clear"] == -1, row


def smoke(rows, backend):
    assert len(rows) == 1, rows
    row = rows[0]
    assert row["id"] == f"{backend}-smoke", row
    assert row["status"] == "ok", row
    assert row["backend"] == backend, row
    assert row["prompt_tokens"] > 0 and row["decode_calls"] > 0, row
    require_cleaned(row)


def structured(rows, backend):
    assert len(rows) == 1, rows
    row = rows[0]
    assert backend == "cpu", backend
    assert row["id"] == "structured-final", row
    assert row["status"] == "ok" and row["finish"] == "eog", row
    assert row["output_classification"] == "final_answer", row
    assert json.loads(row["final_text"]) == {"answer": "blue"}, row
    require_cleaned(row)


def lifecycle(rows, backend):
    assert backend == "cpu", backend
    expected_ids = {
        "structured-final",
        "cancelled-before-decode",
        "injected-failure",
        "grammar-accepted",
        "grammar-rejected",
    }
    expected_cycles = 3
    assert len(rows) == len(expected_ids) * expected_cycles, rows
    grouped = {request_id: [] for request_id in expected_ids}
    for row in rows:
        assert row["id"] in grouped, row
        grouped[row["id"]].append(row)
    assert all(len(matches) == expected_cycles for matches in grouped.values()), grouped
    by_id = {request_id: matches[-1] for request_id, matches in grouped.items()}
    structured([by_id["structured-final"]], backend)
    cancelled = by_id["cancelled-before-decode"]
    assert cancelled["status"] == "ok" and cancelled["finish"] == "cancelled", cancelled
    require_cleaned(cancelled)
    failure = by_id["injected-failure"]
    assert failure["status"] == "InjectedFailure" and failure["finish"] == "error", failure
    require_cleaned(failure)
    accepted = by_id["grammar-accepted"]
    rejected = by_id["grammar-rejected"]
    assert accepted["grammar_accepts"] is True and accepted["finish"] == "grammar_accepted", accepted
    assert rejected["grammar_accepts"] is False and rejected["finish"] == "grammar_rejected", rejected
    for row in (accepted, rejected):
        assert row["sampler_reset"] is True and row["sampler_destroyed"] is True, row


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--case", choices=("smoke", "structured", "lifecycle"), required=True)
    parser.add_argument("--backend", choices=("cpu", "cuda"), required=True)
    parser.add_argument("--jsonl", type=Path, required=True)
    args = parser.parse_args()
    rows = load(args.jsonl)
    {"smoke": smoke, "structured": structured, "lifecycle": lifecycle}[args.case](rows, args.backend)
    print(f"PASS: {args.backend} {args.case} ({len(rows)} result rows)")


if __name__ == "__main__":
    main()
