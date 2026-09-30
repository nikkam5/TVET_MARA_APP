// Smoke tests for the app's pure geofence matching logic.
//
// The default Flutter counter template test was removed — it expected the
// old counter UI which no longer exists. These tests verify the zone
// matching logic that powers the punchcard's location meter, including the
// regression where a nearby small zone shadowed a larger distant zone that
// actually contained the user.

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tvet_staff_app/services/geofence_service.dart';

void main() {
  // Constructing a real Position requires platform metadata; build a
  // minimal one via the public constructor with sane defaults.
  Position makePosition(double lat, double lng) {
    final now = DateTime.now();
    return Position(
      latitude: lat,
      longitude: lng,
      timestamp: now,
      accuracy: 10,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
  }

  // GeofenceService._evaluate is private; exercise it indirectly through
  // the exposed result fields by replicating the same zone data the
  // dashboard would receive from Supabase.
  final smallNearbyZone = <String, dynamic>{
    'id': 'zone-a',
    'name': 'Small Test Zone',
    'center_lat': 3.1375, // ~56m north of the test position
    'center_lng': 101.6870,
    'radius_m': 30,
    'is_active': true,
  };
  final largeDistantZone = <String, dynamic>{
    'id': 'zone-b',
    'name': 'Campus Zone',
    'center_lat': 3.1350, // ~314m south-west of the test position
    'center_lng': 101.6850,
    'radius_m': 500,
    'is_active': true,
  };

  test('GeofenceResult exposes zone fallback name and accuracy', () {
    const result = GeofenceResult(isInside: false, distanceMeters: 123.4);
    expect(result.zoneName, 'TVET MARA zone');
    expect(result.accuracyMeters, isNull);
  });

  test('Small nearby zone does not shadow containing larger zone', () {
    // Position is ~56m from the small zone's center (outside its 30m
    // radius) and ~314m from the large zone's center (inside its 500m
    // radius) — so the small zone is NEARER but the large zone CONTAINS.
    final position = makePosition(3.1370, 101.6870);

    // The old buggy code gated the containment check behind
    // `distance < minDistance`: with the small zone first in the list, it
    // recorded minDistance = 56m, never set a matched zone (56 > 30), and
    // then SKIPPED the large zone entirely (314 > 56) — reporting
    // isInside = false despite the position being inside the large zone.
    final result = GeofenceService.evaluateForTest(position, [
      smallNearbyZone,
      largeDistantZone,
    ]);

    expect(result.isInside, isTrue);
    expect(result.matchedZone?['id'], 'zone-b');
    expect(result.nearestZone?['id'], 'zone-a');
    // distanceMeters = distance to NEAREST zone center (~56m).
    expect(result.distanceMeters, greaterThan(30));
    expect(result.distanceMeters, lessThan(100));
  });

  test('Outside all zones reports nearest zone and distance', () {
    final position = makePosition(3.1500, 101.7000);

    final result = GeofenceService.evaluateForTest(position, [
      smallNearbyZone,
      largeDistantZone,
    ]);

    expect(result.isInside, isFalse);
    expect(result.matchedZone, isNull);
    // Small zone center is ~2003m away, large ~2356m — small is nearest.
    expect(result.nearestZone?['id'], 'zone-a');
    expect(result.distanceMeters, greaterThan(500));
  });

  test('No active zones is unrestricted (inside)', () {
    final position = makePosition(3.1500, 101.7000);
    final inactiveZone = Map<String, dynamic>.from(smallNearbyZone)
      ..['is_active'] = false;

    final result = GeofenceService.evaluateForTest(position, [inactiveZone]);

    expect(result.isInside, isTrue);
    expect(result.matchedZone, isNull);
    expect(result.nearestZone, isNull);
    expect(result.distanceMeters, 0);
  });

  test('Two containing zones: closest center wins', () {
    // Position exactly at the small zone's center: ~0m from the small
    // zone (inside its 30m radius) and ~355m from the large zone's
    // center (inside its 500m radius). Both contain it, but the small
    // zone has the smaller center distance, so it should match.
    final position = makePosition(3.1375, 101.6870);

    final result = GeofenceService.evaluateForTest(position, [
      largeDistantZone,
      smallNearbyZone,
    ]);

    expect(result.isInside, isTrue);
    expect(result.matchedZone?['id'], 'zone-a');
    expect(result.nearestZone?['id'], 'zone-a');
  });
}
