import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaitlab/gait_engine.dart';
import 'package:gaitlab/main.dart';

void main() {
  testWidgets(
    'latest unavailable state does not erase earlier usable sections',
    (tester) async {
      final a = MotionAnalysis();
      for (var t = 0; t <= 7000000; t += 10000) {
        a.addAcceleration(t, 0, 9.81, 0, cadence: 0, periodicity: 0);
        a.addGyroscope(t, 0, 0, 0);
      }
      a.addAcceleration(9000000, 0, 9.81, 0, cadence: 0, periodicity: 0);
      a.finish();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MotionResults(analysis: a, elapsedSeconds: 9),
            ),
          ),
        ),
      );
      expect(find.text('最近區段尚不可判讀'), findsOneWidget);
    },
  );
  testWidgets('ready directions and expanded plots fit320px at1.6x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final a = MotionAnalysis(calibrate: true);
    for (var t = 0; t <= 20000000; t += 10000) {
      final v = t > 16000000 ? (t % 200000 < 100000 ? 0.5 : -0.5) : 0.0;
      a.addAcceleration(t, v, 9.81, v, cadence: 170, periodicity: .8);
      a.addGyroscope(t, 0, .1, 0);
    }
    a.finish();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: MotionResults(analysis: a, elapsedSeconds: 20),
            ),
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text('查看動作與旋轉趨勢'));
    await tester.tap(find.text('查看動作與旋轉趨勢'));
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNWidgets(3));
    expect(find.byType(MetricTrendChart), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'empty motion results explain missing directions and avoid zero claims',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MotionResults(
                analysis: MotionAnalysis(),
                elapsedSeconds: 0,
              ),
            ),
          ),
        ),
      );
      expect(find.text('動作概況'), findsOneWidget);
      expect(find.text('尚無可判讀區段'), findsOneWidget);
      expect(find.textContaining('在「紀錄設定」開啟'), findsOneWidget);
      expect(find.text('0.00 rad/s'), findsNothing);
    },
  );
  testWidgets(
    'calibration countdown and failed reason are readable at large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final a = MotionAnalysis(calibrate: true);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: MotionResults(analysis: a, elapsedSeconds: 3),
              ),
            ),
          ),
        ),
      );
      expect(find.textContaining('準備校正'), findsOneWidget);
      expect(tester.takeException(), isNull);
      for (var t = 0; t <= 16000000; t += 10000) {
        a.addAcceleration(t, 0, 0, 9.81, cadence: 0, periodicity: 0);
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MotionResults(analysis: a, elapsedSeconds: 16),
            ),
          ),
        ),
      );
      expect(find.textContaining('螢幕太接近水平'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('known stationary bins show physical units without form score', (
    tester,
  ) async {
    final a = MotionAnalysis(calibrate: true);
    for (var t = 0; t <= 18000000; t += 10000) {
      a.addAcceleration(t, 0, 9.81, 0, cadence: 0, periodicity: 0);
      a.addGyroscope(t, 0, 0, 0);
    }
    a.finish();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MotionResults(analysis: a, elapsedSeconds: 18),
          ),
        ),
      ),
    );
    expect(find.text('0.00 rad/s'), findsOneWidget);
    expect(find.textContaining('幅度過小'), findsOneWidget);
    expect(find.textContaining('依固定方式估計'), findsWidgets);
    expect(find.textContaining('跑姿分數'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
