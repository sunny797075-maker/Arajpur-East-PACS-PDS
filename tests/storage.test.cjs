const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
function setup() {
  const values = new Map();
  const context = vm.createContext({ window: {}, localStorage: { getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value) }, console });
  for (const file of ['storage.js', 'tracker.js']) vm.runInContext(fs.readFileSync(path.join(__dirname, '../js', file), 'utf8'), context);
  return { storage: context.window.PDSStorage, tracker: context.window.PDSTracker, values, context };
}
const person = { rcNumber: '001234', headName: 'Asha Devi', phone: '9876543210', members: 4, wheat: 10.25, rice: 9.75 };
test('persists beneficiaries, preserves leading zeros and rejects duplicate cards', () => {
  const { storage } = setup(); storage.initialize(); storage.saveBeneficiary(person);
  assert.equal(storage.read().beneficiaries[0].rcNumber, '001234');
  assert.throws(() => storage.saveBeneficiary(person), /already registered/);
  assert.equal(storage.read().beneficiaries.length, 1);
});
test('records one sale per month, retains quota snapshots through edits and deletion', () => {
  const { storage, tracker } = setup(); let data = storage.saveBeneficiary(person); const id = data.beneficiaries[0].id;
  data = storage.recordSale(id, data.activeMonth);
  assert.throws(() => storage.recordSale(id, data.activeMonth), /already received/);
  data = storage.saveBeneficiary({ ...person, wheat: 20 }, id);
  assert.equal(tracker.summary(data).wheat, 10.25);
  assert.equal(tracker.summary(data).pending, 0);
  data = storage.deleteBeneficiary(id);
  assert.equal(data.sales.length, 1); assert.equal(tracker.summary(data).wheat, 10.25);
});
test('month rollover clears current status and totals while retaining people and historical sales', () => {
  const { storage, tracker } = setup(); let data = storage.saveBeneficiary(person); const id = data.beneficiaries[0].id;
  data = storage.recordSale(id, data.activeMonth); const prior = data.activeMonth;
  data = storage.startMonth(tracker.nextMonth(prior), prior);
  assert.equal(data.beneficiaries.length, 1); assert.equal(data.sales.length, 1);
  assert.equal(tracker.summary(data).pending, 1); assert.equal(tracker.summary(data).wheat, 0);
  data = storage.recordSale(id, data.activeMonth); assert.equal(data.sales.length, 2);
  assert.equal(tracker.nextMonth('2026-12'), '2027-01');
  assert.throws(() => storage.startMonth('2028-01', prior), /active month changed/);
});
test('invalid input and malformed backups cannot overwrite existing data', () => {
  const { storage, values } = setup(); storage.saveBeneficiary(person); const before = values.get(storage.key);
  for (const patch of [{ phone: 'javascript:bad' }, { members: 0 }, { wheat: -2 }, { wheat: 1.111 }, { wheat: 0, rice: 0 }, { rice: '' }]) assert.throws(() => storage.saveBeneficiary({ ...person, ...patch }));
  assert.throws(() => storage.restore({ version: 2 }));
  assert.equal(values.get(storage.key), before);
  const corrupt = '{broken'; values.set(storage.key, corrupt);
  assert.throws(() => storage.initialize(), /not been overwritten/);
  assert.equal(values.get(storage.key), corrupt);
});
test('backup round trip preserves all records and rejects duplicate sales', () => {
  const { storage } = setup(); let data = storage.saveBeneficiary(person);
  data = storage.recordSale(data.beneficiaries[0].id, data.activeMonth);
  const json = JSON.stringify(data); storage.deleteBeneficiary(data.beneficiaries[0].id);
  assert.equal(JSON.stringify(storage.restore(JSON.parse(json))), json);
  data.sales.push({ ...data.sales[0], id: 'another' }); assert.throws(() => storage.restore(data), /duplicate sales/);
});
test('failed persistence reports an error without pretending a sale succeeded', () => {
  const { storage, context } = setup(); const data = storage.saveBeneficiary(person);
  context.localStorage.setItem = () => { throw new Error('quota exceeded'); };
  assert.throws(() => storage.recordSale(data.beneficiaries[0].id, data.activeMonth), /Could not save/);
  assert.equal(storage.read().sales.length, 0);
});
test('search matches names, card numbers and phone numbers without case sensitivity', () => {
  const { tracker } = setup(); const people = [person, { ...person, headName: 'Other', rcNumber: '999', phone: '1234567890' }];
  for (const query of ['ASHA', '001234', '98765', 'devi 0012']) assert.equal(tracker.search(people, query).length, 1);
  assert.equal(tracker.search(people, 'missing').length, 0);
});
test('current and previous month sales are independent and persisted in the status matrix', () => {
  const { storage, tracker } = setup(); let data = storage.saveBeneficiary(person);
  const id = data.beneficiaries[0].id, current = data.activeMonth, previous = storage.previousMonth(current);
  assert.ok(data.months.includes(previous));
  data = storage.recordSale(id, current);
  assert.equal(tracker.summary(data, current).completed, 1);
  assert.equal(tracker.summary(data, previous).pending, 1);
  assert.equal(tracker.summary(data, previous).wheat, 0);
  assert.equal(data.beneficiaries[0].statusByMonth[storage.statusKey(current)], 'DISTRIBUTED');
  assert.equal(data.beneficiaries[0].statusByMonth[storage.statusKey(previous)], 'REMAINING');
  data = storage.recordSale(id, previous);
  assert.equal(tracker.summary(data, previous).completed, 1);
  assert.equal(tracker.summary(data, current).wheat, person.wheat);
  assert.throws(() => storage.recordSale(id, previous), /already received/);
  assert.equal(storage.read().beneficiaries[0].statusByMonth[storage.statusKey(previous)], 'DISTRIBUTED');
});
test('starting another month preserves selectable history and its remaining families', () => {
  const { storage, tracker } = setup(); let data = storage.saveBeneficiary(person);
  const month = data.activeMonth, previous = storage.previousMonth(month), id = data.beneficiaries[0].id;
  data = storage.recordSale(id, previous);
  const next = tracker.nextMonth(month); data = storage.startMonth(next, month);
  for (const key of [previous, month, next]) assert.ok(data.months.includes(key));
  assert.equal(tracker.summary(data, previous).pending, 0);
  assert.equal(tracker.summary(data, month).pending, 1);
  assert.equal(tracker.summary(data, next).pending, 1);
  assert.equal(data.beneficiaries[0].statusByMonth[storage.statusKey(next)], 'REMAINING');
  assert.throws(() => storage.recordSale(id, '1900-01'), /unavailable/);
});
test('legacy v1 data migrates in place without losing sales, including older history', () => {
  const { storage, tracker, values } = setup();
  const legacy = { version: 1, activeMonth: '2026-09', beneficiaries: [{ id: 'legacy-person', ...person }], sales: [{ id: 'legacy-sale', beneficiaryId: 'legacy-person', month: '2026-07', rcNumber: person.rcNumber, headName: person.headName, wheat: 10, rice: 5, recordedAt: '2026-07-20T12:00:00.000Z' }] };
  values.set(storage.key, JSON.stringify(legacy));
  const data = storage.initialize();
  assert.equal(data.version, 2); assert.equal(data.sales[0].id, 'legacy-sale');
  for (const month of ['2026-07', '2026-08', '2026-09']) assert.ok(data.months.includes(month));
  assert.equal(tracker.summary(data, '2026-07').completed, 1);
  assert.equal(tracker.summary(data, '2026-08').pending, 1);
  assert.equal(JSON.parse(values.get(storage.key)).version, 2);
  assert.equal(storage.restore(legacy).sales.length, 1);
});
test('multi-month backup round trip preserves every month and rebuilds statuses from the ledger', () => {
  const { storage } = setup(); let data = storage.saveBeneficiary(person);
  const id = data.beneficiaries[0].id, current = data.activeMonth, previous = storage.previousMonth(current);
  data = storage.recordSale(id, previous); data = storage.recordSale(id, current);
  const copy = JSON.parse(JSON.stringify(data));
  copy.beneficiaries[0].statusByMonth[storage.statusKey(previous)] = 'REMAINING';
  const restored = storage.restore(copy);
  assert.equal(restored.sales.length, 2);
  assert.equal(restored.beneficiaries[0].statusByMonth[storage.statusKey(previous)], 'DISTRIBUTED');
  copy.months = [current]; assert.throws(() => storage.restore(copy), /outside its month register/);
});
