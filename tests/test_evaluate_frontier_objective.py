from __future__ import annotations

import importlib.util
import sys
import unittest
from decimal import Decimal
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "frontier_eval", ROOT / "scripts" / "evaluate_frontier_objective.py"
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class FrontierObjectiveTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.objective = MODULE.load_objective(
            ROOT / "data" / "frozen_frontier_objective_20260901.json"
        )

    def point(self, name, status, throughput, p90):
        return MODULE.Point(
            name=name,
            status=status,
            throughput=Decimal(str(throughput)),
            p90=Decimal(str(p90)),
            artifact="test",
        )

    def test_frozen_baseline_matches_agreed_mean_and_target(self):
        result = MODULE.evaluate(self.objective, [], include_provisional=False)
        self.assertEqual(result["baseline_mean"], Decimal("119.9264966666666666666666667"))
        self.assertEqual(result["new_mean"], result["baseline_mean"])
        self.assertEqual(result["target_mean"], Decimal("143.9117960000000000000000000"))
        self.assertFalse(result["objective_achieved"])

    def test_one_candidate_can_advance_multiple_throughput_anchors(self):
        candidate = self.point("multi-anchor", "accepted", 30000, 200)
        result = MODULE.evaluate(self.objective, [candidate], include_provisional=False)
        advanced = [
            row["id"] for row in result["selected"] if row["selected_point"] == candidate.name
        ]
        self.assertEqual(
            advanced,
            [
                "a03_tp2ep1_c4",
                "a04_tp2ep1_c8",
                "a05_tp2ep1_c12_maxrun4",
                "a06_tp2ep1_c12_runner",
            ],
        )

    def test_target_is_mean_gain_not_per_anchor_gain(self):
        candidate = self.point("portfolio-gain", "accepted", 100000, 200)
        result = MODULE.evaluate(self.objective, [candidate], include_provisional=False)
        unchanged = [
            row["id"]
            for row in result["selected"]
            if row["selected_point"] == "frozen-baseline"
        ]
        self.assertEqual(unchanged, ["a01_tp4ep1_c1", "a02_tp2ep1_c1"])
        self.assertTrue(result["objective_achieved"])

    def test_throughput_floor_prevents_regression(self):
        candidate = self.point("too-slow", "accepted", 26000, 1000)
        result = MODULE.evaluate(self.objective, [candidate], include_provisional=False)
        anchor = next(row for row in result["selected"] if row["id"] == "a05_tp2ep1_c12_maxrun4")
        self.assertEqual(anchor["selected_point"], "frozen-baseline")

    def test_provisional_point_never_proves_completion(self):
        candidate = self.point("screen", "provisional", 100000, 1000)
        omitted = MODULE.evaluate(self.objective, [candidate], include_provisional=False)
        included = MODULE.evaluate(self.objective, [candidate], include_provisional=True)
        self.assertEqual(omitted["new_mean"], omitted["baseline_mean"])
        self.assertTrue(included["target_numerically_met"])
        self.assertTrue(included["uses_provisional"])
        self.assertFalse(included["objective_achieved"])

    def test_rejected_point_is_never_selected(self):
        candidate = self.point("rejected", "rejected", 100000, 1000)
        result = MODULE.evaluate(self.objective, [candidate], include_provisional=True)
        self.assertEqual(result["new_mean"], result["baseline_mean"])

    def test_checked_in_accepted_portfolio_meets_target_without_provisional(self):
        candidates = MODULE.load_candidates(
            [ROOT / "data" / "qwen35_frontier_accepted_portfolio_20260902.json"]
        )
        result = MODULE.evaluate(
            self.objective, candidates, include_provisional=False
        )

        self.assertTrue(result["objective_achieved"])
        self.assertTrue(result["target_numerically_met"])
        self.assertFalse(result["uses_provisional"])
        self.assertGreaterEqual(result["new_mean"], result["target_mean"])
        self.assertEqual(result["new_mean"], Decimal("144.1663816666666666666666667"))
        self.assertEqual(
            result["relative_mean_gain"],
            Decimal("0.202122847525299454952254227"),
        )
        self.assertTrue(
            all(point.status == "accepted" for point in candidates),
            "published completion evidence must not contain provisional points",
        )


if __name__ == "__main__":
    unittest.main()
