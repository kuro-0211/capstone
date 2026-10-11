import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:petmind_app/main.dart';

void main() {
  testWidgets('empty input is explicit and evaluation disabled', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = MockClient((request) async {
      final path = request.url.path;
      final dynamic data = path == '/care/latest' || path.endsWith('/profile') ? null : path == '/metrics' || path == '/media/catalog' ? {} : [];
      return http.Response(jsonEncode(data), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await tester.pumpWidget(MaterialApp(home: DashboardPage(client: client)));
    await tester.pumpAndSettle();
    expect(find.text('데이터 없음'), findsWidgets);
    final button = tester.widget<FilledButton>(find.ancestor(
      of: find.text('현재 상태 평가하기'), matching: find.byWidgetPredicate((widget) => widget is FilledButton)));
    expect(button.onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('scenario creates observation and evaluates its ID then approves', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map<String, dynamic>? suggestion;
    final observation = {'id': 42, 'source': 'synthetic_demo', 'observed_at': '2026-10-11T00:00:00Z',
      'context': {'motion': {'dominant': 'spinning'}, 'bark': {'count': 8, 'peak_db': -24}}};
    var observed = false;
    var approved = false;
    final client = MockClient((request) async {
      dynamic result;
      final path = request.url.path;
      if (request.method == 'POST' && path == '/demo/observe') {
        expect(jsonDecode(request.body)['scenario'], 'anxious');
        observed = true;
        result = observation;
      } else if (request.method == 'POST' && path == '/care/evaluate') {
        expect(jsonDecode(request.body)['observation_id'], 42);
        suggestion = {'id': 7, 'observation_id': 42, 'summary': '상태를 확인해 주세요.', 'severity': 'attention', 'status': 'pending',
          'provider': 'rule', 'reasons': ['반복 신호'], 'recommended_actions': ['music'],
          'cited_observation_ids': [3], 'retrieval': {'mode': 'mcp', 'status': 'ok',
            'records': [{'id': 3, 'summary': '과거 관찰', 'source': 'synthetic_demo', 'observed_at': '2026-10-10'}],
            'tool_calls': [], 'stats': {'sample_count': 1}}};
        result = suggestion;
      } else if (request.method == 'POST' && path == '/care/7/approve') {
        expect(jsonDecode(request.body)['action_type'], 'music');
        approved = true;
        suggestion!['status'] = 'approved';
        result = {'status': 'requested'};
      } else if (path == '/care/latest') {
        result = suggestion;
      } else if (path.endsWith('/profile')) {
        result = null;
      } else if (path == '/observations') {
        result = observed ? [observation] : [];
      } else if (path == '/metrics' || path == '/media/catalog') {
        result = {};
      } else {
        result = [];
      }
      return http.Response(jsonEncode(result), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await tester.pumpWidget(MaterialApp(home: DashboardPage(client: client)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('회전·짖음 시연'));
    await tester.pumpAndSettle();
    expect(find.textContaining('#3 · 과거 관찰'), findsOneWidget);
    final approval = find.text('가상 음악 실행 승인');
    await tester.ensureVisible(approval);
    await tester.tap(approval);
    await tester.pumpAndSettle();
    expect(approved, isTrue);
    await tester.pumpWidget(const SizedBox());
  });
}
