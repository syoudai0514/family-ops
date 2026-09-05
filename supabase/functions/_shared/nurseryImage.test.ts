import { assertEquals, assertThrows } from 'jsr:@std/assert';
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
