# Lion Manager

Lion Manager is a native Flutter/Dart app for managing a lion-dance team. The Windows build opens in its own app window and the Android build installs as an APK; neither uses a browser or WebView.

## Downloads

Get the Windows ZIP and Android APK from [GitHub Releases](https://github.com/Hanqwn/TJlion/releases). Extract the complete Windows bundle and run `lion_team_manager.exe` alongside its DLLs and `data/` assets. The APK is debug-signed for sideloading; Play Store distribution requires a separate release signing key.

## Data and migration

The app stores data locally in ordinary, unencrypted SQLite and does not sync automatically. First launch creates an empty database from `native_app/assets/schema.sql`; the populated seed database is not included. To continue with existing records, import a database in **Settings**. Export a backup before upgrading or moving devices.

Existing databases migrate to schema v5 on open. The migration adds long-term member profiles, recurring-activity classifications and semester links, and inventory tables while retaining existing records and media references. Photos, videos, audio, and documents are separate managed media files, so migrate the database and media package separately. Device-to-device wireless transfer is not implemented yet.

## Features

- **Members:** create semesters, set the current semester, manage semester-specific positions, open a member card with cross-semester history, and import an XLSX roster. Download the roster template from the Members page; imports show a preview before changes are applied.
- **Attendance and Daily:** record attendance and training sessions, notes, photos, videos, audio, and PDF/DOCX attachments.
- **Events:** assign events to a semester and recurring-activity category; filter current, past, all, or unspecified semesters.
- **Archives:** maintain long-term member records and browse activity history by semester and recurring category.
- **Inventory:** manage props and stock-movement history; import XLSX inventory sheets and download the matching template.
- **Routines, Plans, Reports, Finance, and Library:** manage performance references, training plans, written records, the local ledger, and saved attachments.
- **Settings:** import/export the SQLite database and media packages and compare attachment manifests.

The XLSX templates are bundled with the app and can be saved from the Members and Inventory pages. PDF files open in the app. DOCX preview extracts plain text and does not preserve full formatting, images, or page layout; legacy `.doc` files are not supported for body preview.

## Build from source

Use Flutter stable 3.47.5 or compatible. Windows builds require Visual Studio's Desktop development with C++ workload. Android builds require JDK 17 and the Android SDK. From `native_app/`:

```powershell
flutter pub get
flutter build windows --release
flutter build apk --release
```

Windows output is in `build/windows/x64/runner/Release/`; the APK is in `build/app/outputs/flutter-apk/app-release.apk`. Linux, macOS, and iOS project folders exist, but this release targets Windows and Android.