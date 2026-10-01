import 'package:flutter/material.dart';
import '../../services/task_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/staff/staff_page_header.dart';

/// Tasks tab — "N priorities today" list with per-task progress bars.
/// Personal tasks saved to the signed-in staff account by [TaskService].
class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key});

  @override
  State<TasksScreen> createState() => _TasksScreenState();
}

class _TasksScreenState extends State<TasksScreen> {
  List<StaffTask> _tasks = [];
  bool _isLoading = true;
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      final tasks = await TaskService.getMyTasks();
      if (!mounted) return;
      setState(() {
        _tasks = tasks;
        _error = null;
        _isLoading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = error.toString();
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _toggleDone(StaffTask task) async {
    if (_saving) return;
    _saving = true;
    try {
      await TaskService.setProgress(task.id, task.isDone ? 0 : 1);
      if (mounted) await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Could not save task: $error')));
      }
    } finally {
      _saving = false;
    }
  }

  // Opens the add-task form as a root-navigator dialog hosting a
  // self-contained [_AddTaskDialog]. The dialog owns its controllers,
  // focus and setState, so popping it can never leave dependents
  // attached to a deactivated route (the old StatefulBuilder version
  // mixed outer/inner contexts and disposed controllers after pop,
  // which tripped the `_dependents.isEmpty` framework assertion).
  Future<void> _showAddTaskDialog() async {
    final created = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (_) => const _AddTaskDialog(),
    );

    if (created != true || !mounted) return;
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text(
            'Task added.',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
          backgroundColor: AppTheme.success,
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.all(14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  int get _openCount => _tasks.where((t) => !t.isDone).length;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.bgBottom,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  StaffPageHeader(
                    title: 'Tasks',
                    subtitle: '$_openCount personal tasks pending',
                    trailing: ElevatedButton.icon(
                      onPressed: _showAddTaskDialog,
                      icon: const Icon(
                        Icons.add_rounded,
                        size: 18,
                        color: Colors.white,
                      ),
                      label: const Text(
                        'Add Task',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 13.5,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.gold,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 10,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
                    child: _error != null
                        ? Column(
                            children: [
                              Text('Could not load tasks: $_error'),
                              TextButton(
                                onPressed: _load,
                                child: const Text('Retry'),
                              ),
                            ],
                          )
                        : _tasks.isEmpty
                        ? _buildEmptyState()
                        : Column(
                            children: [
                              for (int i = 0; i < _tasks.length; i++) ...[
                                _TaskCard(
                                  index: i + 1,
                                  task: _tasks[i],
                                  onTap: () => _toggleDone(_tasks[i]),
                                ),
                                if (i != _tasks.length - 1)
                                  const SizedBox(height: 14),
                              ],
                            ],
                          ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildEmptyState() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 60),
      child: Center(
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppTheme.success.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.task_alt_rounded,
                size: 30,
                color: AppTheme.success,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'All caught up — no tasks pending.',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: _showAddTaskDialog,
              icon: const Icon(Icons.add_rounded, size: 17),
              label: const Text('Add your first task'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.navy,
                side: BorderSide(color: AppTheme.navy.withValues(alpha: 0.3)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Self-contained add-task form. Owns its controllers, focus node and
/// saving/error state, and pops with its *own* BuildContext, so the host
/// page never touches dialog internals across an async gap.
class _AddTaskDialog extends StatefulWidget {
  const _AddTaskDialog();

  @override
  State<_AddTaskDialog> createState() => _AddTaskDialogState();
}

class _AddTaskDialogState extends State<_AddTaskDialog> {
  final _titleController = TextEditingController();
  final _descController = TextEditingController();
  final _titleFocus = FocusNode();
  DateTime _date = DateTime.now();
  TimeOfDay _time = const TimeOfDay(hour: 17, minute: 0);
  String _error = '';
  bool _saving = false;

  @override
  void dispose() {
    _titleController.dispose();
    _descController.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  String get _dateLabel {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${weekdays[_date.weekday - 1]}, ${_date.day} ${months[_date.month - 1]} ${_date.year}';
  }

  String get _timeLabel {
    final hour12 = _time.hour % 12 == 0 ? 12 : _time.hour % 12;
    final minute = _time.minute.toString().padLeft(2, '0');
    final ampm = _time.period == DayPeriod.am ? 'AM' : 'PM';
    return '$hour12:$minute $ampm';
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: today.subtract(const Duration(days: 1)),
      lastDate: today.add(const Duration(days: 365)),
    );
    if (picked != null && mounted) {
      setState(() => _date = picked);
    }
  }

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    if (picked != null && mounted) {
      setState(() => _time = picked);
    }
  }

  Future<void> _submit() async {
    if (_saving) return;
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Give the task a title.');
      _titleFocus.requestFocus();
      return;
    }
    setState(() {
      _saving = true;
      _error = '';
    });
    final dueAt = DateTime(
      _date.year,
      _date.month,
      _date.day,
      _time.hour,
      _time.minute,
    );
    try {
      await TaskService.addTask(
        title: title,
        description: _descController.text,
        dueAt: dueAt,
      );
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save task: $error';
        });
      }
      return;
    }
    if (!mounted) return;
    // Release focus before popping so no focus/MediaQuery dependent is
    // left attached to the outgoing route.
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(true);
  }

  InputDecoration _fieldDecoration(String hint) => InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: const Color(0xFFF4F6FB),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
  );

  Widget _label(String text) => Text(
    text,
    style: const TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w700,
      color: AppTheme.textSecondary,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      title: const Text(
        'Add task',
        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _label('Title'),
            const SizedBox(height: 6),
            TextField(
              controller: _titleController,
              focusNode: _titleFocus,
              textCapitalization: TextCapitalization.sentences,
              decoration: _fieldDecoration('e.g. Prepare lab materials'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 14),
            _label('Description (optional)'),
            const SizedBox(height: 6),
            TextField(
              controller: _descController,
              maxLines: 3,
              minLines: 2,
              textCapitalization: TextCapitalization.sentences,
              decoration: _fieldDecoration('Notes, location, checklist…'),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _label('Date'),
                      const SizedBox(height: 6),
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: _pickDate,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF4F6FB),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.calendar_today_rounded,
                                size: 16,
                                color: AppTheme.navy,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _dateLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _label('Time'),
                      const SizedBox(height: 6),
                      InkWell(
                        borderRadius: BorderRadius.circular(12),
                        onTap: _pickTime,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF4F6FB),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.schedule_rounded,
                                size: 16,
                                color: AppTheme.navy,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _timeLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.textPrimary,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                _error,
                style: const TextStyle(color: AppTheme.maraRed, fontSize: 12.5),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        ElevatedButton.icon(
          onPressed: _saving ? null : _submit,
          icon: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.add_rounded, size: 18, color: Colors.white),
          label: Text(
            _saving ? 'Adding…' : 'Add task',
            style: const TextStyle(color: Colors.white),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.navy,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ],
    );
  }
}

class _TaskCard extends StatelessWidget {
  final int index;
  final StaffTask task;
  final VoidCallback onTap;

  const _TaskCard({
    required this.index,
    required this.task,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final percent = (task.progress * 100).round();
    final barColor = task.isDone
        ? AppTheme.success
        : task.progress >= 0.5
        ? AppTheme.maraBlue
        : AppTheme.goldDeep;
    final statusLabel = task.isDone ? 'Done' : '$percent%';
    final statusBg = task.isDone
        ? AppTheme.successSoft
        : const Color(0xFFF1F4FA);
    final statusFg = task.isDone ? AppTheme.successDeep : AppTheme.navy;

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xFFEAEDF5)),
          boxShadow: [
            BoxShadow(
              color: AppTheme.navy.withValues(alpha: 0.07),
              blurRadius: 18,
              spreadRadius: 0,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.03),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTap: onTap,
              child: Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: task.isDone
                      ? AppTheme.success
                      : AppTheme.navy.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: task.isDone
                    ? const Icon(
                        Icons.check_rounded,
                        color: Colors.white,
                        size: 18,
                      )
                    : Text(
                        '$index',
                        style: const TextStyle(
                          color: AppTheme.navy,
                          fontWeight: FontWeight.w800,
                          fontSize: 13,
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(
                          task.title,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            height: 1.3,
                            letterSpacing: -0.1,
                            color: AppTheme.textPrimary,
                            decoration: task.isDone
                                ? TextDecoration.lineThrough
                                : TextDecoration.none,
                            decorationColor: AppTheme.textFaint,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: statusBg,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          statusLabel,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                            color: statusFg,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Icon(
                        Icons.schedule_rounded,
                        size: 13,
                        color: AppTheme.textFaint,
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          task.dueLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (task.description.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Text(
                      task.description,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        height: 1.4,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: LinearProgressIndicator(
                            value: task.progress,
                            minHeight: 8,
                            backgroundColor: const Color(0xFFEDF0F7),
                            valueColor: AlwaysStoppedAnimation<Color>(barColor),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    task.isDone
                        ? 'Completed — tap to reopen'
                        : 'Tap to mark complete',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.textFaint,
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
}
