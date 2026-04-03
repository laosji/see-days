import 'calendar_storage_stub.dart'
    if (dart.library.io) 'calendar_storage_io.dart'
    if (dart.library.html) 'calendar_storage_web.dart'
    as impl;

class CalendarPersistedState {
  const CalendarPersistedState({
    required this.year,
    required this.visibleDay,
    this.birthYear,
    this.birthMonth,
    this.birthDay,
    this.expectedAge,
    this.futureNotes = const {},
  });

  final int year;
  final int visibleDay;
  final int? birthYear;
  final int? birthMonth;
  final int? birthDay;
  final int? expectedAge;
  final Map<int, String> futureNotes;
}

Future<CalendarPersistedState?> loadCalendarState() {
  return impl.loadCalendarState();
}

Future<void> saveCalendarState(CalendarPersistedState state) {
  return impl.saveCalendarState(state);
}
