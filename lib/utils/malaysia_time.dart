/// Malaysia wall-clock dates for attendance, independent of device timezone.
class MalaysiaTime {
  MalaysiaTime._();

  static const offset = Duration(hours: 8);

  /// Use the returned components for display, not as a stored timestamp.
  static DateTime fromUtc(DateTime instant) => instant.toUtc().add(offset);
  static DateTime now() => fromUtc(DateTime.now());
  static DateTime? parse(String? value) {
    final instant = DateTime.tryParse(value ?? '');
    return instant == null ? null : fromUtc(instant);
  }

  static String dateString(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  static DateTime dayStartUtc(DateTime date) =>
      DateTime.utc(date.year, date.month, date.day).subtract(offset);

  static bool isLate(DateTime instant) {
    final malaysia = fromUtc(instant);
    return malaysia.hour * 60 + malaysia.minute >= 8 * 60;
  }
}
