import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";
import { clearLineRequestContext, type LineMustCompleteContext, tryHandleLineMustCompletePostback, tryHandleLineMustCompleteText } from "./lineMustComplete.ts";

type Row = Record<string, unknown>;
function fixture(count = 3) {
  const actor = "self", household = "home", selfRef = "self-ref";
  const requests: Row[] = Array.from({ length: count }, (_, i) => ({ id: `request-${i + 1}`, request_kind: "light", shared_title: `お願い${i + 1}`, due_at: "2027-02-05T09:00:00Z", requester_actor_ref_id: "partner-ref", recipient_actor_ref_id: selfRef, revision: 1, household_id: household, test_context_id: null }));
  const attempts: Row[] = requests.map((r, i) => ({ id: `attempt-${i + 1}`, request_id: r.id, state: "consulting", revision: 4, terms_revision: 2, terms: { candidate: `元のメモ${i + 1}` }, created_at: `2027-02-01T00:00:0${i}Z`, household_id: household, test_context_id: null }));
  let context: Row | null = null;
  const replies: Array<{ text: string; quick: LineQuickReplyAction[] }> = [];
  const writes: Row[] = [];
  const receipts = new Map<unknown, Row>();
  const queries: Array<{ table: string; filter: string; key: string; value: unknown }> = [];
  let readError = false, contextError = false, expireOnWrite = false;
  const client = {
    from(table: string) {
      let rows = table === "domain_actor_refs" ? [{ id: selfRef, actor_kind: "real_user", real_user_id: actor, household_id: household, test_context_id: null }] : table === "requests" ? [...requests] : [...attempts];
      const q = {
        select: () => q,
        eq: (key: string, value: unknown) => { queries.push({ table, filter: "eq", key, value }); rows = rows.filter((row) => row[key] === value); return q; },
        is: (key: string, value: unknown) => { queries.push({ table, filter: "is", key, value }); rows = rows.filter((row) => row[key] === value); return q; },
        in: (key: string, value: unknown[]) => { rows = rows.filter((row) => value.includes(row[key])); return q; },
        or: () => q,
        order: () => q,
        maybeSingle: () => Promise.resolve({ data: rows[0] ?? null, error: readError ? { message: "read down" } : null }),
        then: (resolve: (value: unknown) => unknown) => Promise.resolve({ data: rows, error: readError ? { message: "read down" } : null }).then(resolve),
      };
      return q;
    },
    rpc(name: string, args: Row) {
      if (name === "server_tx_line_request_context") {
        if (contextError) return Promise.resolve({ data: null, error: { message: "context unavailable" } });
        if (args.p_action === "set") context = { ...args.p_context as Row };
        if (args.p_action === "clear") context = null;
        return Promise.resolve({ data: context, error: null });
      }
      assert(["server_tx_transition_request_v2", "server_tx_line_decline_request_comment"].includes(name));
      const receipt = receipts.get(args.p_operation_id);
      if (receipt) return Promise.resolve({ data: receipt, error: null });
      const attempt = attempts.find((a) => a.id === args.p_attempt_id)!;
      if (args.p_expected_revision !== attempt.revision || args.p_expected_terms_revision !== attempt.terms_revision)
        return Promise.resolve({ data: null, error: { message: "REVISION_CONFLICT" } });
      writes.push(args);
      assertEquals(args.p_actor_id, actor);
      attempt.revision = Number(attempt.revision) + 1;
      if (expireOnWrite) attempt.state = "expired";
      else if (name === "server_tx_line_decline_request_comment") {
        assert(["pending", "checking"].includes(String(attempt.state)));
        attempt.state = "declined";
        attempt.terms = { ...attempt.terms as Row, decline_comment: args.p_comment };
      } else assertEquals(args.p_source, "line");
      if (!expireOnWrite && args.p_action === "edit_terms") {
        attempt.terms = args.p_terms;
        attempt.terms_revision = Number(attempt.terms_revision) + 1;
        attempt.state = "awaiting_confirmation";
      }
      const data = { state: attempt.state };
      receipts.set(args.p_operation_id, data);
      return Promise.resolve({ data, error: null });
    },
  } as unknown as LineMustCompleteContext["client"];
  const ctx: LineMustCompleteContext = { client, actorId: actor, householdId: household, eventId: "event-1", reply: (text, quick = []) => { replies.push({ text, quick }); return Promise.resolve(); } };
  const click = async (label: string, extra: Row = {}) => {
    const action = replies.at(-1)!.quick.find((a) => a.label === label);
    assert(action && "data" in action);
    await tryHandleLineMustCompletePostback(ctx, { ...Object.fromEntries(new URLSearchParams(action.data)), ...extra } as Record<string, string>);
  };
  return { ctx, requests, attempts, replies, writes, queries, click, setContext: (value: Row | null) => context = value, failReads: () => readError = true, failContext: () => contextError = true, expireOnSend: () => expireOnWrite = true };
}

