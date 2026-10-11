"""Deterministic scoped fact ranking; guardian notes remain evidence, never commands."""
import re
import unicodedata
from collections import deque

INTENTS = {
    'comparison': ('비교', '지난', '이전', '차이', '늘었', '줄었', '전보다'),
    'guardian_opinion': ('보호자', '의견', '메모', '확인한', '확인했', '사용자', 'tv', '텔레비전', '외부 소리'),
    'bark': ('짖', '소리', '소음', '발성'),
    'quality': ('판단', 'unknown', '추적', '불확실', '누락', '분석 안', '구분하지 못', '알 수 없', '불분명', '인식 못'),
    'summary': ('요약', '외출', '관찰', '오늘', '귀가', '정리', '기록'),
}


def question_intents(question):
    question = ' '.join(unicodedata.normalize('NFKC', question).lower().split())
    requested = [kind for kind, terms in INTENTS.items() if any(t in question for t in terms)]
    if re.search(r'(분석|녹음|저장|표본).{0,15}(분량|몇\s*초|얼마|길이|총\s*시간)', question):
        requested.append('summary')
    return list(dict.fromkeys(requested))


def select_facts(facts, question, limit=8):
    """Reserve a slot per requested evidence kind before filling recent details.

    Matching is over the user's question, not instructions in guardian notes.
    All input facts must already have passed pet/session scoping.
    """
    if limit < 1:
        return []
    requested = question_intents(question)
    if not requested:
        return []
    normalized_question = unicodedata.normalize('NFKC', question).lower()
    if '보호자' in normalized_question:
        facts = [fact for fact in facts if fact['kind'] != 'guardian_opinion' or
                 fact.get('review_source', 'guardian_opinion') == 'guardian_opinion']
    kinds = list(requested)
    if 'summary' in kinds:
        kinds += ['quality', 'bark', 'guardian_opinion', 'observation']
    if 'bark' in kinds:
        # A sound count must not conceal missing/undecidable observation time.
        kinds += ['quality', 'guardian_opinion', 'observation']
    if 'comparison' in kinds:
        kinds += ['summary', 'quality']
    kinds = list(dict.fromkeys(kinds))
    buckets = {kind: [f for f in facts if f['kind'] == kind] for kind in kinds}
    # Facts are built in observation-ID order, so prefer recent details.
    for kind in ('guardian_opinion', 'observation'):
        if kind in buckets:
            buckets[kind].reverse()
    buckets = {kind: deque(values) for kind, values in buckets.items()}
    result, seen = [], set()
    while len(result) < limit:
        added = False
        for kind in kinds:
            while buckets[kind] and buckets[kind][0]['id'] in seen:
                buckets[kind].popleft()
            if buckets[kind] and len(result) < limit:
                fact = buckets[kind].popleft()
                result.append(fact)
                seen.add(fact['id'])
                added = True
        if not added:
            break
    return result
