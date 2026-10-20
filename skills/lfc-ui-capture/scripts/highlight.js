// highlight.js: pass to the Chrome DevTools evaluate_script tool as `function`, with `args` = the uids from
// take_snapshot of the element just finished (filled, selected) and the one about to be clicked, in that order;
// either may be left out. Draws a thick red box around each, replacing the previous step's boxes. The boxes
// ignore the mouse (pointer-events: none), so the click goes through; remove them with clear-highlight.js.
(...els) => {
  document.querySelectorAll('[data-lfc-highlight]').forEach(e => e.remove());
  const pad = 6;
  for (const el of els.filter(Boolean)) {
    el.scrollIntoView({block: 'nearest', inline: 'nearest'});
    const r = el.getBoundingClientRect();
    const box = document.createElement('div');
    box.setAttribute('data-lfc-highlight', '');
    Object.assign(box.style, {
      position: 'fixed', left: `${r.left - pad}px`, top: `${r.top - pad}px`,
      width: `${r.width + 2 * pad}px`, height: `${r.height + 2 * pad}px`,
      border: '5px solid #ff0000', borderRadius: '4px', boxSizing: 'border-box',
      pointerEvents: 'none', zIndex: 2147483647,
    });
    document.body.appendChild(box);
  }
  return document.querySelectorAll('[data-lfc-highlight]').length;
}
