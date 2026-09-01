#!/usr/bin/env python3
"""Create the 2026-09-01 Qwen 3.5 AgentX MI355X/B200 Pareto chart.

The chart uses P90 full-response interactivity when available and falls back to
the legacy interactivity field for aggregates (notably the B200 runner) that do
not contain the full-response field. ITL is intentionally not used.
"""

from __future__ import annotations

import argparse
import csv
import json
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Iterable


CURRENT_RUN = "InferenceX 33298482346 attempt 1"
B200_RUN = "InferenceX 30758866378 attempt 1"
OPTIMIZED_RUN = "Accepted MI355X sustained optimization"

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CURRENT_DIR = REPO_ROOT / "data/current_mi355x_33298482346_attempt1"
DEFAULT_B200_DIR = REPO_ROOT / "data/b200_30758866378_attempt1"
DEFAULT_OUTPUT_STEM = (
    REPO_ROOT
    / "artifacts/reproduced"
    / "Qwen3.5_AgentX_Pareto_MI355X_Optimized_vs_Current_vs_B200_2026-09-01"
)


@dataclass(frozen=True)
class Point:
    series: str
    source_run: str
    point_origin: str
    tp: int
    ep: int
    concurrency: int
    kv_offloading: str
    p90_interactivity: float
    throughput_per_gpu: float
    duration_seconds: float
    successful_requests: int
    artifact_source: str
    frontier: bool = False

    @property
    def label(self) -> str:
        kv = "resident" if self.kv_offloading == "none" else "HiCache"
        return f"TP{self.tp}/EP{self.ep} C{self.concurrency} {kv}"


def parse_aggregate(path: Path, series: str, source_run: str) -> Point | None:
    try:
        data = json.loads(path.read_text())
        metrics = data["request_metrics"]
        latency = metrics["latency"]
        interactivity = latency.get("full_response_intvty", latency["intvty"])
        throughput = metrics["throughput"]
        return Point(
            series=series,
            source_run=source_run,
            point_origin="runner aggregate",
            tp=int(data["tp"]),
            ep=int(data["ep"]),
            concurrency=int(data["conc"]),
            kv_offloading=str(data["kv_offloading"]),
            p90_interactivity=float(interactivity["p90"]),
            throughput_per_gpu=float(throughput["per_gpu"]["total_tput_tps"]),
            duration_seconds=float(throughput["duration_seconds"]),
            successful_requests=int(data["num_requests_successful"]),
            artifact_source=str(path),
        )
    except (KeyError, TypeError, ValueError, json.JSONDecodeError):
        return None


def load_aggregates(directory: Path, series: str, source_run: str) -> list[Point]:
    points: list[Point] = []
    for path in sorted(directory.rglob("*.json")):
        point = parse_aggregate(path, series, source_run)
        if point is not None:
            points.append(point)
    if not points:
        raise RuntimeError(f"No aggregate JSON files found under {directory}")
    return points


