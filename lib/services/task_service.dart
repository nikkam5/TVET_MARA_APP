import 'package:supabase_flutter/supabase_flutter.dart';

/// Personal staff tasks, saved in the signed-in user's Supabase Auth metadata.
/// No task table or sample records are required. These are self-managed tasks,
/// not administrator assignments.
class StaffTask {
  final String id;
  final String title;
  final String description;
  final DateTime dueAt;
  final double progress;

  const StaffTask({
    required this.id,
    required this.title,
    this.description = '',
    required this.dueAt,
    this.progress = 0,
  });

  bool get isDone => progress >= 1;
  String get dueLabel => TaskService.formatDueLabel(dueAt);

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'due_at': dueAt.toIso8601String(),
    'progress': progress,
  };

  static StaffTask? fromJson(dynamic value) {
    if (value is! Map || value['id'] is! String || value['title'] is! String) {
      return null;
    }
    final dueAt = DateTime.tryParse(value['due_at']?.toString() ?? '');
    if (dueAt == null) return null;
    return StaffTask(
      id: value['id'] as String,
      title: value['title'] as String,
      description: value['description']?.toString() ?? '',
      dueAt: dueAt,
      progress:
          (value['progress'] is num
                  ? (value['progress'] as num).toDouble()
                  : 0.0)
              .clamp(0.0, 1.0),
    );
  }
}

class TaskService {
  TaskService._();
  static SupabaseClient get _client => Supabase.instance.client;
  static const _metadataKey = 'personal_tasks';

  static Future<List<StaffTask>> getMyTasks() async {
    if (_client.auth.currentUser == null) throw Exception('Please sign in.');
    final user = (await _client.auth.getUser()).user;
    if (user == null) throw Exception('Your session has expired.');
    final raw = user.userMetadata?[_metadataKey];
    final tasks = raw is List
        ? raw.map(StaffTask.fromJson).whereType<StaffTask>().toList()
        : <StaffTask>[];
    tasks.sort((a, b) => a.dueAt.compareTo(b.dueAt));
    return tasks;
  }

  static Future<void> _save(List<StaffTask> tasks) async {
    await _client.auth.updateUser(
      UserAttributes(
        data: {_metadataKey: tasks.map((task) => task.toJson()).toList()},
      ),
    );
  }

  static Future<void> setProgress(String id, double progress) async {
    final tasks = await getMyTasks();
    final index = tasks.indexWhere((task) => task.id == id);
    if (index < 0) {
      throw Exception('This task no longer exists. Refresh the list.');
    }
    final task = tasks[index];
    tasks[index] = StaffTask(
      id: task.id,
      title: task.title,
      description: task.description,
      dueAt: task.dueAt,
      progress: progress.clamp(0, 1),
    );
    await _save(tasks);
  }

  static Future<StaffTask> addTask({
    required String title,
    String description = '',
    DateTime? dueAt,
  }) async {
    if (title.trim().isEmpty) throw Exception('Give the task a title.');
    if (title.length > 200 || description.length > 1000) {
      throw Exception('Use a shorter task title or description.');
    }
    final tasks = await getMyTasks();
    if (tasks.length >= 50) {
      throw Exception('You can save up to 50 personal tasks.');
    }
    final now = DateTime.now();
    final task = StaffTask(
      id: now.microsecondsSinceEpoch.toString(),
      title: title.trim(),
      description: description.trim(),
      dueAt: dueAt ?? DateTime(now.year, now.month, now.day, 17),
    );
    await _save([...tasks, task]);
    return task;
  }

  static String formatDueLabel(DateTime dueAt) {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final now = DateTime.now();
    final diff = DateTime(
      dueAt.year,
      dueAt.month,
      dueAt.day,
    ).difference(DateTime(now.year, now.month, now.day)).inDays;
    final day = diff == 0
        ? 'today'
        : diff == 1
        ? 'tomorrow'
        : '${weekdays[dueAt.weekday - 1]}, ${dueAt.day}/${dueAt.month}/${dueAt.year}';
    final hour = dueAt.hour % 12 == 0 ? 12 : dueAt.hour % 12;
    return 'Due $day · $hour:${dueAt.minute.toString().padLeft(2, '0')} ${dueAt.hour < 12 ? 'AM' : 'PM'}';
  }
}
