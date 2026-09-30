import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'database_service.dart';

/// Result of a geofence check.
class GeofenceResult {
  final bool isInside;

  /// Distance in meters from the device to the center of the nearest zone
  /// ([nearestZone]). [double.infinity] when no zone could be evaluated.
  final double distanceMeters;

  /// The zone that actually contains the current position (if any).
  /// May differ from [nearestZone] when a farther zone has a larger radius.
  final Map<String, dynamic>? matchedZone;

  /// The zone whose center is closest to the current position, regardless
  /// of whether the position is inside it. Used by the UI for the distance
  /// meter when the user is outside all zones.
  final Map<String, dynamic>? nearestZone;

  /// The GPS position this result was computed from (null on permission /
  /// fetch errors). Captured so callers can reuse it instead of issuing a
  /// redundant [Geolocator.getCurrentPosition] call.
  final Position? position;

  final String? error;

  const GeofenceResult({
    required this.isInside,
    required this.distanceMeters,
    this.matchedZone,
    this.nearestZone,
    this.position,
    this.error,
  });

  /// GPS accuracy of [position] in meters, or null when unavailable.
  double? get accuracyMeters => position?.accuracy;

  String get zoneName =>
      (matchedZone?['name'] as String?) ??
      (nearestZone?['name'] as String?) ??
      'TVET MARA zone';
}

/// GeofenceService
///
/// Handles device GPS location + geofence zone matching.
/// No external API needed — uses the device's built-in GPS via
/// [geolocator] and compares against zones stored in Supabase.
///
/// Flow:
///   1. Request location permission (if not already granted)
///   2. Get current GPS position (lat, lng, accuracy)
///   3. Fetch geofence zones from Supabase (DatabaseService)
///   4. For each zone, compute distance from current position to zone center
///   5. If distance ≤ zone radius → inside that zone
///   6. Return the matched zone (or null if outside all zones)
class GeofenceService {
  GeofenceService._();

