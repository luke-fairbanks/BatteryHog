const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {JSDOM, VirtualConsole} = require('jsdom');
const root = path.resolve(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'dashboard.html'), 'utf8');
const catalogs = Object.fromEntries(['en', 'zh-Hans'].map(lang =>
  [lang, JSON.parse(fs.readFileSync(path.join(root, `locales/${lang}.json`), 'utf8'))]));

function dashboard(languages) {
  const errors = [];
  const console = new VirtualConsole();
  console.on('jsdomError', error => { if (error.type !== 'css parsing') errors.push(error); });
  const dom = new JSDOM(html, {runScripts: 'dangerously', virtualConsole: console, beforeParse(w) {
    w.__batteryHogLanguages = languages;
    w.fetch = () => new Promise(() => {});
    w.setTimeout = w.setInterval = () => 0;
  }});
  return {dom, w: dom.window, errors};
}
const stats = {
  ts: 1793500000, ncpu: 8, lowpower: false,
  battery: {percent: 45, state: 'discharging', on_ac: false, time: '4:20'},
  power: {watts: 31, direction: 'discharging'},
  memory: {total_gb: 16, used_gb: 12, pressure: 'high', swap_used_mb: 2048},
  health: {health: 79, cycles: 300, temp_c: 36, condition: 'Normal'},
  settings: {alerts: false, menubar: {}, dev: {enabled: true, slots: 2}},
  dev_summary: {projects: 2, workers: 9, active_workers: 4, heavy_workers: 3, cpu: 155, level: 'high', agents: ['Codex']},
  processes: [{name: '<App> {cpu}', path: '/test', procs: 2, cpu: 120, mem_mb: 1500, score: 99, level: 'high'}],
  workloads: [{name: 'Demo', path: '/demo', status: 'Building', cpu: 100, workers: 2, mem_mb: 400}],
  sleep_blockers: [{name: 'Test App', detail: 'PreventUserIdleSystemSleep', duration_s: 130, stale: true}],
  power_policy: {display_sleep: 30},
  insights: {ok: true, today: {runtime_h: 4, rate: 25, on_battery_h: 2}, week: {rate: 20}, wakes: 20, charges: 2},
  gate: {command: 'batteryhog-gate --', active: [{label: 'Build', state: 'active', started_at: 1793499990}]},
  uptime: {days: 5}
};

function render(w, data) {
  w.eval(`state.data=${JSON.stringify(data)};recordPowerSample(state.data);render();`);
}

test('every locale preserves catalog keys and named placeholders', () => {
  const keys = Object.keys(catalogs.en).sort();
  const placeholders = text => [...text.matchAll(/\{([A-Za-z]\w*)\}/g)].map(m => m[1]).sort();
  for (const [lang, catalog] of Object.entries(catalogs)) {
    assert.deepEqual(Object.keys(catalog).sort(), keys, lang);
    for (const key of keys) {
      const variants = typeof catalog[key] === 'string' ? [catalog[key]] : Object.values(catalog[key]);
      for (const value of variants) {
        assert.ok(value.length > 0, `${lang}: ${key}`);
        assert.deepEqual(placeholders(value), placeholders(key), `${lang}: ${key}`);
      }
    }
  }
});

test('language priority, regional aliases, and unsupported languages', () => {
  const {dom, w, errors} = dashboard(['en']);
  try {
    for (const [languages, expected] of [
      [['zh-Hans-CN', 'en'], 'zh-Hans'], [['zh_CN'], 'zh-Hans'], [['zh-SG'], 'zh-Hans'],
      [['en-GB', 'zh-Hans'], 'en'], [['fr', 'zh-Hans'], 'zh-Hans'],
      [['zh-Hant', 'en'], 'en'], [['zh-TW'], 'en'], [['de'], 'en'], [[], 'en']
    ]) assert.equal(w.eval(`BatteryHogI18n.resolveLanguage(${JSON.stringify(languages)})`), expected);
    assert.deepEqual(errors, []);
  } finally { dom.window.close(); }
});

