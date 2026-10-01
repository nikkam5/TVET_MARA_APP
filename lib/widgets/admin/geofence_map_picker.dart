import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../services/geofence_service.dart';
import '../../theme/app_theme.dart';

class GeofenceSelection {
  const GeofenceSelection({
    required this.latitude,
    required this.longitude,
    required this.radiusM,
  });
  final double latitude;
  final double longitude;
  final int radiusM;
}

/// Teammate's OpenStreetMap pin and radius picker, using the working GPS service.
class GeofenceMapPicker extends StatefulWidget {
  const GeofenceMapPicker({
    super.key,
    this.initialLatitude = 3.1390,
    this.initialLongitude = 101.6869,
    this.initialRadiusM = 200,
    this.onChanged,
  });
  final double initialLatitude;
  final double initialLongitude;
  final int initialRadiusM;
  final ValueChanged<GeofenceSelection>? onChanged;
  @override
  State<GeofenceMapPicker> createState() => _GeofenceMapPickerState();
}

class _GeofenceMapPickerState extends State<GeofenceMapPicker> {
  final _mapController = MapController();
  late final TextEditingController _radiusController;
  late LatLng _pin;
  late int _radius;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    _pin = LatLng(widget.initialLatitude, widget.initialLongitude);
    _radius = widget.initialRadiusM.clamp(50, 1000);
    _radiusController = TextEditingController(text: '$_radius');
  }

  @override
  void dispose() {
    _mapController.dispose();
    _radiusController.dispose();
    super.dispose();
  }

  void _emit() => widget.onChanged?.call(
    GeofenceSelection(
      latitude: _pin.latitude,
      longitude: _pin.longitude,
      radiusM: _radius,
    ),
  );

  void _setRadius(int value) {
    setState(() => _radius = value.clamp(50, 1000));
    _radiusController.text = '$_radius';
    _emit();
  }

  Future<void> _locate() async {
    setState(() => _locating = true);
    try {
      if (!await GeofenceService.ensurePermission()) {
        throw Exception('Location permission denied.');
      }
      final position = await GeofenceService.getCurrentPosition();
      if (!mounted) return;
      setState(() => _pin = LatLng(position.latitude, position.longitude));
      _mapController.move(_pin, 17);
      _emit();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not get location. Place the pin on the map: $error',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  void _zoom(double change) {
    final camera = _mapController.camera;
    _mapController.move(camera.center, (camera.zoom + change).clamp(3, 19));
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          height: 260,
          child: Stack(
            children: [
              FlutterMap(
                mapController: _mapController,
                options: MapOptions(
                  initialCenter: _pin,
                  initialZoom: 16,
                  minZoom: 3,
                  maxZoom: 19,
                  onTap: (_, point) {
                    setState(() => _pin = point);
                    _emit();
                  },
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'tvet_staff_app',
                    maxNativeZoom: 19,
                  ),
                  CircleLayer(
                    circles: [
                      CircleMarker(
                        point: _pin,
                        radius: _radius.toDouble(),
                        useRadiusInMeter: true,
                        color: AppTheme.maraBlue.withValues(alpha: 0.16),
                        borderColor: AppTheme.maraBlue,
                        borderStrokeWidth: 2,
                      ),
                    ],
                  ),
                  MarkerLayer(
                    markers: [
                      Marker(
                        point: _pin,
                        width: 44,
                        height: 44,
                        alignment: Alignment.topCenter,
                        child: const Icon(
                          Icons.location_on,
                          color: AppTheme.navy,
                          size: 40,
                        ),
                      ),
                    ],
                  ),
                  RichAttributionWidget(
                    attributions: [
                      TextSourceAttribution(
                        '© OpenStreetMap contributors',
                        onTap: () => launchUrl(
                          Uri.parse('https://www.openstreetmap.org/copyright'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              Positioned(
                top: 8,
                right: 8,
                child: Material(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  child: Column(
                    children: [
                      IconButton(
                        onPressed: () => _zoom(1),
                        icon: const Icon(Icons.add),
                        tooltip: 'Zoom in',
                      ),
                      IconButton(
                        onPressed: () => _zoom(-1),
                        icon: const Icon(Icons.remove),
                        tooltip: 'Zoom out',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 10),
      Text(
        'Tap the map to place the pin · $_radius m coverage radius',
        style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
      ),
      Row(
        children: [
          Expanded(
            child: Slider(
              value: _radius.toDouble(),
              min: 50,
              max: 1000,
              divisions: 19,
              label: '$_radius m',
              onChanged: (value) => _setRadius(value.round()),
            ),
          ),
          SizedBox(
            width: 88,
            child: TextField(
              controller: _radiusController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(suffixText: 'm'),
              onChanged: (value) {
                final parsed = int.tryParse(value);
                if (parsed == null || parsed < 50 || parsed > 1000) return;
                setState(() => _radius = parsed);
                _emit();
              },
              onSubmitted: (value) =>
                  _setRadius(int.tryParse(value) ?? _radius),
            ),
          ),
        ],
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _locating ? null : _locate,
          icon: _locating
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.my_location, size: 18),
          label: const Text('Use current location'),
        ),
      ),
    ],
  );
}
