# Local PDS Ration Management Tracker

A mobile-first, local-only hybrid app foundation. Open `index.html` in a modern browser or bundle `index.html`, `css/`, and `js/` as native WebView assets. No build step, account, API, or backend is required.

## Files

- `index.html`: accessible layout and optional asynchronous Tailwind CDN script.
- `css/style.css`: complete offline styles, responsive layouts and 48px minimum controls.
- `js/storage.js`: validated LocalStorage persistence, beneficiary CRUD, sale snapshots and backup restore.
- `js/tracker.js`: search, monthly calculations and safe record rendering.
- `js/app.js`: navigation, forms, confirmations, state and backup controls.
- `tests/storage.test.cjs`: dependency-free storage and tracking checks. Run `node --test tests/storage.test.cjs`.

## Usage

1. Add a beneficiary with a unique RC number, contact details, family size and monthly quotas.
2. Choose a **Distribution month** at the top. Current and previous calendar months are available, along with all retained months. Search the distribution register, select **Sale**, and confirm the actual grain handover for the selected month. Each family can receive one full-quota distribution per month. To distribute two months together, record one sale in each month's register.
3. Use **Remaining / Call Remainder** to find families pending for the selected month and **Call** to open the device dialer. Dashboard totals, issued quantities, progress, and record statuses all follow the selection.
4. Export JSON regularly. **Restore backup** validates a backup and asks before replacing the device's data.
5. **Start New Month** adds the month after the latest registered month, selects it, and initializes its families as remaining. Earlier months, including months with no sales, remain selectable. On app initialization, the current and previous calendar months are also added if missing; no history is cleared.

The version 2 document contains a `months` register, a month-keyed sale ledger, and each beneficiary's `statusByMonth` matrix, for example `status_2026_09: "DISTRIBUTED"` and `status_2026_08: "REMAINING"`. The ledger is authoritative and the matrix is rebuilt on each commit to prevent disagreement. `activeMonth` stores the latest registered month; the UI maintains its selected month independently. Existing version 1 local data and backups migrate automatically using their recorded sale months. No distribution is inferred for months without a sale. All currently registered beneficiaries appear in each month; historical enrollment is not tracked.

Editing quotas does not modify recorded sales. Deleting a beneficiary retains historical sales, so issued grain remains included in monthly totals; family counts reflect currently registered cards. Re-adding a deleted card creates a new beneficiary, so avoid deleting and re-adding cards to correct details—use Edit.

## Offline and native packaging

All essential styling, scripts, storage and calculations work without a network connection when the files are on the device. The requested Tailwind CDN is optional; no Tailwind utilities are required by the interface. It can be removed for a native build that must make zero network requests.

Enable JavaScript and DOM storage in the native WebView and keep a stable application origin so the same LocalStorage is used between launches. Native wrappers must handle `tel:` links and Blob download/file-picker support for export and restore. Test these integrations on the actual target devices before shipping. This project supplies the web application, not a compiled Android/iOS package.

The hosted HTTPS version registers `sw.js` to cache the app shell after the first successful online visit. It then supports offline page reloads; requests never upload beneficiary records. Bundled local assets do not require a service worker. Use one active editing instance per device; LocalStorage is not a multi-user transactional database.

## GitHub deployment

The `Deploy PDS web app` GitHub Actions workflow validates and publishes only `index.html`, `sw.js`, `css/`, and `js/` to GitHub Pages when these files change on `main`. Flutter source is included in the repository but is not part of the public website artifact. Generated APKs, tokens, local data and personal backups are excluded.

Localhost and GitHub Pages have separate browser storage. Export your localhost backup and restore it on the hosted app to move existing records. Keep a private copy of the backup. The public code repository must not be used for confidential `data.json`; the Flutter sync engine requires a private repository before uploading personal data.

Records are stored under `local-pds-tracker.v1` in LocalStorage. They are not encrypted or synchronized. Browser/app data removal and uninstall can erase them. Keep private JSON backups outside the app. Corrupt saved data is not silently overwritten; restore a valid backup to recover.
