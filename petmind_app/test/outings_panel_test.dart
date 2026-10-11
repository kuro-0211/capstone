import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:petmind_app/outings_panel.dart';

void main() {
  testWidgets('narrow outing selector keeps date status and input legible', (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = MockClient((request) async {
      final dynamic result = request.url.path == '/outings'
        ? [{'id': 'outing-1', 'status': 'ended',
            'started_at': '2026-10-11T08:00:00Z', 'input_mode': 'uploaded_audio'}]
        : request.url.path == '/audio-clips/review-queue' ? {'items': []}
        : request.url.path == '/audio-clips' ? []
        : {'moments': [], 'sample_seconds': 0, 'unknown_seconds': 0,
            'bark_candidate_count': 0};
      return http.Response(jsonEncode(result), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: OutingsPanel(client: client, base: 'http://localhost',
        petId: 'demo-dog', onActiveChanged: (_) {})))));
    await tester.pumpAndSettle();
    expect(find.text('10/11 17:00 · 종료 · 음원'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('older cited observation opens evidence outside the selected outing', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var evidenceRequests = 0;
    final report = {'moments': [], 'sample_seconds': 0,
      'unknown_seconds': 0, 'bark_candidate_count': 0};
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/outings/observations/99/evidence') {
        evidenceRequests++;
        expect(request.url.queryParameters['pet_id'], 'demo-dog');
        return http.Response(jsonEncode({'observation_id': 99,
          'media_available': false, 'audio_available': true,
          'audio_url': '/audio-clips/clip-old/player?pet_id='}), 200);
      }
      final dynamic result = path == '/outings'
        ? [{'id': 'outing-current', 'status': 'ended',
            'started_at': '2026-10-11T08:00:00Z', 'input_mode': 'uploaded_audio'}]
        : path.endsWith('/explain')
        ? {'provider': 'grounded-template', 'retrieval_mode': 'local',
            'question': '이번 외출을 요약해 주세요.', 'answer': '과거 기록',
            'claims': [{'text': '과거 근거', 'observation_ids': [99]}],
            'report': {'comparison': {'status': 'not_requested'}}}
        : path == '/audio-clips' ? []
        : path == '/audio-clips/review-queue' ? {'items': []} : report;
      return http.Response(jsonEncode(result), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: OutingsPanel(client: client, base: 'http://localhost',
        petId: 'demo-dog', onActiveChanged: (_) {})))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('근거 기반 요약'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('근거 #99'));
    await tester.pumpAndSettle();
    expect(evidenceRequests, 1);
    expect(find.text('관찰 #99 · 원본 근거'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('new outing starts in audio mode for the current demo flow', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    Map<String, dynamic>? started;
    final report = {'moments': [], 'sample_seconds': 0,
      'unknown_seconds': 0, 'bark_candidate_count': 0};
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/outings' && request.method == 'POST') {
        expect(jsonDecode(request.body)['input_mode'], 'uploaded_audio');
        started = {'id': 'outing-audio', 'status': 'active',
          'input_mode': 'uploaded_audio', 'input_note': '사용자 음원',
          'started_at': '2026-10-11T08:00:00Z'};
        return http.Response(jsonEncode(started), 201,
          headers: {'content-type': 'application/json; charset=utf-8'});
      }
      final dynamic result = path == '/outings' ? (started == null ? [] : [started])
        : path == '/audio-clips' ? []
        : path == '/audio-clips/review-queue' ? {'items': []} : report;
      return http.Response(jsonEncode(result), 200,
        headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: OutingsPanel(client: client, base: 'http://localhost',
        petId: 'demo-dog', onActiveChanged: (_) {})))));
    await tester.pumpAndSettle();
    expect(find.text('사용자 음원'), findsOneWidget);
    await tester.tap(find.text('외출 시작'));
    await tester.pumpAndSettle();
    expect(started?['input_mode'], 'uploaded_audio');
    expect(find.textContaining('외출 진행 중'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('HTML server error shows a readable outings retry message', (tester) async {
    final client = MockClient((_) async => http.Response('<html>proxy error</html>', 502));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: OutingsPanel(
      client: client, base: 'http://localhost', petId: 'demo-dog',
      onActiveChanged: (_) {}))));
    await tester.pumpAndSettle();
    expect(find.textContaining('HTTP 502'), findsOneWidget);
    expect(find.textContaining('proxy error'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('day summary failure keeps outing report visible and recovers', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var dayOnline = false;
    final report = {'moments': [], 'sample_seconds': 5,
      'demo_sample_seconds': 0, 'unknown_seconds': 5, 'bark_candidate_count': 0};
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path == '/outings/day' && !dayOnline) {
        return http.Response('{"detail":"unavailable"}', 503);
      }
      final dynamic result = path == '/outings'
        ? [{'id': 'outing-1', 'status': 'ended',
            'started_at': '2026-10-11T08:00:00Z', 'input_mode': 'uploaded_audio'}]
        : report;
      return http.Response(jsonEncode(result), 200);
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: OutingsPanel(client: client, base: 'http://localhost',
        petId: 'demo-dog', onActiveChanged: (_) {})))));
    await tester.pumpAndSettle();
    expect(find.text('분석 표본'), findsOneWidget);
    expect(find.text('5초'), findsWidgets);
    expect(find.textContaining('외출 기록은 표시 중'), findsOneWidget);
    dayOnline = true;
    await tester.tap(find.text('외출 기록 새로고침'));
    await tester.pumpAndSettle();
    expect(find.textContaining('외출 기록은 표시 중'), findsNothing);
    expect(find.text('분석 표본'), findsNWidgets(2));
    await tester.pumpWidget(const SizedBox());
  });

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
            'question': jsonDecode(request.body)['question'],
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
    await tester.enterText(find.byType(TextField).first, '얼마나 오래 봤나요?');
    await tester.tap(find.text('근거 기반 요약'));
    await tester.pumpAndSettle();
    expect(find.textContaining('이전 외출 비교:'), findsNothing);
    await tester.tap(find.text('지난 외출과 비교'));
    await tester.pumpAndSettle();
    expect(find.textContaining('섞어 비교하지 않습니다'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
