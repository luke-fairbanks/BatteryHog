import re
import unittest
from collections import Counter
from html.parser import HTMLParser
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DASHBOARD = ROOT / "dashboard.html"
ROOMS = ("overview", "processes", "workloads", "health", "insights", "settings")


class DashboardParser(HTMLParser):
    """Small stdlib-only index of the static dashboard DOM."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.elements = []

    def handle_starttag(self, tag, attrs):
        self.elements.append((tag.lower(), dict(attrs)))


class DashboardContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.html = DASHBOARD.read_text(encoding="utf-8")
        cls.parser = DashboardParser()
        cls.parser.feed(cls.html)
        cls.elements = cls.parser.elements
        cls.ids = [attrs["id"] for _tag, attrs in cls.elements if attrs.get("id")]
        cls.by_id = {
            attrs["id"]: (tag, attrs)
            for tag, attrs in cls.elements
            if attrs.get("id")
        }
        cls.classes = {
            name
            for _tag, attrs in cls.elements
            for name in attrs.get("class", "").split()
        }
        cls.scripts = [
            (dict(re.findall(r"([\w:-]+)(?:\s*=\s*['\"]([^'\"]*)['\"])?", attrs)), body)
            for attrs, body in re.findall(
                r"<script\b([^>]*)>(.*?)</script\s*>", cls.html,
                flags=re.IGNORECASE | re.DOTALL,
            )
        ]
        cls.script = "\n".join(body for _attrs, body in cls.scripts)
        cls.css = "\n".join(re.findall(
            r"<style\b[^>]*>(.*?)</style\s*>", cls.html,
            flags=re.IGNORECASE | re.DOTALL,
        ))

    def attrs_for(self, element_id):
        self.assertIn(element_id, self.by_id, f"missing dashboard element #{element_id}")
        return self.by_id[element_id]

    def assert_function(self, name):
        self.assertRegex(
            self.script,
            rf"\b(?:async\s+)?function\s+{re.escape(name)}\s*\(",
            f"missing JavaScript function {name}()",
        )

    def test_static_ids_are_unique(self):
        duplicates = sorted(name for name, count in Counter(self.ids).items() if count > 1)
        self.assertEqual(duplicates, [], f"duplicate dashboard IDs: {duplicates}")

    def test_rooms_keep_accessible_tab_and_panel_pairs(self):
        room_values = {
            attrs.get("data-room")
            for _tag, attrs in self.elements
            if attrs.get("data-room")
        }
        self.assertTrue(set(ROOMS).issubset(room_values))

        for room in ROOMS:
            tab_tag, tab = self.attrs_for(f"tab-{room}")
            page_tag, page = self.attrs_for(f"page-{room}")
            self.assertEqual(tab_tag, "button")
            self.assertEqual(tab.get("data-room"), room)
            self.assertEqual(tab.get("role"), "tab")
            self.assertEqual(tab.get("aria-controls"), f"page-{room}")
            self.assertEqual(page_tag, "section")
            self.assertEqual(page.get("role"), "tabpanel")
            self.assertEqual(page.get("aria-labelledby"), f"tab-{room}")

        active_tabs = [
            attrs for _tag, attrs in self.elements
            if attrs.get("data-room") and "active" in attrs.get("class", "").split()
        ]
        active_pages = [
            attrs for _tag, attrs in self.elements
            if attrs.get("id", "").startswith("page-")
            and "active" in attrs.get("class", "").split()
        ]
        self.assertEqual([item.get("data-room") for item in active_tabs], ["overview"])
        self.assertEqual([item.get("id") for item in active_pages], ["page-overview"])

    def test_go_remains_global_for_native_open_workloads_action(self):
        go_blocks = [(attrs, body) for attrs, body in self.scripts
                     if re.search(r"\bfunction\s+go\s*\(\s*room\s*\)", body)]
        self.assertTrue(go_blocks, "native shell requires a global go(room) function")
        explicitly_exported = re.search(r"\b(?:window|globalThis)\.go\s*=\s*go\b", self.script)
        classic_script = any(
            attrs.get("type", "").lower() not in {"module", "text/module"}
            for attrs, _body in go_blocks
        )
        self.assertTrue(classic_script or explicitly_exported,
                        "go(room) must be callable by native evaluateJavaScript")
        self.assertRegex(self.script, r"dataset\.room\s*===?\s*room")
        self.assertRegex(self.script, r"[\"']page-[\"']\s*\+\s*room")
        self.assertIn("workloads", ROOMS)

    def test_loading_and_preview_body_state_contracts(self):
        self.attrs_for("loadingScreen")
        self.assertRegex(self.css, r"body\.loaded\s+\.loading-screen")
        self.assertRegex(self.css, r"body\.preview\s+\.preview-badge")
        self.assertRegex(
            self.script,
            r"document\.body\.classList\.add\(\s*[\"']loaded[\"']\s*\)",
        )
        self.assertRegex(
            self.script,
            r"document\.body\.classList\.toggle\(\s*[\"']preview[\"']",
        )

    def test_native_window_drag_aliases_remain_in_the_dom(self):
        # BatteryHogApp.swift treats these as aliases for draggable title-bar space.
        self.assertTrue({"page-head", "drag-strip", "brand"}.issubset(self.classes))
        for alias in ("page-head", "drag-strip", "brand"):
            self.assertRegex(self.css, rf"\.{alias}\b")

    def test_core_fetch_and_render_entry_points_remain_available(self):
        required_functions = {
            "fetchStats", "render", "renderBattery", "renderMemory",
            "renderLowPower", "renderTopUsers", "renderProcesses", "renderQuick",
            "renderWorkloads", "renderSleepBlockers", "renderHealth",
            "renderSuggestions", "renderSettings", "renderInsights",
            "loadHistory", "renderHistory", "updateAge",
        }
        for name in sorted(required_functions):
            with self.subTest(function=name):
                self.assert_function(name)

        for endpoint in ("/api/stats", "/api/history", "/api/settings",
                         "/api/kill", "/api/lowpower", "/api/ignore"):
            with self.subTest(endpoint=endpoint):
                self.assertIn(endpoint, self.script)

        self.assertIn("statsInFlight", self.script)
        self.assertRegex(self.script, r"finally\s*\{[^}]*statsInFlight\s*=\s*false")
        self.assertRegex(self.script, r"setInterval\(\s*fetchStats\s*,")

    def test_action_data_hooks_stay_delegated_and_name_safe(self):
        for action in ("kill", "lpm", "ignore", "unmute"):
            with self.subTest(action=action):
                self.assertRegex(
                    self.script,
                    rf"data-act\s*=\s*[\"']{action}[\"']",
                    f"missing rendered data-act={action} hook",
                )
                self.assertRegex(
                    self.script,
                    rf"\[data-act\s*=\s*[\\\"']{action}[\\\"']\]",
                    f"missing delegated data-act={action} handler",
                )
        self.assertIn("[data-jump]", self.script)
        self.assertIn("dataset.jump", self.script)
        for hook in ("data-name", "data-bundle", "data-pids"):
            self.assertIn(hook, self.script)

        inline_handlers = [
            (tag, attr)
            for tag, attrs in self.elements
            for attr in attrs
            if attr.lower().startswith("on")
        ]
        self.assertEqual(inline_handlers, [], "actions should use delegated listeners")

    def test_process_rows_keep_stable_keys_and_safe_action_payloads(self):
        self.attrs_for("procList")
        self.assertRegex(self.script, r"querySelectorAll\(\s*[\"']\.prow[\"']\s*\)")
        self.assertRegex(self.script, r"existing\.set\(\s*el\.dataset\.key\s*,\s*el\s*\)")
        self.assertRegex(self.script, r"el\.dataset\.key\s*=\s*p\.name")
        self.assertRegex(self.script, r"qb\.dataset\.bundle\s*=")
        self.assertRegex(self.script, r"qb\.dataset\.pids\s*=")
        self.assert_function("delegatedKill")
        self.assert_function("killProc")

    def test_history_chart_keeps_svg_and_range_contracts(self):
        tag, svg = self.attrs_for("histSvg")
        self.assertEqual(tag, "svg")
        self.assertEqual(svg.get("role"), "img")
        self.assertTrue(svg.get("viewbox"), "history SVG needs a coordinate system")
        self.attrs_for("histSeg")
        ranges = {
            attrs.get("data-range")
            for _tag, attrs in self.elements
            if attrs.get("data-range")
        }
        self.assertTrue({"24h", "10d"}.issubset(ranges))
        self.assertIn('/api/history?range=', self.script)
        self.assertRegex(self.script, r"\$\(\s*[\"']#histSvg[\"']\s*\)")

    def test_agent_heat_and_settings_control_contracts(self):
        required_ids = {
            "workloadList", "agentModeCard", "agentModeSwitch", "devSlots",
            "devWorkersCtl", "devDraw", "gateCommand", "copyGateBtn", "gateList",
            "workSleepNotice", "mbPreviewTxt", "alertToggle", "thrRange", "thrVal",
            "insRefresh", "sleepList",
        }
        for element_id in sorted(required_ids):
            with self.subTest(element_id=element_id):
                self.attrs_for(element_id)

        settings = {
            attrs.get("data-set")
            for _tag, attrs in self.elements
            if attrs.get("data-set")
        }
        menubar = {
            attrs.get("data-mb")
            for _tag, attrs in self.elements
            if attrs.get("data-mb")
        }
        self.assertTrue({"alerts", "heat"}.issubset(settings))
        self.assertTrue({"percent", "watts", "time", "hog", "dev"}.issubset(menubar))

        for name in ("toggleAgentMode", "copyGateCommand", "toggleHeatAlerts",
                     "applyPendingSettings", "setMenubar"):
            with self.subTest(function=name):
                self.assert_function(name)
        self.assertRegex(self.script, r"pendingSettings\.heat")
        self.assertRegex(self.script, r"JSON\.stringify\(\s*\{\s*heat\s*:")

    def test_javascript_id_references_have_static_targets(self):
        # Catch accidental removal/renaming of a live target during a visual rewrite.
        referenced = set(re.findall(
            r"(?:\$|setStat)\(\s*[\"']#([A-Za-z][\w:.-]*)[\"']\s*\)",
            self.script,
        ))
        # runEnergy()/renderEnergy() are retained, explicitly marked legacy, and no
        # longer wired to the DOM. They may be deleted independently of the UI.
        retired_energy_ui = {
            "energyErr", "energyIdle", "energyResults", "energyTasks",
            "measureBtn", "measureBtnInner", "measureBtnTop", "scanDesc",
            "scanIco", "scanRing", "scanTitle", "wattGrid",
        }
        missing = sorted(referenced - set(self.ids) - retired_energy_ui)
        self.assertEqual(missing, [], f"JavaScript references missing static IDs: {missing}")

    def test_overhaul_keeps_theme_motion_and_keyboard_accessibility(self):
        self.assertRegex(self.css, r"@media\s*\(\s*prefers-color-scheme\s*:\s*dark\s*\)")
        self.assertRegex(self.css, r"@media\s*\(\s*prefers-reduced-motion\s*:\s*reduce\s*\)")
        self.assertIn(":focus-visible", self.css)
        self.assertRegex(self.css, r":root\s*\{[^}]*--accent\s*:")

        for element_id in ("agentModeSwitch", "lpmSwitch"):
            _tag, attrs = self.attrs_for(element_id)
            self.assertEqual(attrs.get("role"), "switch")
            self.assertEqual(attrs.get("tabindex"), "0")
        _tag, toast = self.attrs_for("toast")
        self.assertEqual(toast.get("role"), "status")
        self.assertEqual(toast.get("aria-live"), "polite")

    def test_battery_level_rail_and_threshold_row_keep_polished_layout_contracts(self):
        self.assertNotIn("charge horizon", self.html.lower())
        self.assertRegex(
            self.html,
            r'class="current-energy-rail"\s*>\s*<span>Empty</span>'
            r'\s*<span>Battery level</span>\s*<span>Full</span>',
        )
        self.assertRegex(
            self.html,
            r'class="set-row set-row-threshold"[^>]*>.*?id="thrRange"',
        )
        self.assertRegex(self.css, r"\.current-energy:after\s*\{\s*content:none")
        self.assertRegex(
            self.css,
            r"\.set-row-threshold\s*\{[^}]*flex-direction:column",
        )


if __name__ == "__main__":
    unittest.main()
