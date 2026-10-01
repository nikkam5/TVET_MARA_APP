import 'package:flutter/material.dart';
import '../../services/database_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/admin/admin_ui.dart';
import '../../widgets/admin/geofence_map_picker.dart';

/// In-shell geofence management: teammate's cards and map, live Supabase data.
class GeofenceZonesScreen extends StatefulWidget {
  const GeofenceZonesScreen({super.key, this.onChanged});
  final VoidCallback? onChanged;
  @override
  State<GeofenceZonesScreen> createState() => _GeofenceZonesScreenState();
}

class _GeofenceZonesScreenState extends State<GeofenceZonesScreen> {
  List<Map<String, dynamic>> _zones = [];
  final Set<String> _working = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final zones = await DatabaseService.getGeofenceZones();
      if (mounted) {
        setState(() {
          _zones = zones;
          _loading = false;
          _error = null;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _loading = false;
        });
      }
    }
  }

  void _snack(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  Future<void> _add() async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => const _AddZoneDialog(),
    );
    if (saved != true || !mounted) return;
    widget.onChanged?.call();
    await _load();
  }

  Future<void> _toggle(Map<String, dynamic> zone, bool active) async {
    final id = zone['id'] as String;
    if (_working.contains(id)) return;
    setState(() => _working.add(id));
    try {
      await DatabaseService.setGeofenceZoneActive(id, active);
      if (!mounted) return;
      setState(() => zone['is_active'] = active);
      widget.onChanged?.call();
    } catch (error) {
      if (mounted) _snack('Could not update zone: $error');
    } finally {
      if (mounted) setState(() => _working.remove(id));
    }
  }

  Future<void> _delete(Map<String, dynamic> zone) async {
    final id = zone['id'] as String;
    if (_working.contains(id)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Zone'),
        content: Text('Remove "${zone['name']}" from the campus zones?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _working.add(id));
    try {
      await DatabaseService.deleteGeofenceZone(id);
      if (!mounted) return;
      widget.onChanged?.call();
      await _load();
    } catch (error) {
      if (mounted) _snack('Could not delete zone: $error');
    } finally {
      if (mounted) setState(() => _working.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) => AdminPage(
    embedded: true,
    title: 'Geofence Settings',
    subtitle:
        '${_zones.length} campus zones · ${_zones.where((z) => z['is_active'] == true).length} active',
    action: FilledButton.icon(
      onPressed: _add,
      icon: const Icon(Icons.add_location_alt),
      label: const Text('Add Zone'),
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _error != null
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Could not load live zones: $_error',
                  textAlign: TextAlign.center,
                ),
                TextButton(onPressed: _load, child: const Text('Retry')),
              ],
            ),
          )
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(20),
              children: [
                if (_zones.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No active zones configured. Add a zone to restrict check-in to your campus.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                for (final zone in _zones)
                  Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.all(18),
                    decoration: AdminUi.panel(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(
                              Icons.location_on_outlined,
                              color: AppTheme.navy,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                zone['name']?.toString() ?? 'Unnamed zone',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                            Switch(
                              value: zone['is_active'] == true,
                              onChanged: _working.contains(zone['id'])
                                  ? null
                                  : (active) => _toggle(zone, active),
                            ),
                            IconButton(
                              tooltip: 'Delete zone',
                              onPressed: _working.contains(zone['id'])
                                  ? null
                                  : () => _delete(zone),
                              icon: const Icon(
                                Icons.delete_outline,
                                color: AppTheme.maraRed,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          '${zone['radius_m']} m coverage · ${zone['is_active'] == true ? 'Active' : 'Inactive'}',
                          style: const TextStyle(color: AdminUi.muted),
                        ),
                        Text(
                          '${zone['center_lat']}, ${zone['center_lng']}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: AdminUi.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
  );
}

class _AddZoneDialog extends StatefulWidget {
  const _AddZoneDialog();
  @override
  State<_AddZoneDialog> createState() => _AddZoneDialogState();
}

class _AddZoneDialogState extends State<_AddZoneDialog> {
  final _name = TextEditingController();
  GeofenceSelection _selection = const GeofenceSelection(
    latitude: 3.1390,
    longitude: 101.6869,
    radiusM: 200,
  );
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_name.text.trim().isEmpty) {
      setState(() => _error = 'Please give the zone a name.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await DatabaseService.addGeofenceZone(
        name: _name.text.trim(),
        centerLat: _selection.latitude,
        centerLng: _selection.longitude,
        radiusM: _selection.radiusM,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save zone: $error';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Add Geofence Zone'),
    content: SizedBox(
      width: 520,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Tap the map to choose the campus location, then set the coverage radius.',
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _name,
              enabled: !_saving,
              decoration: const InputDecoration(labelText: 'Zone name'),
            ),
            const SizedBox(height: 14),
            IgnorePointer(
              ignoring: _saving,
              child: GeofenceMapPicker(
                onChanged: (selection) => _selection = selection,
              ),
            ),
            if (_error != null)
              Text(_error!, style: const TextStyle(color: AppTheme.maraRed)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: Text(_saving ? 'Saving…' : 'Add zone'),
      ),
    ],
  );
}
