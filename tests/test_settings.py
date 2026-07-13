import copy
import json
import unittest
from unittest import mock

import battery_hog


class SettingsTests(unittest.TestCase):
    def test_heat_alerts_default_to_disabled(self):
        with mock.patch("builtins.open", side_effect=FileNotFoundError):
            settings = battery_hog._load_settings()

        self.assertEqual(settings["heat"], {"enabled": False})

    def test_loads_heat_setting_without_mutating_parsed_input(self):
        parsed = {
            "alerts": True,
            "menubar": {"watts": False},
            "dev": {"slots": 3},
            "heat": {"enabled": True},
        }
        original = copy.deepcopy(parsed)
        with mock.patch("builtins.open", mock.mock_open()), \
                mock.patch.object(battery_hog.json, "load", return_value=parsed):
            settings = battery_hog._load_settings()

        self.assertEqual(parsed, original)
        self.assertTrue(settings["heat"]["enabled"])
        self.assertEqual(settings["dev"]["slots"], 3)

    def test_rejects_non_boolean_persisted_heat_setting(self):
        parsed = {"heat": {"enabled": "yes"}}
        with mock.patch("builtins.open", mock.mock_open()), \
                mock.patch.object(battery_hog.json, "load", return_value=parsed):
            settings = battery_hog._load_settings()

        self.assertFalse(settings["heat"]["enabled"])

    def test_settings_api_updates_heat_alert_preference(self):
        handler = object.__new__(battery_hog.Handler)
        handler.path = "/api/settings"
        handler._read_json = lambda: {"heat": {"enabled": True}}
        response = {}
        handler._send = lambda code, body, ctype="application/json": response.update(
            code=code, body=json.loads(body))

        original = copy.deepcopy(battery_hog._SETTINGS)
        try:
            battery_hog._SETTINGS.setdefault("heat", {})["enabled"] = False
            with mock.patch.object(battery_hog, "_save_settings"):
                battery_hog.Handler.do_POST(handler)
            self.assertEqual(response["code"], 200)
            self.assertTrue(response["body"]["settings"]["heat"]["enabled"])
        finally:
            battery_hog._SETTINGS.clear()
            battery_hog._SETTINGS.update(original)


if __name__ == "__main__":
    unittest.main()
