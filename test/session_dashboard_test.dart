import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaitlab/main.dart';

void main() {
  testWidgets('cadence target is optional and editable before recording', (
    tester,
  ) async {
    await tester.pumpWidget(const GaitLabApp());
    await tester.tap(find.byKey(const ValueKey('recording-settings')));
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('cadence-target-switch'));
    await tester.scrollUntilVisible(
      toggle,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byType(RangeSlider), findsNothing);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final slider = find.byType(RangeSlider);
    expect(slider, findsOneWidget);
    expect(find.textContaining('160–180'), findsWidgets);
    tester.widget<RangeSlider>(slider).onChanged!(const RangeValues(150, 175));
    await tester.pump();
    expect(find.textContaining('150–175'), findsWidgets);
  });

  testWidgets('empty trend explains unavailable data without a perfect score', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MetricTrendChart(points: [], series: MetricSeries.cadence),
        ),
      ),
    );
    expect(find.text('等待符合品質條件的步頻'), findsOneWidget);
    expect(find.text('100%'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MetricTrendChart(points: [], series: MetricSeries.intervalCv),
        ),
      ),
    );
    expect(find.text('等待足夠且符合品質條件的候選間隔'), findsOneWidget);
  });

  testWidgets('dashboard fits a narrow phone with larger text', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(1.4)),
        child: GaitLabApp(),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('開始紀錄'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
  });
}
