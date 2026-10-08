import asyncio
import unittest
from unittest.mock import AsyncMock, patch

from land_watch import (
    CHECKS_APPEAR_TIMEOUT_SECONDS,
    POLL_SECONDS,
    PrInfo,
    dedupe_check_runs,
    is_merge_conflicting,
    summarize_checks,
    wait_for_checks,
)


class TestLandWatchChecks(unittest.TestCase):
    def test_dedupe_check_runs(self):
        check_runs = [
            {
                "name": "make-all",
                "status": "completed",
                "conclusion": "failure",
                "completed_at": "2026-09-17T04:00:00Z",
            },
            {
                "name": "make-all",
                "status": "completed",
                "conclusion": "success",
                "completed_at": "2026-09-17T05:00:00Z",
            },
            {
                "name": "pr-description-lint",
                "status": "completed",
                "conclusion": "success",
                "completed_at": "2026-09-17T05:00:00Z",
            },
        ]
        deduped = dedupe_check_runs(check_runs)
        self.assertEqual(len(deduped), 2)
        make_all_run = next(r for r in deduped if r["name"] == "make-all")
        self.assertEqual(make_all_run["conclusion"], "success")

    def test_summarize_checks_missing(self):
        pending, failed, failures = summarize_checks([])
        self.assertTrue(pending)
        self.assertFalse(failed)
        self.assertEqual(failures, ["no checks reported"])

    def test_summarize_checks_pending(self):
        check_runs = [
            {"name": "make-all", "status": "in_progress", "conclusion": None},
            {"name": "pr-description-lint", "status": "completed", "conclusion": "success"},
        ]
        pending, failed, failures = summarize_checks(check_runs)
        self.assertTrue(pending)
        self.assertFalse(failed)
        self.assertEqual(failures, [])

    def test_summarize_checks_success(self):
        check_runs = [
            {"name": "make-all", "status": "completed", "conclusion": "success"},
            {"name": "pr-description-lint", "status": "completed", "conclusion": "success"},
        ]
        pending, failed, failures = summarize_checks(check_runs)
        self.assertFalse(pending)
        self.assertFalse(failed)
        self.assertEqual(failures, [])

    def test_summarize_checks_skipped_and_neutral(self):
        check_runs = [
            {"name": "make-all", "status": "completed", "conclusion": "skipped"},
            {"name": "pr-description-lint", "status": "completed", "conclusion": "neutral"},
        ]
        pending, failed, failures = summarize_checks(check_runs)
        self.assertFalse(pending)
        self.assertFalse(failed)
        self.assertEqual(failures, [])

    def test_summarize_checks_failure(self):
        check_runs = [
            {"name": "make-all", "status": "completed", "conclusion": "failure"},
            {"name": "pr-description-lint", "status": "completed", "conclusion": "success"},
        ]
        pending, failed, failures = summarize_checks(check_runs)
        self.assertFalse(pending)
        self.assertTrue(failed)
        self.assertIn("make-all: failure", failures)

    def test_summarize_checks_cancelled(self):
        check_runs = [
            {"name": "make-all", "status": "completed", "conclusion": "cancelled"},
        ]
        pending, failed, failures = summarize_checks(check_runs)
        self.assertFalse(pending)
        self.assertTrue(failed)
        self.assertIn("make-all: cancelled", failures)

    def test_summarize_checks_timed_out(self):
        check_runs = [
            {"name": "make-all", "status": "completed", "conclusion": "timed_out"},
        ]
        pending, failed, failures = summarize_checks(check_runs)
        self.assertFalse(pending)
        self.assertTrue(failed)
        self.assertIn("make-all: timed_out", failures)

    def test_is_merge_conflicting(self):
        pr_clean = PrInfo(number=1, url="", head_sha="sha1", mergeable="CLEAN", merge_state="CLEAN")
        pr_conflict1 = PrInfo(number=1, url="", head_sha="sha1", mergeable="CONFLICTING", merge_state="CLEAN")
        pr_conflict2 = PrInfo(number=1, url="", head_sha="sha1", mergeable="CLEAN", merge_state="DIRTY")

        self.assertFalse(is_merge_conflicting(pr_clean))
        self.assertTrue(is_merge_conflicting(pr_conflict1))
        self.assertTrue(is_merge_conflicting(pr_conflict2))


class TestLandWatchAsyncChecks(unittest.IsolatedAsyncioTestCase):
    @patch("land_watch.get_check_runs", new_callable=AsyncMock)
    async def test_wait_for_checks_success(self, mock_get_check_runs):
        mock_get_check_runs.return_value = [
            {"name": "make-all", "status": "completed", "conclusion": "success"}
        ]
        checks_done = asyncio.Event()
        await wait_for_checks("test_sha", checks_done)
        self.assertTrue(checks_done.is_set())

    @patch("land_watch.get_check_runs", new_callable=AsyncMock)
    async def test_wait_for_checks_failure(self, mock_get_check_runs):
        mock_get_check_runs.return_value = [
            {"name": "make-all", "status": "completed", "conclusion": "failure"}
        ]
        checks_done = asyncio.Event()
        with self.assertRaises(SystemExit) as ctx:
            await wait_for_checks("test_sha", checks_done)
        self.assertEqual(ctx.exception.code, 3)
        self.assertFalse(checks_done.is_set())

    @patch("land_watch.get_check_runs", new_callable=AsyncMock)
    @patch("land_watch.POLL_SECONDS", 0.01)
    @patch("land_watch.CHECKS_APPEAR_TIMEOUT_SECONDS", 0.02)
    async def test_wait_for_checks_missing_timeout(self, mock_get_check_runs):
        mock_get_check_runs.return_value = []
        checks_done = asyncio.Event()
        with self.assertRaises(SystemExit) as ctx:
            await wait_for_checks("test_sha", checks_done)
        self.assertEqual(ctx.exception.code, 3)
        self.assertFalse(checks_done.is_set())


if __name__ == "__main__":
    unittest.main()
