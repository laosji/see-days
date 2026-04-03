import 'dart:convert';
import 'dart:io';

import 'calendar_storage.dart';

File _stateFile() {
  return File('${Directory.systemTemp.path}/real_calendar_state.json');
}

Future<CalendarPersistedState?> loadCalendarState() async {
  try {
    final file = _stateFile();
    if (!await file.exists()) {
      return null;
    }

    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final year = decoded['year'];
    final visibleDay = decoded['visibleDay'];
    if (year is int && visibleDay is int) {
      return CalendarPersistedState(
        year: year,
        visibleDay: visibleDay,
        birthYear: decoded['birthYear'] as int?,
        birthMonth: decoded['birthMonth'] as int?,
        birthDay: decoded['birthDay'] as int?,
        expectedAge: decoded['expectedAge'] as int?,
        futureNotes: _decodeFutureNotes(decoded['futureNotes']),
      );
    }
  } catch (_) {
    return null;
  }

  return null;
}

Future<void> saveCalendarState(CalendarPersistedState state) async {
  try {
    final file = _stateFile();
    await file.writeAsString(
      jsonEncode({
        'year': state.year,
        'visibleDay': state.visibleDay,
        'birthYear': state.birthYear,
        'birthMonth': state.birthMonth,
        'birthDay': state.birthDay,
        'expectedAge': state.expectedAge,
        'futureNotes': state.futureNotes.map(
          (key, value) => MapEntry(key.toString(), value),
        ),
      }),
      flush: true,
    );
  } catch (_) {}
}

Map<int, String> _decodeFutureNotes(Object? raw) {
  if (raw is! Map) {
    return const {};
  }

  final notes = <int, String>{};
  raw.forEach((key, value) {
    final day = int.tryParse(key.toString());
    final text = value?.toString().trim();
    if (day != null && text != null && text.isNotEmpty) {
      notes[day] = text;
    }
  });
  return notes;
}
