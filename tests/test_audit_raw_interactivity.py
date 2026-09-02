from __future__ import annotations

import unittest

from scripts.audit_raw_interactivity import percentile


class RawInteractivityAuditTest(unittest.TestCase):
    def test_percentile_matches_linear_type7_interpolation(self):
        self.assertEqual(percentile([1.0], 0.9), 1.0)
        self.assertAlmostEqual(percentile([1.0, 2.0, 3.0], 0.9), 2.8)

    def test_percentile_rejects_empty_input(self):
        with self.assertRaises(ValueError):
            percentile([], 0.9)


if __name__ == "__main__":
    unittest.main()