def optimized_points() -> list[Point]:
    """Accepted sustained MI355X points produced by the tuning campaign."""

    root = "/shared/data/R7N/andy_luo_3v7/qwen35-agentx-results"
    rows = [
        # tp, ep, C, kv, interactivity, throughput, duration, requests, artifact
        (
            2,
            1,
            12,
            "none",
            147.60291,
            26579.15484,
            3623.63864,
            1927,
            "qwen35_pr2737_tp2ep1_c12_exact_maxrun4_graph24_3600s_confirm_"
            "20260901T001648-0500",
        ),
        (
            2,
            2,
            16,
            "dram",
            82.85874,
            36905.27889,
            913.74848,
            663,
            "qwen35_tp2ep2_c16_pr36330_pr36758asmctx_tokenmeta_p64_prefill8k_"
            "maxrun12_pd32_mintok8192_aitercarlegacymax253952_nobubble_"
            "customar_900s_20260829T002509-0500",
        ),
        (
            2,
            2,
            18,
            "dram",
            81.37383,
            40365.06972,
            927.27543,
            768,
            "qwen35_tp2ep2_c18_pr36330_pr36758asmctx_tokenmeta_p64_prefill8k_"
            "maxrun12_pd32_mintok8192_aitercarlegacymax253952_nobubble_"
            "customar_900s_20260829T000003-0500",
        ),
        (
            2,
            2,
            20,
            "dram",
            86.64070,
            43292.13539,
            917.86582,
            866,
            "qwen35_tp2ep2_c20_pr36330_pr36758asmctx_tokenmeta_p64_prefill8k_"
            "maxrun12_pd32_mintok8192_aitercarlegacymax253952_nobubble_"
            "customar_900s_20260827T204111-0700",
        ),
        (
            2,
            2,
            22,
            "dram",
            81.13203,
            43632.97300,
            929.91701,
            938,
            "qwen35_tp2ep2_c22_pr36330_pr36758asmctx_tokenmeta_p64_prefill8k_"
            "maxrun12_pd32_mintok8192_aitercarlegacymax253952_nobubble_"
            "customar_900s_20260828T233243-0500",
        ),
        (
            2,
            2,
            24,
            "dram",
            79.67836,
            42678.42266,
            929.34686,
            942,
            "qwen35_tp2ep2_c24_pr36330_pr36758asmctx_tokenmeta_p64_prefill8k_"
            "maxrun12_pd32_mintok8192_aitercarlegacymax253952_nobubble_"
            "customar_900s_20260828T211745-0500",
        ),
        (
            2,
            2,
            28,
            "dram",
            76.26678,
            45559.25747,
            928.75578,
            1013,
            "qwen35_tp2ep2_c28_pr36330_pr36758asmctx_tokenmeta_p64_prefill8k_"
            "maxrun12_pd32_mintok8192_aitercarlegacymax253952_nobubble_"
            "customar_900s_20260828T222959-0500",
        ),
        (
            2,
            2,
            32,
            "dram",
            78.78076,
            46811.57575,
            925.05769,
            983,
            "qwen35_tp2ep2_c32_pr36330_pr36758asmctx_tokenmeta_p64_prefill8k_"
            "maxrun12_pd32_mintok8192_aitercarlegacymax253952_nobubble_"
            "customar_900s_20260829T005004-0500",
        ),
    ]
    return [
        Point(
            series="Best-known MI355X",
            source_run=OPTIMIZED_RUN,
            point_origin="accepted optimized result",
            tp=tp,
            ep=ep,
            concurrency=concurrency,
            kv_offloading=kv,
            p90_interactivity=interactivity,
            throughput_per_gpu=throughput,
            duration_seconds=duration,
            successful_requests=requests,
            artifact_source=f"{root}/{artifact}",
        )
        for (
            tp,
            ep,
            concurrency,
            kv,
            interactivity,
            throughput,
            duration,
            requests,
            artifact,
        ) in rows
    ]


def pareto_frontier(points: Iterable[Point]) -> list[Point]:
    values = list(points)
    frontier = [
        point
        for point in values
        if not any(
            other.p90_interactivity >= point.p90_interactivity
            and other.throughput_per_gpu >= point.throughput_per_gpu
            and (
                other.p90_interactivity > point.p90_interactivity
                or other.throughput_per_gpu > point.throughput_per_gpu
            )
            for other in values
        )
    ]
    return sorted(frontier, key=lambda point: point.p90_interactivity)


def mark_frontier(points: list[Point]) -> list[Point]:
    frontier_ids = {id(point) for point in pareto_frontier(points)}
    return [replace(point, frontier=id(point) in frontier_ids) for point in points]


def inherited_best_known(current: list[Point], tuned: list[Point]) -> list[Point]:
    inherited = [
        replace(
            point,
            series="Best-known MI355X",
            point_origin="inherited from current runner",
        )
        for point in current
    ]
    return inherited + tuned