  /// Ensure the user has granted location permission.
  /// Returns true if permission is granted, false otherwise.
  static Future<bool> ensurePermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      // Try to prompt the user to enable location services
      serviceEnabled = await Geolocator.openLocationSettings();
      if (!serviceEnabled) return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.deniedForever ||
        permission == LocationPermission.denied) {
      return false;
    }
    return true;
  }

  /// Get the current GPS position.
  /// Throws if permission is not granted or location is unavailable.
  static Future<Position> getCurrentPosition() async {
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        timeLimit: Duration(seconds: 10),
      ),
    );
  }

  /// Evaluate [position] against [zones].
  ///
  /// - [nearestZone]: the active zone with the smallest center distance.
  /// - [matchedZone]: the zone that CONTAINS the position. When multiple
  ///   zones contain the position, the one with the smallest center
  ///   distance wins. Importantly, a containing zone is never skipped just
  ///   because a *closer* zone exists — that was the old bug, where a
  ///   small nearby zone shadowed a larger distant zone the user was
  ///   actually inside.
  /// - When there are no active zones, the result is "unrestricted"
  ///   (isInside: true) so users can still punch in.
  static GeofenceResult _evaluate(
    Position position,
    List<Map<String, dynamic>> zones,
  ) {
    double nearestDistance = double.infinity;
    Map<String, dynamic>? nearestZone;

    double matchedDistance = double.infinity;
    Map<String, dynamic>? matchedZone;

    int activeZones = 0;

    for (final zone in zones) {
      final zoneLat = (zone['center_lat'] as num?)?.toDouble();
      final zoneLng = (zone['center_lng'] as num?)?.toDouble();
      final radiusM = (zone['radius_m'] as num?)?.toInt() ?? 200;
      final isActive = zone['is_active'] as bool? ?? true;

      if (zoneLat == null || zoneLng == null || !isActive) continue;
      activeZones++;

      final distance = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        zoneLat,
        zoneLng,
      );

      if (distance < nearestDistance) {
        nearestDistance = distance;
        nearestZone = zone;
      }

      if (distance <= radiusM && distance < matchedDistance) {
        matchedDistance = distance;
        matchedZone = zone;
      }
    }

    // No active zones configured — allow punch-in from anywhere.
    if (activeZones == 0) {
      return GeofenceResult(
        isInside: true,
        distanceMeters: 0,
        matchedZone: null,
        nearestZone: null,
        position: position,
      );
    }

    return GeofenceResult(
      isInside: matchedZone != null,
      distanceMeters: nearestDistance,
      matchedZone: matchedZone,
      nearestZone: nearestZone,
      position: position,
    );
  }

  /// Test-visible wrapper around the private zone evaluation logic.
  ///
  /// Production code always evaluates real GPS positions against real
  /// zones; tests use this to verify the matching rules (nearest zone
  /// tracking, containing-zone selection, unrestricted fallback) with
  /// synthetic positions and zone data.
  @visibleForTesting
  static GeofenceResult evaluateForTest(
    Position position,
    List<Map<String, dynamic>> zones,
  ) => _evaluate(position, zones);

  /// Check whether the current GPS position is inside any geofence zone.
  ///
  /// Returns a [GeofenceResult] with:
  /// - isInside = true + matchedZone if inside a zone
  /// - isInside = false + distanceMeters (to nearest zone) if outside
  /// - error message if something went wrong (no permission, no GPS, etc.)
  static Future<GeofenceResult> checkGeofence() async {
    // 1. Permission
    final hasPermission = await ensurePermission();
    if (!hasPermission) {
      return const GeofenceResult(
        isInside: false,
        distanceMeters: double.infinity,
        error: 'Location permission denied. Enable it in Settings.',
      );
    }

    // 2. Get GPS position
    late final Position position;
    try {
      position = await getCurrentPosition();
    } on Exception catch (e) {
      return GeofenceResult(
        isInside: false,
        distanceMeters: double.infinity,
        error: 'Could not get GPS location: $e',
      );
    }

    // 3. Fetch geofence zones from Supabase
    final zones = await DatabaseService.getGeofenceZones();

    // 4. Evaluate against zones (no active zones → unrestricted)
    return _evaluate(position, zones);
  }

  /// Live geofence stream — emits a new [GeofenceResult] every time the
  /// device moves a meaningful distance (≥5m).
  ///
  /// Use this on the Punchcard screen so the distance indicator updates
  /// in real-time as the user walks toward / away from the zone.
  ///
  /// An immediate first result is emitted from [getCurrentPosition] so the
  /// UI shows a live status right away — [Geolocator.getPositionStream]
  /// with distanceFilter fires only on movement, so a stationary device
  /// (common on desktop Windows) would otherwise never receive an event.
  static Stream<GeofenceResult> geofenceStream() async* {
    final hasPermission = await ensurePermission();
    if (!hasPermission) {
      yield const GeofenceResult(
        isInside: false,
        distanceMeters: double.infinity,
        error: 'Location permission denied. Enable it in Settings.',
      );
      return;
    }

    // Fetch zones once (they rarely change mid-session)
    final zones = await DatabaseService.getGeofenceZones();

    // No zones configured at all — unrestricted, single result.
    if (zones.isEmpty) {
      yield const GeofenceResult(isInside: true, distanceMeters: 0);
      return;
    }

    // Emit an immediate result so the UI is never stuck waiting for the
    // movement-filtered stream to fire (stationary devices emit nothing).
    try {
      final initial = await getCurrentPosition();
      yield _evaluate(initial, zones);
    } on Exception catch (e) {
      yield GeofenceResult(
        isInside: false,
        distanceMeters: double.infinity,
        error: 'Could not get GPS location: $e',
      );
    }

    // Stream GPS updates — fires when device moves ≥5m
    final positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5, // meters
      ),
    );

    await for (final position in positionStream) {
      yield _evaluate(position, zones);
    }
  }
}
