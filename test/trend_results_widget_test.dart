import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaitlab/main.dart';

Map<String, dynamic> comparison(String status) => {
  'status': status,
  'baseline_start_s': 3.0,
  'baseline_end_s': 33.0,
  'recent_start_s': 60.0,
  'recent_end_s': 90.0,
  'baseline_usable_s': 30.0,
  'recent_usable_s': 29.0,
  'metrics': {
    'cadence': {
      'baseline': 170.0,
      'recent': 172.0,
      'delta': 2.0,
      'relative_percent': 1.18,
    },
    'rms': {
      'baseline': 1.0,
      'recent': 1.12,
      'delta': .12,
      'relative_percent': 12.0,
    },
    'interval_cv': {
      'baseline': 2.0,
      'recent': 3.0,
      'delta': 1.0,
      'relative_percent': 50.0,
    },
    'periodicity': {
      'baseline': .8,
      'recent': .7,
      'delta': -.1,
      'relative_percent': -12.5,
    },
  },
};

void main() {
  testWidgets(
    'results name direction and units without declaring better gait',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SessionTrendResults(comparison: comparison('ready')),
            ),
          ),
        ),
      );
      expect(find.text('訊號幅度'), findsOneWidget);
      expect(find.text('增加 12.0%'), findsOneWidget);
      expect(find.text('增加 1.0 百分點'), findsOneWidget);
      expect(find.text('下降 0.10'), findsOneWidget);
      expect(find.textContaining('0:03–0:33'), findsOneWidget);
      expect(find.text('跑姿改善'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('changed cadence explains why motion comparison is withheld', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionTrendResults(comparison: comparison('cadence_changed')),
        ),
      ),
    );
    expect(find.text('步頻改變，動作比較暫停'), findsOneWidget);
    expect(find.text('增加 12.0%'), findsNothing);
  });

  testWidgets(
    'empty comparison supplies next action and no fabricated changes',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SessionTrendResults(
              comparison: {'status': 'collecting', 'metrics': {}},
            ),
          ),
        ),
      );
      expect(find.text('還沒有兩段可比較的資料'), findsOneWidget);
      expect(find.textContaining('各 30 秒'), findsOneWidget);
      expect(find.text('增加 0.0%'), findsNothing);
    },
  );

  testWidgets('large text narrow screen can read the entire result', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SessionTrendResults(comparison: comparison('ready')),
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('候選步頻'),
      120,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
  });
}
