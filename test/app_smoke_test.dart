import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gaitlab/main.dart';

void main() {
  testWidgets('dashboard renders without subscribing until record is pressed',
      (tester) async {
    await tester.pumpWidget(const GaitLabApp());
    expect(find.text('GaitLab'), findsOneWidget);
    expect(find.text('腰帶固定 · 即時步態分析'), findsOneWidget);
    expect(find.text('步頻'), findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsOneWidget);
    await tester.scrollUntilVisible(find.text('開始紀錄'), 240,
        scrollable: find.byType(Scrollable).first);
    expect(find.text('開始紀錄'), findsOneWidget);
  });
}
