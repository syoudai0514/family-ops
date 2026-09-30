import { assertEquals, assertThrows } from 'jsr:@std/assert@1';
import {
  assertPrivacySafeStructuredValue,
  classifyTimetableItem,
  isSafeExternalUrl,
  mayGroupNurseryPages,
  requiredClarificationFields,
  validateBoundedRecurrence,
} from './nurseryImage.ts';

Deno.test('Q92 only groups explicitly continuous pages from same household/sender', () => {
  assertEquals(mayGroupNurseryPages({ sameDocumentAsPrevious: true, sameHousehold: true, sameLineUser: true, elapsedSeconds: 45, currentPageCount: 2 }), true);
  assertEquals(mayGroupNurseryPages({ sameDocumentAsPrevious: false, sameHousehold: true, sameLineUser: true, elapsedSeconds: 20, currentPageCount: 1 }), false);
  assertEquals(mayGroupNurseryPages({ sameDocumentAsPrevious: true, sameHousehold: false, sameLineUser: true, elapsedSeconds: 20, currentPageCount: 1 }), false);
});

Deno.test('Q100 asks only explicitly ambiguous fields', () => {
  assertEquals(requiredClarificationFields({ triage: 'needs_clarification', same_document_as_previous: false, child_school_context_id: null, context_confidence: 'low', ambiguous_fields: ['child', 'class', 'known_title'], source_facts: [], ai_candidates: [] }), ['child', 'class']);
  assertEquals(requiredClarificationFields({ triage: 'nursery_notice', same_document_as_previous: false, child_school_context_id: 'ctx', context_confidence: 'high', ambiguous_fields: [], source_facts: [], ai_candidates: [] }), []);
});

Deno.test('Q105 rejects unsafe URL schemes', () => {
  assertEquals(isSafeExternalUrl('https://example.jp/form'), true);
  assertEquals(isSafeExternalUrl('http://example.jp/form'), true);
  assertEquals(isSafeExternalUrl('javascript:alert(1)'), false);
  assertEquals(isSafeExternalUrl('data:text/html,hi'), false);
  assertEquals(isSafeExternalUrl('file:///etc/passwd'), false);
});

Deno.test('Q99 rejects explicit third-party/raw-data channels', () => {
  assertPrivacySafeStructuredValue({ title: '遠足', required: ['水筒'] });
  assertThrows(() => assertPrivacySafeStructuredValue({ class_roster: ['A', 'B'] }), Error, 'NURSERY_THIRD_PARTY_DATA_FORBIDDEN');
  assertThrows(() => assertPrivacySafeStructuredValue({ nested: { phone: '090...' } }), Error, 'NURSERY_THIRD_PARTY_DATA_FORBIDDEN');
});

Deno.test('Q101 retains Other timetable classification', () => {
  assertEquals(classifyTimetableItem(true), 'recommended');
  assertEquals(classifyTimetableItem(false), 'other');
});

Deno.test('Q102 recurrence must be bounded', () => {
  assertEquals(validateBoundedRecurrence({ effective_from: '2026-09-01', effective_to: '2027-08-31' }), true);
  assertEquals(validateBoundedRecurrence({ effective_from: '2026-09-01', effective_to: '2028-09-01' }), false);
});

import { buildNurseryResultMessage, keepValidReviewItems } from './nurseryImage.ts';

Deno.test('a failed photo tells the sender to retry or type it', () => {
  const text = buildNurseryResultMessage({ kind: 'failed', itemCount: 0, hasContexts: true, link: 'https://x/r' });
  if (!text.includes('撮り直して') || text.includes('https://x/r')) throw new Error(text);
});

Deno.test('a read photo reports the count, the missing school setup and the review link', () => {
  const ready = buildNurseryResultMessage({ kind: 'review_ready', itemCount: 3, hasContexts: true, link: 'https://x/r' });
  if (ready !== '📷 保育園のお知らせを読み取りました（候補3件）。\n内容を確認して登録してください。\nhttps://x/r') throw new Error(ready);
  const noContext = buildNurseryResultMessage({ kind: 'needs_clarification', itemCount: 3, hasContexts: false, link: '' });
  if (!noContext.includes('まだ登録されていない')) throw new Error(noContext);
  const clarify = buildNurseryResultMessage({ kind: 'needs_clarification', itemCount: 2, hasContexts: true, link: '' });
  if (!clarify.includes('どの子・どのクラス')) throw new Error(clarify);
  const empty = buildNurseryResultMessage({ kind: 'review_ready', itemCount: 0, hasContexts: true, link: '' });
  if (!empty.includes('見つかりませんでした')) throw new Error(empty);
});

Deno.test('one malformed review item no longer discards the others', () => {
  const { kept, dropped } = keepValidReviewItems([1, 2, 3, 4], (n) => {
    if (n === 2) throw new Error('NURSERY_SOURCE_PAGE_INVALID');
    if (n === 4) throw new TypeError("Cannot read properties of null");
  });
  if (JSON.stringify(kept) !== '[1,3]') throw new Error(JSON.stringify(kept));
  if (JSON.stringify(dropped) !== '["NURSERY_SOURCE_PAGE_INVALID","NURSERY_REVIEW_ITEM_INVALID"]') throw new Error(JSON.stringify(dropped));
});
