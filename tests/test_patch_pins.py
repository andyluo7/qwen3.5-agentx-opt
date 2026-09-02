from __future__ import annotations

import hashlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class PatchPinTest(unittest.TestCase):
    def assert_default_pin_matches(self, script: str, variable: str, patch: str):
        script_text = (ROOT / script).read_text(encoding="utf-8")
        prefix = f'{variable}="${{'
        lines = [
            line
            for line in script_text.splitlines()
            if line.startswith(prefix) and line.endswith('}"')
        ]
        self.assertEqual(
            len(lines), 1, f"expected one default {variable} in {script}"
        )
        actual = lines[0][len(prefix) : -2].split(":-", maxsplit=1)[1]
        expected = hashlib.sha256((ROOT / patch).read_bytes()).hexdigest()
        self.assertEqual(actual, expected, f"stale {variable} in {script}")

    def test_combined_sglang_patch_defaults_match_checked_in_patch(self):
        patch = "patches/sglang_pr35872_pr37465_combined_instrumented.patch"
        scripts = [
            "scripts/run_qwen35_combined_c4_if_target_missing_node3.sh",
            "scripts/run_qwen35_combined_c8_if_target_missing_node3.sh",
            "scripts/run_qwen35_confirm_combined_c4_after_screen_node3.sh",
            "scripts/run_qwen35_confirm_combined_candidate_after_screen.sh",
            "scripts/run_qwen35_maxrun4_if_target_missing_node5.sh",
        ]
        for script in scripts:
            with self.subTest(script=script):
                self.assert_default_pin_matches(script, "patch_sha256", patch)

    def test_aiter_patch_defaults_match_checked_in_patch(self):
        patch = "patches/aiter_pr5190_mtp_verify_attn_asm.patch"
        scripts = [
            "scripts/run_qwen35_combined_c4_if_target_missing_node3.sh",
            "scripts/run_qwen35_combined_c8_if_target_missing_node3.sh",
            "scripts/run_qwen35_confirm_combined_c4_after_screen_node3.sh",
            "scripts/run_qwen35_confirm_combined_candidate_after_screen.sh",
            "scripts/run_qwen35_maxrun4_if_target_missing_node5.sh",
        ]
        for script in scripts:
            with self.subTest(script=script):
                self.assert_default_pin_matches(script, "aiter_patch_sha256", patch)

    def test_confirmation_point_launcher_pin_matches_checked_in_script(self):
        scripts = [
            "scripts/run_qwen35_frontier_confirm_node2.sh",
            "scripts/run_qwen35_pr2737_client_concurrency_bracket_node2.sh",
            "scripts/run_qwen35_pr2737_c12_maxrun_ladder_node2.sh",
            "scripts/run_qwen35_sglang_patch_bracket_node2.sh",
        ]
        for script in scripts:
            with self.subTest(script=script):
                self.assert_default_pin_matches(
                    script,
                    "point_sha256",
                    "scripts/run_qwen35_pr2737_c12_exact_point_node2.sh",
                )

    def test_generic_combined_confirmation_uses_client_bracket_gate(self):
        script = (
            ROOT / "scripts/run_qwen35_confirm_combined_candidate_after_screen.sh"
        ).read_text(encoding="utf-8")
        expected = (
            'qualification_gate="${QUALIFICATION_GATE:-'
            'advance_selected_candidates_to_sustained_confirmation=1}"'
        )
        self.assertIn(expected, script)
        self.assertIn('grep -Fqx "$qualification_gate" "$screen_decision"', script)
        self.assertIn('QUALIFICATION_GATE="$qualification_gate"', script)

    def test_generic_combined_confirmation_requires_current_accepted_portfolio(self):
        script = (
            ROOT / "scripts/run_qwen35_confirm_combined_candidate_after_screen.sh"
        ).read_text(encoding="utf-8")
        self.assertIn(
            'for expected in "12 1" "12 2" "4 1" "8 1"; do', script
        )
        self.assertIn('(( ${#accepted_manifests[@]} >= 4 ))', script)
        self.assertIn('.metadata.concurrency == $conc', script)
        self.assertIn('.metadata.max_running_requests == $maxrun', script)

    def test_generic_combined_confirmation_can_skip_after_prior_postflight(self):
        script = (
            ROOT / "scripts/run_qwen35_confirm_combined_candidate_after_screen.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('prior_postflight_stdout="${PRIOR_POSTFLIGHT_STDOUT:-}"', script)
        self.assertIn('included_prior_postflight manifest=', script)
        self.assertIn('accepted_manifests+=("$prior_manifest")', script)

    def test_generic_combined_confirmation_binds_page_size(self):
        script = (
            ROOT / "scripts/run_qwen35_confirm_combined_candidate_after_screen.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('candidate_page_size="${CANDIDATE_PAGE_SIZE:-16}"', script)
        self.assertIn(
            'candidate_scheduler_recv_interval="${CANDIDATE_SCHEDULER_RECV_INTERVAL:-30}"',
            script,
        )
        self.assertIn('.metadata.page_size == $page_size', script)
        self.assertIn(
            '.metadata.scheduler_recv_interval == $scheduler_recv_interval', script
        )
        self.assertIn('PAGE_SIZE_OVERRIDE="$candidate_page_size"', script)
        self.assertIn(
            'SCHEDULER_RECV_INTERVAL_OVERRIDE="$candidate_scheduler_recv_interval"',
            script,
        )

    def test_generic_combined_confirmation_extracts_promoted_point(self):
        script = (
            ROOT / "scripts/run_qwen35_confirm_combined_candidate_after_screen.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('screen_manifest="$(sed -n', script)
        self.assertIn('.metadata.max_running_requests == $maxrun', script)
        self.assertIn('reason=candidate_not_promoted', script)
        self.assertIn(
            '{schema_version: (.schema_version // 1), points: [.points[] | select(.name == $name)]}',
            script,
        )
        self.assertIn('QUALIFICATION_DECISION="$qualification_decision"', script)

    def test_client_bracket_can_promote_selected_cross_floor_tradeoff(self):
        script = (
            ROOT / "scripts/run_qwen35_pr2737_client_concurrency_bracket_node2.sh"
        ).read_text(encoding="utf-8")
        self.assertIn(
            'require_candidate_p90_above_controls="${REQUIRE_CANDIDATE_P90_ABOVE_CONTROLS:-1}"',
            script,
        )
        self.assertIn(
            '[[ "$require_candidate_p90_above_controls" == 0', script
        )
        self.assertIn(
            'require_candidate_p90_above_controls=%s', script
        )

    def test_low_concurrency_runners_support_c6_and_c7(self):
        exact = (
            ROOT / "scripts/run_qwen35_pr2737_c12_exact_point_node2.sh"
        ).read_text(encoding="utf-8")
        bracket = (
            ROOT / "scripts/run_qwen35_pr2737_client_concurrency_bracket_node2.sh"
        ).read_text(encoding="utf-8")
        confirm = (
            ROOT / "scripts/run_qwen35_frontier_confirm_node2.sh"
        ).read_text(encoding="utf-8")
        conditional = (
            ROOT / "scripts/run_qwen35_confirm_combined_candidate_after_screen.sh"
        ).read_text(encoding="utf-8")

        self.assertIn('1|4|6|7|8|12', exact)
        self.assertIn('1|4|6|7|8|12', bracket)
        self.assertIn('expected_warmups_from_log()', bracket)
        self.assertIn('expected_warmups_from_log()', confirm)
        self.assertIn('per_lane * conc + primers', bracket)
        self.assertIn('per_lane * conc + primers', confirm)
        self.assertIn('1|4|6|7|8|12', conditional)

    def test_confirmation_allows_legacy_identity_only_with_exact_command_flags(self):
        script = (
            ROOT / "scripts/run_qwen35_frontier_confirm_node2.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('qualification_legacy_identity_missing', script)
        self.assertIn('if grep -q "^${identity_key}="', script)
        self.assertIn('--scheduler-recv-interval[[:space:]]+', script)
        self.assertIn('--page-size[[:space:]]+', script)

    def test_qualified_confirmation_is_target_gated(self):
        script = (
            ROOT / "scripts/run_qwen35_qualified_confirm_if_target_missing.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('prior_postflight_stdout="${PRIOR_POSTFLIGHT_STDOUT:-}"', script)
        self.assertIn('--require-target --json --output', script)
        self.assertIn('skip_qualified_confirmation reason=accepted_target_met', script)
        self.assertIn('DURATION=3600', script)
        self.assertIn('submitted_qualified_postflight', script)

    def test_maxrun_ladder_supports_pinned_combined_overlays(self):
        script = (
            ROOT / "scripts/run_qwen35_pr2737_c12_maxrun_ladder_node2.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('fixed_patch_path="${PATCH_PATH:-}"', script)
        self.assertIn('fixed_aiter_patch_path="${AITER_PATCH_PATH:-}"', script)
        self.assertIn('SGLANG_PATCH="$fixed_patch_path"', script)
        self.assertIn('AITER_PATCH="$fixed_aiter_patch_path"', script)
        self.assertIn('grep -Eq "$expected_route_regex_3"', script)
        self.assertIn('sglang_patch_sha256: $patch_sha256', script)
        self.assertIn('aiter_patch_sha256: $aiter_patch_sha256', script)

    def test_maxrun4_followup_is_target_gated_and_pareto_scoped(self):
        script = (
            ROOT / "scripts/run_qwen35_maxrun4_if_target_missing_node5.sh"
        ).read_text(encoding="utf-8")
        self.assertIn('--require-target --json --output', script)
        self.assertIn('skip_maxrun4 reason=accepted_target_met', script)
        self.assertIn('CONTROL_MAXRUN=5', script)
        self.assertIn('CANDIDATE_MAXRUNS=4', script)
        self.assertIn('CANDIDATE_MAXRUN=4', script)
        self.assertIn('prior_confirmation_stdout="${PRIOR_CONFIRMATION_STDOUT:-}"', script)
        self.assertIn('submitted_combined_postflight job_id=', script)
        self.assertIn('qwen35-frontier-postflight-after-confirm-${prior_postflight_job_id}.out', script)
        self.assertIn('advance_to_full_node_postflight=0', script)
        self.assertIn('reason=no_frontier_advance', script)
        self.assertIn(
            'QUALIFICATION_GATE=advance_selected_candidates_to_isolated_bracket=1',
            script,
        )
        self.assertIn('submitted_maxrun4_confirmation', script)


if __name__ == "__main__":
    unittest.main()
