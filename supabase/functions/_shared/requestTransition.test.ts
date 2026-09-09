import { assertEquals, assertThrows } from 'jsr:@std/assert@1';
import { requestTransitionArgs } from './requestTransition.ts';
Deno.test('PWA and LINE bind equivalent observed attempt/terms commands', () => {
  const fixture = { request_id: 'r', attempt_id: 'a', action: 'accept', expected_revision: 2, expected_terms_revision: 1 };
  const pwa = requestTransitionArgs('user', 'op', fixture, 'pwa');
  const line = requestTransitionArgs('user', 'op', fixture, 'line');
  assertEquals({ ...pwa, p_source: 'line' }, line);
});
Deno.test('old ID-only LINE action and missing CAS cannot be upgraded to current consent', () => {
  for (const patch of [{ attempt_id: undefined }, { expected_revision: undefined }, { expected_revision: null }, { expected_terms_revision: undefined }]) {
    assertThrows(() => requestTransitionArgs('u', 'op', { request_id: 'r', attempt_id: 'a', action: 'accept', expected_revision: 1, expected_terms_revision: 1, ...patch }, 'line'));
  }
});
