import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'clip_view.dart';
import 'audio_panel.dart';

class OutingsPanel extends StatefulWidget {
  const OutingsPanel({super.key, required this.client, required this.base,
    required this.petId, required this.onActiveChanged, this.observationId});
  final http.Client client;
  final String base;
  final String petId;
  final int? observationId;
  final ValueChanged<Map<String, dynamic>?> onActiveChanged;
  @override
  State<OutingsPanel> createState() => _OutingsPanelState();
}

class _OutingsPanelState extends State<OutingsPanel> {
  List<dynamic> outings = [];
  Map<String, dynamic>? active, report, explanation, dayReport, dayExplanation;
  String? selected;
  String mode = 'synthetic_demo';
  String error = '';
  bool busy = false;
  int generation = 0;
  DateTime day = DateTime.now().toUtc().add(const Duration(hours: 9));
  final question = TextEditingController(text: '이번 외출을 요약해 주세요.');
  String get petQuery => 'pet_id=${Uri.encodeQueryComponent(widget.petId)}';
  String get dayText => '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

  @override
  void initState() { super.initState(); load(); }
  @override
  void didUpdateWidget(covariant OutingsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.petId != widget.petId) {
      generation++;
      outings = []; active = null; selected = null; report = null; explanation = null; dayReport = null; dayExplanation = null;
      load();
    } else if (oldWidget.observationId != widget.observationId) { load(); }
  }
  @override
  void dispose() { question.dispose(); super.dispose(); }

  Future<dynamic> request(String path, [Map<String, dynamic>? body]) async {
    final uri = Uri.parse('${widget.base}$path');
    final response = await (body == null ? widget.client.get(uri) : widget.client.post(uri,
      headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))).timeout(const Duration(seconds: 50));
    final value = jsonDecode(utf8.decode(response.bodyBytes));
    if (response.statusCode >= 400) throw Exception(value['detail'] ?? 'HTTP ${response.statusCode}');
    return value;
  }

  Future<void> load() async {
    final epoch = ++generation;
    final pet = widget.petId;
    try {
      final values = await request('/outings?$petQuery');
      if (!mounted || epoch != generation || pet != widget.petId) return;
      outings = values as List<dynamic>;
      final running = outings.where((o) => o['status'] == 'active');
      active = running.isEmpty ? null : Map<String, dynamic>.from(running.first);
      if (!outings.any((o) => o['id'] == selected)) selected = active?['id'] ?? (outings.isEmpty ? null : outings.first['id']);
      widget.onActiveChanged(active);
      final loaded = selected == null ? null : await request('/outings/$selected/summary?$petQuery');
      final daily = await request('/outings/day?$petQuery&day=$dayText');
      if (!mounted || epoch != generation || pet != widget.petId) return;
      setState(() {
        report = loaded is Map ? Map<String, dynamic>.from(loaded) : null;
        dayReport = daily is Map ? Map<String, dynamic>.from(daily) : null;
        explanation = null; dayExplanation = null; error = '';
      });
    } catch (e) { if (mounted && epoch == generation) setState(() => error = '외출 기록 조회 실패: $e'); }
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() { busy = true; error = ''; });
    try { await action(); } catch (e) { if (mounted) setState(() => error = '$e'); }
    finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> explain([String? preset]) async {
    if (selected == null) return;
    final pet = widget.petId, id = selected;
    await run(() async {
      final result = await request('/outings/$id/explain', {'pet_id': pet, 'question': preset ?? question.text});
      if (mounted && pet == widget.petId && id == selected) setState(() => explanation = Map<String, dynamic>.from(result));
    });
  }

  void openMoment(Map<String, dynamic> item) {
    if (item['media_available'] != true && item['audio_available'] != true) return;
    final url = '${widget.base}${item['media_available'] == true ? item['clip_url'] : item['audio_url']}${Uri.encodeQueryComponent(widget.petId)}';
    showDialog<void>(context: context, builder: (context) => AlertDialog(
      title: Text('관찰 #${item['observation_id']} · 원본 근거'),
      content: SizedBox(width: 850, height: 500, child: clipView(url)),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('닫기'))],
    ));
  }

  Widget metrics(Map<String, dynamic> data) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('분석 표본 ${data['sample_seconds'] ?? 0}초 · 판단 불가 ${data['unknown_seconds'] ?? 0}초 · 짖음 후보 ${data['bark_candidate_count'] ?? 0}회'),
    Text('정지 ${data['seconds_by_label']?['still'] ?? 0}초 · 이동 ${data['seconds_by_label']?['moving'] ?? 0}초 · 회전 ${data['seconds_by_label']?['spinning'] ?? 0}초 · 왕복 ${data['seconds_by_label']?['pacing'] ?? 0}초'),
    if (data['unobserved_seconds'] != null) Text('미관찰 ${data['unobserved_seconds']}초'),
    Text('중복·겹침 제외 ${(data['skipped_overlap_ids'] as List? ?? []).length}건 · 날짜 경계 제외 ${(data['excluded_day_boundary_ids'] as List? ?? []).length}건'),
    const Text('저장된 분석 구간의 합계입니다. 실제 외출 전체 시간의 활동량이 아닙니다.'),
  ]);

  @override
  Widget build(BuildContext context) {
    final moments = (report?['moments'] as List? ?? []);
    final previous = explanation?['report']?['comparison']?['previous_summary']?['moments'] as List? ?? [];
    final allMoments = [...moments, ...previous];
    return Card(child: Padding(padding: const EdgeInsets.all(20), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('외출 모드 · 귀가 리포트', style: Theme.of(context).textTheme.titleLarge),
        const Text('시작 버튼은 기록 묶음을 만듭니다. 카메라 자동 촬영을 시작하지 않습니다.'),
        if (active == null) Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          DropdownButton<String>(value: mode, items: const [
            DropdownMenuItem(value: 'synthetic_demo', child: Text('합성 시연')),
            DropdownMenuItem(value: 'prepared_video', child: Text('준비된 영상·음원')),
            DropdownMenuItem(value: 'uploaded_audio', child: Text('사용자 음원')),
          ], onChanged: busy ? null : (value) => setState(() => mode = value!)),
          FilledButton(onPressed: busy ? null : () => run(() async {
            final result = await request('/outings', {'pet_id': widget.petId, 'input_mode': mode, 'title': '외출 관찰'});
            selected = result['id']; await load();
          }), child: const Text('외출 시작')),
        ]),
        if (active != null) ...[
          Text('외출 진행 중 · ${active!['input_note']}'),
          FilledButton(onPressed: busy ? null : () => run(() async {
            selected = active!['id']; await request('/outings/$selected/end?$petQuery', {}); await load();
          }), child: const Text('귀가 · 외출 종료')),
        ],
        if (outings.isNotEmpty) DropdownButton<String>(value: selected, isExpanded: true,
          items: outings.map((o) => DropdownMenuItem<String>(value: o['id'],
            child: Text('${o['started_at']} · ${o['status'] == 'active' ? '진행 중' : '종료'} · ${o['input_mode']}'))).toList(),
          onChanged: busy ? null : (value) { selected = value; load(); }),
        TextButton(onPressed: busy ? null : load, child: const Text('외출 기록 새로고침')),
        AudioPanel(key: ValueKey(widget.petId), client: widget.client, base: widget.base,
          petId: widget.petId, outing: active, onChanged: () { load(); }),
        if (report == null) const Text('외출을 시작하고 아래에서 관찰 입력을 추가해 주세요.'),
        if (report != null) ...[
          metrics(report!),
          const SizedBox(height: 12),
          TextField(controller: question, decoration: const InputDecoration(labelText: '외출 기록에 질문하기'), maxLength: 1000),
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: busy ? null : () => explain(), child: const Text('근거 기반 요약')),
            OutlinedButton(onPressed: busy ? null : () => explain('지난 외출과 비교해 주세요.'), child: const Text('지난 외출과 비교')),
          ]),
          if (explanation != null) ...[
            Text('설명: ${explanation!['provider']} · 검색: ${explanation!['retrieval_mode']}'),
            if ((explanation!['claims'] as List).isEmpty) Text(explanation!['answer']),
            for (final claim in explanation!['claims']) Padding(padding: const EdgeInsets.only(top: 8), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(claim['text']),
                Wrap(children: [for (final id in claim['observation_ids']) TextButton(
                  onPressed: () {
                    final matched = allMoments.where((m) => m['observation_id'] == id);
                    if (matched.isNotEmpty && (matched.first['media_available'] == true || matched.first['audio_available'] == true)) {
                      openMoment(Map<String, dynamic>.from(matched.first));
                    } else { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('관찰 #$id: 연결된 영상이 없습니다.'))); }
                  }, child: Text('근거 #$id'))]),
              ])),
            if (explanation!['report']['comparison']['status'] != 'sample_rate_comparison')
              const Text('이전 외출 비교: 같은 입력 방식의 충분한 기록이 필요합니다.'),
          ],
          const SizedBox(height: 12),
          Text('중요한 순간 · 관찰 근거', style: Theme.of(context).textTheme.titleMedium),
          if (moments.isEmpty) const Text('저장된 관찰이 없습니다.'),
          for (final item in moments) ListTile(contentPadding: EdgeInsets.zero,
            title: Text('#${item['observation_id']} · ${item['reason']}'), subtitle: Text(item['summary']),
            trailing: TextButton(onPressed: item['media_available'] == true || item['audio_available'] == true ? () => openMoment(Map<String, dynamic>.from(item)) : null,
              child: Text(item['media_available'] == true ? '구간 보기' : item['audio_available'] == true ? '음원 듣기' : '원본 없음'))),
        ],
        const Divider(),
        Text('하루 관찰 요약 · $dayText (한국 시간)', style: Theme.of(context).textTheme.titleMedium),
        TextButton(onPressed: busy ? null : () async {
          final picked = await showDatePicker(context: context, initialDate: day,
            firstDate: DateTime(2020), lastDate: DateTime(2100));
          if (picked != null) { day = picked; await load(); }
        }, child: const Text('날짜 선택')),
        if (dayReport != null) metrics(dayReport!),
        OutlinedButton(onPressed: busy ? null : () => run(() async {
          final pet = widget.petId, date = dayText, epoch = generation;
          final result = await request('/outings/day/explain?day=$date',
            {'pet_id': pet, 'question': '오늘 기록 요약과 보호자 의견을 알려주세요.'});
          if (mounted && pet == widget.petId && date == dayText && epoch == generation) {
            setState(() => dayExplanation = Map<String, dynamic>.from(result));
          }
        }), child: const Text('하루 근거 설명')),
        if (dayExplanation != null) ...[
          if ((dayExplanation!['claims'] as List).isEmpty) Text(dayExplanation!['answer']),
          for (final claim in dayExplanation!['claims']) Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(claim['text']),
              Wrap(children: [for (final id in claim['observation_ids']) TextButton(
                onPressed: () {
                  final candidates = (dayExplanation!['report']['moments'] as List)
                    .where((m) => m['observation_id'] == id);
                  if (candidates.isNotEmpty && (candidates.first['audio_available'] == true || candidates.first['media_available'] == true)) {
                    openMoment(Map<String, dynamic>.from(candidates.first));
                  } else {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('관찰 #$id: 재생 가능한 원본이 없습니다.')));
                  }
                }, child: Text('하루 근거 #$id'))]),
            ]),
          Text(dayExplanation!['note']),
        ],
        if (busy) const LinearProgressIndicator(),
        if (error.isNotEmpty) Text(error, style: const TextStyle(color: Colors.orange)),
      ],
    )));
  }
}
