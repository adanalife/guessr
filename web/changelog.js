// Renders CHANGELOG.md into the About panel.
//
// ponytail: this handles the slice of markdown release-please emits — `##` and
// `###` headings, `*` bullets, inline links and bold — and drops everything
// else. It is not a general parser, and a markdown library would be a
// dependency for one file that only ever holds one shape. Reach for one if the
// changelog ever grows hand-written prose.
//
// A plain script rather than a module so node can eval it in a test, the same
// arrangement daily.js and zoom.js use.

// Escape first, so the tags substituted in below are the only markup that
// survives — the changelog is generated, but it quotes commit subjects that
// aren't.
function inlineMarkdown(text) {
  return text
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, '<a href="$2">$1</a>')
    .replace(/\*\*([^*]+)\*\*/g, '<b>$1</b>');
}

function renderChangelog(md) {
  return md.split('\n').map(line => {
    const t = inlineMarkdown(line.trim());
    if (t.startsWith('### ')) return `<h5>${t.slice(4)}</h5>`;
    if (t.startsWith('## ')) return `<h4>${t.slice(3)}</h4>`;
    if (t.startsWith('* ')) return `<div class="bullet">${t.slice(2)}</div>`;
    return '';
  }).join('');
}
