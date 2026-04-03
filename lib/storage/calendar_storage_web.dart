// ignore_for_file: deprecated_member_use, avoid_web_libraries_in_flutter

import 'dart:convert';
import 'dart:html' as html;

import 'calendar_storage.dart';

const _storageKey = 'real_calendar_state';

Future<CalendarPersistedState?> loadCalendarState() async {
  try {
    final raw = html.window.localStorage[_storageKey];
    if (raw == null) {
      return null;
    }

    final decoded = jsonDecode(raw) as Map<String, dynamic>;
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
    html.window.localStorage[_storageKey] = jsonEncode({
      'year': state.year,
      'visibleDay': state.visibleDay,
      'birthYear': state.birthYear,
      'birthMonth': state.birthMonth,
      'birthDay': state.birthDay,
      'expectedAge': state.expectedAge,
      'futureNotes': state.futureNotes.map(
        (key, value) => MapEntry(key.toString(), value),
      ),
    });
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
