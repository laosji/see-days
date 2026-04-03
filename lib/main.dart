import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'storage/calendar_storage.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RealCalendarApp());
}

class RealCalendarApp extends StatelessWidget {
  const RealCalendarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'See Days',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('zh'), Locale('en')],
      theme: ThemeData(
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF3EEE4),
        colorScheme: const ColorScheme.light(
          primary: Color(0xFFB65A33),
          secondary: Color(0xFFD8C8AF),
          surface: Color(0xFFFFF8EF),
        ),
        fontFamilyFallback: const ['Songti SC', 'STSong', 'Noto Serif CJK SC'],
      ),
      home: const RealCalendarHome(),
    );
  }
}

class RealCalendarHome extends StatefulWidget {
  const RealCalendarHome({super.key});

  @override
  State<RealCalendarHome> createState() => _RealCalendarHomeState();
}

class _RealCalendarHomeState extends State<RealCalendarHome>
    with TickerProviderStateMixin {
  static final DateTime _demoBirthday = DateTime(1996, 6, 14);
  static const int _demoExpectedAge = 82;
  static const double _statusCoreCardHeight = 198;

  late final AnimationController _tearController;
  late final AnimationController _gestureNudgeController;
  DateTime _today = _startOfDay(DateTime.now());
  int _daysInYear = 365;
  int _visibleDay = 1;
  DateTime _birthday = _demoBirthday;
  int _expectedAge = _demoExpectedAge;
  int? _animatingDay;
  final List<DeskPaperBall> _deskBalls = [];
  Timer? _openingVeilTimer;
  bool _isReady = false;
  bool _isCatchingUp = false;
  bool _isCompressing = false;
  bool _isRebounding = false;
  bool _hideOpeningVeil = false;
  bool _showLifeSettings = false;
  bool _showDebugActions = false;
  Offset _dragOffset = Offset.zero;
  bool _showDragResistanceHint = false;
  bool _showDayReleasedHint = false;
  String _hintText = '今天已经是最新一页，不会自动撕掉。';
  Map<int, String> _futureNotes = const {};

  @override
  void initState() {
    super.initState();
    _tearController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1900),
    );
    _gestureNudgeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat(reverse: true);
    unawaited(_loadState());
    _openingVeilTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) {
        setState(() => _hideOpeningVeil = true);
      }
    });
  }

  @override
  void dispose() {
    _openingVeilTimer?.cancel();
    _tearController.dispose();
    _gestureNudgeController.dispose();
    super.dispose();
  }

  Future<void> _loadState() async {
    _today = _startOfDay(DateTime.now());
    _daysInYear = _getDaysInYear(_today.year);

    final savedState = await loadCalendarState();
    final savedYear = savedState?.year;
    final savedVisibleDay = savedState?.visibleDay;
    final savedBirthday = _birthdayFromState(savedState);
    final savedExpectedAge = savedState?.expectedAge;

    if (savedYear == _today.year && savedVisibleDay != null) {
      _visibleDay = savedVisibleDay.clamp(1, _daysInYear);
    } else {
      _visibleDay = _getDayOfYear(_today);
    }
    if (savedBirthday != null) {
      _birthday = savedBirthday;
    }
    if (savedExpectedAge != null) {
      _expectedAge = savedExpectedAge.clamp(1, 140);
    }
    _futureNotes = Map<int, String>.from(savedState?.futureNotes ?? const {});
    await _persistState();

    if (!mounted) {
      return;
    }

    setState(() {
      _isReady = true;
    });

    final overduePages = math.max(0, _getDayOfYear(_today) - _visibleDay);
    if (overduePages > 0) {
      _hintText = '重新打开时，会把你错过的日子一页页补撕回来。';
      unawaited(_runCatchUp(overduePages));
    }
  }

  Future<void> _persistState() async {
    await saveCalendarState(
      CalendarPersistedState(
        year: _today.year,
        visibleDay: _visibleDay,
        birthYear: _birthday.year,
        birthMonth: _birthday.month,
        birthDay: _birthday.day,
        expectedAge: _expectedAge,
        futureNotes: _futureNotes,
      ),
    );
  }

  Future<void> _simulateAbsence(int days) async {
    if (_isCatchingUp) {
      return;
    }

    final todayDay = _getDayOfYear(_today);
    setState(() {
      _visibleDay = math.max(1, todayDay - days);
    });
    await _persistState();
    final overduePages = math.max(0, todayDay - _visibleDay);
    if (overduePages > 0) {
      _hintText = '模拟完成，现在开始补撕缺席的日子。';
      unawaited(_runCatchUp(overduePages));
    }
  }

  Future<void> _resetToToday() async {
    if (_isCatchingUp) {
      return;
    }

    setState(() {
      _visibleDay = _getDayOfYear(_today);
      _hintText = '已经回到今天这一页。';
    });
    await _persistState();
  }

  Future<void> _tearCurrentPage() async {
    if (_isCatchingUp || _animatingDay != null) {
      return;
    }
    final isFuturePage = _visibleDay > _getDayOfYear(_today);
    _hintText = isFuturePage ? '你正在把未来往前放下。' : '撕掉今天这一页，留一句话在桌上。';
    await _tearPage(_visibleDay);
  }

  void _handlePanStart(DragStartDetails details) {
    if (_isCatchingUp || _animatingDay != null) {
      return;
    }
    setState(() {
      _dragOffset = Offset.zero;
      _showDragResistanceHint = false;
    });
  }

  void _handlePanUpdate(DragUpdateDetails details) {
    if (_isCatchingUp || _animatingDay != null) {
      return;
    }
    final isFuturePage = _visibleDay > _getDayOfYear(_today);
    final next = _dragOffset + details.delta;
    final futureResistance = isFuturePage ? 0.64 : 1.0;
    final resistedX = next.dx > 0
        ? math.min(
            next.dx * 0.24 * futureResistance,
            isFuturePage ? 20.0 : 32.0,
          )
        : next.dx * 0.08;
    final resistedY = next.dy < 0
        ? math.max(
            next.dy * 0.2 * futureResistance,
            isFuturePage ? -18.0 : -30.0,
          )
        : next.dy * 0.08;
    final shouldWarn = isFuturePage
        ? next.dx > 36 || next.dy < -34
        : next.dx > 38 || next.dy < -38;
    setState(() {
      _dragOffset = Offset(resistedX, resistedY);
      _showDragResistanceHint = shouldWarn;
    });
  }

  void _handlePanEnd(DragEndDetails details) {
    if (_isCatchingUp || _animatingDay != null) {
      return;
    }
    final isFuturePage = _visibleDay > _getDayOfYear(_today);
    final velocity = details.velocity.pixelsPerSecond;
    final shouldTear = isFuturePage
        ? velocity.dy < -1220 ||
              velocity.dx > 1220 ||
              _dragOffset.dx > 54 ||
              _dragOffset.dy < -40
        : velocity.dy < -700 ||
              velocity.dx > 700 ||
              _dragOffset.dx > 28 ||
              _dragOffset.dy < -24;
    setState(() {
      _dragOffset = Offset.zero;
      _showDragResistanceHint = false;
    });
    if (shouldTear) {
      unawaited(_tearCurrentPage());
    }
  }

  Future<void> _pickBirthday() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthday,
      firstDate: DateTime(1920, 1, 1),
      lastDate: _today,
      helpText: '选择出生年月日',
      locale: const Locale('zh'),
    );
    if (picked == null) {
      return;
    }
    setState(() {
      _birthday = _startOfDay(picked);
    });
    await _persistState();
  }

  Future<void> _composeFutureNote() async {
    final tomorrow = _startOfDay(_today.add(const Duration(days: 1)));
    final lastDay = DateTime(_today.year, 12, 31);
    if (tomorrow.isAfter(lastDay)) {
      return;
    }

    final picked = await showDatePicker(
      context: context,
      initialDate: tomorrow,
      firstDate: tomorrow,
      lastDate: lastDay,
      helpText: '选择未来的某一天',
      locale: const Locale('zh'),
    );
    if (picked == null || !mounted) {
      return;
    }

    final targetDay = _getDayOfYear(_startOfDay(picked));
    final controller = TextEditingController(
      text: _futureNotes[targetDay] ?? '',
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) {
      controller.dispose();
      return;
    }

    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFFFFF8EF),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (context) {
        final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, bottomInset + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '留一句话给 ${picked.month} 月 ${picked.day} 日',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFF241A12),
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 36,
                maxLines: 3,
                decoration: const InputDecoration(
                  hintText: '写一句想留给那天的话',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.of(context).pop(null),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () =>
                          Navigator.of(context).pop(controller.text.trim()),
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );

    controller.dispose();
    if (text == null || !mounted) {
      return;
    }

    setState(() {
      if (text.isEmpty) {
        _futureNotes.remove(targetDay);
      } else {
        _futureNotes[targetDay] = text;
      }
      _hintText = text.isEmpty ? '这一天重新留白了。' : '这句话会在那一天等你。';
    });
    await _persistState();
  }

  Future<void> _adjustExpectedAge(int delta) async {
    final nextAge = (_expectedAge + delta).clamp(1, 140);
    if (nextAge == _expectedAge) {
      return;
    }
    setState(() {
      _expectedAge = nextAge;
    });
    await _persistState();
  }

  Future<void> _runCatchUp(int overduePages) async {
    if (_isCatchingUp) {
      return;
    }

    _isCatchingUp = true;
    if (mounted) {
      setState(() {});
    }

    final startDay = _visibleDay;
    for (var offset = 0; offset < overduePages; offset++) {
      await _tearPage(startDay + offset);
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _visibleDay = _getDayOfYear(_today);
      _hintText = '补撕完成，现在停在今天这一页。';
    });
    await _persistState();
    _isCatchingUp = false;
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _tearPage(int dayOfYear) async {
    if (!mounted) {
      return;
    }
    final isTodayPage = dayOfYear == _getDayOfYear(_today);

    setState(() {
      _isCompressing = true;
      _isRebounding = false;
    });
    await Future<void>.delayed(const Duration(milliseconds: 90));

    if (!mounted) {
      return;
    }

    setState(() {
      _isCompressing = false;
      _isRebounding = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 150));

    if (!mounted) {
      return;
    }

    setState(() {
      _isRebounding = false;
      _animatingDay = dayOfYear;
      _showDayReleasedHint = false;
    });

    _tearController.reset();
    await _tearController.forward();

    if (!mounted) {
      return;
    }

    setState(() {
      _visibleDay = (dayOfYear + 1).clamp(1, _daysInYear);
      _animatingDay = null;
      _futureNotes.remove(dayOfYear);
      _registerDeskBall(dayOfYear);
      if (isTodayPage) {
        _showDayReleasedHint = true;
        _hintText = '今天已经是最新一页，不会自动撕掉。';
      }
    });
    await _persistState();
    await Future<void>.delayed(const Duration(milliseconds: 90));
  }

  void _registerDeskBall(int seed) {
    final random = math.Random(seed * 41);
    _deskBalls.add(
      DeskPaperBall(
        seed: seed,
        x: 0.28 + random.nextDouble() * 0.38,
        y: 0.72 + random.nextDouble() * 0.12,
        scale: 0.72 + random.nextDouble() * 0.3,
        rotation: -0.22 + random.nextDouble() * 0.44,
      ),
    );
    if (_deskBalls.length > 4) {
      _deskBalls.removeAt(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCompact = MediaQuery.sizeOf(context).width < 920;
    final todayDayOfYear = _getDayOfYear(_today);
    final currentEntry = _entryForDay(_visibleDay);
    final tornPages = _visibleDay - 1;
    final remainingPages = _daysInYear - _visibleDay;
    final lifeDayCount = _today.difference(_birthday).inDays + 1;
    final configuredLifeDayCount = _today.difference(_birthday).inDays + 1;
    final expectedLifeDays = _expectedAge * 365;
    final lifeDaysRemaining = math.max(
      0,
      expectedLifeDays - configuredLifeDayCount,
    );
    final thickness = _getThicknessPresentation(
      remainingPages: remainingPages,
      tornPages: tornPages,
      daysInYear: _daysInYear,
    );
    final isAheadOfToday = _visibleDay > todayDayOfYear;
    final todayEntry = _entryForDay(todayDayOfYear);
    final currentNote = _futureNotes[currentEntry.dayOfYear];

    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFFF3EEE4), Color(0xFFD8C8AF)],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: Stack(
          children: [
            Positioned.fill(child: CustomPaint(painter: _GridPaperPainter())),
            const Positioned.fill(
              child: IgnorePointer(child: _AmbientLightLayer()),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: _DeskPaperBallLayer(balls: _deskBalls),
              ),
            ),
            SafeArea(
              child: AnimatedOpacity(
                opacity: _isReady ? 1 : 0.6,
                duration: const Duration(milliseconds: 300),
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(20, isCompact ? 14 : 24, 20, 24),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1120),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _IntroBlock(),
                          SizedBox(height: isCompact ? 14 : 24),
                          if (isCompact)
                            Column(
                              children: [
                                _buildScene(
                                  currentEntry,
                                  thickness,
                                  isAheadOfToday: isAheadOfToday,
                                  todayEntry: todayEntry,
                                  note: currentNote,
                                ),
                                const SizedBox(height: 20),
                                _buildStatusPanel(
                                  tornPages: tornPages,
                                  lifeDayCount: lifeDayCount,
                                  lifeDaysRemaining: lifeDaysRemaining,
                                  isAheadOfToday: isAheadOfToday,
                                ),
                              ],
                            )
                          else
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  flex: 12,
                                  child: _buildScene(
                                    currentEntry,
                                    thickness,
                                    isAheadOfToday: isAheadOfToday,
                                    todayEntry: todayEntry,
                                    note: currentNote,
                                  ),
                                ),
                                const SizedBox(width: 28),
                                Expanded(
                                  flex: 7,
                                  child: _buildStatusPanel(
                                    tornPages: tornPages,
                                    lifeDayCount: lifeDayCount,
                                    lifeDaysRemaining: lifeDaysRemaining,
                                    isAheadOfToday: isAheadOfToday,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (_animatingDay != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _tearController,
                    builder: (context, child) {
                      return _FullScreenImpactOverlay(
                        progress: _tearController.value,
                        seed: _animatingDay!,
                      );
                    },
                  ),
                ),
              ),
            IgnorePointer(
              ignoring: _hideOpeningVeil,
              child: AnimatedOpacity(
                opacity: _hideOpeningVeil ? 0 : 1,
                duration: const Duration(milliseconds: 900),
                child: const _OpeningVeil(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScene(
    CalendarEntry currentEntry,
    ThicknessPresentation thickness, {
    required bool isAheadOfToday,
    required CalendarEntry todayEntry,
    required String? note,
  }) {
    final compact = MediaQuery.sizeOf(context).width < 700;
    final dragAmount = (_dragOffset.distance / 42).clamp(0.0, 1.0);
    final liftAmount = (_dragOffset.dx > 0 || _dragOffset.dy < 0)
        ? ((_dragOffset.dx * 0.026) + (-_dragOffset.dy * 0.038)).clamp(0.0, 1.0)
        : 0.0;
    final shouldShowGestureHint =
        !_showDayReleasedHint &&
        !isAheadOfToday &&
        _animatingDay == null &&
        !_isCatchingUp;
    final nudgeValue = shouldShowGestureHint
        ? Curves.easeInOut.transform(_gestureNudgeController.value)
        : 0.5;
    final idleNudgeX = shouldShowGestureHint
        ? lerpDouble(-4, 6, nudgeValue)!
        : 0.0;
    final idleNudgeY = shouldShowGestureHint
        ? lerpDouble(1.5, -2.5, nudgeValue)!
        : 0.0;
    final idleNudgeTilt = shouldShowGestureHint
        ? lerpDouble(-0.005, 0.009, nudgeValue)!
        : 0.0;
    final dragTilt = (_dragOffset.dx * 0.0022) + (_dragOffset.dy * 0.0005);
    final liftRotateX = lerpDouble(0, 0.24, liftAmount)!;
    final liftRotateY = lerpDouble(0, -0.14, liftAmount)!;
    final dragScale = 1 - dragAmount * 0.012;
    final stackScaleY = _isCompressing
        ? 0.975
        : _isRebounding
        ? 1.012
        : 1.0;
    final stackYOffset = _isCompressing
        ? 10.0
        : _isRebounding
        ? -4.0
        : 0.0;

    return _GlassPanel(
      borderRadius: 34,
      padding: EdgeInsets.all(compact ? 22 : 28),
      child: SizedBox(
        height: compact ? 640 : 700,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              left: 0,
              right: 0,
              top: compact ? 392 : 438,
              child: Center(
                child: Container(
                  width: 420,
                  height: 88,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    gradient: const RadialGradient(
                      colors: [Color(0x364B321C), Colors.transparent],
                      radius: 0.9,
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: compact ? 406 : 452,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 320),
                  curve: Curves.easeOutCubic,
                  width: 392,
                  height: math.max(10, thickness.depth).toDouble(),
                  decoration: BoxDecoration(
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(18),
                    ),
                    gradient: const LinearGradient(
                      colors: [Color(0xFFF4EAD6), Color(0xFFE5D8BF)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0x154D351D),
                        blurRadius: 10,
                        offset: Offset(0, math.max(6, thickness.depth * 0.18)),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: compact ? 16 : 36,
              child: Center(
                child: Transform.translate(
                  offset: Offset(
                    _dragOffset.dx * 0.72 + idleNudgeX,
                    stackYOffset + _dragOffset.dy * 0.68 + idleNudgeY,
                  ),
                  child: Transform.rotate(
                    angle: dragTilt + idleNudgeTilt,
                    child: Transform.scale(
                      scale: dragScale,
                      child: Transform(
                        alignment: Alignment.topCenter,
                        transform: Matrix4.identity()
                          ..setEntry(3, 2, 0.0011)
                          ..rotateX(liftRotateX)
                          ..rotateY(liftRotateY),
                        child: Transform.scale(
                          scaleY: stackScaleY - (_dragOffset.dy < 0 ? 0.01 : 0),
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanStart: _handlePanStart,
                            onPanUpdate: _handlePanUpdate,
                            onPanEnd: _handlePanEnd,
                            onPanCancel: () {
                              setState(() {
                                _dragOffset = Offset.zero;
                                _showDragResistanceHint = false;
                              });
                            },
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              width: 400,
                              height: 520,
                              child: Stack(
                                clipBehavior: Clip.none,
                                children: [
                                  if (isAheadOfToday &&
                                      _animatingDay == null &&
                                      !_isCatchingUp)
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      top: -30,
                                      child: Center(
                                        child: _TodayDateBadge(
                                          entry: todayEntry,
                                        ),
                                      ),
                                    ),
                                  _CalendarPaperCard(
                                    entry: currentEntry,
                                    note: note,
                                    liftAmount: liftAmount,
                                  ),
                                  if (dragAmount > 0.08 &&
                                      _animatingDay == null)
                                    Positioned(
                                      left: 24,
                                      right: 24,
                                      bottom: 18,
                                      child: Opacity(
                                        opacity: 0.18 + dragAmount * 0.16,
                                        child: Container(
                                          height: 26,
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                            gradient: const RadialGradient(
                                              colors: [
                                                Color(0x384A301A),
                                                Color(0x004A301A),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (liftAmount > 0.46 &&
                                      _animatingDay == null)
                                    Positioned(
                                      left: 64,
                                      right: 64,
                                      top: 48,
                                      child: Opacity(
                                        opacity: lerpDouble(
                                          0.0,
                                          0.5,
                                          ((liftAmount - 0.46) / 0.54).clamp(
                                            0.0,
                                            1.0,
                                          ),
                                        )!,
                                        child: Container(
                                          height: 6,
                                          decoration: BoxDecoration(
                                            borderRadius: BorderRadius.circular(
                                              999,
                                            ),
                                            gradient: const LinearGradient(
                                              colors: [
                                                Color(0x00B65A33),
                                                Color(0x30D19A63),
                                                Color(0x00B65A33),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (_showDragResistanceHint &&
                                      _animatingDay == null &&
                                      !_isCatchingUp)
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      top: 98,
                                      child: Center(
                                        child: _DragResistanceBadge(
                                          isFuturePage: isAheadOfToday,
                                        ),
                                      ),
                                    ),
                                  if (_animatingDay == null && !_isCatchingUp)
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      top: 578,
                                      child: Center(
                                        child:
                                            _showDayReleasedHint &&
                                                !isAheadOfToday
                                            ? const _DayReleasedHint()
                                            : _GestureHint(
                                                progress:
                                                    _gestureNudgeController
                                                        .value,
                                                label: isAheadOfToday
                                                    ? '这一天还没到'
                                                    : '轻轻撕掉这一页',
                                              ),
                                      ),
                                    ),
                                  if (_animatingDay != null)
                                    Positioned.fill(
                                      child: AnimatedBuilder(
                                        animation: _tearController,
                                        builder: (context, child) {
                                          return _AnimatedTearLayer(
                                            progress: _tearController.value,
                                            entry: _entryForDay(_animatingDay!),
                                            lifeDayCount: _dayToLifeCount(
                                              _animatingDay!,
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusPanel({
    required int tornPages,
    required int lifeDayCount,
    required int lifeDaysRemaining,
    required bool isAheadOfToday,
  }) {
    final progress = tornPages / _daysInYear;
    return _GlassPanel(
      borderRadius: 28,
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: SizedBox(
              height: _showLifeSettings ? null : _statusCoreCardHeight,
              child: _LifeCountdownCard(
                lifeDaysRemaining: lifeDaysRemaining,
                lifeDayCount: lifeDayCount,
                companionText: _dailyCompanionText(
                  isAheadOfToday: isAheadOfToday,
                ),
                birthday: _birthday,
                expectedAge: _expectedAge,
                showSettings: _showLifeSettings,
                onToggleSettings: () {
                  setState(() => _showLifeSettings = !_showLifeSettings);
                },
                onPickBirthday: _pickBirthday,
                onDecreaseAge: () => _adjustExpectedAge(-1),
                onIncreaseAge: () => _adjustExpectedAge(1),
              ),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: _statusCoreCardHeight,
            child: _ProgressStatusBlock(
              label: '${_today.year} 已经过去',
              headline: '$tornPages / $_daysInYear',
              progress: progress,
              trailing: '${(progress * 100).toStringAsFixed(1)}%',
              footnote: '时间正被一页页撕掉',
            ),
          ),
          const SizedBox(height: 14),
          _FutureNoteCard(onCompose: _composeFutureNote),
          if (kIsWeb) ...[
            const SizedBox(height: 10),
            const Text(
              '电脑端可固定标签页，或在 Chrome / Edge 中安装到桌面。',
              style: TextStyle(
                fontSize: 11,
                height: 1.55,
                color: Color(0x72241A12),
              ),
            ),
          ],
          const SizedBox(height: 14),
          InkWell(
            onTap: () {
              setState(() => _showDebugActions = !_showDebugActions);
            },
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  const Text(
                    '测试入口',
                    style: TextStyle(fontSize: 11, color: Color(0x5A241A12)),
                  ),
                  const Spacer(),
                  Icon(
                    _showDebugActions
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 14,
                    color: const Color(0x5A241A12),
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 180),
            crossFadeState: _showDebugActions
                ? CrossFadeState.showFirst
                : CrossFadeState.showSecond,
            firstChild: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isCatchingUp
                          ? null
                          : () => _simulateAbsence(3),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        side: const BorderSide(color: Color(0x14452D19)),
                        foregroundColor: const Color(0xAA241A12),
                        backgroundColor: const Color(0xA6FFF8EE),
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                      child: const Text('模拟缺席 3 天'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _isCatchingUp ? null : _resetToToday,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        side: const BorderSide(color: Color(0x14452D19)),
                        foregroundColor: const Color(0xAA241A12),
                        backgroundColor: const Color(0xA6FFF8EE),
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                      child: const Text('重置今年'),
                    ),
                  ),
                ],
              ),
            ),
            secondChild: const SizedBox.shrink(),
          ),
          const SizedBox(height: 12),
          Text(
            _hintText,
            style: const TextStyle(
              color: Color(0x8C241A12),
              fontSize: 13,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }

  CalendarEntry _entryForDay(int dayOfYear) {
    final date = DateTime(_today.year, 1, dayOfYear);
    const weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return CalendarEntry(
      year: date.year,
      month: date.month,
      day: date.day,
      weekday: weekdays[date.weekday - 1],
      dayOfYear: dayOfYear,
    );
  }

  ThicknessPresentation _getThicknessPresentation({
    required int remainingPages,
    required int tornPages,
    required int daysInYear,
  }) {
    final ratio = remainingPages / daysInYear;
    final amplified = math.pow(ratio, 0.62).toDouble();
    final baseDepth = math.max(6, (amplified * 74).round());

    if (remainingPages > 300) {
      return ThicknessPresentation(depth: baseDepth + 10, label: '还是厚厚一本');
    }
    if (remainingPages > 200) {
      return ThicknessPresentation(depth: baseDepth + 8, label: '明显还很有分量');
    }
    if (remainingPages > 100) {
      return ThicknessPresentation(depth: baseDepth + 5, label: '开始轻下来了');
    }
    if (remainingPages > 30) {
      return ThicknessPresentation(
        depth: math.max(14, baseDepth),
        label: '只剩一小叠了',
      );
    }
    if (remainingPages > 7) {
      return ThicknessPresentation(
        depth: math.max(9, baseDepth - 4),
        label: '已经薄得很明显',
      );
    }
    return ThicknessPresentation(
      depth: math.max(5, baseDepth - 8),
      label: '最后几页，薄得发轻',
    );
  }

  int _dayToLifeCount(int dayOfYear) {
    final date = DateTime(_today.year, 1, dayOfYear);
    return date.difference(_birthday).inDays + 1;
  }

  DateTime? _birthdayFromState(CalendarPersistedState? state) {
    if (state?.birthYear == null ||
        state?.birthMonth == null ||
        state?.birthDay == null) {
      return null;
    }
    return DateTime(state!.birthYear!, state.birthMonth!, state.birthDay!);
  }

  String _dailyCompanionText({required bool isAheadOfToday}) {
    if (isAheadOfToday) {
      return '你走在时间前面了，慢一点也没关系。';
    }
    if (_isCatchingUp) {
      return '错过的日子会回到你眼前，今天还在这里。';
    }
    return '慢一点，也没关系。今天只需要好好看见它。';
  }
}

class CalendarEntry {
  const CalendarEntry({
    required this.year,
    required this.month,
    required this.day,
    required this.weekday,
    required this.dayOfYear,
  });

  final int year;
  final int month;
  final int day;
  final String weekday;
  final int dayOfYear;
}

class ThicknessPresentation {
  const ThicknessPresentation({required this.depth, required this.label});

  final int depth;
  final String label;
}

class DeskPaperBall {
  const DeskPaperBall({
    required this.seed,
    required this.x,
    required this.y,
    required this.scale,
    required this.rotation,
  });

  final int seed;
  final double x;
  final double y;
  final double scale;
  final double rotation;
}

class _IntroBlock extends StatelessWidget {
  const _IntroBlock();

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 700;
    final titleSize = compact ? 18.0 : 68.0;
    final bodySize = compact ? 15.0 : 20.0;
    final logoSize = compact ? 42.0 : 56.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _SeeDaysLogoMark(size: logoSize),
            SizedBox(width: compact ? 10 : 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SEE DAYS',
                  style: const TextStyle(
                    fontSize: 12,
                    letterSpacing: 4,
                    color: Color(0xAA241A12),
                  ),
                ),
                if (!compact) ...[
                  const SizedBox(height: 4),
                  const Text(
                    'Every day is a page.',
                    style: TextStyle(
                      fontSize: 13,
                      letterSpacing: 0.2,
                      color: Color(0x8C241A12),
                    ),
                  ),
                ] else
                  const Text(
                    'Today, in your hands.',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 0.1,
                      color: Color(0x8C241A12),
                    ),
                  ),
              ],
            ),
          ],
        ),
        SizedBox(height: compact ? 10 : 12),
        if (!compact)
          Text(
            'See Days',
            style: TextStyle(
              fontSize: titleSize,
              height: 0.95,
              fontWeight: FontWeight.w700,
              color: const Color(0xFF241A12),
            ),
          ),
        if (!compact) const SizedBox(height: 16),
        Text(
          compact ? '每一天都是被撕掉的一页人生' : '每一天都是被撕掉的一页人生，记得每天来撕掉你的昨天',
          style: TextStyle(
            fontSize: bodySize,
            height: compact ? 1.42 : 1.7,
            color: const Color(0xAA241A12),
          ),
        ),
        if (!compact) ...[
          const SizedBox(height: 10),
          const Text(
            'Tear yesterday.\nSee today.',
            style: TextStyle(
              fontSize: 15,
              height: 1.6,
              color: Color(0x8C241A12),
            ),
          ),
        ],
      ],
    );
  }
}

class _OpeningVeil extends StatelessWidget {
  const _OpeningVeil();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFFF3EEE4), Color(0xFFD8C8AF)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: const [
            _SeeDaysLogoMark(size: 72),
            SizedBox(height: 18),
            Text(
              'SEE DAYS',
              style: TextStyle(
                fontSize: 12,
                letterSpacing: 5,
                color: Color(0xAA241A12),
              ),
            ),
            SizedBox(height: 10),
            Text(
              'Every day is a page.',
              style: TextStyle(
                fontSize: 34,
                fontWeight: FontWeight.w600,
                color: Color(0xFF241A12),
              ),
            ),
            SizedBox(height: 8),
            Text(
              'Tear yesterday. See today.',
              style: TextStyle(fontSize: 16, color: Color(0x8C241A12)),
            ),
          ],
        ),
      ),
    );
  }
}

class _SeeDaysLogoMark extends StatelessWidget {
  const _SeeDaysLogoMark({this.size = 56});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size * 0.22),
          gradient: const LinearGradient(
            colors: [Color(0xFFFFFAF0), Color(0xFFF3EBDD)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          border: Border.all(color: const Color(0x22452D19)),
        ),
        child: Stack(
          children: [
            Positioned(
              left: size * 0.44,
              top: size * 0.08,
              bottom: size * 0.08,
              child: Transform.rotate(
                angle: -0.12,
                child: Transform.translate(
                  offset: Offset(size * -0.02, 0),
                  child: Container(
                    width: size * 0.08,
                    decoration: BoxDecoration(
                      color: const Color(0xFFB65A33),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              left: size * 0.16,
              top: size * 0.16,
              child: Text(
                'S',
                style: TextStyle(
                  color: const Color(0xFF241A12),
                  fontSize: size * 0.28,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
            ),
            Positioned(
              right: size * 0.14,
              bottom: size * 0.12,
              child: Text(
                'D',
                style: TextStyle(
                  color: const Color(0xFF241A12),
                  fontSize: size * 0.28,
                  fontWeight: FontWeight.w700,
                  height: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({
    required this.child,
    required this.borderRadius,
    required this.padding,
  });

  final Widget child;
  final double borderRadius;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0x88FFFBF5),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(color: const Color(0x16452D19)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x153F2917),
                blurRadius: 52,
                offset: Offset(0, 16),
              ),
            ],
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class _AmbientLightLayer extends StatelessWidget {
  const _AmbientLightLayer();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned(
          left: -120,
          top: -80,
          child: Container(
            width: 320,
            height: 320,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [Color(0x40FFF7E8), Color(0x00FFF7E8)],
              ),
            ),
          ),
        ),
        Positioned(
          right: -80,
          top: 180,
          child: Container(
            width: 260,
            height: 260,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [Color(0x20FFFFFF), Color(0x00FFFFFF)],
              ),
            ),
          ),
        ),
        Positioned(
          left: 80,
          right: 80,
          bottom: -120,
          child: Container(
            height: 260,
            decoration: const BoxDecoration(
              gradient: RadialGradient(
                colors: [Color(0x12D3B98E), Color(0x00D3B98E)],
                center: Alignment.topCenter,
                radius: 1.15,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DeskPaperBallLayer extends StatelessWidget {
  const _DeskPaperBallLayer({required this.balls});

  final List<DeskPaperBall> balls;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    return Stack(
      children: [
        for (final ball in balls)
          Positioned(
            left: viewport.width * ball.x,
            top: viewport.height * ball.y,
            child: Transform.rotate(
              angle: ball.rotation,
              child: Transform.scale(
                scale: ball.scale,
                child: Opacity(
                  opacity: 0.88,
                  child: _PaperBallView(
                    size: 54,
                    seed: ball.seed,
                    mode: PaperBallRenderMode.compact,
                    detailStrength: 0.42,
                    shadowOpacity: 0.78,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _PaperBallView extends StatelessWidget {
  const _PaperBallView({
    required this.size,
    required this.seed,
    this.mode = PaperBallRenderMode.detailed,
    this.detailStrength = 1,
    this.shadowOpacity = 1,
  });

  final double size;
  final int seed;
  final PaperBallRenderMode mode;
  final double detailStrength;
  final double shadowOpacity;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: size * 0.06,
            right: size * 0.06,
            bottom: -size * 0.12,
            child: Container(
              height: size * 0.18,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                gradient: RadialGradient(
                  colors: [
                    const Color(
                      0x283D2C1C,
                    ).withValues(alpha: 0.16 * shadowOpacity),
                    Colors.transparent,
                  ],
                  radius: 0.86,
                ),
              ),
            ),
          ),
          ClipPath(
            clipper: _PaperBallClipper(seed: seed),
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: mode == PaperBallRenderMode.detailed
                    ? const RadialGradient(
                        colors: [
                          Color(0xFFFFFFFF),
                          Color(0xFFFDFCFA),
                          Color(0xFFF3F0E8),
                          Color(0xFFE2DDD3),
                        ],
                        stops: [0, 0.34, 0.72, 1],
                        center: Alignment(-0.22, -0.28),
                        radius: 1.06,
                      )
                    : const RadialGradient(
                        colors: [
                          Color(0xFFFFFFFF),
                          Color(0xFFF8F7F2),
                          Color(0xFFECE8DE),
                        ],
                        center: Alignment(-0.16, -0.24),
                        radius: 1.02,
                      ),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x22453022),
                    blurRadius: 18,
                    offset: Offset(0, 9),
                  ),
                ],
              ),
              child: CustomPaint(
                painter: mode == PaperBallRenderMode.detailed
                    ? _PaperBallDetailedPainter(
                        seed: seed,
                        detailStrength: detailStrength,
                      )
                    : _PaperBallPainter(
                        seed: seed,
                        detailStrength: detailStrength,
                      ),
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

enum PaperBallRenderMode { compact, detailed }

class _PaperBallClipper extends CustomClipper<Path> {
  const _PaperBallClipper({required this.seed});

  final int seed;

  @override
  Path getClip(Size size) {
    final random = math.Random(seed * 59);
    final points = <Offset>[];
    const count = 22;
    final center = Offset(size.width / 2, size.height / 2);
    final baseRadiusX = size.width * 0.4;
    final baseRadiusY = size.height * 0.37;

    for (var i = 0; i < count; i++) {
      final angle = (math.pi * 2 / count) * i;
      final pinch = i.isEven
          ? 0.84 + random.nextDouble() * 0.18
          : 0.72 + random.nextDouble() * 0.26;
      final radiusX = baseRadiusX * pinch;
      final radiusY = baseRadiusY * (0.8 + random.nextDouble() * 0.22);
      points.add(
        Offset(
          center.dx + math.cos(angle) * radiusX,
          center.dy + math.sin(angle) * radiusY,
        ),
      );
    }

    final path = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 0; i < points.length; i++) {
      final current = points[i];
      final next = points[(i + 1) % points.length];
      final mid = Offset(
        (current.dx + next.dx) / 2,
        (current.dy + next.dy) / 2,
      );
      path.quadraticBezierTo(current.dx, current.dy, mid.dx, mid.dy);
    }
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant _PaperBallClipper oldDelegate) {
    return oldDelegate.seed != seed;
  }
}

class _ProgressStatusBlock extends StatelessWidget {
  const _ProgressStatusBlock({
    required this.label,
    required this.headline,
    required this.progress,
    required this.trailing,
    this.footnote,
  });

  final String label;
  final String headline;
  final double progress;
  final String trailing;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final clampedProgress = progress.clamp(0.0, 1.0);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xBFFFFAF3),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0x12452D19)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 14, color: Color(0xAA241A12)),
            ),
            const SizedBox(height: 8),
            Text(
              headline,
              style: const TextStyle(
                fontSize: 20,
                height: 1.35,
                fontWeight: FontWeight.w700,
                color: Color(0xFF241A12),
              ),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Container(
                height: 14,
                color: const Color(0x14B65A33),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FractionallySizedBox(
                    widthFactor: clampedProgress,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        gradient: const LinearGradient(
                          colors: [Color(0xFFCC7B48), Color(0xFFB65A33)],
                        ),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  footnote ?? '',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Color(0x8C241A12),
                  ),
                ),
                Text(
                  trailing,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF8E4529),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FutureNoteCard extends StatelessWidget {
  const _FutureNoteCard({required this.onCompose});

  final VoidCallback onCompose;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xBFFFFAF3),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0x12452D19)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 17, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '留一句话给未来',
              style: TextStyle(fontSize: 13, color: Color(0x9C241A12)),
            ),
            const SizedBox(height: 8),
            Text(
              '挑未来某一天，留一句话等它到来。',
              style: const TextStyle(
                fontSize: 12,
                height: 1.55,
                color: Color(0x8A241A12),
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: onCompose,
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  side: const BorderSide(color: Color(0x18452D19)),
                  foregroundColor: const Color(0xD6241A12),
                  backgroundColor: const Color(0xCCFFF8EE),
                  textStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  elevation: 0,
                ),
                child: const Text('写给未来的一天'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LifeCountdownCard extends StatelessWidget {
  const _LifeCountdownCard({
    required this.lifeDaysRemaining,
    required this.lifeDayCount,
    required this.companionText,
    required this.birthday,
    required this.expectedAge,
    required this.showSettings,
    required this.onToggleSettings,
    required this.onPickBirthday,
    required this.onDecreaseAge,
    required this.onIncreaseAge,
  });

  final int lifeDaysRemaining;
  final int lifeDayCount;
  final String companionText;
  final DateTime birthday;
  final int expectedAge;
  final bool showSettings;
  final VoidCallback onToggleSettings;
  final VoidCallback onPickBirthday;
  final VoidCallback onDecreaseAge;
  final VoidCallback onIncreaseAge;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xBFFFFAF3),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0x12452D19)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '人生剩余',
              style: TextStyle(fontSize: 14, color: Color(0xAA241A12)),
            ),
            const SizedBox(height: 8),
            Text(
              '大约还有 ${_formatCount(lifeDaysRemaining)} 天',
              style: const TextStyle(
                fontSize: 30,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: Color(0xFF241A12),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '今天是你人生的第 ${_formatCount(lifeDayCount)} 天',
              style: const TextStyle(
                fontSize: 12,
                height: 1.55,
                color: Color(0x99241A12),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              companionText,
              style: const TextStyle(
                fontSize: 13,
                height: 1.6,
                color: Color(0xA6241A12),
              ),
            ),
            const SizedBox(height: 10),
            InkWell(
              onTap: onToggleSettings,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Text(
                      showSettings ? '收起我的人生设置' : '我的人生设置',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Color(0x8C241A12),
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      showSettings
                          ? Icons.keyboard_arrow_up
                          : Icons.keyboard_arrow_down,
                      size: 18,
                      color: const Color(0x8C241A12),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedCrossFade(
              duration: const Duration(milliseconds: 220),
              crossFadeState: showSettings
                  ? CrossFadeState.showFirst
                  : CrossFadeState.showSecond,
              firstChild: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    OutlinedButton(
                      onPressed: onPickBirthday,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 14,
                        ),
                        side: const BorderSide(color: Color(0x22452D19)),
                        foregroundColor: const Color(0xFF241A12),
                        backgroundColor: const Color(0xF2FFF8EE),
                        textStyle: const TextStyle(fontSize: 13),
                      ),
                      child: Text(
                        '出生 ${birthday.year}.${birthday.month}.${birthday.day}',
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        const Text(
                          '我想活到',
                          style: TextStyle(
                            fontSize: 13,
                            color: Color(0xAA241A12),
                          ),
                        ),
                        const SizedBox(width: 12),
                        IconButton.outlined(
                          onPressed: onDecreaseAge,
                          icon: const Icon(Icons.remove, size: 18),
                          color: const Color(0xFF241A12),
                          visualDensity: VisualDensity.compact,
                        ),
                        SizedBox(
                          width: 58,
                          child: Text(
                            '$expectedAge 岁',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFF241A12),
                            ),
                          ),
                        ),
                        IconButton.outlined(
                          onPressed: onIncreaseAge,
                          icon: const Icon(Icons.add, size: 18),
                          color: const Color(0xFF241A12),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              secondChild: const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

class _CalendarPaperCard extends StatelessWidget {
  const _CalendarPaperCard({
    required this.entry,
    this.note,
    this.liftAmount = 0,
  });

  final CalendarEntry entry;
  final String? note;
  final double liftAmount;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [Color(0xFFFBF6EC), Color(0xFFF7F1E3)],
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
        ),
        boxShadow: const [
          BoxShadow(
            color: Color(0x2955391F),
            blurRadius: 30,
            offset: Offset(0, 14),
          ),
        ],
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _PaperSurfacePainter(seed: entry.dayOfYear),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                gradient: const LinearGradient(
                  colors: [Color(0x16FFFFFF), Color(0x00FFFFFF)],
                  begin: Alignment.topCenter,
                  end: Alignment.center,
                ),
              ),
            ),
          ),
          if (liftAmount > 0.02)
            Positioned(
              left: 18,
              right: 18,
              top: 54,
              child: Opacity(
                opacity: lerpDouble(0.0, 0.34, liftAmount)!,
                child: Container(
                  height: lerpDouble(10, 22, liftAmount)!,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    gradient: const LinearGradient(
                      colors: [Color(0x24F0D9B1), Color(0x00F0D9B1)],
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                    ),
                  ),
                ),
              ),
            ),
          if (liftAmount > 0.04)
            Positioned(
              left: 26,
              right: 26,
              bottom: 18,
              child: Opacity(
                opacity: lerpDouble(0.0, 0.22, liftAmount)!,
                child: Container(
                  height: lerpDouble(14, 30, liftAmount)!,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    gradient: const RadialGradient(
                      colors: [Color(0x38432D19), Color(0x00432D19)],
                    ),
                  ),
                ),
              ),
            ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0x10BFAE8C)),
                gradient: const LinearGradient(
                  colors: [
                    Color(0x10FFFFFF),
                    Color(0x00FFFFFF),
                    Color(0x12D9CCB6),
                  ],
                  stops: [0, 0.42, 1],
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                ),
              ),
            ),
          ),
          if (entry.dayOfYear > 1)
            Positioned(
              left: 18,
              right: 18,
              top: 34,
              child: SizedBox(
                height: 24,
                child: CustomPaint(
                  painter: _TearResiduePainter(seed: entry.dayOfYear),
                ),
              ),
            ),
          const Positioned(top: 20, left: 26, child: _PaperHole()),
          const Positioned(top: 20, right: 26, child: _PaperHole()),
          Padding(
            padding: const EdgeInsets.fromLTRB(32, 28, 32, 30),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      entry.weekday,
                      style: const TextStyle(
                        fontSize: 14,
                        letterSpacing: 0.6,
                        color: Color(0xAA241A12),
                      ),
                    ),
                    Text(
                      '第 ${entry.dayOfYear} 天',
                      style: const TextStyle(
                        fontSize: 14,
                        letterSpacing: 0.6,
                        color: Color(0xAA241A12),
                      ),
                    ),
                  ],
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${entry.month} 月',
                        style: const TextStyle(
                          fontSize: 48,
                          color: Color(0xFF241A12),
                        ),
                      ),
                      Text(
                        entry.day.toString().padLeft(2, '0'),
                        style: const TextStyle(
                          fontSize: 164,
                          height: 0.92,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF241A12),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${entry.year} 年 ${entry.month} 月 ${entry.day} 日',
                        style: const TextStyle(
                          fontSize: 22,
                          color: Color(0xAA241A12),
                        ),
                      ),
                      if (note != null && note!.isNotEmpty) ...[
                        const SizedBox(height: 28),
                        DecoratedBox(
                          decoration: BoxDecoration(
                            color: const Color(0x80FFF8EE),
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(color: const Color(0x16452D19)),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '这一天留下的话',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    letterSpacing: 1.2,
                                    color: Color(0x7A241A12),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  note!,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    height: 1.55,
                                    color: Color(0xD9241A12),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '今年已过去 ${entry.dayOfYear - 1} 天',
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xAA241A12),
                      ),
                    ),
                    Text(
                      '还剩 ${_getDaysInYear(entry.year) - entry.dayOfYear} 天',
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xAA241A12),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _AnimatedTearLayer extends StatelessWidget {
  const _AnimatedTearLayer({
    required this.progress,
    required this.entry,
    required this.lifeDayCount,
  });

  final double progress;
  final CalendarEntry entry;
  final int lifeDayCount;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final slamX = math.max(220.0, viewport.width * 0.18);
    final slamY = math.max(42.0, viewport.height * 0.05);
    final handoffLift = ((0.26 - progress) / 0.26).clamp(0.0, 1.0);
    final offsetX = _multiStage(progress, [0, 0, 3, 8, 16, 34, 176, slamX]);
    final offsetY = _multiStage(progress, [
      0,
      -1,
      -6,
      -16,
      -30,
      -24,
      -10,
      slamY,
    ]);
    final rotation = _multiStage(progress, [0, -0.2, 0.8, 2, 4, 8, 220, 940]);
    final scale = _multiStage(progress, const [
      1,
      1.001,
      1.002,
      0.998,
      0.985,
      0.94,
      0.42,
      4.6,
    ]);
    final handoffRotateX = lerpDouble(0.24, 0.0, 1 - handoffLift)!;
    final handoffRotateY = lerpDouble(-0.12, 0.0, 1 - handoffLift)!;
    final radius = _multiStage(progress, const [20, 20, 22, 26, 42, 84, 999]);
    final opacity = progress < 0.96
        ? 1.0
        : lerpDouble(1, 0.04, (progress - 0.96) / 0.04)!.clamp(0.0, 1.0);
    final blur = _multiStage(progress, const [
      0,
      0,
      0.08,
      0.18,
      0.5,
      1.3,
      2.4,
      1.2,
    ]);
    final shadowOpacity = progress < 0.54
        ? 0.0
        : lerpDouble(0, 0.28, ((progress - 0.54) / 0.46).clamp(0.0, 1.0))!;
    final crumpleProgress = ((progress - 0.54) / 0.46).clamp(0.0, 1.0);
    final showPaperBall = progress > 0.58;
    final paperOpacity = progress < 0.56
        ? opacity
        : lerpDouble(opacity, 0.0, ((progress - 0.56) / 0.12).clamp(0.0, 1.0))!;
    final ballSize = _multiStage(progress, const [0, 0, 0, 0, 18, 42, 56, 68]);
    final trailWidth = _multiStage(progress, const [
      0,
      0,
      0,
      0,
      0,
      36,
      112,
      76,
    ]);
    final trailOpacity = progress < 0.68
        ? 0.0
        : lerpDouble(0, 0.18, ((progress - 0.68) / 0.14).clamp(0.0, 1.0))!;
    final dayGonePhase = ((progress - 0.22) / 0.26).clamp(0.0, 1.0);
    final dayGoneOpacity = dayGonePhase <= 0
        ? 0.0
        : dayGonePhase < 0.2
        ? Curves.easeOut.transform((dayGonePhase / 0.2).clamp(0.0, 1.0))
        : dayGonePhase < 0.8
        ? 1.0
        : 1 -
              Curves.easeIn.transform(
                ((dayGonePhase - 0.8) / 0.2).clamp(0.0, 1.0),
              );
    return Transform.translate(
      offset: Offset(offsetX, offsetY),
      child: Transform.rotate(
        angle: rotation * math.pi / 180,
        child: Transform(
          alignment: Alignment.topCenter,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0011)
            ..rotateX(handoffRotateX)
            ..rotateY(handoffRotateY),
          child: Transform.scale(
            scale: scale,
            child: SizedBox(
              width: 400,
              height: 520,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (progress > 0.42)
                    Positioned(
                      left: 54,
                      top: 364,
                      child: Transform.rotate(
                        angle: rotation * math.pi / 180 * 0.22,
                        child: Container(
                          width: _multiStage(progress, const [
                            0,
                            0,
                            18,
                            46,
                            70,
                            94,
                          ]),
                          height: _multiStage(progress, const [
                            0,
                            0,
                            8,
                            18,
                            26,
                            32,
                          ]),
                          decoration: BoxDecoration(
                            color: Color(
                              0xFF4A301A,
                            ).withValues(alpha: shadowOpacity),
                            borderRadius: BorderRadius.circular(999),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(
                                  0xFF4A301A,
                                ).withValues(alpha: shadowOpacity * 0.5),
                                blurRadius: 18,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (dayGoneOpacity > 0)
                    Positioned(
                      left: 36,
                      right: 36,
                      top: 110,
                      child: Opacity(
                        opacity: dayGoneOpacity,
                        child: Transform.translate(
                          offset: Offset(0, lerpDouble(16, 0, dayGoneOpacity)!),
                          child: Transform.scale(
                            scale: lerpDouble(0.94, 1.0, dayGoneOpacity)!,
                            child: _DayGoneBadge(lifeDayCount: lifeDayCount),
                          ),
                        ),
                      ),
                    ),
                  if (trailOpacity > 0)
                    Positioned(
                      left: -trailWidth * 0.72,
                      top: 220,
                      child: Opacity(
                        opacity: trailOpacity,
                        child: Container(
                          width: trailWidth,
                          height: 14,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            gradient: LinearGradient(
                              colors: [
                                const Color(0x00FFF5E5),
                                const Color(0x3AFFF5E5),
                                const Color(0x80F5E8D2),
                              ],
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                            ),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x26FFF5E5),
                                blurRadius: 16,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  Opacity(
                    opacity: paperOpacity,
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                      child: ClipPath(
                        clipper: _PaperTearClipper(progress),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(radius),
                          ),
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: _CalendarPaperCard(entry: entry),
                              ),
                              if (progress > 0.18)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 54,
                                  child: Container(
                                    height: 56,
                                    decoration: const BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          Colors.transparent,
                                          Color(0x12B64F2A),
                                          Colors.transparent,
                                        ],
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (showPaperBall)
                    Positioned(
                      left: lerpDouble(182, 170, crumpleProgress)!,
                      top: lerpDouble(208, 188, crumpleProgress)!,
                      child: Transform.rotate(
                        angle: rotation * math.pi / 180 * 0.28,
                        child: Opacity(
                          opacity: 0.88 + crumpleProgress * 0.12,
                          child: _PaperBallView(
                            size: ballSize,
                            seed: entry.dayOfYear,
                            mode: PaperBallRenderMode.detailed,
                            detailStrength: 0.34,
                            shadowOpacity: 0.92,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DayGoneBadge extends StatelessWidget {
  const _DayGoneBadge({required this.lifeDayCount});

  final int lifeDayCount;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xECFFF8EE),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0x1E452D19)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x163B2618),
            blurRadius: 24,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'TIME PASSED',
              style: TextStyle(
                fontSize: 10,
                letterSpacing: 2.2,
                color: Color(0x7A241A12),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '人生过去了 ${_formatCount(lifeDayCount)} 天',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 22,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: Color(0xF2241A12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GestureHint extends StatelessWidget {
  const _GestureHint({required this.progress, required this.label});

  final double progress;
  final String label;

  @override
  Widget build(BuildContext context) {
    final eased = Curves.easeInOut.transform(progress);
    final offsetX = lerpDouble(-5, 7, eased)!;
    final textOpacity = lerpDouble(0.46, 0.68, eased)!;
    final chipOpacity = lerpDouble(0.52, 0.72, eased)!;

    return Transform.translate(
      offset: Offset(offsetX, 0),
      child: Opacity(
        opacity: chipOpacity,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: const Color(0xB8FFF8EE),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: const Color(0x12452D19)),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.arrow_upward_rounded,
                  size: 12,
                  color: const Color(0x8C241A12).withValues(alpha: textOpacity),
                ),
                const SizedBox(width: 4),
                Icon(
                  Icons.arrow_forward_rounded,
                  size: 12,
                  color: const Color(0x8C241A12).withValues(alpha: textOpacity),
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    color: const Color(
                      0x8C241A12,
                    ).withValues(alpha: textOpacity),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DragResistanceBadge extends StatelessWidget {
  const _DragResistanceBadge({required this.isFuturePage});

  final bool isFuturePage;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xEAFBF3E8),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x16452D19)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(
          isFuturePage ? '这一天还没到' : '今天还没结束',
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Color(0xB2241A12),
          ),
        ),
      ),
    );
  }
}

class _DayReleasedHint extends StatelessWidget {
  const _DayReleasedHint();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xCCFFF8EE),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x14452D19)),
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Text(
          '今天，被你提前放下了',
          style: TextStyle(fontSize: 12, color: Color(0x8C241A12)),
        ),
      ),
    );
  }
}

class _TodayDateBadge extends StatelessWidget {
  const _TodayDateBadge({required this.entry});

  final CalendarEntry entry;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xD8FFF8EE),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0x14452D19)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x10000000),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          '今天是 ${entry.month} 月 ${entry.day} 日，被你提前放下了。',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Color(0x9C241A12),
          ),
        ),
      ),
    );
  }
}

class _PaperTearClipper extends CustomClipper<Path> {
  const _PaperTearClipper(this.progress);

  final double progress;

  @override
  Path getClip(Size size) {
    if (progress < 0.28) {
      return Path()..addRRect(
        RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(20)),
      );
    }

    final points = progress < 0.58
        ? <Offset>[
            Offset(0, 0),
            Offset(size.width, 0),
            Offset(size.width, size.height * 0.82),
            Offset(size.width * 0.88, size.height * 0.89),
            Offset(size.width * 0.79, size.height * 0.84),
            Offset(size.width * 0.63, size.height * 0.94),
            Offset(size.width * 0.44, size.height * 0.86),
            Offset(size.width * 0.30, size.height * 0.95),
            Offset(size.width * 0.13, size.height * 0.90),
            Offset(0, size.height * 0.94),
          ]
        : progress < 0.82
        ? <Offset>[
            Offset(size.width * 0.08, size.height * 0.06),
            Offset(size.width * 0.96, size.height * 0.03),
            Offset(size.width * 0.97, size.height * 0.75),
            Offset(size.width * 0.83, size.height * 0.91),
            Offset(size.width * 0.65, size.height * 0.87),
            Offset(size.width * 0.51, size.height * 0.96),
            Offset(size.width * 0.28, size.height * 0.85),
            Offset(size.width * 0.09, size.height * 0.91),
          ]
        : <Offset>[
            Offset(size.width * 0.20, size.height * 0.18),
            Offset(size.width * 0.79, size.height * 0.14),
            Offset(size.width * 0.88, size.height * 0.75),
            Offset(size.width * 0.63, size.height * 0.90),
            Offset(size.width * 0.37, size.height * 0.84),
            Offset(size.width * 0.18, size.height * 0.72),
          ];

    return Path()..addPolygon(points, true);
  }

  @override
  bool shouldReclip(covariant _PaperTearClipper oldClipper) {
    return oldClipper.progress != progress;
  }
}

class _PaperHole extends StatelessWidget {
  const _PaperHole();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 12,
      height: 12,
      decoration: const BoxDecoration(
        color: Color(0xFFD9C7AB),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: Color(0x26472E16),
            blurRadius: 2,
            offset: Offset(0, 2),
          ),
        ],
      ),
    );
  }
}

class _TearResiduePainter extends CustomPainter {
  const _TearResiduePainter({required this.seed});

  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(seed * 17);
    final residuePath = Path()..moveTo(0, 2.4);
    final segments = 10;
    final step = size.width / segments;

    for (var index = 1; index <= segments; index++) {
      final x = step * index;
      final y = 2.4 + random.nextDouble() * 5.2;
      final previousX = step * (index - 0.5);
      final previousY = 2.2 + random.nextDouble() * 4.6;
      residuePath.quadraticBezierTo(previousX, previousY, x, y);
    }

    final shadowPaint = Paint()
      ..color = const Color(0x10452D19)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.4);
    final linePaint = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xCCF8EFD9), Color(0x66E7D2AE)],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(Offset.zero & size)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final edgePaint = Paint()
      ..color = const Color(0x1FD3BA91)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6;

    canvas.drawPath(residuePath.shift(const Offset(0, 1.1)), shadowPaint);
    canvas.drawPath(residuePath, linePaint);
    canvas.drawPath(residuePath, edgePaint);

    final fiberPaint = Paint()
      ..color = const Color(0x44FFFDF7)
      ..strokeWidth = 0.8
      ..strokeCap = StrokeCap.round;

    for (var index = 0; index < 14; index++) {
      final x = 10 + (size.width - 20) / 14 * index + random.nextDouble() * 3;
      final baseY = 2.8 + random.nextDouble() * 4.8;
      final lift = 1.2 + random.nextDouble() * 2.2;
      canvas.drawLine(
        Offset(x, baseY - lift),
        Offset(x + random.nextDouble() * 1.4, baseY),
        fiberPaint,
      );
    }

    final anchorPaint = Paint()
      ..color = const Color(0x3FDCC49A)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(const Offset(26, 1.2), const Offset(26, 8.8), anchorPaint);
    canvas.drawLine(
      Offset(size.width - 26, 1.2),
      Offset(size.width - 26, 8.4),
      anchorPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _TearResiduePainter oldDelegate) {
    return oldDelegate.seed != seed;
  }
}

class _PaperBallPainter extends CustomPainter {
  const _PaperBallPainter({required this.seed, this.detailStrength = 1});

  final int seed;
  final double detailStrength;

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(seed * 31);
    final strength = detailStrength.clamp(0.0, 1.0);
    final shadowCreasePaint = Paint()
      ..color = const Color(0x2C625649).withValues(alpha: 0.1 * strength)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * (0.012 + 0.007 * strength)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.2);
    final creasePaint = Paint()
      ..color = const Color(0x426D6356).withValues(alpha: 0.16 * strength)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * (0.007 + 0.006 * strength)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fineCreasePaint = Paint()
      ..color = const Color(0x24695F52).withValues(alpha: 0.12 * strength)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * (0.003 + 0.004 * strength)
      ..strokeCap = StrokeCap.round;
    final highlightPaint = Paint()
      ..color = const Color(
        0x7AFFFFFF,
      ).withValues(alpha: 0.42 + 0.18 * strength)
      ..strokeWidth = size.width * (0.008 + 0.008 * strength)
      ..strokeCap = StrokeCap.round;
    final fiberPaint = Paint()
      ..color = const Color(0x12A79A8B).withValues(alpha: 0.03 * strength)
      ..strokeWidth = size.width * (0.0015 + 0.002 * strength)
      ..strokeCap = StrokeCap.round;

    final shadePaint = Paint()
      ..shader = LinearGradient(
        colors: const [Color(0x00B8ADA1), Color(0x18D8D2CA), Color(0x00FFFFFF)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        stops: [0, 0.55 + random.nextDouble() * 0.1, 1],
      ).createShader(Offset.zero & size);

    for (var i = 0; i < 2 + (strength * 2).round(); i++) {
      final patch = Path();
      final start = Offset(
        size.width * (0.16 + random.nextDouble() * 0.24),
        size.height * (0.2 + random.nextDouble() * 0.2),
      );
      patch.moveTo(start.dx, start.dy);
      patch.cubicTo(
        start.dx + size.width * (0.08 + random.nextDouble() * 0.08),
        start.dy - size.height * (0.03 + random.nextDouble() * 0.06),
        start.dx + size.width * (0.2 + random.nextDouble() * 0.1),
        start.dy + size.height * (0.05 + random.nextDouble() * 0.08),
        start.dx + size.width * (0.16 + random.nextDouble() * 0.12),
        start.dy + size.height * (0.16 + random.nextDouble() * 0.08),
      );
      patch.cubicTo(
        start.dx + size.width * (0.06 + random.nextDouble() * 0.06),
        start.dy + size.height * (0.18 + random.nextDouble() * 0.08),
        start.dx - size.width * (0.02 + random.nextDouble() * 0.04),
        start.dy + size.height * (0.08 + random.nextDouble() * 0.06),
        start.dx,
        start.dy,
      );
      canvas.drawPath(patch, shadePaint);
    }

    for (var i = 0; i < 2 + (strength * 4).round(); i++) {
      final path = Path();
      final start = Offset(
        size.width * (0.12 + random.nextDouble() * 0.2),
        size.height * (0.18 + random.nextDouble() * 0.16),
      );
      path.moveTo(start.dx, start.dy);
      path.cubicTo(
        size.width * (0.22 + random.nextDouble() * 0.18),
        size.height * (0.08 + random.nextDouble() * 0.22),
        size.width * (0.5 + random.nextDouble() * 0.12),
        size.height * (0.26 + random.nextDouble() * 0.18),
        size.width * (0.7 + random.nextDouble() * 0.08),
        size.height * (0.44 + random.nextDouble() * 0.14),
      );
      path.cubicTo(
        size.width * (0.8 + random.nextDouble() * 0.04),
        size.height * (0.58 + random.nextDouble() * 0.12),
        size.width * (0.56 + random.nextDouble() * 0.14),
        size.height * (0.8 + random.nextDouble() * 0.06),
        size.width * (0.24 + random.nextDouble() * 0.1),
        size.height * (0.72 + random.nextDouble() * 0.08),
      );
      canvas.drawPath(path.shift(const Offset(0.9, 1.1)), shadowCreasePaint);
      canvas.drawPath(path, creasePaint);
    }

    for (var i = 0; i < 3 + (strength * 8).round(); i++) {
      final path = Path();
      final start = Offset(
        size.width * (0.16 + random.nextDouble() * 0.62),
        size.height * (0.16 + random.nextDouble() * 0.62),
      );
      final end = Offset(
        start.dx + size.width * (-0.08 + random.nextDouble() * 0.16),
        start.dy + size.height * (-0.08 + random.nextDouble() * 0.16),
      );
      final mid = Offset(
        (start.dx + end.dx) / 2 +
            size.width * (-0.03 + random.nextDouble() * 0.06),
        (start.dy + end.dy) / 2 +
            size.height * (-0.03 + random.nextDouble() * 0.06),
      );
      path.moveTo(start.dx, start.dy);
      path.quadraticBezierTo(mid.dx, mid.dy, end.dx, end.dy);
      canvas.drawPath(path, fineCreasePaint);
    }

    for (var i = 0; i < 2 + (strength * 4).round(); i++) {
      final start = Offset(
        size.width * (0.18 + random.nextDouble() * 0.34),
        size.height * (0.12 + random.nextDouble() * 0.26),
      );
      final end = Offset(
        start.dx + size.width * (0.05 + random.nextDouble() * 0.08),
        start.dy + size.height * (0.02 + random.nextDouble() * 0.06),
      );
      canvas.drawLine(start, end, highlightPaint);
    }

    for (var i = 0; i < (8 + strength * 22).round(); i++) {
      final start = Offset(
        size.width * random.nextDouble(),
        size.height * random.nextDouble(),
      );
      final end = Offset(
        start.dx + size.width * (-0.01 + random.nextDouble() * 0.02),
        start.dy + size.height * (-0.01 + random.nextDouble() * 0.02),
      );
      canvas.drawLine(start, end, fiberPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _PaperBallPainter oldDelegate) {
    return oldDelegate.seed != seed;
  }
}

class _PaperBallDetailedPainter extends CustomPainter {
  const _PaperBallDetailedPainter({
    required this.seed,
    this.detailStrength = 1,
  });

  final int seed;
  final double detailStrength;

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(seed * 97);
    final strength = detailStrength.clamp(0.0, 1.0);
    final center = Offset(size.width * 0.5, size.height * 0.5);

    final baseWash = Paint()
      ..shader = const RadialGradient(
        colors: [Color(0x22FFFFFF), Color(0x10EEE7DC), Color(0x00D9D0C3)],
        stops: [0, 0.58, 1],
        center: Alignment(-0.16, -0.2),
        radius: 0.96,
      ).createShader(Offset.zero & size);
    final facetPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0x20D7CEC1).withValues(alpha: 0.2 * strength);
    final deepFacetPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = const Color(0x28B5AC9E).withValues(alpha: 0.18 * strength);
    final ridgeGlowPaint = Paint()
      ..color = const Color(0x246B645B).withValues(alpha: 0.1 * strength)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * (0.014 + 0.003 * strength)
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.6);
    final ridgePaint = Paint()
      ..color = const Color(0x50746D63).withValues(alpha: 0.14 * strength)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * (0.006 + 0.003 * strength)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final highlightPaint = Paint()
      ..color = const Color(
        0xA6FFFFFF,
      ).withValues(alpha: 0.58 + 0.08 * strength)
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * (0.009 + 0.005 * strength)
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(center, size.shortestSide * 0.52, baseWash);

    for (var i = 0; i < 9; i++) {
      final patch = Path();
      final start = Offset(
        size.width * (0.14 + random.nextDouble() * 0.3),
        size.height * (0.14 + random.nextDouble() * 0.24),
      );
      patch.moveTo(start.dx, start.dy);
      patch.quadraticBezierTo(
        size.width * (0.24 + random.nextDouble() * 0.28),
        size.height * (0.1 + random.nextDouble() * 0.18),
        size.width * (0.38 + random.nextDouble() * 0.22),
        size.height * (0.22 + random.nextDouble() * 0.18),
      );
      patch.quadraticBezierTo(
        size.width * (0.28 + random.nextDouble() * 0.24),
        size.height * (0.32 + random.nextDouble() * 0.18),
        size.width * (0.16 + random.nextDouble() * 0.18),
        size.height * (0.26 + random.nextDouble() * 0.24),
      );
      patch.close();
      canvas.drawPath(patch, i.isEven ? facetPaint : deepFacetPaint);
    }

    for (var i = 0; i < 6; i++) {
      final path = Path();
      final start = Offset(
        size.width * (0.1 + random.nextDouble() * 0.18),
        size.height * (0.16 + random.nextDouble() * 0.16),
      );
      final c1 = Offset(
        size.width * (0.24 + random.nextDouble() * 0.22),
        size.height * (0.06 + random.nextDouble() * 0.18),
      );
      final c2 = Offset(
        size.width * (0.54 + random.nextDouble() * 0.16),
        size.height * (0.14 + random.nextDouble() * 0.22),
      );
      final end = Offset(
        size.width * (0.7 + random.nextDouble() * 0.14),
        size.height * (0.34 + random.nextDouble() * 0.18),
      );
      path.moveTo(start.dx, start.dy);
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
      canvas.drawPath(path, ridgeGlowPaint);
      canvas.drawPath(path, ridgePaint);
    }

    for (var i = 0; i < 7; i++) {
      final path = Path();
      final start = Offset(
        size.width * (0.24 + random.nextDouble() * 0.16),
        size.height * (0.38 + random.nextDouble() * 0.16),
      );
      final c1 = Offset(
        size.width * (0.14 + random.nextDouble() * 0.16),
        size.height * (0.52 + random.nextDouble() * 0.14),
      );
      final c2 = Offset(
        size.width * (0.44 + random.nextDouble() * 0.16),
        size.height * (0.72 + random.nextDouble() * 0.12),
      );
      final end = Offset(
        size.width * (0.68 + random.nextDouble() * 0.12),
        size.height * (0.82 + random.nextDouble() * 0.08),
      );
      path.moveTo(start.dx, start.dy);
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, end.dx, end.dy);
      canvas.drawPath(path, ridgeGlowPaint);
      canvas.drawPath(path, ridgePaint);
    }

    for (var i = 0; i < 3; i++) {
      final start = Offset(
        size.width * (0.18 + random.nextDouble() * 0.34),
        size.height * (0.18 + random.nextDouble() * 0.32),
      );
      final end = Offset(
        start.dx + size.width * (0.04 + random.nextDouble() * 0.08),
        start.dy - size.height * (0.01 + random.nextDouble() * 0.04),
      );
      canvas.drawLine(start, end, highlightPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _PaperBallDetailedPainter oldDelegate) {
    return oldDelegate.seed != seed ||
        oldDelegate.detailStrength != detailStrength;
  }
}

class _FullScreenImpactOverlay extends StatelessWidget {
  const _FullScreenImpactOverlay({required this.progress, required this.seed});

  final double progress;
  final int seed;

  @override
  Widget build(BuildContext context) {
    final viewport = MediaQuery.sizeOf(context);
    final impact = ((progress - 0.66) / 0.34).clamp(0.0, 1.0);
    if (impact <= 0) {
      return const SizedBox.shrink();
    }

    final burstScale = Curves.easeOutExpo.transform(impact);
    final flashOpacity = (1 - impact) * 0.045;
    final ringOpacity = (1 - impact) * 0.2;
    final lensShadowOpacity = (1 - impact) * 0.42;
    final ballScale = lerpDouble(0.52, 22.0, burstScale)!;
    final impactDx = lerpDouble(
      viewport.width * 0.62,
      viewport.width * 0.52,
      impact,
    )!;
    final impactDy = lerpDouble(
      viewport.height * 0.48,
      viewport.height * 0.46,
      impact,
    )!;
    final ringSize = lerpDouble(120, viewport.longestSide * 1.15, burstScale)!;
    final impactCompression = Curves.easeOut.transform(
      (1 - (impact - 0.16).abs() / 0.16).clamp(0.0, 1.0),
    );

    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: lensShadowOpacity,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: const [
                      Color(0x00000000),
                      Color(0x17000000),
                      Color(0x2C000000),
                    ],
                    stops: const [0.0, 0.58, 1.0],
                    center: Alignment(
                      (impactDx / viewport.width) * 2 - 1,
                      (impactDy / viewport.height) * 2 - 1,
                    ),
                    radius: 1.05,
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: Opacity(
            opacity: flashOpacity,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: RadialGradient(
                  colors: [
                    Color(0xFFFFFFFF),
                    Color(0x16FFF8EE),
                    Color(0x00FFF8EE),
                  ],
                  center: Alignment(0.16, -0.04),
                  radius: 0.92,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: impactDx - ringSize / 2,
          top: impactDy - ringSize / 2,
          child: Opacity(
            opacity: ringOpacity,
            child: Container(
              width: ringSize,
              height: ringSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: const Color(
                    0xF2FFF6E6,
                  ).withValues(alpha: 0.28 - impact * 0.14),
                  width: lerpDouble(7, 1.4, impact)!,
                ),
                boxShadow: [
                  BoxShadow(
                    color: const Color(
                      0x99FFF6E1,
                    ).withValues(alpha: 0.1 - impact * 0.05),
                    blurRadius: 24,
                    spreadRadius: 4,
                  ),
                ],
              ),
            ),
          ),
        ),
        Positioned(
          left: impactDx - 36,
          top: impactDy - 36,
          child: Transform.scale(
            scale: ballScale,
            child: Transform.scale(
              scaleX: lerpDouble(1.0, 1.08, impactCompression)!,
              scaleY: lerpDouble(0.98, 0.9, impactCompression)!,
              child: Opacity(
                opacity: 1 - impact * 0.04,
                child: SizedBox(
                  width: 72,
                  height: 72,
                  child: _PaperBallView(
                    size: 72,
                    seed: seed,
                    mode: PaperBallRenderMode.detailed,
                    detailStrength: 0.62,
                    shadowOpacity: 1.0,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GridPaperPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final verticalPaint = Paint()..color = const Color(0x03241A12);
    final horizontalPaint = Paint()..color = const Color(0x02241A12);
    const gap = 32.0;
    for (double x = 0; x < size.width; x += gap) {
      canvas.drawRect(Rect.fromLTWH(x, 0, 1, size.height), verticalPaint);
    }
    for (double y = 0; y < size.height; y += gap) {
      canvas.drawRect(Rect.fromLTWH(0, y, size.width, 1), horizontalPaint);
    }
    final vignette = Paint()
      ..shader = const RadialGradient(
        colors: [Color(0x00FFFFFF), Color(0x10D8C8AF)],
        radius: 1.12,
      ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, vignette);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _PaperSurfacePainter extends CustomPainter {
  const _PaperSurfacePainter({required this.seed});

  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(seed * 67);
    final fiberPaint = Paint()
      ..color = const Color(0x12B8AA8F)
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 0.7;
    final warmWash = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0x00FFFFFF), Color(0x08E9D9BB), Color(0x00FFFFFF)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ).createShader(Offset.zero & size);

    canvas.drawRect(Offset.zero & size, warmWash);

    for (var i = 0; i < 90; i++) {
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      final length = 1.2 + random.nextDouble() * 2.8;
      canvas.drawLine(Offset(x, y), Offset(x + length, y + 0.4), fiberPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _PaperSurfacePainter oldDelegate) {
    return oldDelegate.seed != seed;
  }
}

double _multiStage(double progress, List<double> values) {
  if (values.length < 2) {
    return values.isEmpty ? 0 : values.first;
  }
  final step = 1 / (values.length - 1);
  final stops = List<double>.generate(
    values.length,
    (index) => index == values.length - 1 ? 1.0 : index * step,
  );
  for (var i = 0; i < stops.length - 1; i++) {
    final start = stops[i];
    final end = stops[i + 1];
    if (progress <= end) {
      final t = ((progress - start) / (end - start)).clamp(0.0, 1.0);
      return lerpDouble(
        values[i],
        values[i + 1],
        Curves.easeInOut.transform(t.clamp(0.0, 1.0)),
      )!;
    }
  }
  return values.last;
}

DateTime _startOfDay(DateTime date) =>
    DateTime(date.year, date.month, date.day);

int _getDayOfYear(DateTime date) {
  final start = DateTime(date.year, 1, 0);
  return _startOfDay(date).difference(start).inDays;
}

int _getDaysInYear(int year) {
  return DateTime(year + 1, 1, 1).difference(DateTime(year, 1, 1)).inDays;
}

String _formatCount(int value) {
  final raw = value.toString();
  final buffer = StringBuffer();
  for (var index = 0; index < raw.length; index++) {
    if (index > 0 && (raw.length - index) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(raw[index]);
  }
  return buffer.toString();
}
