import { assertEquals, assertStringIncludes } from 'jsr:@std/assert@1';
import { missingRoleQuickReplies, missingRoleRecoveryText } from './linePartnerInviteFlow.ts';

Deno.test('missing partner role preserves the draft and exposes a safe invite recovery', () => {
  const text = missingRoleRecoveryText('mama', false);
  assertStringIncludes(text, 'ママはまだおうちノートに参加していません');
  assertStringIncludes(text, '下書きはそのまま');

  const quickReplies = missingRoleQuickReplies('pending-1', 'mama');
  assertEquals(quickReplies.map((item) => item.label), [
    '招待リンクを作る',
    '自分に戻す',
    'キャンセル',
  ]);
  assertEquals(
    (quickReplies[0] as { data: string }).data,
    'action=create_partner_invite&pending_action_id=pending-1',
  );
});

Deno.test('a joined partner with no P/M role gets a role-setup explanation, not an invite', () => {
  const text = missingRoleRecoveryText('papa', true);
  assertStringIncludes(text, 'パパの役割がまだ決まっていません');
  assertStringIncludes(text, '設定 ＞ 家族');
});
