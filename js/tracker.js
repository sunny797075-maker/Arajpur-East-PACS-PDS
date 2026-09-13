/* Pure tracking helpers and safe DOM rendering; no user data is interpreted as HTML. */
(function () {
  'use strict';
  const number = new Intl.NumberFormat(undefined, { maximumFractionDigits: 2 });
  const kg = value => number.format(value);
  function monthLabel(month) { const [year, m] = month.split('-').map(Number); return new Date(year, m - 1, 1).toLocaleDateString(undefined, { month: 'long', year: 'numeric' }); }
  function nextMonth(month) { const [y, m] = month.split('-').map(Number); return `${m === 12 ? y + 1 : y}-${String(m === 12 ? 1 : m + 1).padStart(2, '0')}`; }
  function summary(data, month = data.activeMonth) {
    const sales = data.sales.filter(s => s.month === month);
    const served = new Set(sales.map(s => s.beneficiaryId));
    const completed = data.beneficiaries.filter(p => served.has(p.id)).length;
    const wheat = sales.reduce((sum, s) => sum + Math.round(s.wheat * 100), 0) / 100;
    const rice = sales.reduce((sum, s) => sum + Math.round(s.rice * 100), 0) / 100;
    return { served, completed, wheat, rice, total: data.beneficiaries.length, pending: data.beneficiaries.length - completed };
  }
  function search(records, query) {
    const terms = query.trim().toLocaleLowerCase().split(/\s+/).filter(Boolean);
    return records.filter(p => terms.every(term => `${p.rcNumber} ${p.headName} ${p.phone}`.toLocaleLowerCase().includes(term))).sort((a, b) => a.headName.localeCompare(b.headName));
  }
  function el(tag, className, text) { const node = document.createElement(tag); if (className) node.className = className; if (text !== undefined) node.textContent = text; return node; }
  function action(text, className, operation, person) { const node = el('button', `button ${className}`, text); node.type = 'button'; node.dataset.action = operation; node.dataset.id = person.id; node.setAttribute('aria-label', `${text}: ${person.headName}, RC ${person.rcNumber}`); return node; }
  function renderList(container, people, data, mode, month = data.activeMonth) {
    const { served } = summary(data, month);
    const fragment = document.createDocumentFragment();
    if (!people.length) {
      const empty = el('div', 'empty');
      empty.append(el('strong', '', data.beneficiaries.length ? 'No matching families' : 'Your register starts here'), el('p', '', data.beneficiaries.length ? 'Try another search or status filter.' : 'Open Add Beneficiary to register your first family.'));
      fragment.append(empty);
    }
    for (const person of people) {
      const done = served.has(person.id);
      const card = el('article', 'record');
      const avatar = el('div', 'avatar', Array.from(person.headName)[0]?.toLocaleUpperCase() || '•'); avatar.setAttribute('aria-hidden', 'true');
      const main = el('div', 'record-main'), title = el('div', 'record-title');
      title.append(el('h3', '', person.headName), el('span', `status ${done ? 'distributed' : 'pending'}`, done ? 'DISTRIBUTED' : 'PENDING'));
      main.append(title, el('p', 'record-meta', `RC ${person.rcNumber} · ${person.members} ${person.members === 1 ? 'member' : 'members'}`), el('p', 'record-meta', person.phone), el('p', 'quota', `Wheat ${kg(person.wheat)} kg · Rice ${kg(person.rice)} kg`));
      if (done) {
        const sale = data.sales.find(s => s.beneficiaryId === person.id && s.month === month);
        main.append(el('p', 'record-meta', `${monthLabel(month)} · Issued wheat ${kg(sale.wheat)} kg + rice ${kg(sale.rice)} kg · Recorded ${new Date(sale.recordedAt).toLocaleDateString()}`));
      }
      const actions = el('div', 'record-actions');
      if (mode === 'manage') actions.append(action('Edit', 'secondary', 'edit', person), action('Delete', 'outline-danger', 'delete', person));
      else if (!done) {
        const call = el('a', 'button secondary', '☎ Call'); call.href = `tel:${person.phone}`; call.setAttribute('aria-label', `Call ${person.headName} at ${person.phone}`);
        actions.append(call, action('📦 Sale', 'primary', 'sale', person));
      } else { const issued = el('button', 'button secondary', '✓ Issued'); issued.disabled = true; actions.append(issued); }
      card.append(avatar, main, actions); fragment.append(card);
    }
    container.replaceChildren(fragment);
  }
  window.PDSTracker = Object.freeze({ kg, monthLabel, nextMonth, summary, search, renderList });
})();
