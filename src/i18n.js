/* Shared JSON catalogs are embedded here by scripts/build_localizations.py.
   No fetch, remote script, or relaxed content policy is needed. */
const BatteryHogI18n = (() => {
  function resolveLanguage(preferences) {
    for (const preference of preferences || []) {
      const tag = String(preference).replace(/_/g, '-').toLowerCase();
      if (tag === 'en' || tag.startsWith('en-')) return 'en';
      if (tag === 'zh' || tag === 'zh-cn' || tag === 'zh-sg' || tag.startsWith('zh-hans')) return 'zh-Hans';
      // Traditional Chinese is not silently treated as Simplified Chinese.
    }
    return 'en';
  }
  const language = resolveLanguage(window.__batteryHogLanguages || navigator.languages || [navigator.language]);
  const locale = language === 'zh-Hans' ? 'zh-CN' : 'en';
  function translate(key, values = {}) {
    let message = batteryHogCatalogs[language]?.[key] ?? batteryHogCatalogs.en[key] ?? key;
    if (typeof message === 'object' && message !== null) {
      const category = new Intl.PluralRules(locale).select(Number(values.count) || 0);
      message = message[category] ?? message.other ?? key;
    }
    // One pass prevents user-controlled values from being interpreted as placeholders.
    return String(message).replace(/\{([A-Za-z][\w]*)\}/g, (match, name) =>
      Object.prototype.hasOwnProperty.call(values, name) ? String(values[name]) : match);
  }
  function localizeDocument(root = document) {
    root.querySelectorAll('[data-i18n]').forEach(el => { el.textContent = translate(el.dataset.i18n); });
    for (const attribute of ['title', 'aria-label']) {
      root.querySelectorAll(`[data-i18n-${attribute}]`).forEach(el => {
        el.setAttribute(attribute, translate(el.getAttribute(`data-i18n-${attribute}`)));
      });
    }
    document.documentElement.lang = language;
  }
  return {language, locale, translate, localizeDocument, resolveLanguage};
})();
const tr = BatteryHogI18n.translate;
BatteryHogI18n.localizeDocument();
