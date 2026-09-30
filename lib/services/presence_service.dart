import 'dart:async';

import 'package:flutter/foundation.dart';

import 'database_service.dart';

/// Tracks whether the signed-in staff member's app is running, so the Staff
/// Directory can show "Online now" / "Last online 2h ago".
///
/// How presence works
/// ------------------
/// There is no reliable "app closed" event — a force-quit, a power cut or a
/// dropped Wi-Fi connection all send nothing. So instead of trying to report
/// going offline, every running app reports that it is *still here*:
///
///   * [start] stamps `staff.last_seen` immediately, then again every
///     [heartbeatInterval] (60s) for as long as the app is running.
///   * Anyone reading the directory treats a staff member as online when
///     `last_seen` is newer than [onlineThreshold] (2 minutes).
///   * When the app dies the heartbeat simply stops, so the row goes stale
///     and the staff member turns offline on its own — and `last_seen` is
///     exactly the "last online" time to display.
///
/// The threshold is deliberately larger than the interval so one missed
/// heartbeat (a brief network blip) doesn't flicker somebody offline.
class PresenceService {
  PresenceService._();

  /// How often a running app reports that it is still alive.
  static const Duration heartbeatInterval = Duration(seconds: 60);

  /// How fresh `last_seen` must be for a staff member to count as online.
  /// Must stay comfortably larger than [heartbeatInterval].
  static const Duration onlineThreshold = Duration(minutes: 2);

  static Timer? _timer;

  /// Whether the heartbeat is currently running.
  static bool get isRunning => _timer != null;

  /// Begins the heartbeat. Call once the user is signed in (dashboard
  /// `initState`). Safe to call again — it restarts rather than stacking
  /// timers.
  static void start() {
    stop();
    markNow();
    _timer = Timer.periodic(heartbeatInterval, (_) => markNow());
  }

  /// Stops the heartbeat. Call on sign-out and in `dispose`.
  ///
  /// This does *not* clear `last_seen`: the final heartbeat stays as the
  /// "last online" time, and the staleness threshold flips the staff member
  /// to offline within [onlineThreshold].
  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// One-off heartbeat. Used on app resume so someone coming back from a
  /// slept laptop shows online right away instead of waiting up to a minute.
  ///
  /// Failures are intentionally swallowed: if the write fails the user
  /// genuinely has no connection, and appearing offline is the correct
  /// outcome.
  static Future<void> markNow() async {
    try {
      await DatabaseService.updateMyLastSeen();
    } catch (e) {
      debugPrint('[Presence] heartbeat skipped: $e');
    }
  }

  /// Whether [lastSeen] is recent enough to count as online.
  ///
  /// `last_seen` is stamped from the database clock while the comparison runs
  /// on the device clock, so a timestamp can land slightly in the future when
  /// the two disagree. That still means "seen a moment ago", so a negative
  /// difference counts as online.
  static bool isOnline(DateTime? lastSeen) {
    if (lastSeen == null) return false;
    final diff = DateTime.now().toUtc().difference(lastSeen.toUtc());
    return diff <= onlineThreshold;
  }

  /// Parses the `last_seen` value coming back from Supabase, which arrives as
  /// an ISO-8601 string (or null for a staff member who has never signed in).
  static DateTime? parseLastSeen(dynamic value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    return DateTime.tryParse(value.toString());
  }
}
