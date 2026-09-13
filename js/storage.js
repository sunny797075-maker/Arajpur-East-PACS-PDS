/* Local persistence. Each mutation commits one complete document before updating the UI. */
(function () {
  'use strict';
  const KEY = 'local-pds-tracker.v1';
  const monthPattern = /^\d{4}-(0[1-9]|1[0-2])$/;
  const clone = value => JSON.parse(JSON.stringify(value));
  function currentMonth() {
    const date = new Date();
    return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}`;
  }
  function previousMonth(month) {
    const [year, m] = month.split('-').map(Number);
    return `${m === 1 ? year - 1 : year}-${String(m === 1 ? 12 : m - 1).padStart(2, '0')}`;
  }
  const statusKey = month => `status_${month.replace('-', '_')}`;
  // Sales are the authoritative ledger. Rebuild the persisted matrix on every commit.
  function syncStatuses(data) {
    const issued = new Set(data.sales.map(sale => `${sale.beneficiaryId}:${sale.month}`));
    for (const person of data.beneficiaries) {
      person.statusByMonth = Object.fromEntries(data.months.map(month => [statusKey(month), issued.has(`${person.id}:${month}`) ? 'DISTRIBUTED' : 'REMAINING']));
    }
    return data;
  }
  function id() {
    return globalThis.crypto?.randomUUID?.() || `${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}-${Math.random().toString(36).slice(2)}`;
  }
  function normalize(input) {
    const rcNumber = String(input.rcNumber ?? '').trim();
    const headName = String(input.headName ?? '').trim().replace(/\s+/g, ' ');
    const phone = String(input.phone ?? '').trim().replace(/[\s()-]/g, '');
    if (!rcNumber || rcNumber.length > 40) throw new Error('Enter a ration card number of up to 40 characters.');
    if (!headName || headName.length > 100) throw new Error('Enter a head name of up to 100 characters.');
    if (!/^\+?\d{7,15}$/.test(phone)) throw new Error('Enter a valid phone number with 7–15 digits, optionally starting with +.');
    for (const field of ['members', 'wheat', 'rice']) {
      if (input[field] === '' || input[field] == null || !['string', 'number'].includes(typeof input[field])) throw new Error('Enter family members and both grain quotas.');
    }
    const members = Number(input.members), wheat = Number(input.wheat), rice = Number(input.rice);
    if (!Number.isInteger(members) || members < 1 || members > 100) throw new Error('Family members must be a whole number from 1 to 100.');
    if (![wheat, rice].every(n => Number.isFinite(n) && n >= 0 && n <= 10000 && Math.abs(n * 100 - Math.round(n * 100)) < 0.00001)) throw new Error('Grain quotas must be 0–10,000 kg with at most two decimal places.');
    if (wheat + rice <= 0) throw new Error('At least one grain quota must be greater than zero.');
    return { rcNumber, headName, phone, members, wheat, rice };
  }
  function validate(data) {
    if (!data || ![1, 2].includes(data.version) || !monthPattern.test(data.activeMonth) || !Array.isArray(data.beneficiaries) || !Array.isArray(data.sales)) throw new Error('This is not a supported PDS backup.');
    if (data.version === 2 && (!Array.isArray(data.months) || !data.months.length || data.months.some(month => typeof month !== 'string' || !monthPattern.test(month) || month > data.activeMonth) || !data.months.includes(data.activeMonth) || new Set(data.months).size !== data.months.length)) throw new Error('Backup contains an invalid month register.');
    const ids = new Set(), cards = new Set(), sales = new Set(), saleIds = new Set();
    for (const person of data.beneficiaries) {
      const clean = normalize(person);
      if (typeof person.id !== 'string' || !person.id || ids.has(person.id) || cards.has(clean.rcNumber.toLowerCase())) throw new Error('Backup contains duplicate or invalid beneficiary records.');
      ids.add(person.id); cards.add(clean.rcNumber.toLowerCase());
    }
    for (const sale of data.sales) {
      if (!sale || typeof sale !== 'object') throw new Error('Backup contains an invalid sale.');
      const key = `${sale.month}:${sale.beneficiaryId}`;
      if (!sale || typeof sale.id !== 'string' || !sale.id || saleIds.has(sale.id) || typeof sale.beneficiaryId !== 'string' || !sale.beneficiaryId || !monthPattern.test(sale.month) || sale.month > data.activeMonth || sales.has(key) || !Number.isFinite(Date.parse(sale.recordedAt)) || ![sale.wheat, sale.rice].every(n => typeof n === 'number' && Number.isFinite(n) && n >= 0 && n <= 10000 && Math.abs(n * 100 - Math.round(n * 100)) < 0.00001) || sale.wheat + sale.rice <= 0 || typeof sale.rcNumber !== 'string' || typeof sale.headName !== 'string') throw new Error('Backup contains invalid or duplicate sales.');
      sales.add(key); saleIds.add(sale.id);
    }
    const months = data.version === 1 ? [...new Set([data.activeMonth, previousMonth(data.activeMonth), ...data.sales.map(s => s.month)])].sort() : [...data.months].sort();
    if (data.sales.some(sale => !months.includes(sale.month))) throw new Error('Backup contains a sale outside its month register.');
    return syncStatuses({ version: 2, activeMonth: data.activeMonth, months, beneficiaries: data.beneficiaries.map(p => ({ id: p.id, ...normalize(p) })), sales: data.sales.map(s => ({ id: s.id, beneficiaryId: s.beneficiaryId, month: s.month, rcNumber: s.rcNumber, headName: s.headName, wheat: s.wheat, rice: s.rice, recordedAt: s.recordedAt })) });
  }
  function read() {
    let raw;
    try { raw = localStorage.getItem(KEY); } catch (_) { throw new Error('Device storage is unavailable. Enable browser/app storage to save records.'); }
    if (raw === null) return { version: 2, activeMonth: currentMonth(), months: [previousMonth(currentMonth()), currentMonth()], beneficiaries: [], sales: [] };
    try { return validate(JSON.parse(raw)); } catch (_) { throw new Error('Saved data could not be read. It has not been overwritten. Restore a valid backup to recover.'); }
  }
  function write(data) {
    syncStatuses(data);
    try { localStorage.setItem(KEY, JSON.stringify(data)); } catch (_) { throw new Error('Could not save to device storage. Storage may be full or disabled. Export a backup before clearing anything.'); }
    return clone(data);
  }
  function mutate(fn) { const data = read(); fn(data); return write(data); }
  window.PDSStorage = Object.freeze({
    key: KEY, read, validate, currentMonth, previousMonth, statusKey,
    initialize() {
      const data = read(), current = currentMonth();
      data.months = [...new Set([...data.months, previousMonth(current), current])].sort();
      data.activeMonth = data.months[data.months.length - 1];
      return write(data);
    },
    saveBeneficiary(input, editId = null) {
      const clean = normalize(input);
      return mutate(data => {
        if (data.beneficiaries.some(p => p.id !== editId && p.rcNumber.toLowerCase() === clean.rcNumber.toLowerCase())) throw new Error('This ration card number is already registered.');
        if (editId) {
          const index = data.beneficiaries.findIndex(p => p.id === editId);
          if (index < 0) throw new Error('This beneficiary no longer exists.');
          data.beneficiaries[index] = { id: editId, ...clean };
        } else data.beneficiaries.push({ id: id(), ...clean });
      });
    },
    deleteBeneficiary(beneficiaryId) {
      return mutate(data => { data.beneficiaries = data.beneficiaries.filter(p => p.id !== beneficiaryId); });
    },
    recordSale(beneficiaryId, month) {
      return mutate(data => {
        if (!data.months.includes(month)) throw new Error('This distribution month is unavailable. Refresh the register and try again.');
        const person = data.beneficiaries.find(p => p.id === beneficiaryId);
        if (!person) throw new Error('This beneficiary no longer exists.');
        if (data.sales.some(s => s.beneficiaryId === beneficiaryId && s.month === month)) throw new Error('This family has already received grain this month.');
        data.sales.push({ id: id(), beneficiaryId, month, rcNumber: person.rcNumber, headName: person.headName, wheat: person.wheat, rice: person.rice, recordedAt: new Date().toISOString() });
      });
    },
    startMonth(month, expectedMonth) {
      return mutate(data => {
        if (data.activeMonth !== expectedMonth) throw new Error('The active month changed. Review it before starting another month.');
        if (!monthPattern.test(month) || month <= data.activeMonth) throw new Error('The new month must follow the active month.');
        data.activeMonth = month;
        data.months.push(month);
      });
    },
    restore(input) { return write(validate(input)); }
  });
})();
