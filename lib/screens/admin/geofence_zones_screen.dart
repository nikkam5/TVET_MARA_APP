import 'package:flutter/material.dart';
import '../../services/database_service.dart';
import '../../services/geofence_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/admin_ui.dart';

/// Admin screen for managing geofence zones — the campus areas staff must
/// be inside to punch in. Lists every zone, lets the admin add a new one
/// (optionally using the device's current GPS position), toggle a zone
/// active/inactive, or delete it.
class GeofenceZonesScreen extends StatefulWidget {
  const GeofenceZonesScreen({super.key});

  @override
  State<GeofenceZonesScreen> createState() => _GeofenceZonesScreenState();
}

class _GeofenceZonesScreenState extends State<GeofenceZonesScreen> {
  List<Map<String, dynamic>> _zones = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final zones = await DatabaseService.getGeofenceZones();
      if (!mounted) return;
      setState(() {
        _zones = zones;
        _isLoading = false;
      });
    } on Exception catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _addZone() async {
    final nameController = TextEditingController();
    final latController = TextEditingController();
    final lngController = TextEditingController();
    final radiusController = TextEditingController(text: '200');
    bool locating = false;

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Add Geofence Zone'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Zone name (e.g. Main Campus)',
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: latController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Latitude',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: lngController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                          signed: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Longitude',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: locating
                        ? null
                        : () async {
                            setDialogState(() => locating = true);
                            try {
                              final granted =
                                  await GeofenceService.ensurePermission();
                              if (!granted) {
                                throw Exception('Location permission denied.');
                              }
                              final pos =
                                  await GeofenceService.getCurrentPosition();
                              latController.text = pos.latitude.toStringAsFixed(
                                6,
                              );
                              lngController.text = pos.longitude
                                  .toStringAsFixed(6);
                            } on Exception catch (_) {
                              // Surfaced implicitly — fields just stay empty.
                            } finally {
                              setDialogState(() => locating = false);
                            }
                          },
                    icon: locating
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.my_location, size: 16),
                    label: const Text('Use current location'),
                  ),
                ),
                const SizedBox(height: 4),
                TextField(
                  controller: radiusController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Radius (meters)',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );

    if (result != true) return;
    final lat = double.tryParse(latController.text.trim());
    final lng = double.tryParse(lngController.text.trim());
    final radius = int.tryParse(radiusController.text.trim());
    if (nameController.text.trim().isEmpty ||
        lat == null ||
        lng == null ||
        radius == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Please fill in a valid name, latitude, longitude, and radius.',
          ),
        ),
      );
      return;
    }
    try {
      await DatabaseService.addGeofenceZone(
        name: nameController.text.trim(),
        centerLat: lat,
        centerLng: lng,
        radiusM: radius,
      );
      if (mounted) _loadData();
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to add: $e')));
    }
  }

  Future<void> _toggleActive(Map<String, dynamic> zone, bool value) async {
    try {
      await DatabaseService.setGeofenceZoneActive(zone['id'] as String, value);
      if (mounted) _loadData();
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to update: $e')));
    }
  }

  Future<void> _deleteZone(Map<String, dynamic> zone) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Zone'),
        content: Text(
          'Remove "${zone['name']}"? Staff will no longer be able to punch in from this location.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: AppTheme.maraRed),
            ),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await DatabaseService.deleteGeofenceZone(zone['id'] as String);
      if (mounted) _loadData();
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to delete: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AdminPage(
      title: 'Campus zones',
      subtitle:
          'Define where your team can check in. Manage locations, coverage and access.',
      action: FilledButton.icon(
        onPressed: _addZone,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text('Add Zone', style: TextStyle(color: Colors.white)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Failed to load: $_error',
                    style: const TextStyle(color: AppTheme.maraRed),
                  ),
                  TextButton(onPressed: _loadData, child: const Text('Retry')),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadData,
              child: _zones.isEmpty
                  ? ListView(
                      children: const [
                        Padding(
                          padding: EdgeInsets.all(40),
                          child: Center(
                            child: Text(
                              'No zones configured — staff can currently punch in from anywhere.\nTap "Add Zone" to restrict punch-in to campus.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ],
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) => GridView.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: constraints.maxWidth > 1000 ? 2 : 1,
                          mainAxisExtent: 156,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                        ),
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                        itemCount: _zones.length,
                        itemBuilder: (context, i) {
                          final zone = _zones[i];
                          final isActive = (zone['is_active'] as bool?) ?? true;
                          final radius = zone['radius_m'] as num? ?? 200;
                          final lat =
                              (zone['center_lat'] as num?)?.toStringAsFixed(
                                5,
                              ) ??
                              '—';
                          final lng =
                              (zone['center_lng'] as num?)?.toStringAsFixed(
                                5,
                              ) ??
                              '—';
                          return Container(
                            padding: const EdgeInsets.all(16),
                            decoration: AdminUi.panel(),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color:
                                        (isActive
                                                ? AppTheme.maraBlue
                                                : AppTheme.textFaint)
                                            .withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Icon(
                                    Icons.location_on_rounded,
                                    color: isActive
                                        ? AppTheme.maraBlue
                                        : AppTheme.textFaint,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        (zone['name'] as String?) ??
                                            'Unnamed zone',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                        ),
                                      ),
                                      Text(
                                        '${radius.toInt()} m coverage · ${isActive ? 'Active' : 'Inactive'}\n$lat, $lng',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: AppTheme.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Switch(
                                  value: isActive,
                                  activeThumbColor: AppTheme.navy,
                                  onChanged: (v) => _toggleActive(zone, v),
                                ),
                                IconButton(
                                  tooltip: 'Delete zone',
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    color: AppTheme.maraRed,
                                  ),
                                  onPressed: () => _deleteZone(zone),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
            ),
    );
  }
}
