import { assertEquals } from 'jsr:@std/assert@1';
import { applyConfirmedTerminology } from './lineTerminology.ts';

Deno.test('confirmed terminology is parser input and longest phrase wins', () => {
  assertEquals(applyConfirmedTerminology('明日、送りと送をお願い', [
    { phrase: '送', meaning: '配送' }, { phrase: '送り', meaning: '保育園の送り' },
  ]), '明日、保育園の送りと配送をお願い');
});
Deno.test('deleted or unconfirmed terms are not applied at the parser boundary', () => {
  assertEquals(applyConfirmedTerminology('夜の家事をする', []), '夜の家事をする');
});
