# Arajpur East PACS PDS — Flutter Android app

Native Flutter implementation alongside the original web app. Main entry: `lib/main.dart`. Android package: `in.arajpureastpacs.pds_ration_tracker`. The repository is fixed to `sunny797075-maker/Arajpur-East-PACS-PDS`; `https://github.com` alone is not a repository address.

## Run and build

Use Flutter 3.29.3 / Dart 3.7.2 or compatible newer stable Flutter. Resolved dependencies are pinned in `pubspec.lock`.

```powershell
cd flutter_app
flutter pub get
flutter analyze
flutter test
flutter run
flutter build apk --debug
```

Review APK output: `build/app/outputs/flutter-apk/app-debug.apk`. Android SDK 35, NDK 27.0.12077973, Java 17 or newer, and Android minimum API 23 are configured. Accept any required Android SDK licenses through `flutter doctor --android-licenses` on the build machine.

Release builds deliberately require the owner's signing key; they never silently use a debug signature. Create `android/key.properties` with four actual values: `storeFile` (keystore path, relative to android or absolute), `storePassword`, `keyAlias`, and `keyPassword`. Keep that file and the keystore private. Then run `flutter build apk --release` or `flutter build appbundle --release`. No signing password is embedded in source.

## GitHub setup

1. Use the existing repository `sunny797075-maker/Arajpur-East-PACS-PDS`. Make it private: `data.json` contains personal ration-card and telephone information. The sync engine refuses public repositories.
2. Create a fine-grained GitHub Personal Access Token, limited to this repository, with **Contents: Read and write**. The token also needs normal repository metadata access. Direct commits must be permitted by the default branch's rules.
3. Open the app's Settings gear, paste the token, and tap **Save token & sync**. Tokens are encrypted using Android secure storage, obscured in the input, and excluded from backups and commits. The app never logs request headers or tokens.
4. The engine discovers the default branch and reads/creates `data.json`. It accepts the web app's version 1 or 2 JSON register, migrates version 1, and writes version 2. If you want to migrate existing web records, export them from the browser and place that export as `data.json` in the private repository before your first Flutter sync. The two apps do not share device storage automatically.

No real GitHub commit is required to build or test. Automated network tests use a mock HTTP client. A real token is required to verify live repository access; do not paste it into chat or source files.

## Local persistence and sync behavior

- Adding a card or recording a sale first commits the register **and persistent outbox** together in a SQLite transaction. A shared_preferences cache is updated immediately after that commit. Network I/O is separate and never awaited by the sale/form UI.
- SQLite is intentionally included because shared_preferences is an unencrypted preferences cache and its documentation does not guarantee durability for critical writes. It is not appropriate as the sole copy of an unsynchronized ration sale. The token uses flutter_secure_storage instead of either data store.
- Each operation has a unique ID. Sync fetches the latest remote document and SHA, replays the captured operations, and PUTs Base64 JSON through GitHub's Contents API. SHA conflicts trigger a fresh fetch and merge, with bounded retries. Operations added during upload remain queued. A lost PUT response is safe to replay without duplicating a sale.
- Missing internet/timeouts and retryable server errors retain the queue. Connectivity events, a 30-second scheduler with backoff, app resume, and **Sync now** trigger retries. Android can suspend or kill the app: there is no guarantee of upload while it is closed. The durable queue resumes on next launch. This implementation does not claim to run a permanent background service.
- Authentication/permission errors, corrupt remote JSON, and ambiguous duplicate RC/sale conflicts pause automatic retries and show an actionable status. They do not overwrite the remote document or discard local operations. Copy a local backup and reconcile the conflicting record in the repository, then use **Sync now**. The app does not silently combine two independent physical distributions of the same family/month.
- GitHub stores a whole-file document, not a transactional multi-user database. This implementation limits the file to 900 KB to stay inside the Contents API's inline Base64 behavior. Its intended use is a small local register with occasional sync, not many dealers concurrently editing a large database. A larger deployment needs a purpose-built backend.

## Monthly UI

Select any available distribution month. Current and previous calendar months are created on startup; **Start New Month** adds the month after the latest one without clearing history. Dashboard, search results, status, and call remainder lists follow the selected month. Each household's exported `statusByMonth` includes keys such as `status_2026_09`. Immutable sale snapshots preserve the quota and date recorded for that month's distribution.

To distribute two months together, record one sale in each month's view. The confirmation explicitly names the month. Each family can have only one sale per month. All registered cards appear in each available month; historical enrollment is not tracked.

**Copy backup JSON** copies a recovery envelope with `data`, `pending`, and selected month to the clipboard. Paste it into a private file; it contains personal data but no token. For repository recovery, use its `data` object as the contents of `data.json`. Never delete local app data before recovering its pending transactions.

## Code map

- `lib/main.dart`: startup, lifecycle/connectivity hooks, responsive dashboard, filters, lazy family list, form, call handling and secure settings.
- `lib/models.dart`: validated schema, month helpers, status matrix, indexed sale lookup and idempotent operation application.
- `lib/local_store.dart`: durable SQLite envelope plus shared_preferences mirror.
- `lib/tracker_controller.dart`: serial local mutations, state notifications, persistent queue and retry scheduling.
- `lib/github_sync.dart`: authenticated GitHub GET/PUT, SHA conflict handling and remote validation.
- `test/widget_test.dart`: local transaction, restart, offline retry, concurrent changes, SHA conflict, lost-response and narrow-screen UI tests.

Calling opens the native dialer using `tel:` and does not require direct-call permission. The app uses SafeArea and wrapping layouts; the existing web app's narrow header has also been fixed in `../css/style.css`.

## References

- https://docs.github.com/en/rest/repos/contents#create-or-update-file-contents
- https://pub.dev/packages/shared_preferences
- https://pub.dev/packages/flutter_secure_storage
- https://pub.dev/packages/connectivity_plus
- https://pub.dev/packages/url_launcher
