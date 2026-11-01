# Localization

Battery Hog uses shared UTF-8 JSON catalogs for the WebKit dashboard and native Swift UI. English (`en`) and Simplified Chinese (`zh-Hans`) are included. Interface labels, accessibility labels, charts, empty/loading states, alerts, menus, and native notifications use the same translations.

## Selecting a language

The app follows the ordered macOS language preferences, including the per-app override in **System Settings → General → Language & Region → Applications**. Select **Battery Hog** and **Simplified Chinese**, then restart the app. English remains the fallback for unsupported languages or missing keys. Traditional Chinese is not automatically treated as Simplified Chinese.

A standalone `dashboard.html` preview uses the browser's language preferences. The app injects its macOS preferences before the dashboard executes, keeping the web and native interfaces aligned.

## Editing translations

Update `locales/en.json` and `locales/zh-Hans.json` together. English source phrases serve as stable keys. Use named placeholders for dynamic values; translate complete sentences instead of concatenating translated word fragments. Keep app names, paths, command syntax, API keys, process states, and macOS parser tokens unchanged.

```json
{
  "Quit {name}": "退出 {name}",
  "{count} projects": "{count} 个项目"
}
```

JavaScript calls `tr("Quit {name}", {name})`; Swift calls `L("Quit {name}", ["name": name])`. Static HTML uses `data-i18n`, `data-i18n-title`, and `data-i18n-aria-label`. HTML templates must escape translated values with `esc(...)`; `textContent` and native strings do not need HTML escaping. Replacement values are interpolated once, so braces in app names remain literal.

English count-dependent entries can use `{"one":"{count} project","other":"{count} projects"}`. The dashboard uses `Intl.PluralRules`; native Swift currently supports the one/other rules required by the bundled English and Chinese locales. Adding a language with different plural categories requires extending native plural selection and its tests.

After editing catalogs or `src/i18n.js`, regenerate the embedded dashboard resources:

```bash
python3 scripts/build_localizations.py
python3 scripts/build_localizations.py --check
```

The generated inline block keeps `dashboard.html` standalone and preserves its existing local-only content security policy. Builds check that this block is current and copy the JSON catalogs into the bundle for Swift.

To add a language, add its JSON catalog, register its matching rules in `src/i18n.js` and `src/Localization.swift`, update `CFBundleLocalizations` in `src/Info.plist`, extend the language tests, and regenerate the dashboard. Raw macOS diagnostic output and third-party tool, project, and app names are displayed as supplied.

## Validation

Node.js 18+ is needed only for development tests, not for the app:

```bash
npm ci
npm test
python3 -m unittest discover -s tests -p 'test_*.py'
bash tests/run_localization_tests.sh
bash tests/run_native_tests.sh
SKIP_DMG=1 bash src/package.sh
```

The localization tests cover catalog/placeholder parity, language priority and regional aliases, English fallback, plural forms, Chinese dynamic renders, history charts, and HTML-safe application names. Native tests run both languages with real bundled catalogs.
