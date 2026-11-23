import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import { describeCode, isKnownErrorCode, statusForCode } from './errors.ts';

Deno.test('an expired handover acknowledgement is a definite refusal rather than an unknown server failure', () => {
  assertEquals(isKnownErrorCode('INFO_ACK_NOT_ACTIONABLE'), true);
  assertEquals(statusForCode('INFO_ACK_NOT_ACTIONABLE'), 409);
  assertStringIncludes(describeCode('INFO_ACK_NOT_ACTIONABLE'), '最新の共有');
  assertEquals(isKnownErrorCode('INFO_NOT_FOUND'), true);
  assertEquals(statusForCode('INFO_NOT_FOUND'), 404);
});

Deno.test('an outdated unperformed-work undo uses the same clear label as the app', () => {
  assertEquals(statusForCode('TASK_NOT_COULD_NOT_DO'), 409);
  assertStringIncludes(describeCode('TASK_NOT_COULD_NOT_DO'), '今日はなし（実施せず）');
});
