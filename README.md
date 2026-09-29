# Lion Manager

Lion Manager is a native Flutter/Dart app for managing a lion-dance team. The Windows build opens in its own native app window, and the Android build installs as an APK; neither opens the interface in a browser or WebView.

The app keeps its database and media on the device. It uses ordinary SQLite without database encryption or automatic cloud sync.

## Install

### Windows

Download and extract the Windows ZIP from [GitHub Releases](https://github.com/Hanqwn/TJlion/releases), keeping the full directory structure. Start `lion_team_manager.exe` from the extracted `dist/native/windows/` folder; the EXE depends on the adjacent Flutter runtime, DLLs, and `data/` assets.

### Android

Download the APK from [GitHub Releases](https://github.com/Hanqwn/TJlion/releases) and install it on a compatible Android device. This APK is signed with the project debug key for sideloading; a separate signing key and configuration are needed for Play Store distribution.

## First launch and existing data

The installer does not contain the populated seed database. First launch creates an empty local SQLite database from `native_app/assets/schema.sql`. To continue with existing team records, use **Settings → Import database** and choose the database file you want to use. The original `data/seed.sqlite3` stays in the local project and is not bundled in releases.

Before importing, migrating, reinstalling, or moving to another device, export a database backup from Settings. Photos, videos, audio, and documents are stored as managed media files separately from SQLite, so export the media package separately when you need those attachments. Import both the database and media package on the destination device, then check the attachment list.

Existing local databases are migrated to schema v4 when opened. The migration adds training-session media links and per-semester member positions while retaining existing records and media paths. Keep a backup before the first launch of a new app version.

Device-to-device wireless transfer is not implemented yet. Move data manually using the database and media-package import/export actions in Settings.

## Pages

- **Overview** summarizes the current team records.
- **Members** manages each semester roster. Use **New semester** to create an empty roster. Member positions are stored per semester. Select a member row to open the member card and review that person's semester history and positions.
- **Attendance** records and confirms attendance for training sessions.
- **Daily** records a training date, roster attendance, notes, photos, videos, audio, and document attachments.
- **Events** and **Routines** store event and performance materials. Routines support in-app PDF and DOCX attachments.
- **Training plans**, **Reports**, and **Finance** manage plans, written records, and the local ledger.
- **Library** browses managed attachments and indexed legacy-material records.
- **Settings** imports and exports the database and media packages and compares attachment manifests.

PDF attachments open in the app. DOCX preview extracts plain text and does not preserve full formatting, images, or page layout. Legacy `.doc` files are not accepted by the document importer.

## Build from source

Use Flutter stable 3.47.5 or compatible. Windows builds require Visual Studio's Desktop development with C++ workload. Android builds require JDK 17 and the Android SDK. From `native_app/`, fetch dependencies and build the requested platform:

```powershell
flutter pub get
flutter build windows --release
flutter build apk --release
```

Windows release files are written to `native_app/build/windows/x64/runner/Release/`; the APK is written to `native_app/build/app/outputs/flutter-apk/app-release.apk`. Linux, macOS, and iOS project folders are present, but this release provides packages only for Windows and Android.
