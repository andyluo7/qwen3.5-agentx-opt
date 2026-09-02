#!/usr/bin/env python3
"""Recompute AgentX P90 full-response interactivity from raw request records."""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path


IGNORED_AGGREGATES = {
    "agentic_power_window.json",
    "gpu_metrics_identity.json",
    "power_validation.json",
}


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        raise ValueError("cannot compute a percentile of an empty sequence")
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (position - lower) * (ordered[upper] - ordered[lower])


def find_aggregate(archive: Path) -> Path:
    candidates = [
        path
        for path in archive.glob("*.json")
        if path.name not in IGNORED_AGGREGATES
    ]
    if len(candidates) != 1:
        names = ", ".join(sorted(path.name for path in candidates))
        raise RuntimeError(
            f"expected exactly one aggregate JSON under {archive}; found: {names}"
        )
    return candidates[0]


def audit_archive(archive: Path, tolerance: float) -> dict[str, object]:
    aggregate_path = find_aggregate(archive)
    raw_path = archive / "aiperf_artifacts" / "profile_export.jsonl"
    aggregate = json.loads(aggregate_path.read_text(encoding="utf-8"))

    profiled_records = 0
    full_response_latencies_ms_per_token: list[float] = []
    with raw_path.open(encoding="utf-8") as handle:
        for line in handle:
            record = json.loads(line)
            metadata = record["metadata"]
            if metadata.get("benchmark_phase") != "profiling":
                continue
            if metadata.get("was_cancelled", False):
                continue
            profiled_records += 1
            metrics = record["metrics"]
            output_tokens = float(metrics["output_sequence_length"]["value"])
            full_decode_ms = float(metrics["full_decode_duration"]["value"])
            if output_tokens > 1 and full_decode_ms > 0:
                full_response_latencies_ms_per_token.append(
                    full_decode_ms / (output_tokens - 1)
                )

    reported_profiled = int(aggregate["request_accounting"]["records_profiled"])
    reported_p90 = float(
        aggregate["request_metrics"]["latency"]["full_response_intvty"]["p90"]
    )
    raw_p90_latency = percentile(full_response_latencies_ms_per_token, 0.90)
    recomputed_p90 = 1000.0 / raw_p90_latency
    absolute_delta = abs(recomputed_p90 - reported_p90)
    passed = profiled_records == reported_profiled and absolute_delta <= tolerance

    return {
        "archive": str(archive),
        "aggregate": str(aggregate_path),
        "raw_profiled_records": profiled_records,
        "reported_profiled_records": reported_profiled,
        "raw_records_with_defined_full_response_interactivity": len(
            full_response_latencies_ms_per_token
        ),
        "raw_p90_full_response_latency_ms_per_token": raw_p90_latency,
        "recomputed_p90_interactivity_tokens_per_s_user": recomputed_p90,
        "reported_p90_interactivity_tokens_per_s_user": reported_p90,
        "absolute_delta": absolute_delta,
        "tolerance": tolerance,
        "passed": passed,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", nargs="+", type=Path)
    parser.add_argument("--tolerance", type=float, default=1e-4)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    results = [audit_archive(path, args.tolerance) for path in args.archive]
    print(json.dumps(results, indent=2, sort_keys=True))
    if not all(result["passed"] for result in results):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
