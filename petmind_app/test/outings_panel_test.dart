import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:petmind_app/outings_panel.dart';

void main() {
  testWidgets('day explanation uses scoped API and displays missing original explicitly', (tester) async {
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var explained = false;
    final client = MockClient((request) async {
      dynamic data = [];
      if (request.url.path == '/outings/day') {
        data = {'sample_seconds': 5, 'unknown_seconds': 5, 'bark_candidate_count': 1};
      } else if (request.url.path == '/outings/day/explain') {
        expect(request.method, 'POST');
        expect(jsonDecode(request.body)['pet_id'], 'test-dog');
        expect(request.url.queryParameters['day'], matches(RegExp(r'^\d{4}-\d{2}-\d{2}$')));
        explained = true;
        data = {
          'claims': [{'text': '검증용 하루 설명', 'observation_ids': [7]}],
          'report': {'moments': [{'observation_id': 7, 'audio_available': false, 'media_available': false}]},
          'note': '수치 근거 안내',
        };
      }
      return http.Response(jsonEncode(data), 200, headers: {'content-type': 'application/json; charset=utf-8'});
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child:
      OutingsPanel(client: client, base: 'http://localhost', petId: 'test-dog', onActiveChanged: (_) {})))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('하루 근거 설명'));
    await tester.tap(find.text('하루 근거 설명'));
    await tester.pumpAndSettle();
    expect(explained, isTrue);
    expect(find.text('검증용 하루 설명'), findsOneWidget);
    await tester.ensureVisible(find.text('하루 근거 #7'));
    await tester.tap(find.text('하루 근거 #7'));
    await tester.pumpAndSettle();
    expect(find.text('관찰 #7: 재생 가능한 원본이 없습니다.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
