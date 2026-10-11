import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'audio_input.dart';
import 'clip_view.dart';

class AudioPanel extends StatefulWidget {
  const AudioPanel({super.key, required this.client, required this.base, required this.petId,
    required this.onChanged, this.outing});
  final http.Client client;
  final String base, petId;
  final Map<String, dynamic>? outing;
  final VoidCallback onChanged;
  @override
  State<AudioPanel> createState() => _AudioPanelState();
}

class _AudioPanelState extends State<AudioPanel> {
  List<dynamic> clips = [];
  List<dynamic> reviewQueue = [];
  bool queueOnly = false;
  Uint8List? bytes;
  String filename = '', error = '';
  bool store = false, training = false, busy = false;
  int retention = 7, epoch = 0;
  String get petQuery => 'pet_id=${Uri.encodeQueryComponent(widget.petId)}';
  @override
  void initState() { super.initState(); load(); }
  @override
  void didUpdateWidget(covariant AudioPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.petId != widget.petId) {
      epoch++; clips = []; reviewQueue = []; queueOnly = false; bytes = null; filename = ''; store = false; training = false; error = '';
      load();
    }
  }
  dynamic decode(http.Response response) {
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode >= 400) throw Exception(data['detail']);
    return data;
  }
  Future<void> load() async {
    final token = ++epoch;
    try {
      final data = decode(await widget.client.get(Uri.parse('${widget.base}/audio-clips?$petQuery')).timeout(const Duration(seconds: 20)));
      if (!mounted || token != epoch) { return; }
      final queue = decode(await widget.client.get(Uri.parse('${widget.base}/audio-clips/review-queue?$petQuery')).timeout(const Duration(seconds: 20)));
      if (mounted && token == epoch) {
        setState(() {
          clips = data as List<dynamic>;
          reviewQueue = queue is Map ? queue['items'] as List<dynamic> : [];
        });
      }
    } catch (e) { if (mounted && token == epoch) setState(() => error = '$e'); }
  }
  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    final pet = widget.petId;
    setState(() { busy = true; error = ''; });
    try { await action(); if (mounted && pet == widget.petId) { await load(); widget.onChanged(); } }
    catch (e) { if (mounted && pet == widget.petId) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }
  Future<void> post(String path, Map<String, dynamic> body) async {
    decode(await widget.client.post(Uri.parse('${widget.base}$path'),
      headers: {'Content-Type':'application/json'}, body: jsonEncode(body)).timeout(const Duration(seconds: 30)));
  }
  Future<void> upload() async {
    if (bytes == null || !store) return;
    final pet = widget.petId;
    final allowed = widget.outing == null || widget.outing!['input_mode'] == 'uploaded_audio';
    if (!allowed) { setState(() => error = '기존 외출을 종료하고 사용자 음원 모드로 시작해 주세요.'); return; }
    final query = '$petQuery&store_consent=$store&training_consent=$training&retention_days=$retention'
      '${widget.outing == null ? '' : '&outing_id=${widget.outing!['id']}'}';
    final content = bytes!;
    await run(() async {
      decode(await widget.client.post(Uri.parse('${widget.base}/audio-clips/upload?$query'),
        headers: {'Content-Type':'audio/wav'}, body: content).timeout(const Duration(seconds: 60)));
      if (mounted && pet == widget.petId) setState(() { bytes = null; filename = ''; });
    });
  }
  Future<void> review(Map<String, dynamic> item) async {
    final pet = widget.petId;
    String label = item['review']?['label'] ?? 'uncertain';
    String note = item['review']?['note'] ?? '';
    final result = await showDialog<Map<String,dynamic>>(context: context, builder: (context) =>
      StatefulBuilder(builder: (context, update) => AlertDialog(title: const Text('소리 확인 의견'),
        content: SizedBox(width: 450, child: Column(mainAxisSize: MainAxisSize.min, children: [
          DropdownButton<String>(value: label, isExpanded: true, items: const [
            DropdownMenuItem(value:'pet_vocalization',child:Text('반려견 소리')),
            DropdownMenuItem(value:'external_or_tv',child:Text('TV·외부 소리')),
            DropdownMenuItem(value:'other',child:Text('기타 소리')),
            DropdownMenuItem(value:'uncertain',child:Text('판단하기 어려움')),
          ],onChanged:(value) => update(() => label = value!)),
          TextFormField(initialValue:note,onChanged:(value) => note = value,maxLength:1000,decoration:const InputDecoration(labelText:'상황 메모')),
          const Text('보호자 의견으로 저장됩니다. 모델의 확정 정답이나 감정 진단이 아닙니다.'),
        ])), actions: [TextButton(onPressed:() => Navigator.pop(context),child:const Text('취소')),
          FilledButton(onPressed:() => Navigator.pop(context,{'pet_id':pet,'label':label,'note':note}),child:const Text('의견 저장'))])));
    if (result != null && mounted && pet == widget.petId) await run(() => post('/audio-clips/${item['id']}/review',result));
  }
  void play(Map<String,dynamic> item) {
    showDialog<void>(context:context,builder:(context) => AlertDialog(title:const Text('원본 음원 확인'),
      content:SizedBox(width:650,height:260,child:clipView('${widget.base}/audio-clips/${item['id']}/player?$petQuery')),
      actions:[TextButton(onPressed:() => Navigator.pop(context),child:const Text('닫기'))]));
  }
  @override
  Widget build(BuildContext context) => ExpansionTile(title:const Text('사용자 음원 · 보호자 확인'),
    subtitle:const Text('30초 이하 WAV · 모델 학습 참여는 별도 선택'),children:[
    Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
      audioInput((name,data) { if (mounted) setState(() { filename = name; bytes = data; }); },
        (message) { if (mounted) setState(() => error = message); }),
      if (filename.isNotEmpty) Text('선택: $filename'),
      CheckboxListTile(value:store,onChanged:busy ? null : (v) => setState(() { store = v!; if (!store) training = false; }),
        title:const Text('개인 관찰 기록으로 음원 저장에 동의')),
      CheckboxListTile(value:training,onChanged:busy || !store ? null : (v) => setState(() => training = v!),
        title:const Text('검수 후 공통 모델 개선에 제공 (선택)')),
      DropdownButton<int>(value:retention,items:[1,7,30].map((n) => DropdownMenuItem(value:n,child:Text('원본 보관 $n일'))).toList(),
        onChanged:busy ? null : (v) => setState(() => retention = v!)),
      const Text('원본 삭제 후에도 관찰 수치와 확인 의견은 남습니다. 현재는 로컬 단일 사용자용입니다.'),
      FilledButton(onPressed:busy || bytes == null || !store ? null : upload,child:const Text('음원 업로드·분석')),
      TextButton(onPressed:busy ? null : load,child:const Text('음원 목록 새로고침')),
      TextButton(onPressed:busy ? null : () => setState(() => queueOnly = !queueOnly),
        child:Text(queueOnly ? '전체 음원 보기' : '확인 추천 ${reviewQueue.length}건 보기')),
      if (queueOnly) const Text('판별이 애매한 구간과 일반 구간 표본을 함께 확인합니다. 업로드하지 않은 소리의 누락은 측정할 수 없습니다.'),
      if (queueOnly && reviewQueue.isEmpty) const Text('확인이 필요한 새 음원이 없습니다.'),
      if (clips.isEmpty) const Text('아직 저장된 사용자 음원이 없습니다.'),
      for (final raw in queueOnly ? reviewQueue : clips) Builder(builder:(context) {
        final item = Map<String,dynamic>.from(raw);
        final model = item['analysis']?['audio_lstm'];
        return Card(child:Padding(padding:const EdgeInsets.all(12),child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
          Text('관찰 #${item['observation_id']} · ${item['duration_s']}초'),
          Text(item['review_priority'] == 'model_disagreement' ? '확인 권장: 모델과 에너지 감지 결과가 다릅니다.' :
            item['review_priority'] == 'uncertain' ? '확인 권장: 판별 근거가 부족합니다.' : '일반 구간 확인 표본'),
          if (model != null) Text('실험 LSTM 개 소리 점수 ${model['dog_score']} · 기준 ${model['threshold']} (정확도·확률 아님)'),
          if (model == null) const Text('실험 음성 모델이 준비되지 않았거나 분석에 실패했습니다. 에너지 후보만 기록했습니다.'),
          if ((item['review'] as Map).isNotEmpty) Text('보호자 의견: ${item['review']['label']} · ${item['review']['note']}'),
          Text('학습 참여 ${item['training_consent'] == true ? '동의' : '미동의'} · 원본 만료 ${item['expires_at']}'),
          Wrap(spacing:8,children:[
            TextButton(onPressed:item['audio_available'] == true ? () => play(item) : null,child:Text(item['deleted'] == true ? '원본 삭제됨' : '음원 듣기')),
            TextButton(onPressed:busy ? null : () => review(item),child:const Text('확인 의견')),
            if (item['training_consent'] == true) TextButton(onPressed:busy ? null : () => run(() => post('/audio-clips/${item['id']}/consent',
              {'pet_id':widget.petId,'training_consent':false})),child:const Text('학습 참여 철회')),
            if (item['deleted'] != true) TextButton(onPressed:busy ? null : () async {
              final pet = widget.petId;
              final yes = await showDialog<bool>(context:context,builder:(context) => AlertDialog(title:const Text('원본 음원을 삭제할까요?'),
                content:const Text('복구할 수 없습니다. 학습 참여도 철회됩니다. 관찰 수치와 의견은 남습니다.'),
                actions:[TextButton(onPressed:() => Navigator.pop(context,false),child:const Text('취소')),
                  FilledButton(onPressed:() => Navigator.pop(context,true),child:const Text('원본 삭제'))]));
              if (yes == true && mounted && pet == widget.petId) await run(() => post('/audio-clips/${item['id']}/delete-original?$petQuery',{}));
            },child:const Text('원본 삭제')),
          ]),
        ])));
      }),
      if (busy) const LinearProgressIndicator(),
      if (error.isNotEmpty) Text(error,style:const TextStyle(color:Colors.orange)),
    ])),
  ]);
}
