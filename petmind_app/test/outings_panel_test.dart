import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:petmind_app/outings_panel.dart';

void main() {
  testWidgets('demo totals and incompatible previous outing are explained', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final summary = {'moments': [], 'sample_seconds': 5,
      'demo_sample_seconds': 5, 'unknown_seconds': 5, 'bark_candidate_count': 1};
    final client = MockClient((request) async {
      final path = request.url.path;
      final dynamic result = path == '/outings'
        ? [{'id': 'outing-1', 'status': 'ended',
            'started_at': '2026-10-11T08:00:00Z', 'input_mode': 'uploaded_audio'}]
        : path.endsWith('/explain')
        ? {'provider': 'grounded-template', 'retrieval_mode': 'local',
            'claims': [], 'answer': '기록 비교 불가',
            'report': {'comparison': {'status': 'incompatible_provenance'}}}
        : path.endsWith('/summary') || path == '/outings/day'
        ? summary
        : path == '/audio-clips/review-queue' ? {'items': []} : [];
      return http.Response(jsonEncode(result), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: OutingsPanel(client: client, base: 'http://localhost',
        petId: 'demo-dog', onActiveChanged: (_) {})))));
    await tester.pumpAndSettle();
    expect(find.textContaining('공개·합성 시연 표본 5초 포함'), findsWidgets);
    await tester.tap(find.text('지난 외출과 비교'));
    await tester.pumpAndSettle();
    expect(find.textContaining('섞어 비교하지 않습니다'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
