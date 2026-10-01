# TVET MARA Staff App

A Flutter staff-management application with Supabase authentication and data storage.

## Features

- Role-based staff and administrator dashboards.
- Attendance punch-in/out with geofence checks and attendance history.
- Attendance reports and PDF generation.
- Staff directory, departments, geofence zones and approval management.
- Redesigned four-tab staff interface and in-shell admin workspace.
- Personal tasks stored on the staff member's Supabase Auth account.

Leave and lateness forms save to the existing `leaves` and `attendance`
tables. Medical requests can include an HTTPS supporting-document link;
direct file uploads require a configured Supabase Storage bucket.

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

## Deploy to Netlify from GitHub

The repository includes `netlify.toml` and `scripts/build_netlify.sh`.
Netlify installs Flutter **3.44.8**, builds the website, and publishes
**`build/web`**. The repository's `web/` folder contains source templates;
it is not the deployable website.

1. Commit and push the deployment files to your connected GitHub branch.
2. In Netlify's build settings, use:

   | Setting | Value |
   | --- | --- |
   | Base directory | `.` (repository root) |
   | Package directory | Leave empty |
   | Build command | `bash scripts/build_netlify.sh` |
   | Publish directory | `build/web` |

3. Trigger a new deploy. These settings are also declared in `netlify.toml`.
4. Check the deploy log ends with `Netlify website is ready in build/web.`
   The published files must include `index.html`, `flutter_bootstrap.js`,
   `main.dart.js`, `assets/`, and `_redirects`.

`web/_redirects` supplies Netlify's single-page-app fallback, so refreshing
an app URL serves `index.html` instead of the Netlify 404 page. Existing
JavaScript, images, and other files are served normally.

The working Supabase defaults remain in `lib/config/app_config.dart`.
Optional Netlify **build** environment variables `SUPABASE_URL` and
`SUPABASE_ANON_KEY` override them. Use a public client key; server-only
service-role keys belong in Supabase Edge Functions. Firebase's existing
`FIREBASE_*` configuration variables are also supported if needed.

To verify the deployment build locally in Git Bash:

```sh
FLUTTER_BIN=flutter bash scripts/build_netlify.sh
```

## Project structure

| Directory | Purpose |
| --- | --- |
| `lib/screens/auth/` | Sign-in interface |
| `lib/screens/staff/` | Staff dashboard, tasks, profile and attendance |
| `lib/screens/admin/` | Administration screens |
| `lib/screens/reports/` | Attendance report screen shared by both roles |
| `lib/services/` | Authentication, database, location, presence and tasks |
| `lib/services/reports/` | PDF and CSV report export services |
| `lib/models/`, `lib/utils/` | Attendance models and Malaysia-time helpers |
| `lib/widgets/admin/`, `lib/widgets/staff/` | Role-specific UI components |
| `lib/widgets/shared/`, `lib/theme/`, `lib/navigation/` | Shared UI, styling and page transitions |
| `test/models/`, `test/services/` | Calculation and geofence tests |
| `test/screens/`, `test/widgets/` | Login and layout tests |
| `test/integration/` | Mock-backend workflow tests |
| `supabase/` | Database setup, repair SQL and account Edge Functions |
| `scripts/`, `netlify.toml` | GitHub-connected Netlify build configuration |
| `tvet_app_redisegine11/` | Git-ignored teammate UI reference |

## Verify changes

```sh
flutter analyze lib test
flutter test
flutter build windows
flutter build web
```

Integration tests use a mock backend to check role routing, the redesigned
mobile/desktop screens and database request fields. They do not access live
staff accounts or prove deployed RLS/Edge Function behaviour.

The geofence map uses `flutter_map`. Its platform dependencies are pinned in
`pubspec.yaml` to avoid a native build-hook path issue on Flutter 3.44.8 on
Windows. The local `tvet_app_redisegine11/` reference remains Git-ignored.

## Generated files

`build/`, `.dart_tool/`, `.flutter-plugins-dependencies` and platform
`ephemeral/` directories are generated by Flutter and ignored by Git.
Clean them from the project root with `flutter clean`. Flutter recreates
the required files when you run `flutter pub get` and build/run the app.
