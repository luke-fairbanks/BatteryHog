const header = document.querySelector('.site-header');
const syncHeader = () => header?.classList.toggle('scrolled', window.scrollY > 8);
syncHeader();
addEventListener('scroll', syncHeader, { passive: true });

for (const link of document.querySelectorAll('[data-download]')) {
  link.addEventListener('click', () => {
    // Intentionally local-only. No analytics or tracking request is made.
    document.documentElement.dataset.lastAction = 'download';
  });
}

const screenImage = document.querySelector('[data-screen-image]');
const screenCaption = document.querySelector('[data-screen-caption]');
const screenCopy = {
  now: ['assets/product-now.png', 'Battery Hog Now screen showing energy forecast, total power draw, likely app contributor, and current history.', 'A live battery investigation at a glance.'],
  apps: ['assets/product-apps.png', 'Battery Hog Apps screen ranking active Mac applications by estimated energy impact.', 'Rank likely app contributors without pretending they are exact per-app watts.'],
  workloads: ['assets/product-workloads.png', 'Battery Hog Workloads screen grouping compiler workers and dev servers into projects.', 'Turn workers, compilers, and coding-agent descendants into projects.'],
  insights: ['assets/product-insights.png', 'Battery Hog Insights screen showing drain, sleep, and charge observations.', 'Connect charge history, drain patterns, wake events, and sleep blockers.'],
  settings: ['assets/product-settings.png', 'Battery Hog Settings screen with alert, menu bar, and updater controls.', 'Opt into the alerts and controls that fit your workflow.']
};
for (const tab of document.querySelectorAll('[data-screen]')) {
  tab.addEventListener('click', () => {
    const next = screenCopy[tab.dataset.screen];
    if (!screenImage || !next) return;
    screenImage.src = next[0];
    screenImage.alt = next[1];
    if (screenCaption) screenCaption.textContent = next[2];
    for (const peer of document.querySelectorAll('[data-screen]')) {
      peer.setAttribute('aria-selected', String(peer === tab));
    }
  });
}
