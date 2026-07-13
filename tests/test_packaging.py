import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SRC = ROOT / "src"


class DmgPackagingContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.package = (SRC / "package.sh").read_text(encoding="utf-8")
        cls.release = (SRC / "release.sh").read_text(encoding="utf-8")
        cls.builder = (SRC / "build_dmg.sh").read_text(encoding="utf-8")
        cls.artwork = (SRC / "make_dmg_background.swift").read_text(encoding="utf-8")

    def test_ad_hoc_and_notarized_builds_share_the_styled_dmg_builder(self):
        invocation = '"$ROOT/src/build_dmg.sh" "$APP" "$DMG" "Battery Hog Installer"'
        self.assertIn(invocation, self.package)
        self.assertIn(invocation, self.release)

    def test_builder_keeps_the_native_drag_to_install_contract(self):
        for required in (
            'ln -s /Applications "$MOUNT_DIR/Applications"',
            '"$MOUNT_DIR/.background/background.png"',
            'set bounds of container window to {140, 120, 820, 572}',
            'set icon size of viewOptions to 112',
            'set position of item applicationName of container window to {170, 236}',
            'set position of item "Applications" of container window to {510, 236}',
            'set background picture of viewOptions to file ".background:background.png"',
            'SetFile -c icnC "$MOUNT_DIR/.VolumeIcon.icns"',
            'hdiutil convert "$RW_DMG"',
            '-format UDZO',
        ):
            with self.subTest(required=required):
                self.assertIn(required, self.builder)

        self.assertIn('[ -s "$MOUNT_DIR/.DS_Store" ]', self.builder)
        self.assertIn('rm -rf "$MOUNT_DIR/.fseventsd"', self.builder)

    def test_artwork_matches_the_current_battery_hog_visual_language(self):
        for required in (
            'NSSize(width: 680, height: 420)',
            '"Drag Battery Hog to Applications"',
            '"Then launch it from Spotlight or Launchpad."',
            'NSColor(hex: 0xcaff58)',
            'drawLabelPlate(x: 105, width: 130)',
            'drawLabelPlate(x: 445, width: 130)',
        ):
            with self.subTest(required=required):
                self.assertIn(required, self.artwork)

        self.assertNotIn("BATTERY HOG / INSTALL", self.artwork)
        self.assertNotIn("SIGNED & NOTARIZED", self.artwork)


if __name__ == "__main__":
    unittest.main()
