// Dumps Remon's accessibility tree (role, title/description, value) to a given depth.
// Usage: osascript -l JavaScript scripts/e2e/ax-dump.js [depth] [windowIndex]
function run(argv) {
  const se = Application('System Events');
  const proc = se.processes.byName('Remon');
  const depth = parseInt(argv[0] || '6');
  const win = proc.windows[parseInt(argv[1] || '0')];
  const out = [];
  function walk(el, d) {
    if (d > depth) return;
    let role = '', name = '', desc = '', value = '';
    try { role = el.role(); } catch (e) {}
    try { name = el.name() || ''; } catch (e) {}
    try { desc = el.description() || ''; } catch (e) {}
    try { const v = el.value(); value = (v === null || v === undefined) ? '' : String(v).slice(0, 40); } catch (e) {}
    if (role !== 'AXGroup' || name || desc) out.push('  '.repeat(d) + [role, name, desc, value].filter(x => x).join(' | '));
    let kids = [];
    try { kids = el.uiElements(); } catch (e) {}
    for (const k of kids) walk(k, d + 1);
  }
  walk(win, 0);
  return out.join('\n');
}