def write_csv(path: Path, groups: list[list[Point]]) -> None:
    fields = [
        "series",
        "source_run",
        "point_origin",
        "tp",
        "ep",
        "concurrency",
        "kv_offloading",
        "p90_interactivity_tokens_per_s_user",
        "throughput_per_gpu_tokens_per_s",
        "duration_seconds",
        "successful_requests",
        "pareto_frontier",
        "artifact_source",
    ]
    with path.open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        for points in groups:
            for point in sorted(
                points,
                key=lambda p: (p.series, -p.p90_interactivity, p.throughput_per_gpu),
            ):
                writer.writerow(
                    {
                        "series": point.series,
                        "source_run": point.source_run,
                        "point_origin": point.point_origin,
                        "tp": point.tp,
                        "ep": point.ep,
                        "concurrency": point.concurrency,
                        "kv_offloading": point.kv_offloading,
                        "p90_interactivity_tokens_per_s_user": (
                            f"{point.p90_interactivity:.5f}"
                        ),
                        "throughput_per_gpu_tokens_per_s": (
                            f"{point.throughput_per_gpu:.5f}"
                        ),
                        "duration_seconds": f"{point.duration_seconds:.5f}",
                        "successful_requests": point.successful_requests,
                        "pareto_frontier": str(point.frontier).lower(),
                        "artifact_source": point.artifact_source,
                    }
                )