Deno.test("LINE selects the second of several consultations and keeps memo/deadline on that request", async () => {
  const f = fixture();
  assertEquals(await tryHandleLineMustCompleteText(f.ctx, "お願いの返事"), true);
  assertStringIncludes(f.replies.at(-1)!.text, "どのお願い");
  assertEquals(f.writes.length, 0);
  await f.click("2件目を開く");
  assertStringIncludes(f.replies.at(-1)!.text, "お願い2");
  const picker = f.replies.at(-1)!.quick.find((a) => a.label === "作業期限を変更");
  assert(picker?.type === "datetimepicker");
  assert(!picker.data.includes("2026-09-11"));
  await f.click("相談メモを書く");
  await tryHandleLineMustCompleteText(f.ctx, "相談メモ：18時ならできる");
  assertEquals(f.writes[0].p_request_id, "request-2");
  assertEquals((f.attempts[1].terms as Row).candidate, "18時ならできる");
  assertEquals((f.attempts[0].terms as Row).candidate, "元のメモ1");
  await f.click("条件を確認"); // Reopens latest revision after saving.
  await f.click("作業期限を変更", { datetime: "2027-02-06T18:30" });
  assertEquals(f.writes[1].p_request_id, "request-2");
  assertEquals(((f.writes[1].p_terms as Row).material_patch as Row).work_due_at, "2027-02-06T09:30:00.000Z");
  assertEquals((f.writes[1].p_terms as Row).candidate, "18時ならできる");
  assertEquals(f.writes.length, 2);
  assert(f.queries.some((q) => q.table === "requests" && q.key === "household_id" && q.value === "home"));
  assert(f.queries.some((q) => q.table === "request_attempts" && q.key === "test_context_id" && q.value === null));
});

Deno.test("LINE does not infer a consultation after selection clear, expiry, or concurrent revision", async () => {
  const f = fixture(1);
  await tryHandleLineMustCompleteText(f.ctx, "お願いの返事");
  await clearLineRequestContext(f.ctx);
  await tryHandleLineMustCompleteText(f.ctx, "相談メモ：これは新しい話");
  assertEquals(f.writes.length, 0); // A sole consultation still requires explicit scope.
  await tryHandleLineMustCompleteText(f.ctx, "お願いの返事");
  f.setContext({ expired: true });
  await tryHandleLineMustCompleteText(f.ctx, "条件期限 2027-02-05 18:30");
  assertEquals(f.writes.length, 0);
  await tryHandleLineMustCompleteText(f.ctx, "お願いの返事");
  f.attempts[0].revision = 5;
  await f.click("作業期限を変更", { datetime: "2027-02-06T18:30" });
  assertEquals(f.writes.length, 0);
  assertStringIncludes(f.replies.at(-1)!.text, "もう一度選んで");
});

Deno.test("LINE request pages remain reachable and old attempts do not revive after a terminal attempt", async () => {
  const f = fixture(7);
  f.attempts.push({ ...f.attempts[0], id: "new-terminal", created_at: "2027-02-02T00:00:00Z", state: "accepted" });
  await tryHandleLineMustCompleteText(f.ctx, "お願いの返事");
  assert(!f.replies.at(-1)!.text.includes("お願い1\n"));
  await f.click("次のお願い");
  assertStringIncludes(f.replies.at(-1)!.text, "お願い7");
  await f.click("6件目を開く");
  assertStringIncludes(f.replies.at(-1)!.text, "お願い7");
  assertEquals(f.writes.length, 0);
});

Deno.test("LINE request read and context failures do not become empty or authorizing state", async () => {
  const f = fixture();
  f.failReads();
  await tryHandleLineMustCompleteText(f.ctx, "お願いの返事");
  assertStringIncludes(f.replies.at(-1)!.text, "読み込めません");
  const g = fixture(1);
  g.failContext();
  await tryHandleLineMustCompleteText(g.ctx, "相談メモ：続ける");
  assertEquals(g.writes.length, 0);
  let threw = false;
  try { await clearLineRequestContext(g.ctx); } catch { threw = true; }
  assert(threw); // Caller must retry an unrelated event before moving topics.
});