test('Chinese static labels, dynamic pages, chart states, and escaped app names', () => {
  const {dom, w, errors} = dashboard(['zh-Hans']);
  const text = id => w.document.getElementById(id).textContent;
  try {
    assert.equal(w.document.documentElement.lang, 'zh-Hans');
    assert.equal(text('tab-workloads').trim().startsWith('工作负载'), true);
    render(w, stats);
    assert.equal(text('currentCauseAction'), '查看工作负载');
    assert.match(text('workloadList'), /正在构建/);
    assert.equal(text('hCond'), '正常');
    assert.ok(w.document.querySelector('#condChip .normal'));
    assert.match(text('insRuntime'), /小时/);
    assert.match(text('sleepList'), /显示器睡眠时间为 30 分钟/);
    assert.match(text('powerTraceSummary'), /采样/);
    assert.match(text('procList'), /<App> \{cpu\}/);
    assert.equal(w.document.querySelector('#procList app'), null);
    for (const range of ['24h', '10d']) {
      const start = stats.ts - 86400, end = stats.ts;
      w.eval(`hist.data=${JSON.stringify({range,start,end,last_full:start,bins:[{v:70,hi:75,ac:true},{v:45,hi:50,ac:false}]})};hist.loading=false;renderHistory();`);
      assert.equal(text('histTitle'), '上次充满电');
      assert.ok(w.document.querySelector('#histSvg path'));
    }
    w.eval('hist.data=null;hist.error=true;renderHistory();');
    assert.match(text('histSvg'), /正在重试/);
    render(w, {...stats, dev_summary: {}, workloads: [], processes: [], sleep_blockers: [], power_policy: {}, battery: {}});
    assert.match(text('batState'), /无电池/);
    assert.match(text('currentCauseTitle'), /Mac/);
    assert.deepEqual(errors, []);
  } finally { dom.window.close(); }
});

test('Chinese updater retains direct checks, consent, and Homebrew controls', () => {
  const {dom, w, errors} = dashboard(['zh-Hans']);
  const text = id => w.document.getElementById(id).textContent;
  try {
    w.eval('batteryHogUpdatesDidChange({available:true,canCheck:true,installMethod:"direct",status:"idle",automaticChecks:false})');
    assert.equal(w.document.getElementById('updateCheckBtn').disabled, false);
    assert.equal(text('updateTitle'), '随时检查软件更新');
    assert.equal(w.document.getElementById('updateAutomaticSwitch').getAttribute('aria-checked'), 'false');
    w.eval('batteryHogUpdatesDidChange({status:"checking",checking:true})');
    assert.equal(text('updateTitle'), '正在检查新版本…');
    assert.equal(w.document.getElementById('updateCheckBtn').disabled, true);
    w.eval('batteryHogUpdatesDidChange({status:"updateAvailable",checking:false,updateAvailable:true,latestVersion:"1.5.0"})');
    assert.equal(text('updateTitle'), '更新 v1.5.0 已就绪');
    assert.equal(w.document.getElementById('updateCheckBtn').disabled, false);
    w.eval('batteryHogUpdatesDidChange({installMethod:"homebrew",status:"homebrew",updateAvailable:false,homebrewCommand:"brew upgrade --cask luke-fairbanks/tap/battery-hog"})');
    assert.equal(text('updateTitle'), '由 Homebrew 管理');
    assert.equal(w.document.getElementById('updateDirectControls').hidden, true);
    assert.equal(w.document.getElementById('updateHomebrewControls').hidden, false);
    assert.equal(text('updateHomebrewCommand'), 'brew upgrade --cask luke-fairbanks/tap/battery-hog');
    assert.deepEqual(errors, []);
  } finally { dom.window.close(); }
});

test('English renders after refresh, plural rules and one-pass placeholder substitution', () => {
  const {dom, w, errors} = dashboard(['en-US']);
  try {
    render(w, stats);
    assert.equal(w.document.getElementById('currentCauseAction').textContent, 'Open Workloads');
    assert.equal(w.eval('tr("{count} projects",{count:1})'), '1 project');
    assert.equal(w.eval('tr("{count} projects",{count:2})'), '2 projects');
    assert.equal(w.eval('tr("Quit {name}",{name:"{cpu} <App>",cpu:99})'), 'Quit {cpu} <App>');
    assert.equal(w.eval('tr("Unknown future message")'), 'Unknown future message');
    assert.deepEqual(errors, []);
  } finally { dom.window.close(); }
});

test('all annotated text and literal translation keys exist in catalogs', () => {
  const {dom, w} = dashboard(['en']);
  try {
    for (const el of w.document.querySelectorAll('[data-i18n], [data-i18n-title], [data-i18n-aria-label]')) {
      for (const attr of ['data-i18n', 'data-i18n-title', 'data-i18n-aria-label']) {
        const key = el.getAttribute(attr);
        if (key) assert.ok(Object.hasOwn(catalogs.en, key), key);
      }
    }
    const source = html.slice(html.lastIndexOf('<script>'));
    for (const match of source.matchAll(/\btr\(("(?:[^"\\]|\\.)*")/g)) {
      const key = JSON.parse(match[1]);
      assert.ok(Object.hasOwn(catalogs.en, key), key);
    }
  } finally { dom.window.close(); }
});
