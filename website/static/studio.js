for (const gallery of document.querySelectorAll('[data-gallery]')) {
  const choices = JSON.parse(gallery.querySelector('script').textContent);
  const image = gallery.querySelector('.screen img');
  const link = image.parentElement;
  const base = new URL('.', image.src);
  const controls = gallery.querySelector('.selectors');
  controls.hidden = false;
  controls.addEventListener('click', event => {
    const button = event.target.closest('button');
    if (!button) return;
    for (const peer of button.parentElement.querySelectorAll('button')) {
      peer.setAttribute('aria-pressed', String(peer === button));
    }
    const preset = controls.querySelector('[data-preset][aria-pressed="true"]');
    const mode = controls.querySelector('[data-mode][aria-pressed="true"]');
    const source = new URL(choices[preset.dataset.preset + '-' + mode.dataset.mode], base);
    image.src = link.href = source.href;
    image.alt = preset.textContent.trim() + ' · ' + mode.textContent.trim();
  });
}

const search = document.querySelector('[data-search]');
if (search) {
  const query = (new URLSearchParams(location.search).get('q') || '').trim();
  search.elements.q.value = query;
  if (query) showMatches(query);
}

async function showMatches(query) {
  const status = document.querySelector('[data-status]');
  try {
    const response = await fetch(search.dataset.index);
    if (!response.ok) throw new Error('Search index unavailable');
    const pages = await response.json();
    const terms = query.toLocaleLowerCase().split(/\s+/);
    const list = document.querySelector('[data-results]');
    const matches = pages.filter(page => terms.every(term =>
      (page.title + ' ' + page.text).toLocaleLowerCase().includes(term)
    ));
    for (const page of matches) {
      const anchor = document.createElement('a');
      anchor.href = search.dataset.root + page.route + '/';
      anchor.textContent = page.title;
      const item = document.createElement('li');
      item.append(anchor);
      list.append(item);
    }
    if (!matches.length) status.textContent = search.dataset.empty;
  } catch {
    status.textContent = search.dataset.error;
  }
}
