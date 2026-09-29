# Lion Manager Native App

Flutter/Dart source for the native Lion Manager app. Windows and Android are the current release targets; the app runs as a native Flutter window or Android APK, not in a browser or WebView.

See [使用说明.md](使用说明.md) for install, data migration, member-card, daily-training, and attachment instructions. The repository root [README.md](../README.md) contains the project overview and build commands.

The app uses local, ordinary SQLite. The populated seed database is intentionally not included in the application assets; first launch creates an empty database from `assets/schema.sql`.