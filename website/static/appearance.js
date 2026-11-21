(() => {
  const key = 'panache.site.appearance';
  const root = document.documentElement;
  function apply(value) {
    const mode = value === 'light' || value === 'dark' ? value : 'system';
    root.dataset.appearance = mode;
    for (const button of document.querySelectorAll('button[data-appearance]')) {
      button.setAttribute('aria-pressed', String(button.dataset.appearance === mode));
    }
    document.dispatchEvent(new Event('panache:appearance'));
  }
  try {
    apply(localStorage.getItem(key));
  } catch {
    apply('system');
  }
  document.addEventListener('DOMContentLoaded', () => {
    const controls = document.querySelector('.site-appearance');
    apply(root.dataset.appearance);
    controls.hidden = false;
    controls.addEventListener('click', event => {
      const button = event.target.closest('button[data-appearance]');
      if (!button) return;
      apply(button.dataset.appearance);
      try {
        localStorage.setItem(key, button.dataset.appearance);
      } catch {
        // The current page still follows the selected appearance.
      }
    });
  });
  window.addEventListener('storage', event => {
    if (event.key === key || event.key === null) apply(event.newValue);
  });
})();
