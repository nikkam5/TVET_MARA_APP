import 'package:flutter/material.dart';
import '../../services/database_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/admin_ui.dart';

/// Admin screen for managing departments: lists every department with its
/// current headcount, and lets the admin add or delete a department.
class DepartmentsScreen extends StatefulWidget {
  const DepartmentsScreen({super.key});

  @override
  State<DepartmentsScreen> createState() => _DepartmentsScreenState();
}

class _DepartmentsScreenState extends State<DepartmentsScreen> {
  List<Map<String, dynamic>> _departments = [];
  Map<String, int> _headcounts = {};
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
      final results = await Future.wait([
        DatabaseService.getDepartments(),
        DatabaseService.getStaffDirectoryFull(),
      ]);
      final depts = results[0];
      final staff = results[1];
      final counts = <String, int>{};
      for (final s in staff) {
        final deptId = s['department_id'] as String?;
        if (deptId == null) continue;
        counts[deptId] = (counts[deptId] ?? 0) + 1;
      }
      if (!mounted) return;
      setState(() {
        _departments = depts;
        _headcounts = counts;
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

  Future<void> _addDepartment() async {
    final nameController = TextEditingController();
    final codeController = TextEditingController();
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add Department'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Department name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: codeController,
              decoration: const InputDecoration(labelText: 'Code (optional)'),
            ),
          ],
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
    );
    if (result != true || nameController.text.trim().isEmpty) return;
    try {
      await DatabaseService.addDepartment(
        name: nameController.text.trim(),
        code: codeController.text.trim(),
      );
      if (mounted) _loadData();
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to add: $e')));
    }
  }

  Future<void> _deleteDepartment(Map<String, dynamic> dept) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Department'),
        content: Text(
          'Remove "${dept['name']}"? Staff assigned to it will keep their record but lose the department link.',
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
      await DatabaseService.deleteDepartment(dept['id'] as String);
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
      title: 'Departments',
      subtitle:
          'Organise your teams and see how staff are distributed across your institution.',
      action: FilledButton.icon(
        onPressed: _addDepartment,
        icon: const Icon(Icons.add, color: Colors.white),
        label: const Text(
          'Add Department',
          style: TextStyle(color: Colors.white),
        ),
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
              child: _departments.isEmpty
                  ? ListView(
                      children: const [
                        Padding(
                          padding: EdgeInsets.all(40),
                          child: Center(
                            child: Text(
                              'No departments yet. Tap "Add Department" to create one.',
                            ),
                          ),
                        ),
                      ],
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) => GridView.builder(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: constraints.maxWidth > 850 ? 2 : 1,
                          mainAxisExtent: 132,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                        ),
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
                        itemCount: _departments.length,
                        itemBuilder: (context, i) {
                          final dept = _departments[i];
                          final count = _headcounts[dept['id']] ?? 0;
                          return Container(
                            padding: const EdgeInsets.all(24),
                            decoration: AdminUi.panel(),
                            child: Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: AppTheme.maraBlue.withValues(
                                      alpha: 0.12,
                                    ),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: const Icon(
                                    Icons.business_rounded,
                                    color: AppTheme.maraBlue,
                                  ),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        (dept['name'] as String?) ?? 'Unnamed',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          fontSize: 15,
                                        ),
                                      ),
                                      Text(
                                        '$count staff${(dept['code'] as String?)?.isNotEmpty == true ? ' · ${dept['code']}' : ''}',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: AppTheme.textSecondary,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Delete department',
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    color: AppTheme.maraRed,
                                  ),
                                  onPressed: () => _deleteDepartment(dept),
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
