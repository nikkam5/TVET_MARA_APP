# TVET MARA Staff App

A Flutter staff-management application with Supabase authentication and data storage.

## Features

- Role-based staff and administrator dashboards.
- Attendance punch-in/out with geofence checks and attendance history.
- Attendance reports and PDF generation.
- Staff directory, departments, geofence zones and approval management.

## Run locally

Requires Flutter with Dart **3.12.2 or newer**, plus the tooling for your target platform.
Run commands from this directory (the one containing `pubspec.yaml` and `lib/`).

```sh
flutter pub get
flutter run -d windows
```

The app includes a default Supabase project configuration in
`lib/config/app_config.dart`. To use your own project:

```sh
flutter run -d windows --dart-define=SUPABASE_URL=https://YOUR_PROJECT.supabase.co --dart-define=SUPABASE_ANON_KEY=YOUR_PUBLIC_KEY
```

Use a public anon/publishable key for the client. Database access is governed by
Supabase Row Level Security; service-role keys belong only on the server.
Backend resources live in `supabase/`.

Firebase initialization is optional. To enable it, supply `FIREBASE_API_KEY`,
`FIREBASE_PROJECT_ID`, `FIREBASE_MESSAGING_SENDER_ID` and `FIREBASE_APP_ID` using
`--dart-define` with the settings for your target platform.

Sign in using an existing staff account’s registered **email address and password**.
The staff profile role determines which dashboard opens. Users who cannot access
their account should contact their institution’s staff administrator.

## Project structure

| Directory | Purpose |
| --- | --- |
| `lib/screens/auth/` | Sign-in interface |
| `lib/screens/staff/` | Staff dashboard, profile, attendance and reports |
| `lib/screens/admin/` | Administration screens |
| `lib/services/` | Authentication, data, location and PDF services |
| `lib/theme/`, `lib/widgets/` | Shared visual styles and UI components |
| `test/` | Automated tests |

## Verify changes

```sh
flutter analyze lib test
flutter test
```
