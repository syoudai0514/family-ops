import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

type Handler = (request: Request) => Promise<Response>;
type Pending = { id: string; status: string; action_type: string; revision: number; normalized_payload: Record<string, unknown> };

// Exercise the worker entrypoint, including its actor resolution and dispatch.
// All database, model and LINE calls are mocked; no live provider is contacted.
Deno.test("LINE native editor and partial completion reach scoped canonical commands", async (t) => {
  const env = {
    SUPABASE_URL: "https://native-completion-test.supabase.co",
    SUPABASE_SERVICE_ROLE_KEY: "test-service",
    CRON_WORKER_TOKEN: "native-test-worker",
    LINE_CHANNEL_ACCESS_TOKEN: "test-line-token",
    APP_BASE_URL: "https://family-test.example.com",
    GEMINI_API_KEY: "test-gemini-key",
    GEMINI_MODEL_LINE_UNDERSTAND: "native-http-understand",
  };
  const previous = Object.fromEntries(Object.keys(env).map((key) => [key, Deno.env.get(key)]));
  for (const [key, value] of Object.entries(env)) Deno.env.set(key, value);
  const originalFetch = globalThis.fetch;
  const originalServe = Object.getOwnPropertyDescriptor(Deno, "serve")!;
  let handler: Handler | undefined;
  Object.defineProperty(Deno, "serve", { configurable: true, value: (value: Handler) => { handler = value; } });
  const actorId = "20000000-0000-4000-8000-000000000001";
  const partnerId = "20000000-0000-4000-8000-000000000002";
  const householdId = "30000000-0000-4000-8000-000000000001";
  const pendingId = "40000000-0000-4000-8000-000000000001";
  const taskId = "50000000-0000-4000-8000-000000000001";
  const tomorrowTaskId = "50000000-0000-4000-8000-000000000002";
  const childId = "60000000-0000-4000-8000-000000000001";
  const today = new Date(Date.now() + 9 * 3600_000).toISOString().slice(0, 10);
  const tomorrow = new Date(Date.now() + 33 * 3600_000).toISOString().slice(0, 10);
  let eventTimestamp = Date.now() - 10_000;
  const originalPayload = {
    title: "送り", scheduled_date: today, due_at: `${today}T08:00:00+09:00`, task_id: taskId,
    recipient_user_id: partnerId, target_label: "ママ", scope: "once", shared_message: "送りをお願いできますか？",
  };
  let pending: Pending | null = { id: pendingId, status: "draft", action_type: "assignment_change_request", revision: 2,
    normalized_payload: { ...originalPayload } };
  let text = "";
  let postback: string | null = null;
  let postbackParams: { datetime: string } | null = null;
  let event = 0;
  let aiEnabled = false;
  let staleUpdate = false;
  let deniedRead = false;
  let childCompleted = false;
  let partialMode: "child" | "progress" | "whole-and-child" | "child-and-legacy" = "child";
  const replies: Record<string, unknown>[] = [];
  const calls: Array<{ rpc: string; args: Record<string, unknown> }> = [];
  const prompts: string[] = [];
  const unexpected: string[] = [];
  const rpcError = (message: string) => Response.json({ code: "P0001", message }, { status: 400 });
  globalThis.fetch = (input, init) => {
    const url = new URL(input instanceof Request ? input.url : String(input));
    const body = JSON.parse(String((init as { body?: unknown } | undefined)?.body ?? "{}"));
    if (url.hostname === "api.line.me" && url.pathname === "/v2/bot/message/reply") {
      replies.push(body);
      return Promise.resolve(Response.json({}));
    }
    if (url.hostname === "generativelanguage.googleapis.com") {
      prompts.push(body.contents[0].parts[0].text);
      const partial = { type: "complete_subtask", ref: "t1", subtask_ref: "t1c1", by: "self", source: "洗濯を回した" };
      const actions = partialMode === "progress"
        ? [{ type: "record_progress", ref: "t1", by: "self", source: text, observed: null,
          done: "洗濯を回した", remaining: "干すのはまだ", next: null }]
        : partialMode === "whole-and-child" ? [{ type: "complete_task", ref: "t1", by: "self" }, partial]
        : partialMode === "child-and-legacy" ? [partial, { type: "legacy" }] : [partial];
      return Promise.resolve(Response.json({ candidates: [{ content: { parts: [{ text: JSON.stringify({
        understanding: "洗濯の一部を実施", reply: "", confidence: "high", actions,
      }) }] } }] }));
    }
    if (url.hostname === "native-completion-test.supabase.co") {
      const rpc = url.pathname.split("/rpc/")[1];
      if (rpc) {
        calls.push({ rpc, args: body });
        let data: unknown;
        switch (rpc) {
          case "server_tx_claim_webhook_inbox_batch": data = [{
            id: `inbox-${event}`, provider_event_id: `native-event-${event}`, source_external_user_id: "test-line-user",
            attempts: 1, lease_token: "test-lease", payload: { type: postback ? "postback" : "message",
              timestamp: eventTimestamp, replyToken: "test-reply", ...(postback ? { postback: { data: postback, params: postbackParams } } : { message: { type: "text", text } }) },
          }]; break;
          case "server_tx_resolve_line_actor": data = { user_id: actorId, household_id: householdId }; break;
          case "server_tx_line_request_context": data = null; break;
          case "server_tx_get_pending_action":
            if (deniedRead) return Promise.resolve(rpcError("PENDING_ACTION_NOT_EDITABLE"));
            data = pending; break;
          case "server_tx_get_line_conversation_pending": data = pending; break;
          case "server_tx_get_line_pending_text_edit": data = pending?.normalized_payload.line_edit_mode ? pending : null; break;
          case "server_tx_create_pending_action":
            pending = { id: pendingId, status: "draft", action_type: body.p_action_type, revision: 0,
              normalized_payload: body.p_normalized_payload };
            data = { pending_action_id: pendingId }; break;
          case "server_tx_update_pending_action":
            if (staleUpdate || !pending || body.p_expected_revision !== pending.revision) return Promise.resolve(rpcError("PENDING_ACTION_STALE_REVISION"));
            pending = { ...pending, revision: pending.revision + 1, normalized_payload: body.p_normalized_payload };
            data = pending; break;
          case "server_read_line_saved_task_v1": data = {
            pending_action_id: pendingId, task_id: taskId, household_id: householdId, title: "ごみ出し",
            scheduled_date: today, due_at: `${today}T08:00:00+09:00`, status: "todo", revision: 4,
            can_reschedule: true, can_reopen: false,
          }; break;
          case "server_tx_correct_line_saved_task_v1": data = {
            ok: true, action: body.p_action, pending_action_id: pendingId, task_id: taskId, household_id: householdId,
            title: "ごみ出し", scheduled_date: tomorrow, due_at: body.p_new_due_at, status: "todo", revision: 5,
          }; break;
          case "server_read_line_understand_enabled": data = aiEnabled; break;
          case "server_read_line_understand_model": data = "native-http-understand"; break;
          case "server_tx_reserve_ai_call": data = true; break;
          case "server_read_line_turns": data = []; break;
          case "server_tx_set_subtask_completion": data = { revision: 5 }; break;
          case "server_tx_record_task_progress": data = { task_id: taskId, revision: 5 }; break;
          case "server_tx_log_line_turn":
          case "server_tx_complete_webhook_inbox_item": data = { ok: true }; break;
          default: unexpected.push(rpc); data = null;
        }
        return Promise.resolve(Response.json(data));
      }
      const table = url.pathname.split("/").at(-1);
      if (table === "household_members") return Promise.resolve(Response.json([
        { household_id: householdId, user_id: actorId, family_role: "papa" },
        { household_id: householdId, user_id: partnerId, family_role: "mama" },
      ]));
      if (table === "task_instances" && [taskId, tomorrowTaskId].some((id) => url.searchParams.get("id") === `eq.${id}`)) {
        return Promise.resolve(Response.json([{ task_definition_id: "native-transport-definition" }]));
      }
      if (table === "task_instances" && url.searchParams.get("task_definition_id") === "eq.native-transport-definition") {
        const targetDate = url.searchParams.get("scheduled_date")?.slice(3) ?? tomorrow;
        return Promise.resolve(Response.json([{ id: targetDate === tomorrow ? tomorrowTaskId : taskId, title: "送り", scheduled_date: targetDate,
          due_at: `${targetDate}T09:15:00+09:00` }]));
      }
      if (table === "task_instances") return Promise.resolve(Response.json(
        url.searchParams.get("scheduled_date") === `eq.${today}` ? [{
          id: taskId, title: "洗濯", scheduled_date: today, status: "in_progress", planned_assignee_id: actorId,
          task_definition_id: null, revision: 4, completion_mode: "subtasks", due_at: null,
        }] : [],
      ));
      if (table === "task_subtask_instances") return Promise.resolve(Response.json([
        { id: childId, task_instance_id: taskId, title: "洗濯を回す", is_completed: childCompleted, required: true, sort_order: 0 },
        { id: "60000000-0000-4000-8000-000000000002", task_instance_id: taskId, title: "干す", is_completed: false, required: true, sort_order: 1 },
      ]));
      if (["task_definitions", "shopping_items", "child_school_contexts", "handovers"].includes(table ?? "")) {
        return Promise.resolve(Response.json([]));
      }
    }
    unexpected.push(url.hostname + url.pathname);
    return Promise.reject(new Error("Unexpected mocked provider request"));
  };
  const run = async (message = "", button: string | null = null, params: { datetime: string } | null = null) => {
    text = message; postback = button; postbackParams = params; event++;
    calls.length = replies.length = prompts.length = unexpected.length = 0;
    const response = await handler!(new Request("https://worker.test/process-line-inbox", {
      method: "POST", headers: { "X-Family-Ops-Worker-Token": env.CRON_WORKER_TOKEN },
    }));
    assertEquals(response.status, 200);
    assertEquals(await response.json(), { claimed: 1, succeeded: 1, failed: 0 });
    assertEquals(unexpected, []);
  };
  const rendered = () => JSON.stringify(replies);
  const mutations = () => calls.filter((call) => /update_pending|correct_line_saved|set_subtask|record_task_progress|complete_task|create_pending|confirm_pending/.test(call.rpc));
  try {
    await import("./index.ts");
    Object.defineProperty(Deno, "serve", originalServe);
    await t.step("sender edit opens in LINE with actor revision and original webhook clock", async () => {
      await run("", `action=edit_pending&pending_action_id=${pendingId}`);
      assertEquals(mutations().length, 1);
      const update = mutations()[0];
      assertEquals(update.rpc, "server_tx_update_pending_action");
      assertEquals(update.args.p_actor_id, actorId);
      assertEquals(update.args.p_expected_revision, 2);
      assertEquals(update.args.p_line_event_timestamp, eventTimestamp);
      assertEquals(pending!.normalized_payload, { ...originalPayload, line_edit_mode: true });
      assertStringIncludes(rendered(), "文面: …");
      assertStringIncludes(rendered(), "field=scope&value=this_week");
      assertEquals(rendered().includes('"uri"'), false);
    });
    await t.step("wording edit preserves linked task and returns scoped native confirmation", async () => {
      await run("文面: 朝の送りをお願いできますか？");
      assertEquals(mutations().length, 1);
      assertEquals(mutations()[0].args.p_expected_revision, 3);
      assertEquals(pending!.normalized_payload, { ...originalPayload, line_edit_mode: false, shared_message: "朝の送りをお願いできますか？" });
      assertStringIncludes(rendered(), `action=confirm_pending&pending_action_id=${pendingId}`);
      assertStringIncludes(rendered(), `action=edit_pending&pending_action_id=${pendingId}`);
      assertEquals(rendered().includes('"uri"'), false);
    });
    await t.step("typed calendar date resolves real matching task and its original time", async () => {
      await run("", `action=edit_pending&pending_action_id=${pendingId}`);
      await run(`${tomorrow}に変更して`);
      assertEquals(mutations().length, 1);
      assertEquals(pending!.normalized_payload.task_id, tomorrowTaskId);
      assertEquals(pending!.normalized_payload.scheduled_date, tomorrow);
      assertEquals(pending!.normalized_payload.due_at, `${tomorrow}T09:15:00+09:00`);
      assertStringIncludes(rendered(), "09:15");
      staleUpdate = true;
      await run("今日に変更して");
      assertEquals(mutations().map((call) => call.rpc), ["server_tx_update_pending_action"]);
      assertStringIncludes(rendered(), "新しい作業やお願いは作成していません");
      staleUpdate = false;
    });
    await t.step("stale edit start and forged generic date buttons cannot rewrite assignment task", async () => {
      staleUpdate = true;
      const before = structuredClone(pending);
      await run("", `action=edit_pending&pending_action_id=${pendingId}`);
      assertEquals(pending, before);
      assertStringIncludes(rendered(), "下書きが更新されています");
      staleUpdate = false;
      await run("", `action=update_pending&pending_action_id=${pendingId}&field=date&value=tomorrow`);
      assertEquals(mutations(), []);
      assertStringIncludes(rendered(), "実際の予定を確認して編集");
    });
    await t.step("foreign or closed pending ID is rejected before any update", async () => {
      deniedRead = true;
      await run("", "action=edit_pending&pending_action_id=40000000-0000-4000-8000-000000000099");
      assertEquals(mutations(), []);
      assertStringIncludes(rendered(), "確定・期限切れ");
      deniedRead = false;
    });
    await t.step("completed input opens persisted saved target instead of drafting a duplicate", async () => {
      pending = { id: pendingId, status: "succeeded", revision: 3, action_type: "task_create_once",
        normalized_payload: { title: "ごみ出し", scheduled_date: today } };
      await run("さっきのごみ出しを明日に変更して");
      assertEquals(mutations(), []);
      assertStringIncludes(rendered(), "登録済みの内容");
      assertStringIncludes(rendered(), '"type":"datetimepicker"');
      assertEquals(calls.find((call) => call.rpc === "server_read_line_saved_task_v1")?.args, {
        p_actor_id: actorId, p_pending_action_id: pendingId,
      });
    });
    await t.step("saved datetime selection comes only from provider params and needs confirmation", async () => {
      const picker = `action=lst_reschedule&pending_action_id=${pendingId}&revision=4&datetime=2026-01-01T01%3A00`;
      await run("", picker);
      assertEquals(mutations(), []);
      assertStringIncludes(rendered(), "安全に確認できない");
      await run("", picker, { datetime: `${tomorrow}T08:30` });
      assertEquals(mutations(), []);
      assertStringIncludes(rendered(), "まだ変更していません");
      assertStringIncludes(rendered(), `due=${tomorrow}T08%3A30`);
      assertEquals(rendered().includes("due=2026-01-01"), false);
    });
    await t.step("saved correction confirm edits original target with revision and replay stable operation", async () => {
      const confirm = `action=lst_apply&pending_action_id=${pendingId}&revision=4&due=${tomorrow}T08%3A30`;
      await run("", confirm);
      assertEquals(mutations().length, 1);
      const first = mutations()[0];
      assertEquals(first.rpc, "server_tx_correct_line_saved_task_v1");
      assertEquals(first.args.p_actor_id, actorId);
      assertEquals(first.args.p_pending_action_id, pendingId);
      assertEquals(first.args.p_expected_revision, 4);
      assertEquals(first.args.p_new_due_at, new Date(`${tomorrow}T08:30:00+09:00`).toISOString());
      assertStringIncludes(rendered(), "日時を変更しました");
      await run("", confirm);
      assertEquals(mutations()[0].args.p_operation_id, first.args.p_operation_id);
    });
    await t.step("queued creation shortcuts preserve the LINE event day across JST midnight", async () => {
      const usualTimestamp = eventTimestamp;
      eventTimestamp = Date.parse(`${today}T00:05:00+09:00`) - 10 * 60_000;
      const sourceDay = new Date(eventTimestamp + 9 * 3600_000).toISOString().slice(0, 10);
      pending = null;
      await run("予定を追加したい");
      const undated = calls.find((call) => call.rpc === "server_tx_create_pending_action")!;
      assertEquals((undated.args.p_normalized_payload as Record<string, unknown>).scheduled_date, sourceDay);
      pending = null;
      await run("明日の予定を追加したい");
      const relative = calls.find((call) => call.rpc === "server_tx_create_pending_action")!;
      assertEquals((relative.args.p_normalized_payload as Record<string, unknown>).scheduled_date, today);
      eventTimestamp = usualTimestamp;
    });
    await t.step("AI partial report completes only referenced child using parent revision", async () => {
      pending = null; aiEnabled = true;
      await run("洗濯を回した。干すのはまだ");
      assertEquals(mutations().length, 1);
      assertEquals(mutations()[0].rpc, "server_tx_set_subtask_completion");
      assertEquals(mutations()[0].args.p_actor_id, actorId);
      assertEquals(mutations()[0].args.p_subtask_instance_id, childId);
      assertEquals(mutations()[0].args.p_expected_revision, 4);
      assertEquals(mutations()[0].args.p_completion_actor, "self");
      assertEquals(mutations()[0].args.p_completed, true);
      assert(typeof mutations()[0].args.p_operation_id === "string");
      assert(prompts.some((prompt) => prompt.includes("t1c1") && prompt.includes("洗濯を回す")));
      assert(prompts.every((prompt) => !prompt.includes(childId) && !prompt.includes(taskId)));
      assertStringIncludes(rendered(), "ほかの項目は変更していません");
    });
    await t.step("mixed whole and partial model proposal never completes the parent", async () => {
      partialMode = "whole-and-child";
      await run("洗濯を回した。干すのはまだ");
      assertEquals(mutations().map((call) => call.rpc), ["server_tx_set_subtask_completion"]);
    });
    await t.step("replayed partial report against updated child cannot become a new draft or whole completion", async () => {
      childCompleted = true; partialMode = "child-and-legacy";
      await run("洗濯を回した。干すのはまだ");
      assertEquals(mutations(), []);
      assertStringIncludes(rendered(), "作業全体の完了や新しい作業の作成は行っていません");
      childCompleted = false;
    });
    await t.step("unmatched partial work records remaining work with no share or completion", async () => {
      partialMode = "progress";
      await run("洗濯を回した、干すのはまだ");
      assertEquals(mutations().length, 1);
      assertEquals(mutations()[0].rpc, "server_tx_record_task_progress");
      assertEquals(mutations()[0].args.p_expected_revision, 4);
      assertEquals(mutations()[0].args.p_share_with_household, false);
      assertStringIncludes(rendered(), "干すのはまだ");
      assertStringIncludes(rendered(), "作業の完了や相手への送信は行っていません");
    });
  } finally {
    globalThis.fetch = originalFetch;
    Object.defineProperty(Deno, "serve", originalServe);
    for (const [key, value] of Object.entries(previous)) value === undefined ? Deno.env.delete(key) : Deno.env.set(key, value);
  }
});
