import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:petmind_app/audio_panel.dart';

void main() {
  testWidgets('each upload requires a fresh source and consent', (tester) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var uploads = 0;
    String? uploadedSource;
    final client = MockClient((request) async {
      if (request.method == 'POST' && request.url.path == '/audio-clips/upload') {
        uploads++;
        uploadedSource = request.url.queryParameters['demo_source'];
        expect(request.url.queryParameters['store_consent'], 'true');
        expect(request.url.queryParameters['training_consent'], 'false');
        return http.Response('{}', 201);
      }
      final dynamic result = request.url.path.endsWith('/review-queue')
        ? {'items': []} : [];
      return http.Response(jsonEncode(result), 200);
    });
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: AudioPanel(client: client, base: 'http://localhost', petId: 'dog-a',
        onChanged: () {}, inputBuilder: (onSelected, onError) => TextButton(
          onPressed: () => onSelected('demo.wav', Uint8List.fromList([1, 2, 3])),
          child: const Text('선택 WAV')))))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('사용자 음원 · 보호자 확인'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('선택 WAV'));
    await tester.tap(find.text('공개 자료 시연용 음원'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'ESC-50 / old.wav');
    await tester.tap(find.text('공개 자료 시연용 음원'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('공개 자료 시연용 음원'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('시연용 기록으로 음원 저장에 동의'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('음원 업로드·분석'));
    await tester.pumpAndSettle();
    expect(uploads, 0);
    expect(find.textContaining('데이터셋·파일명을 5자 이상'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'ESC-50 / new.wav');
    await tester.tap(find.text('음원 업로드·분석'));
    await tester.pumpAndSettle();
    expect(uploads, 1);
    expect(uploadedSource, 'ESC-50 / new.wav');
    expect(find.text('선택: demo.wav'), findsNothing);
    final boxes = tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)).toList();
    expect(boxes[0].value, false);
    expect(boxes[1].value, false);
    final uploadButton = tester.widget<FilledButton>(find.ancestor(
      of: find.text('음원 업로드·분석'), matching: find.byType(FilledButton)));
    expect(uploadButton.onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('separate consent, guardian review and withdrawal', (tester) async {
    tester.view.physicalSize = const Size(1200,2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var consent = true;
    Map<String,dynamic> review = {};
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        final body = jsonDecode(request.body);
        expect(body['pet_id'],'dog-a');
        if (request.url.path.endsWith('/review')) review = body;
        if (request.url.path.endsWith('/consent')) consent = body['training_consent'];
        return http.Response('{}',200);
      }
      return http.Response(jsonEncode([{'id':'clip','observation_id':4,'duration_s':5,
        'training_consent':consent,'expires_at':'2026-10-18','deleted':false,'audio_available':true,
        'review_priority':'uncertain','analysis':{'audio_lstm':{'dog_score':0.8,'threshold':0.5,
          'windows':[{'start_s':0,'end_s':5,'dog_score':0.8,'label':'dog_candidate'}]}},'review':review}]),200,
        headers:{'content-type':'application/json; charset=utf-8'});
    });
    await tester.pumpWidget(MaterialApp(home:Scaffold(body:SingleChildScrollView(child:AudioPanel(
      client:client,base:'http://localhost',petId:'dog-a',onChanged:() {})))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('사용자 음원 · 보호자 확인'));
    await tester.pumpAndSettle();
    expect(find.textContaining('5초 창은 정확한 발성'),findsOneWidget);
    expect(find.textContaining('80.0 / 100 · 기준 50.0 / 100'),findsOneWidget);
    expect(find.text('구간 듣기'),findsOneWidget);
    final boxes = tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)).toList();
    expect(boxes[0].value,false); expect(boxes[1].value,false);
    expect(boxes[2].value,false); expect(boxes[2].onChanged,isNull);
    await tester.tap(find.text('개인 관찰 기록으로 음원 저장에 동의'));
    await tester.pumpAndSettle();
    expect(tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)).last.onChanged,isNotNull);
    await tester.tap(find.text('확인 의견'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField),'보호자가 확인한 상황');
    await tester.tap(find.text('의견 저장'));
    await tester.pumpAndSettle();
    expect(review['label'],'uncertain'); expect(review['note'],'보호자가 확인한 상황');
    expect(find.textContaining('보호자 의견: 판단하기 어려움'),findsOneWidget);
    await tester.tap(find.text('학습 참여 철회'));
    await tester.pumpAndSettle();
    expect(consent,false);
    expect(find.text('학습 참여 철회'),findsNothing);
    await tester.tap(find.text('공개 자료 시연용 음원'));
    await tester.pumpAndSettle();
    expect(find.text('시연용 기록으로 음원 저장에 동의'), findsOneWidget);
  });
}
