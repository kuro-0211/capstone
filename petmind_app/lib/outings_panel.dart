import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'clip_view.dart';
import 'audio_panel.dart';
import 'genesis_theme.dart';

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
  String mode = 'uploaded_audio';
  String error = '';
  bool busy = false;
  int generation = 0;
  DateTime day = DateTime.now().toUtc().add(const Duration(hours: 9));
  final question = TextEditingController(text: '이번 외출을 요약해 주세요.');
  String get petQuery => 'pet_id=${Uri.encodeQueryComponent(widget.petId)}';
  String get dayText => '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
  String outingLabel(Map<String, dynamic> outing) {
    final started = DateTime.tryParse(outing['started_at']?.toString() ?? '');
    final korea = started?.toUtc().add(const Duration(hours: 9));
    final when = korea == null ? (outing['started_at']?.toString() ?? '시각 없음')
      : '${korea.month}월 ${korea.day}일 ${korea.hour.toString().padLeft(2, '0')}:${korea.minute.toString().padLeft(2, '0')}';
    const modes = {'uploaded_audio': '사용자 음원', 'prepared_video': '준비된 영상·음원',
      'synthetic_demo': '합성 시연'};
    return '$when · ${outing['status'] == 'active' ? '진행 중' : '종료'} · ${modes[outing['input_mode']] ?? outing['input_mode']}';
  }
  String providerLabel(dynamic value) {
    final raw = value?.toString() ?? '';
    if (raw.startsWith('gemini:')) return 'Gemini 근거 선택·기록 기반 설명';
    if (raw == 'grounded-template-fallback') return '기록 기반 설명 (외부 설명 대체)';
    if (raw == 'grounded-template') return '기록 기반 설명';
    return '설명 방식 확인 필요';
  }
  String retrievalLabel(dynamic value) => switch (value) {
    'mcp' => 'MCP 기록 검색',
    'local' => '로컬 기록 검색',
    'local-fallback' => '로컬 기록 검색 (MCP 대체)',
    _ => '검색 방식 확인 필요',
  };
  bool comparisonRequested(dynamic question) {
    final text = question?.toString() ?? '';
    return const ['비교', '지난', '이전', '차이', '늘었', '줄었', '전보다']
      .any(text.contains);
  }

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
    dynamic value;
    try { value = jsonDecode(utf8.decode(response.bodyBytes)); }
    catch (_) {
      if (response.statusCode >= 400) {
        throw Exception('서버 응답 오류 (HTTP ${response.statusCode}). 다시 시도해 주세요.');
      }
      throw const FormatException('서버 응답 형식이 올바르지 않습니다.');
    }
    if (response.statusCode >= 400) {
      throw Exception(value is Map && value['detail'] != null
        ? value['detail'] : '서버 응답 오류 (HTTP ${response.statusCode}). 다시 시도해 주세요.');
    }
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
      dynamic daily;
      var dayUnavailable = false;
      try { daily = await request('/outings/day?$petQuery&day=$dayText'); }
      catch (_) { dayUnavailable = true; }
      if (!mounted || epoch != generation || pet != widget.petId) return;
      setState(() {
        report = loaded is Map ? Map<String, dynamic>.from(loaded) : null;
        dayReport = daily is Map ? Map<String, dynamic>.from(daily) : null;
        explanation = null; dayExplanation = null;
        error = dayUnavailable ? '하루 요약을 불러오지 못했습니다. 외출 기록은 표시 중입니다.' : '';
      });
    } catch (e) { if (mounted && epoch == generation) setState(() => error = '외출 기록 조회 실패: $e'); }
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
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

  Future<void> openEvidence(dynamic observationId) async {
    final pet = widget.petId;
    try {
      final raw = await request('/outings/observations/$observationId/evidence?$petQuery');
      if (!mounted || pet != widget.petId) return;
      final item = Map<String, dynamic>.from(raw);
      if (item['media_available'] == true || item['audio_available'] == true) {
        openMoment(item);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('관찰 #$observationId: 재생 가능한 원본이 없습니다.')));
      }
    } catch (_) {
      if (mounted && pet == widget.petId) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('관찰 #$observationId: 근거를 불러오지 못했습니다. 다시 시도해 주세요.')));
      }
    }
  }

  Widget _metric(String label, String value) => Container(
    width: 170,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: GenesisTheme.background,
      border: Border.all(color: GenesisTheme.border),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      const SizedBox(height: 4),
      Text(value, style: Theme.of(context).textTheme.titleMedium),
    ]),
  );

  Widget metrics(Map<String, dynamic> data) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Wrap(spacing: 8, runSpacing: 8, children: [
      _metric('분석 표본', '${data['sample_seconds'] ?? 0}초'),
      _metric('판단 불가', '${data['unknown_seconds'] ?? 0}초'),
      _metric('짖음 후보', '${data['bark_candidate_count'] ?? 0}회'),
    ]),
    if ((data['demo_sample_seconds'] as num? ?? 0) > 0) Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text('공개·합성 시연 표본 ${data['demo_sample_seconds']}초 포함 · 실제 반려견 기록과 구분해 주세요.',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: const Color(0xFF8A5A00))),
    ),
    const SizedBox(height: 12),
    Text('정지 ${data['seconds_by_label']?['still'] ?? 0}초 · 이동 ${data['seconds_by_label']?['moving'] ?? 0}초 · 회전 ${data['seconds_by_label']?['spinning'] ?? 0}초 · 왕복 ${data['seconds_by_label']?['pacing'] ?? 0}초',
      style: Theme.of(context).textTheme.bodySmall),
    if (data['unobserved_seconds'] != null) Text('미관찰 ${data['unobserved_seconds']}초',
      style: Theme.of(context).textTheme.bodySmall),
    Text('중복·겹침 제외 ${(data['skipped_overlap_ids'] as List? ?? []).length}건 · 날짜 경계 제외 ${(data['excluded_day_boundary_ids'] as List? ?? []).length}건',
      style: Theme.of(context).textTheme.bodySmall),
    const SizedBox(height: 4),
    Text('저장된 분석 구간의 합계입니다. 실제 외출 전체 시간의 활동량이 아닙니다.',
      style: Theme.of(context).textTheme.bodySmall),
  ]);

  @override
  Widget build(BuildContext context) {
    final moments = (report?['moments'] as List? ?? []);
    return Card(child: Padding(padding: const EdgeInsets.all(24), child: Column(
      crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('OUTING JOURNAL', style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: GenesisTheme.secondaryInk, letterSpacing: 1.4, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        Text('외출 모드 · 귀가 리포트', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text('시작 버튼은 기록 묶음을 만듭니다. 카메라 자동 촬영을 시작하지 않습니다.',
          style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 20),
        if (active == null) Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
          DropdownButton<String>(value: mode, items: const [
            DropdownMenuItem(value: 'uploaded_audio', child: Text('사용자 음원')),
            DropdownMenuItem(value: 'prepared_video', child: Text('준비된 영상·음원')),
            DropdownMenuItem(value: 'synthetic_demo', child: Text('합성 시연')),
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
            child: Text(outingLabel(Map<String, dynamic>.from(o)), overflow: TextOverflow.ellipsis))).toList(),
          onChanged: busy ? null : (value) { selected = value; load(); }),
        TextButton(onPressed: busy ? null : load, child: const Text('외출 기록 새로고침')),
        const Divider(height: 32),
        AudioPanel(key: ValueKey(widget.petId), client: widget.client, base: widget.base,
          petId: widget.petId, outing: active, onChanged: () { load(); }),
        if (report == null) const Text('외출을 시작하고 아래에서 관찰 입력을 추가해 주세요.'),
        if (report != null) ...[
          const SizedBox(height: 20),
          metrics(report!),
          const SizedBox(height: 24),
          TextField(controller: question, decoration: const InputDecoration(labelText: '외출 기록에 질문하기'), maxLength: 1000),
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: busy ? null : () => explain(), child: const Text('근거 기반 요약')),
            OutlinedButton(onPressed: busy ? null : () => explain('지난 외출과 비교해 주세요.'), child: const Text('지난 외출과 비교')),
          ]),
          if (explanation != null) ...[
            Text('설명: ${providerLabel(explanation!['provider'])} · ${retrievalLabel(explanation!['retrieval_mode'])}',
              style: Theme.of(context).textTheme.bodySmall),
            if ((explanation!['claims'] as List).isEmpty) Text(explanation!['answer']),
            for (final claim in explanation!['claims']) Padding(padding: const EdgeInsets.only(top: 8), child: Column(
              crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(claim['text']),
                Wrap(children: [for (final id in claim['observation_ids']) TextButton(
                  onPressed: () => openEvidence(id), child: Text('근거 #$id'))]),
              ])),
            if (comparisonRequested(explanation!['question']) &&
                explanation!['report']['comparison']['status'] == 'incompatible_provenance')
              const Text('이전 외출 비교: 공개·합성 시연 자료와 사용자 자료를 섞어 비교하지 않습니다.'),
            if (comparisonRequested(explanation!['question']) &&
                explanation!['report']['comparison']['status'] != 'sample_rate_comparison' &&
                explanation!['report']['comparison']['status'] != 'incompatible_provenance')
              const Text('이전 외출 비교: 같은 입력 방식의 충분한 기록이 필요합니다.'),
          ],
          const SizedBox(height: 24),
          Text('중요한 순간 · 관찰 근거', style: Theme.of(context).textTheme.titleMedium),
          if (moments.isEmpty) const Text('저장된 관찰이 없습니다.'),
          for (final item in moments) ListTile(contentPadding: EdgeInsets.zero,
            title: Text('#${item['observation_id']} · ${item['reason']}'), subtitle: Text(item['summary']),
            trailing: TextButton(onPressed: item['media_available'] == true || item['audio_available'] == true ? () => openMoment(Map<String, dynamic>.from(item)) : null,
              child: Text(item['media_available'] == true ? '구간 보기' : item['audio_available'] == true ? '음원 듣기' : '원본 없음'))),
        ],
        const Divider(height: 40),
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
                onPressed: () => openEvidence(id), child: Text('하루 근거 #$id'))]),
            ]),
          Text(dayExplanation!['note']),
        ],
        if (busy) const LinearProgressIndicator(),
        if (error.isNotEmpty) Text(error, style: const TextStyle(color: Colors.orange)),
      ],
    )));
  }
}
