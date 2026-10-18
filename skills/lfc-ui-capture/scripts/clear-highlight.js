// clear-highlight.js: pass to evaluate_script as `function` to remove the boxes highlight.js drew.
() => { const n = document.querySelectorAll('[data-lfc-highlight]'); n.forEach(e => e.remove()); return n.length; }