def plot_chart(
    path: Path,
    b200: list[Point],
    current: list[Point],
    best_known: list[Point],
) -> None:
    import matplotlib.pyplot as plt
    from matplotlib.ticker import FuncFormatter, MultipleLocator

    b200_frontier = pareto_frontier(b200)
    current_frontier = pareto_frontier(current)
    best_frontier = pareto_frontier(best_known)

    fig, axis = plt.subplots(figsize=(13.5, 8.4))
    fig.subplots_adjust(left=0.09, right=0.985, bottom=0.11, top=0.86)
    fig.patch.set_facecolor("white")
    axis.set_facecolor("#fbfbfc")

    series = [
        (
            "B200 · InferenceX run 30758866378",
            b200_frontier,
            dict(color="#1769aa", marker="o", linewidth=2.5, markersize=6.5),
        ),
        (
            "Current MI355X · InferenceX run 33298482346",
            current_frontier,
            dict(
                color="#777777",
                marker="s",
                linewidth=2.0,
                markersize=5.8,
                linestyle="--",
            ),
        ),
        (
            "Best-known MI355X · current + accepted optimizations",
            best_frontier,
            dict(color="#d62728", marker="D", linewidth=2.8, markersize=6.4),
        ),
    ]
    for label, points, style in series:
        axis.plot(
            [point.p90_interactivity for point in points],
            [point.throughput_per_gpu for point in points],
            label=label,
            **style,
        )

    tuned_sources = {point.artifact_source for point in best_known if point.point_origin == "accepted optimized result"}
    tuned_frontier = [
        point for point in best_frontier if point.artifact_source in tuned_sources
    ]
    axis.scatter(
        [point.p90_interactivity for point in tuned_frontier],
        [point.throughput_per_gpu for point in tuned_frontier],
        s=80,
        marker="D",
        facecolor="#d62728",
        edgecolor="white",
        linewidth=1.1,
        zorder=5,
        label="Accepted optimized points on best-known frontier",
    )

    new_c12 = next(
        point
        for point in tuned_frontier
        if point.tp == 2 and point.ep == 1 and point.concurrency == 12
    )
    axis.scatter(
        [new_c12.p90_interactivity],
        [new_c12.throughput_per_gpu],
        marker="*",
        s=290,
        color="#ffb000",
        edgecolor="#8c4f00",
        linewidth=1.0,
        zorder=7,
        label="New sustained optimized C12",
    )
    axis.annotate(
        "New C12: 147.60 interactivity\n26,579 tok/s/GPU",
        (new_c12.p90_interactivity, new_c12.throughput_per_gpu),
        xytext=(28, 34),
        textcoords="offset points",
        fontsize=9.5,
        fontweight="bold",
        color="#8c4f00",
        bbox=dict(boxstyle="round,pad=0.35", facecolor="#fff4ce", edgecolor="#d9a400"),
        arrowprops=dict(arrowstyle="->", color="#8c4f00", linewidth=1.2),
    )

    for point in tuned_frontier:
        if point is new_c12:
            continue
        label_offset = (10, -14) if point.concurrency == 20 else (6, 7)
        axis.annotate(
            f"C{point.concurrency}",
            (point.p90_interactivity, point.throughput_per_gpu),
            xytext=label_offset,
            textcoords="offset points",
            fontsize=8.5,
            color="#a61b1b",
            fontweight="semibold",
        )

    fig.suptitle(
        "Qwen 3.5 FP4 AgentX Pareto Frontier · MI355X vs B200",
        fontsize=17,
        fontweight="bold",
        y=0.972,
    )
    fig.text(
        0.5,
        0.925,
        "P90 interactivity and total throughput per GPU · higher is better for both axes",
        ha="center",
        va="center",
        fontsize=10.5,
        color="#555555",
    )
    axis.set_xlabel(
        "P90 interactivity (tokens/s/user, higher →)", fontsize=12, labelpad=9
    )
    axis.set_ylabel(
        "Total throughput per GPU (tokens/s, higher ↑)", fontsize=12, labelpad=9
    )
    axis.set_xlim(left=25)
    axis.set_ylim(bottom=0)
    axis.xaxis.set_major_locator(MultipleLocator(50))
    axis.yaxis.set_major_formatter(FuncFormatter(lambda value, _: f"{value / 1000:.0f}k"))
    axis.grid(True, which="major", color="#d7dce2", linewidth=0.8, alpha=0.8)
    axis.set_axisbelow(True)
    for spine in axis.spines.values():
        spine.set_color("#b8bec5")
    axis.legend(loc="lower right", frameon=True, framealpha=0.96, fontsize=9.2)
    axis.text(
        0.01,
        0.012,
        "Frontiers computed from nondominated points only. ITL is excluded.",
        transform=axis.transAxes,
        fontsize=8.8,
        color="#666666",
    )

    fig.savefig(path, dpi=220, facecolor=fig.get_facecolor())
    plt.close(fig)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--current-dir", type=Path, default=DEFAULT_CURRENT_DIR)
    parser.add_argument("--b200-dir", type=Path, default=DEFAULT_B200_DIR)
    parser.add_argument("--output-stem", type=Path, default=DEFAULT_OUTPUT_STEM)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    current = load_aggregates(args.current_dir, "Current MI355X", CURRENT_RUN)
    b200 = load_aggregates(args.b200_dir, "B200", B200_RUN)
    tuned = optimized_points()
    best_known = inherited_best_known(current, tuned)

    current_marked = mark_frontier(current)
    b200_marked = mark_frontier(b200)
    best_marked = mark_frontier(best_known)

    # The stem contains "Qwen3.5", so Path.with_suffix() would incorrectly
    # replace everything after ".5". Append the extensions literally.
    png_path = Path(f"{args.output_stem}.png")
    csv_path = Path(f"{args.output_stem}.csv")
    png_path.parent.mkdir(parents=True, exist_ok=True)
    write_csv(csv_path, [b200_marked, current_marked, best_marked])
    plot_chart(png_path, b200_marked, current_marked, best_marked)

    print(f"B200: {len(b200_marked)} points, {sum(p.frontier for p in b200_marked)} frontier")
    print(
        f"Current MI355X: {len(current_marked)} points, "
        f"{sum(p.frontier for p in current_marked)} frontier"
    )
    print(
        f"Best-known MI355X: {len(best_marked)} points, "
        f"{sum(p.frontier for p in best_marked)} frontier"
    )
    print(f"PNG: {png_path}")
    print(f"CSV: {csv_path}")


if __name__ == "__main__":
    main()
