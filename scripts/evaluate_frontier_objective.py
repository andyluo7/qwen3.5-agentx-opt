#!/usr/bin/env python3
"""Evaluate accepted or provisional points against the frozen AgentX frontier.

Each frozen anchor is a throughput floor.  Its selected P90 interactivity is the
best value among the frozen point and every eligible candidate whose throughput
is at least that floor.  This allows one new point to advance several anchors,
while making a throughput regression impossible by construction.

Candidate JSON schema:

    {
      "points": [
        {
          "name": "descriptive-name",
          "status": "accepted",
          "throughput_per_gpu_tokens_per_s": 30000.0,
          "p90_interactivity_tokens_per_s_user": 120.0,
          "artifact": "/path/to/validated/archive"
        }
      ]
    }

Only ``accepted`` points count by default.  ``--include-provisional`` is useful
for ranking screened candidates, but a provisional evaluation can never report
the objective as achieved.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from decimal import Decimal
from pathlib import Path
from typing import Any, Iterable


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OBJECTIVE = REPO_ROOT / "data" / "frozen_frontier_objective_20260901.json"
VALID_STATUSES = {"accepted", "provisional", "rejected"}


@dataclass(frozen=True)
class Point:
    name: str
    status: str
    throughput: Decimal
    p90: Decimal
    artifact: str


def decimal(value: Any, field: str) -> Decimal:
    try:
        parsed = Decimal(str(value))
    except Exception as exc:  # Decimal raises several input-specific exceptions.
        raise ValueError(f"{field} is not numeric: {value!r}") from exc
    if not parsed.is_finite() or parsed < 0:
        raise ValueError(f"{field} must be finite and non-negative: {value!r}")
    return parsed


def load_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle, parse_float=Decimal, parse_int=Decimal)


def load_objective(path: Path) -> dict[str, Any]:
    raw = load_json(path)
    anchors = raw.get("anchors")
    if not isinstance(anchors, list) or not anchors:
        raise ValueError("objective must contain a non-empty anchors list")
    ids: set[str] = set()
    previous_floor: Decimal | None = None
    for anchor in anchors:
        anchor_id = anchor.get("id")
        if not isinstance(anchor_id, str) or not anchor_id or anchor_id in ids:
            raise ValueError(f"invalid or duplicate anchor id: {anchor_id!r}")
        ids.add(anchor_id)
        floor = decimal(anchor.get("throughput_floor"), f"{anchor_id}.throughput_floor")
        decimal(
            anchor.get("baseline_p90_interactivity"),
            f"{anchor_id}.baseline_p90_interactivity",
        )
        if previous_floor is not None and floor <= previous_floor:
            raise ValueError("anchor throughput floors must be strictly increasing")
        previous_floor = floor

    count = Decimal(len(anchors))
    computed_baseline = sum(
        decimal(a["baseline_p90_interactivity"], "baseline_p90_interactivity")
        for a in anchors
    ) / count
    improvement = decimal(
        raw.get("required_relative_improvement"), "required_relative_improvement"
    )
    computed_target = computed_baseline * (Decimal(1) + improvement)
    recorded_baseline = decimal(raw.get("baseline_mean"), "baseline_mean")
    recorded_target = decimal(raw.get("target_mean"), "target_mean")
    tolerance = Decimal("0.00000001")
    if abs(computed_baseline - recorded_baseline) > tolerance:
        raise ValueError(
            f"recorded baseline mean {recorded_baseline} does not match "
            f"computed {computed_baseline}"
        )
    if abs(computed_target - recorded_target) > tolerance:
        raise ValueError(
            f"recorded target mean {recorded_target} does not match "
            f"computed {computed_target}"
        )
    return raw


def candidate_records(raw: Any, path: Path) -> Iterable[dict[str, Any]]:
    if isinstance(raw, list):
        records = raw
    elif isinstance(raw, dict) and "points" in raw:
        records = raw["points"]
    elif isinstance(raw, dict):
        records = [raw]
    else:
        raise ValueError(f"{path}: expected an object, list, or object with points")
    if not isinstance(records, list):
        raise ValueError(f"{path}: points must be a list")
    for record in records:
        if not isinstance(record, dict):
            raise ValueError(f"{path}: each point must be an object")
        yield record


def load_candidates(paths: Iterable[Path]) -> list[Point]:
    points: list[Point] = []
    names: set[str] = set()
    for path in paths:
        for raw in candidate_records(load_json(path), path):
            name = raw.get("name")
            status = raw.get("status")
            if not isinstance(name, str) or not name:
                raise ValueError(f"{path}: candidate name must be a non-empty string")
            if name in names:
                raise ValueError(f"duplicate candidate name: {name}")
            if status not in VALID_STATUSES:
                raise ValueError(
                    f"{path}: {name}: status must be one of {sorted(VALID_STATUSES)}"
                )
            names.add(name)
            points.append(
                Point(
                    name=name,
                    status=status,
                    throughput=decimal(
                        raw.get("throughput_per_gpu_tokens_per_s"),
                        f"{name}.throughput_per_gpu_tokens_per_s",
                    ),
                    p90=decimal(
                        raw.get("p90_interactivity_tokens_per_s_user"),
                        f"{name}.p90_interactivity_tokens_per_s_user",
                    ),
                    artifact=str(raw.get("artifact", "")),
                )
            )
    return points


def select_for_anchors(
    objective: dict[str, Any], points: Iterable[Point]
) -> list[dict[str, Any]]:
    eligible = list(points)
    selected: list[dict[str, Any]] = []
    for anchor in objective["anchors"]:
        floor = decimal(anchor["throughput_floor"], "throughput_floor")
        baseline = decimal(
            anchor["baseline_p90_interactivity"], "baseline_p90_interactivity"
        )
        winner_name = "frozen-baseline"
        winner_status = "accepted"
        winner_throughput = floor
        winner_p90 = baseline
        winner_artifact = str(anchor.get("source", ""))
        for point in eligible:
            if point.throughput < floor or point.p90 <= winner_p90:
                continue
            winner_name = point.name
            winner_status = point.status
            winner_throughput = point.throughput
            winner_p90 = point.p90
            winner_artifact = point.artifact
        selected.append(
            {
                "id": anchor["id"],
                "throughput_floor": floor,
                "baseline_p90": baseline,
                "selected_p90": winner_p90,
                "absolute_gain": winner_p90 - baseline,
                "relative_gain": winner_p90 / baseline - Decimal(1),
                "selected_point": winner_name,
                "selected_status": winner_status,
                "selected_throughput": winner_throughput,
                "artifact": winner_artifact,
            }
        )
    return selected


def evaluate(
    objective: dict[str, Any], candidates: list[Point], include_provisional: bool
) -> dict[str, Any]:
    eligible_statuses = {"accepted"}
    if include_provisional:
        eligible_statuses.add("provisional")
    eligible = [point for point in candidates if point.status in eligible_statuses]
    selected = select_for_anchors(objective, eligible)
    count = Decimal(len(selected))
    baseline_mean = sum(row["baseline_p90"] for row in selected) / count
    new_mean = sum(row["selected_p90"] for row in selected) / count
    required = decimal(
        objective["required_relative_improvement"], "required_relative_improvement"
    )
    target_mean = baseline_mean * (Decimal(1) + required)
    uses_provisional = any(row["selected_status"] == "provisional" for row in selected)
    target_numerically_met = new_mean >= target_mean

    leverage = []
    for point in eligible:
        alone = select_for_anchors(objective, [point])
        alone_mean = sum(row["selected_p90"] for row in alone) / count
        advanced = [row["id"] for row in alone if row["absolute_gain"] > 0]
        leverage.append(
            {
                "name": point.name,
                "status": point.status,
                "anchors_advanced": advanced,
                "anchor_count": len(advanced),
                "mean_gain": alone_mean - baseline_mean,
                "relative_mean_gain": alone_mean / baseline_mean - Decimal(1),
            }
        )
    leverage.sort(
        key=lambda row: (row["mean_gain"], row["anchor_count"], row["name"]),
        reverse=True,
    )

    return {
        "selected": selected,
        "baseline_mean": baseline_mean,
        "new_mean": new_mean,
        "absolute_mean_gain": new_mean - baseline_mean,
        "relative_mean_gain": new_mean / baseline_mean - Decimal(1),
        "target_mean": target_mean,
        "remaining_mean_gain": max(Decimal(0), target_mean - new_mean),
        "target_numerically_met": target_numerically_met,
        "uses_provisional": uses_provisional,
        "objective_achieved": target_numerically_met and not uses_provisional,
        "candidate_leverage": leverage,
    }


def json_ready(value: Any) -> Any:
    if isinstance(value, Decimal):
        return float(value)
    if isinstance(value, dict):
        return {key: json_ready(item) for key, item in value.items()}
    if isinstance(value, list):
        return [json_ready(item) for item in value]
    return value


def render_text(result: dict[str, Any]) -> str:
    lines = [
        f"baseline_mean={result['baseline_mean']:.8f}",
        f"new_mean={result['new_mean']:.8f}",
        f"relative_mean_gain_pct={100 * result['relative_mean_gain']:.6f}",
        f"target_mean={result['target_mean']:.8f}",
        f"remaining_mean_gain={result['remaining_mean_gain']:.8f}",
        f"uses_provisional={int(result['uses_provisional'])}",
        f"objective_achieved={int(result['objective_achieved'])}",
        "",
        "anchor\tthroughput_floor\tbaseline_p90\tselected_p90\tgain_pct\tselected_point",
    ]
    for row in result["selected"]:
        lines.append(
            f"{row['id']}\t{row['throughput_floor']:.5f}\t"
            f"{row['baseline_p90']:.5f}\t{row['selected_p90']:.5f}\t"
            f"{100 * row['relative_gain']:.6f}\t{row['selected_point']}"
        )
    if result["candidate_leverage"]:
        lines.extend(
            [
                "",
                "candidate\tstatus\tanchors_advanced\tmean_gain\trelative_mean_gain_pct",
            ]
        )
        for row in result["candidate_leverage"]:
            lines.append(
                f"{row['name']}\t{row['status']}\t{row['anchor_count']}\t"
                f"{row['mean_gain']:.8f}\t{100 * row['relative_mean_gain']:.6f}"
            )
    return "\n".join(lines) + "\n"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--objective", type=Path, default=DEFAULT_OBJECTIVE)
    parser.add_argument(
        "--candidates",
        type=Path,
        action="append",
        default=[],
        help="candidate JSON manifest; may be repeated",
    )
    parser.add_argument(
        "--include-provisional",
        action="store_true",
        help="include provisional points for screening; they cannot prove completion",
    )
    parser.add_argument("--json", action="store_true", help="emit JSON instead of text")
    parser.add_argument("--output", type=Path, help="write output to this path")
    parser.add_argument(
        "--require-target",
        action="store_true",
        help="exit nonzero unless accepted evidence meets the target",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    try:
        objective = load_objective(args.objective)
        candidates = load_candidates(args.candidates)
        result = evaluate(objective, candidates, args.include_provisional)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if args.json:
        rendered = json.dumps(json_ready(result), indent=2, sort_keys=True) + "\n"
    else:
        rendered = render_text(result)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    else:
        sys.stdout.write(rendered)
    if args.require_target and not result["objective_achieved"]:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
