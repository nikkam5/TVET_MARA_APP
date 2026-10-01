import 'package:flutter/material.dart';
import '../../services/presence_service.dart';
import 'admin_ui.dart';

/// Teammate's directory card layout with live employment and presence fields.
class StaffDirectoryCard extends StatelessWidget {
  const StaffDirectoryCard({
    super.key,
    required this.staff,
    required this.onView,
    required this.onEdit,
    required this.onPrint,
  });

  final Map<String, dynamic> staff;
  final VoidCallback onView;
  final VoidCallback onEdit;
  final VoidCallback onPrint;

  @override
  Widget build(BuildContext context) {
    final name = staff['full_name']?.toString() ?? 'Unknown';
    final department = staff['departments']?['name']?.toString() ?? '—';
    const palette = [
      Color(0xFF0A4EA1),
      Color(0xFF1FAA59),
      Color(0xFFC9992C),
      Color(0xFFC0392B),
      Color(0xFF7C3AED),
      Color(0xFF0E7490),
    ];
    final color =
        palette[department.runes
                .fold(0, (hash, rune) => hash * 31 + rune)
                .abs() %
            palette.length];
    final active = staff['is_active'] == true;
    final online = PresenceService.isOnline(
      PresenceService.parseLastSeen(staff['last_seen']),
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: AdminUi.panel(),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onView,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Stack(
                      children: [
                        CircleAvatar(
                          radius: 21,
                          backgroundColor: color.withValues(alpha: 0.12),
                          child: Text(
                            name.isEmpty ? '?' : name[0].toUpperCase(),
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: online ? Colors.green : Colors.grey,
                              border: Border.all(color: Colors.white, width: 2),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: AdminUi.ink,
                            ),
                          ),
                          Text(
                            'No. Gaji · ${staff['staff_number'] ?? '—'}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: AdminUi.muted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _badge(
                      active ? 'Active' : 'Inactive',
                      active ? Colors.green : Colors.grey,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _badge(department, color),
                    if (staff['role'] == 'admin') _badge('ADMIN', Colors.red),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  '${staff['position'] ?? '—'} · ${staff['staff_grade'] ?? '—'} · ${staff['employment_status'] ?? '—'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AdminUi.ink),
                ),
                Text(
                  staff['email']?.toString() ?? '—',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: AdminUi.muted),
                ),
                const SizedBox(height: 6),
                Text(
                  online ? 'Online now' : 'Offline',
                  style: TextStyle(
                    fontSize: 11,
                    color: online ? Colors.green : AdminUi.muted,
                  ),
                ),
                const Divider(height: 24),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    _action(
                      'View Profile',
                      Icons.person_search_outlined,
                      onView,
                    ),
                    _action('Edit', Icons.edit_outlined, onEdit),
                    _action('Print Report', Icons.print_outlined, onPrint),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _badge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.1),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w700),
    ),
  );

  Widget _action(String label, IconData icon, VoidCallback onTap) =>
      TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 15),
        label: Text(label, style: const TextStyle(fontSize: 11)),
        style: TextButton.styleFrom(
          foregroundColor: AdminUi.navy,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
          minimumSize: Size.zero,
        ),
      );
}