Deno.test("LINE comment decline requires its exact preview and replays one canonical decision", async () => {
  const f = fixture();
  f.attempts.forEach((a) => a.state = "pending");
  await tryHandleLineMustCompleteText(f.ctx, "お願いの返事");
  await f.click("2件目を開く");
  await f.click("コメント付きで難しい");
  await tryHandleLineMustCompleteText(f.ctx, "辞退コメント：今日は間に合いません");
  const firstPreview = f.replies.at(-1)!.quick.find((a) => a.label === "この内容で返す");
  assert(firstPreview && "data" in firstPreview);
  assertEquals(f.writes.length, 0);
  await tryHandleLineMustCompleteText(f.ctx, "辞退コメント：明日なら引き受けられます");
  const latestPreview = f.replies.at(-1)!.quick.find((a) => a.label === "この内容で返す");
  assert(latestPreview && "data" in latestPreview);
  await tryHandleLineMustCompletePostback(f.ctx, Object.fromEntries(new URLSearchParams(firstPreview.data)));
  assertEquals(f.writes.length, 0);
  assertStringIncludes(f.replies.at(-1)!.text, "内容が変わりました");
  const fields = Object.fromEntries(new URLSearchParams(latestPreview.data));
  await tryHandleLineMustCompletePostback(f.ctx, fields);
  assertEquals(f.writes.length, 1);
  assertEquals(f.writes[0].p_request_id, "request-2");
  assertEquals(f.writes[0].p_comment, "明日なら引き受けられます");
  assertEquals(f.attempts[1].state, "declined");
  assertEquals(f.attempts[0].state, "pending");
  await tryHandleLineMustCompletePostback(f.ctx, fields);
  assertEquals(f.writes.length, 1); // Same webhook event receives the existing receipt.
  f.ctx.eventId = "event-new-tap";
  await tryHandleLineMustCompletePostback(f.ctx, fields);
  assertEquals(f.writes.length, 1); // A retry tap also uses the immutable preview receipt.
});

Deno.test("LINE request refuses ambiguous latest attempts and changed decline scope", async () => {
  const f = fixture(1);
  f.attempts.push({ ...f.attempts[0], id: "ambiguous-attempt" });
  await tryHandleLineMustCompleteText(f.ctx, "お願いの返事");
  assertStringIncludes(f.replies.at(-1)!.text, "ありません");
  assertEquals(f.writes.length, 0);
  const g = fixture(1);
  g.attempts[0].state = "pending";
  await tryHandleLineMustCompleteText(g.ctx, "お願いの返事");
  await g.click("コメント付きで難しい");
  await tryHandleLineMustCompleteText(g.ctx, "辞退コメント：難しいです");
  g.attempts[0].revision = 5;
  await g.click("この内容で返す");
  assertEquals(g.writes.length, 0);
  assertStringIncludes(g.replies.at(-1)!.text, "古くなっています");
});

Deno.test("LINE decline preview expiring before send never claims a declined result", async () => {
  const f = fixture(1);
  f.attempts[0].state = "pending";
  await tryHandleLineMustCompleteText(f.ctx, "お願いの返事");
  await f.click("コメント付きで難しい");
  await tryHandleLineMustCompleteText(f.ctx, "辞退コメント：間に合いません");
  f.expireOnSend();
  await f.click("この内容で返す");
  assertEquals(f.attempts[0].state, "expired");
  assertEquals((f.attempts[0].terms as Row).decline_comment, undefined);
  assertStringIncludes(f.replies.at(-1)!.text, "返事期限を過ぎています");
});

Deno.test("LINE consultation deadline crossed during memo or deadline save reports canonical expiry", async () => {
  const f = fixture(1);
  await tryHandleLineMustCompleteText(f.ctx, "お願いの返事");
  f.expireOnSend();
  await tryHandleLineMustCompleteText(f.ctx, "相談メモ：期限をまたいだ入力");
  assertEquals((f.attempts[0].terms as Row).candidate, "元のメモ1");
  assertStringIncludes(f.replies.at(-1)!.text, "返事期限を過ぎています");
  const g = fixture(1);
  await tryHandleLineMustCompleteText(g.ctx, "お願いの返事");
  g.expireOnSend();
  await g.click("作業期限を変更", { datetime: "2027-02-06T18:30" });
  assertEquals((g.attempts[0].terms as Row).material_patch, undefined);
  assertStringIncludes(g.replies.at(-1)!.text, "返事期限を過ぎています");
});
