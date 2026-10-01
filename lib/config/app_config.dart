import 'package:flutter/foundation.dart';

/// Centralized app configuration.
///
/// Supabase URL and anon key are baked in as defaults so the app runs
/// with a plain `flutter run -d windows` — no flags required.
/// They can still be overridden via `--dart-define` (e.g. to switch
/// between dev/prod Supabase projects) without editing this file.
///
/// The anon key is PUBLIC by design — it's protected by Row Level Security
/// in the database. Never put the `service_role` key here.
class AppConfig {
  AppConfig._();

  static const String supabaseUrl = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://qsvtnwvmkqionwhssdcd.supabase.co',
  );
  static const String supabaseAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFzdnRud3Zta3Fpb253aHNzZGNkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODQ4ODc1NjgsImV4cCI6MjEwMDQ2MzU2OH0.INPa06QwJ8ZRXAOxTpam8BflLNDrpzdjsl7uFihRmPI',
  );

  // Firebase Web config (used by firebase_core on all platforms)
  static const String firebaseApiKey = String.fromEnvironment(
    'FIREBASE_API_KEY',
    defaultValue: '',
  );
  static const String firebaseProjectId = String.fromEnvironment(
    'FIREBASE_PROJECT_ID',
    defaultValue: '',
  );
  static const String firebaseMessagingSenderId = String.fromEnvironment(
    'FIREBASE_MESSAGING_SENDER_ID',
    defaultValue: '',
  );
  static const String firebaseAppId = String.fromEnvironment(
    'FIREBASE_APP_ID',
    defaultValue: '',
  );

  static bool get isSupabaseConfigured =>
      supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  static bool get isFirebaseConfigured =>
      firebaseApiKey.isNotEmpty &&
      firebaseProjectId.isNotEmpty &&
      firebaseAppId.isNotEmpty;

  static void validate() {
    if (!isSupabaseConfigured) {
      debugPrint(
        '⚠️ Supabase not configured. Run with '
        '--dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...',
      );
    }
    if (!isFirebaseConfigured) {
      debugPrint(
        '⚠️ Firebase not configured. Run with '
        '--dart-define=FIREBASE_API_KEY=... --dart-define=FIREBASE_PROJECT_ID=... '
        '--dart-define=FIREBASE_MESSAGING_SENDER_ID=... '
        '--dart-define=FIREBASE_APP_ID=...',
      );
    }
  }
}
