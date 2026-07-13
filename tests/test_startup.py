import json
import os
import tempfile
import threading
import time
import unittest
from contextlib import ExitStack
from unittest import mock

import battery_hog


class FastStartupTests(unittest.TestCase):
    def test_build_stats_never_calls_slow_history_functions(self):
        slow = battery_hog._new_slow_snapshot()
        slow.update(wakes=4,
                    insights={"today": {}, "week": {}, "charges": 2,
                              "wakes": 5, "ok": False},
                    saved_at=100.0)
        replacements = {
            "get_process_data": {"processes": [], "workloads": [], "summary": {}},
            "get_sleep_data": {"blockers": [], "policy": {}},
            "gate_snapshot": {"active": [], "queued": []},
            "gate_command": "battery-hog-agent",
            "get_battery": {"percent": 80, "on_ac": False},
            "get_memory": {"pressure": "normal"},
            "get_lowpowermode": False,
            "get_battery_health": {"health": 100},
            "get_power": {"watts": 8.0},
            "get_uptime": {"secs": 10, "days": 0.0},
        }

        with ExitStack() as stack:
            stack.enter_context(mock.patch.object(battery_hog, "_SLOW", slow))
            for name, value in replacements.items():
                stack.enter_context(mock.patch.object(
                    battery_hog, name, return_value=value))
            wake_mock = stack.enter_context(mock.patch.object(
                battery_hog, "get_wakes",
                side_effect=AssertionError("slow wake scan called during build_stats")))
            insight_mock = stack.enter_context(mock.patch.object(
                battery_hog, "get_insights",
                side_effect=AssertionError("slow insights called during build_stats")))
            stats = battery_hog.build_stats()

        self.assertEqual(stats["wakes"], 4)
        self.assertEqual(stats["insights"]["charges"], 2)
        self.assertTrue(stats["insights_stale"])
        self.assertFalse(stats["insights_loading"])
        wake_mock.assert_not_called()
        insight_mock.assert_not_called()

    def test_background_refresh_persists_and_reloads_last_good_snapshot(self):
        insights = {
            "today": {"rate": 9.5},
            "week": {"rate": 8.0},
            "charges": 3,
            "wakes": 6,
            "ok": True,
        }
        with tempfile.TemporaryDirectory() as tmp:
            slow = battery_hog._new_slow_snapshot()
            slow["refreshing"] = True
            with mock.patch.object(battery_hog, "DATA_DIR", tmp), \
                    mock.patch.object(battery_hog, "_SLOW", slow), \
                    mock.patch.object(battery_hog, "get_wakes", return_value=5), \
                    mock.patch.object(battery_hog, "get_insights", return_value=insights):
                self.assertTrue(battery_hog._refresh_slow_snapshot())
                path = battery_hog._slow_cache_file()
                self.assertTrue(os.path.exists(path))
                with open(path, encoding="utf-8") as handle:
                    saved = json.load(handle)
                loaded = battery_hog._load_slow_snapshot()
                flags = battery_hog._slow_stats_snapshot()

            self.assertEqual(saved["schema"], battery_hog._SLOW_CACHE_SCHEMA)
            self.assertEqual(saved["wakes"], 5)
            self.assertEqual(saved["insights"], insights)
            self.assertEqual(loaded["wakes"], 5)
            self.assertEqual(loaded["insights"], insights)
            self.assertFalse(flags["insights_loading"])
            self.assertFalse(flags["insights_refreshing"])
            self.assertFalse(flags["insights_stale"])

            # A cache loaded by a new process is useful immediately, but marked
            # stale until that process's one background refresh finishes.
            stale_flags = None
            with mock.patch.object(battery_hog, "_SLOW", loaded):
                stale_flags = battery_hog._slow_stats_snapshot()
            self.assertFalse(stale_flags["insights_loading"])
            self.assertTrue(stale_flags["insights_refreshing"])
            self.assertTrue(stale_flags["insights_stale"])

    def test_pmset_log_cold_scan_is_single_flight(self):
        calls = []
        calls_lock = threading.Lock()

        def fake_run(_cmd, timeout=12):
            with calls_lock:
                calls.append(timeout)
            time.sleep(0.05)
            return "power history"

        cache = {"t": 0.0, "raw": None}
        results = []
        with mock.patch.object(battery_hog, "_PLOG", cache), \
                mock.patch.object(battery_hog, "run", side_effect=fake_run):
            threads = [threading.Thread(
                target=lambda: results.append(battery_hog._pmset_log()))
                for _ in range(4)]
            for thread in threads:
                thread.start()
            for thread in threads:
                thread.join(timeout=1)

        self.assertEqual(calls, [20])
        self.assertEqual(results, ["power history"] * 4)


if __name__ == "__main__":
    unittest.main()
