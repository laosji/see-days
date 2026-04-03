import 'package:flutter_test/flutter_test.dart';

import 'package:real_calendar_app/main.dart';

void main() {
  testWidgets('renders the real calendar shell', (WidgetTester tester) async {
    await tester.pumpWidget(const RealCalendarApp());
    await tester.pump();

    expect(find.text('真实日历'), findsWidgets);
    expect(find.text('模拟缺席 3 天'), findsOneWidget);
  });
}
