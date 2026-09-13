(function () {
  'use strict';
  const storage = window.PDSStorage, tracker = window.PDSTracker;
  const $ = id => document.getElementById(id);
  const state = { data: null, selectedMonth: null, filter: 'all', editId: null, busy: false };
  let toastTimer;
  function notify(message, error = false) {
    clearTimeout(toastTimer); $('toast').textContent = message; $('toast').classList.toggle('error', error); $('toast').hidden = false;
    toastTimer = setTimeout(() => { $('toast').hidden = true; }, error ? 8000 : 4000);
  }
  function render() {
    if (!state.data) return;
    const data = state.data, month = state.selectedMonth, stats = tracker.summary(data, month);
    const current = storage.currentMonth(), previous = storage.previousMonth(current);
    const options = data.months.slice().sort().reverse().map(key => {
      const option = document.createElement('option'); option.value = key;
      option.textContent = `${tracker.monthLabel(key)}${key === current ? ' · Current month' : key === previous ? ' · Previous month' : ''}`;
      return option;
    });
    $('active-month').replaceChildren(...options); $('active-month').value = month;
    $('month-context').textContent = `Viewing ${tracker.monthLabel(month)}. Sales and remaining-family calls apply to this month only.`;
    $('total-cards').textContent = stats.total;
    $('distributed-cards').textContent = stats.completed;
    $('total-grain').textContent = tracker.kg(stats.wheat + stats.rice);
    $('grain-detail').textContent = `Wheat ${tracker.kg(stats.wheat)} · Rice ${tracker.kg(stats.rice)} kg`;
    $('pending-cards').textContent = stats.pending;
    $('distributed-detail').textContent = `${stats.completed} ${stats.completed === 1 ? 'family' : 'families'} served`;
    const progress = stats.total ? Math.round(stats.completed / stats.total * 100) : 0;
    $('progress-label').textContent = `${progress}%`; $('distribution-progress').value = progress;
    const matches = tracker.search(data.beneficiaries, $('sale-search').value).filter(p => state.filter === 'all' || stats.served.has(p.id) === (state.filter === 'distributed'));
    $('result-count').textContent = `${matches.length} of ${stats.total} families · ${tracker.monthLabel(month)}`;
    tracker.renderList($('sale-list'), matches, data, 'sale', month);
    tracker.renderList($('manage-list'), tracker.search(data.beneficiaries, $('manage-search').value), data, 'manage', month);
    $('manage-count').textContent = `${stats.total} cards`;
  }
  function accept(data) {
    state.data = data;
    if (!data.months.includes(state.selectedMonth)) state.selectedMonth = data.months.includes(storage.currentMonth()) ? storage.currentMonth() : data.activeMonth;
    $('storage-error').hidden = true; render();
  }
  function run(operation, message) {
    try { accept(operation()); if (message) notify(message); return true; }
    catch (error) { notify(error.message, true); return false; }
  }
  function switchTab(name) {
    for (const tab of document.querySelectorAll('[data-tab]')) {
      const selected = tab.dataset.tab === name;
      tab.setAttribute('aria-selected', String(selected)); tab.tabIndex = selected ? 0 : -1;
      $(tab.getAttribute('aria-controls')).hidden = !selected;
    }
  }
  function resetForm() { state.editId = null; $('beneficiary-form').reset(); $('form-title').textContent = 'Add a beneficiary'; $('save-beneficiary').textContent = 'Add beneficiary'; $('cancel-edit').hidden = true; }
  function confirmAction(title, message, label) {
    const dialog = $('confirm-dialog'); $('confirm-title').textContent = title; $('confirm-message').textContent = message; $('confirm-action').textContent = label;
    return new Promise(resolve => { dialog.returnValue = 'cancel'; dialog.addEventListener('close', () => resolve(dialog.returnValue === 'confirm'), { once: true }); dialog.showModal(); });
  }
  async function handleRecord(event) {
    const button = event.target.closest('button[data-action]');
    if (!button || state.busy || !state.data) return;
    const person = state.data.beneficiaries.find(p => p.id === button.dataset.id); if (!person) return;
    const action = button.dataset.action;
    if (action === 'edit') {
      state.editId = person.id;
      for (const key of ['rcNumber', 'headName', 'phone', 'members', 'wheat', 'rice']) $('beneficiary-form').elements.namedItem(key).value = person[key];
      $('form-title').textContent = 'Edit beneficiary'; $('save-beneficiary').textContent = 'Save changes'; $('cancel-edit').hidden = false;
      switchTab('beneficiaries'); $('beneficiary-form').elements.namedItem('rcNumber').focus(); return;
    }
    state.busy = true;
    try {
      const month = state.selectedMonth;
      if (action === 'sale' && await confirmAction('Record distribution?', `${person.headName} · RC ${person.rcNumber}. Confirm that ${tracker.kg(person.wheat)} kg wheat and ${tracker.kg(person.rice)} kg rice have been issued for ${tracker.monthLabel(month)}.`, 'Record sale')) run(() => storage.recordSale(person.id, month), `Sale recorded for ${tracker.monthLabel(month)}. Family marked distributed.`);
      if (action === 'delete' && await confirmAction('Delete beneficiary?', `Remove ${person.headName} (RC ${person.rcNumber}) from the register? Recorded sales will remain in history. This cannot be undone without a backup.`, 'Delete beneficiary')) {
        if (run(() => storage.deleteBeneficiary(person.id), 'Beneficiary deleted.') && state.editId === person.id) resetForm();
      }
    } catch (error) { notify(error.message, true); } finally { state.busy = false; }
  }
  document.querySelectorAll('[data-tab]').forEach(tab => {
    tab.addEventListener('click', () => switchTab(tab.dataset.tab));
    tab.addEventListener('keydown', event => {
      if (['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) {
        event.preventDefault(); const name = event.key === 'Home' ? 'distribution' : event.key === 'End' ? 'beneficiaries' : tab.dataset.tab === 'distribution' ? 'beneficiaries' : 'distribution'; switchTab(name); $(`tab-${name}`).focus();
      }
    });
  });
  document.querySelectorAll('[data-filter]').forEach(button => button.addEventListener('click', () => {
    state.filter = button.dataset.filter;
    document.querySelectorAll('[data-filter]').forEach(item => { item.classList.toggle('active', item === button); item.setAttribute('aria-pressed', String(item === button)); }); render();
  }));
  $('active-month').addEventListener('change', event => {
    if (state.busy || !state.data) { render(); return; }
    if (state.data.months.includes(event.target.value)) { state.selectedMonth = event.target.value; render(); }
  });
  for (const id of ['sale-search', 'manage-search']) $(id).addEventListener('input', render);
  $('sale-list').addEventListener('click', handleRecord); $('manage-list').addEventListener('click', handleRecord);
  $('cancel-edit').addEventListener('click', resetForm);
  $('beneficiary-form').addEventListener('submit', event => {
    event.preventDefault(); if (state.busy) return;
    const values = Object.fromEntries(new FormData(event.currentTarget));
    if (run(() => storage.saveBeneficiary(values, state.editId), state.editId ? 'Beneficiary updated. Previous sales are unchanged.' : 'Beneficiary added.')) resetForm();
  });
  $('export-backup').addEventListener('click', () => {
    try {
      const data = storage.read();
      const blob = new Blob([JSON.stringify({ ...data, exportedAt: new Date().toISOString() }, null, 2)], { type: 'application/json' });
      const url = URL.createObjectURL(blob), anchor = document.createElement('a');
      anchor.href = url; anchor.download = `local-pds-backup-${data.activeMonth}-${Date.now()}.json`; document.body.append(anchor); anchor.click(); anchor.remove(); setTimeout(() => URL.revokeObjectURL(url), 60000);
      notify('Backup download requested. Check your downloads.');
    } catch (error) { notify(error.message, true); }
  });
  $('import-backup').addEventListener('click', () => { if (!state.busy) $('backup-file').click(); });
  $('backup-file').addEventListener('change', async event => {
    const file = event.target.files[0]; if (!file || state.busy) return;
    state.busy = true;
    try {
      if (file.size > 20 * 1024 * 1024) throw new Error('Backup is too large. Choose a JSON file smaller than 20 MB.');
      let parsed; try { parsed = JSON.parse(await file.text()); } catch (_) { throw new Error('The selected file is not valid JSON.'); }
      const data = storage.validate(parsed);
      if (await confirmAction('Replace local records?', `Restore ${data.beneficiaries.length} beneficiaries and ${data.sales.length} sales across ${data.months.length} months? This replaces all current records. Export your current backup first if you need to keep it.`, 'Restore backup')) { if (run(() => storage.restore(data), 'Backup restored.')) resetForm(); }
    } catch (error) { notify(error.message, true); } finally { event.target.value = ''; state.busy = false; }
  });
  $('reset-month').addEventListener('click', async () => {
    if (state.busy || !state.data) return;
    const previous = state.data.activeMonth, next = tracker.nextMonth(previous); state.busy = true;
    try {
      if (await confirmAction('Start a new month?', `Add ${tracker.monthLabel(next)}, after the latest registered month (${tracker.monthLabel(previous)})? All ${state.data.beneficiaries.length} families will start pending for the new month. Existing months and sales remain available in the selector.`, 'Start new month')) {
        if (run(() => storage.startMonth(next, previous), `${tracker.monthLabel(next)} added. Previous months are preserved.`)) { state.selectedMonth = next; render(); }
      }
    } catch (error) { notify(error.message, true); } finally { state.busy = false; }
  });
  window.addEventListener('storage', event => {
    if (event.key === storage.key || event.key === null) {
      try { accept(storage.read()); } catch (error) { $('storage-error').textContent = error.message; $('storage-error').hidden = false; state.data = null; }
    }
  });
  try { accept(storage.initialize()); }
  catch (error) { $('storage-error').textContent = error.message; $('storage-error').hidden = false; }
  if ('serviceWorker' in navigator && ['https:', 'http:'].includes(location.protocol)) {
    navigator.serviceWorker.register('./sw.js').catch(() => {
      notify('Offline page caching is unavailable. Keep this page open when working offline.', true);
    });
  }
})();
