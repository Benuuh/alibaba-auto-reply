// Invented conversation surfaces. No browser, network, or customer data.
function visible(node, shown = true) {
  node.isConnected = true;
  node.getClientRects = () => shown ? [{}] : [];
  return node;
}
function documentFor(rows, opts = {}) {
  let currentName = opts.initialName || opts.name || 'Buyer A';
  const panel = visible({className: 'message-container'});
  const otherPanel = visible({className: 'message-container'}, !!opts.extraVisiblePanel);
  const header = visible({get innerText() { return currentName; }});
  let reads = 0;
  header.closest = sel => sel === '.message-container' ? (opts.detachedHeader ? otherPanel : panel) : null;
  panel.contains = node => node === header || rows.includes(node);
  panel.querySelectorAll = sel => {
    if (sel !== '[class*=message-item-wrapper]') return [];
    return opts.rowSequence ? opts.rowSequence[Math.min(reads++, opts.rowSequence.length - 1)] : rows;
  };
  panel.querySelector = sel => sel === '.content-header' ? header : null;
  for (const r of rows.concat(...(opts.rowSequence || []))) {
    visible(r, !r.hidden);
    r.closest = sel => sel === '.message-container' ? panel : null;
  }
  const outside = opts.outsideRows || [];
  for (const r of outside) {
    visible(r);
    r.closest = sel => sel === '.message-container' ? otherPanel : null;
  }
  const names = opts.contacts || ['Buyer A'];
  const contacts = names.map(name => visible({
    innerText: name + '\n' + (opts.preview || ''),
    querySelector: sel => sel === '.contact-info .name' ? {innerText: name} : null,
    click() { if (!opts.neverSwitch) currentName = name; }
  }));
  const headers = opts.extraHeader ? [header, visible({innerText: 'Buyer B'})] : [header];
  const panels = [panel, otherPanel];
  return {
    querySelector(sel) { return this.querySelectorAll(sel)[0] || null; },
    querySelectorAll(sel) {
      if (sel === '.contact-item-container') return contacts;
      if (sel === '.content-header') return headers;
      if (sel === '.message-container') return panels;
      if (sel === '[class*=message-item-wrapper]') return rows.concat(outside);
      return [];
    }
  };
}
module.exports = {documentFor, visible};
