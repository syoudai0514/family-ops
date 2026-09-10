from pathlib import Path
import re


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor, found {count}")
    return text.replace(old, new, 1)


def write(path: str, text: str) -> None:
    Path(path).write_text(text, encoding="utf-8")


# ---------------------------------------------------------------------------
# LINE worker: route approved LINE-MUST scenarios through the thin canonical
# adapter before the legacy read-only/input fallback or old callback router.
# ---------------------------------------------------------------------------
index_path = "supabase/functions/process-line-inbox/index.ts"
index = Path(index_path).read_text(encoding="utf-8")
if 'from "./lineMustComplete.ts"' not in index:
    anchor = '} from "./lineConversation.ts";\n'
    insertion = '''} from "./lineConversation.ts";\nimport {\n  tryHandleLineMustCompletePostback,\n  tryHandleLineMustCompleteText,\n} from "./lineMustComplete.ts";\n'''
    index = replace_once(index, anchor, insertion, "LINE import")

postback_anchor = '  const fields = parsePostbackData(data);\n\n'
postback_insert = '''  const fields = parsePostbackData(data);\n\n  if (await tryHandleLineMustCompletePostback({\n    client,\n    actorId: actor.user_id,\n    householdId: actor.household_id,\n    eventId: item.provider_event_id,\n    reply: (text, quickReplies) => sendConfirmation(client, item, actor, text, quickReplies),\n  }, fields)) return;\n\n'''
if "tryHandleLineMustCompletePostback({" not in index:
    index = replace_once(index, postback_anchor, postback_insert, "LINE postback hook")

text_anchor = '''  if (await tryClaimLinkToken(client, item.source_external_user_id, text)) return;\n  if (!actor) return;\n  if (await tryHandleReadOnlyText(client, item, actor, text)) return;\n'''
text_insert = '''  if (await tryClaimLinkToken(client, item.source_external_user_id, text)) return;\n  if (!actor) return;\n  if (await tryHandleLineMustCompleteText({\n    client,\n    actorId: actor.user_id,\n    householdId: actor.household_id,\n    eventId: item.provider_event_id,\n    reply: (replyText, quickReplies) => sendConfirmation(client, item, actor, replyText, quickReplies),\n  }, text)) return;\n  if (await tryHandleReadOnlyText(client, item, actor, text)) return;\n'''
if "tryHandleLineMustCompleteText({" not in index:
    index = replace_once(index, text_anchor, text_insert, "LINE text hook")
write(index_path, index)


# ---------------------------------------------------------------------------
# LINE adapter follow-up hardening caught during self-review.
# ---------------------------------------------------------------------------
helper_path = "supabase/functions/process-line-inbox/lineMustComplete.ts"
helper = Path(helper_path).read_text(encoding="utf-8")
helper = helper.replace(
    '  await ctx.reply(buildItemPromptText(next), buildItemQuickReply(sessionId, next.task_instance_id));',
    '  await ctx.reply(buildItemPromptText(sessionId, next), buildItemQuickReply(sessionId, next.task_instance_id));',
)

old_wait_map = '''  const quick = rows.slice(0, 8).map((row) => {\n    const id = str(row.id) ?? "";\n    const revision = num(row.revision) ?? 1;\n    const waiting = row.attention_state === "waiting";\n    return postback(\n      `${waiting ? "再開" : "待ち"}・${(str(row.title) ?? "タスク").slice(0, 12)}`,\n      encodeFields(waiting ? "mc_wait_resume" : "mc_wait_select", { task_id: id, revision }),\n    );\n  });\n'''
new_wait_map = '''  const quick = rows.slice(0, 4).flatMap((row) => {\n    const id = str(row.id) ?? "";\n    const revision = num(row.revision) ?? 1;\n    const waiting = row.attention_state === "waiting";\n    const title = (str(row.title) ?? "タスク").slice(0, 10);\n    if (!waiting) return [postback(`待ち・${title}`, encodeFields("mc_wait_select", { task_id: id, revision }))];\n    return [\n      postback(`再開・${title}`, encodeFields("mc_wait_resume", { task_id: id, revision })),\n      postback(`確認日・${title}`, encodeFields("mc_wait_update", { task_id: id, revision })),\n    ];\n  });\n'''
if old_wait_map in helper:
    helper = helper.replace(old_wait_map, new_wait_map, 1)
helper = helper.replace(
    '  if (action === "set" && !fields.next_check) {\n    await ctx.reply("次に確認するタイミングを選べます。", [\n      postback("明日確認", encodeFields("mc_wait_set", { task_id: taskId, revision, next_check: "tomorrow" })),\n      postback("3日後確認", encodeFields("mc_wait_set", { task_id: taskId, revision, next_check: "3days" })),\n      postback("時刻なしで待ち", encodeFields("mc_wait_set", { task_id: taskId, revision, next_check: "none" })),\n    ]);',
    '  if ((action === "set" || action === "update") && !fields.next_check) {\n    const nextAction = action === "update" ? "mc_wait_update" : "mc_wait_set";\n    await ctx.reply(action === "update" ? "次の確認日を変更します。" : "次に確認するタイミングを選べます。", [\n      postback("明日確認", encodeFields(nextAction, { task_id: taskId, revision, next_check: "tomorrow" })),\n      postback("3日後確認", encodeFields(nextAction, { task_id: taskId, revision, next_check: "3days" })),\n      postback("時刻なし", encodeFields(nextAction, { task_id: taskId, revision, next_check: "none" })),\n    ]);',
)

# Explicit consultation memo prefix: the comment is stored as a new terms
# revision, but never becomes a material Task patch.
if "async function editConsultationMemo" not in helper:
    marker = "async function editStructuredDue(ctx: LineMustCompleteContext, dueIso: string): Promise<void> {"
    memo_fn = '''async function editConsultationMemo(ctx: LineMustCompleteContext, memo: string): Promise<void> {\n  const views = (await activeRequests(ctx)).filter((view) => ["consulting", "awaiting_confirmation"].includes(view.attempt.state));\n  if (views.length !== 1) {\n    await ctx.reply("相談中のお願いを1件に絞れませんでした。先に「お願いの返事」で対象を確認してください。");\n    return;\n  }\n  const view = views[0];\n  const terms: JsonObject = { ...view.attempt.terms, candidate: memo };\n  const operationId = await deterministicOperationId("line-request-memo", ctx.eventId, view.attempt.id, memo, String(view.attempt.revision));\n  const { error } = await ctx.client.rpc("server_tx_transition_request_v2", {\n    p_actor_id: ctx.actorId, p_operation_id: operationId, p_request_id: view.request.id,\n    p_attempt_id: view.attempt.id, p_action: "edit_terms", p_terms: terms,\n    p_expected_revision: view.attempt.revision, p_expected_terms_revision: view.attempt.terms_revision, p_source: "line",\n  });\n  if (error) { await replyMutationError(ctx, error); return; }\n  await ctx.reply("✓ 相談メモを条件版に保存しました。この文章だけでは担当・Task・作業期限は変わりません。具体的な変更は別に明示して、二人で同じ版を確認します。", [message("お願いを確認", "お願いの返事")]);\n}\n\n'''
    helper = replace_once(helper, marker, memo_fn + marker, "consultation memo helper")

text_dispatch_anchor = '''  const dueIso = parseStructuredWorkDue(text);\n  if (dueIso) {\n'''
if 'text.match(/^相談メモ' not in helper:
    text_dispatch_new = '''  const memoMatch = text.match(/^相談メモ[：:\\s]+(.{1,500})$/u);\n  if (memoMatch) {\n    await editConsultationMemo(ctx, memoMatch[1].trim());\n    return true;\n  }\n  const dueIso = parseStructuredWorkDue(text);\n  if (dueIso) {\n'''
    helper = replace_once(helper, text_dispatch_anchor, text_dispatch_new, "consultation memo dispatch")
write(helper_path, helper)


# ---------------------------------------------------------------------------
# PWA Request consultation: stop presenting prose as executable terms.  The
# exact material deadline/assignment structure is visible before confirmation.
# ---------------------------------------------------------------------------
requests_path = "apps/web/src/features/requests/Requests.tsx"
requests = Path(requests_path).read_text(encoding="utf-8")
requests = requests.replace(
    '<ConsultationTerms key={attempt.terms_revision} attempt={attempt} busy={busy} onAction={negotiate} />',
    '<ConsultationTerms key={attempt.terms_revision} request={request} attempt={attempt} busy={busy} onAction={negotiate} />',
)

pattern = re.compile(r"function ConsultationTerms\(.*?\n\nexport function OutgoingRequestRow", re.S)
match = pattern.search(requests)
if not match:
    raise SystemExit("Requests ConsultationTerms anchor not found")
new_component = r'''function ConsultationTerms({ request, attempt, busy, onAction }: { request: RequestRow; attempt: RequestAttempt; busy: boolean; onAction: (action: 'edit_terms' | 'confirm_terms', terms?: Record<string, unknown>) => void }) {
  const savedMemo = typeof attempt.terms?.candidate === 'string' ? attempt.terms.candidate : '';
  const savedPatch = attempt.terms?.material_patch && typeof attempt.terms.material_patch === 'object' ? attempt.terms.material_patch as Record<string, unknown> : null;
  const savedWorkDue = typeof savedPatch?.work_due_at === 'string' ? toDateTimeLocal(savedPatch.work_due_at) : '';
  const [memo, setMemo] = useState(savedMemo);
  const [workDue, setWorkDue] = useState(savedWorkDue);
  const weeklyAssignment = Boolean(request.assignment_task_instance_id && request.assignment_scope === 'this_week');
  const dirty = memo.trim() !== savedMemo || workDue !== savedWorkDue;
  const savedAssignment = savedPatch?.assignment && typeof savedPatch.assignment === 'object' ? savedPatch.assignment as Record<string, unknown> : null;
  const assignmentIsExplicit = savedAssignment?.mode === 'request_recipient';

  function propose() {
    const nextTerms: Record<string, unknown> = { ...attempt.terms, candidate: memo.trim() };
    if (workDue) {
      const materialPatch: Record<string, unknown> = {
        version: 1,
        work_due_at: new Date(workDue).toISOString(),
        scheduled_date: workDue.slice(0, 10),
      };
      if (request.assignment_task_instance_id) {
        materialPatch.assignment = { mode: 'request_recipient', targets: attempt.terms?.assignment_targets };
      }
      nextTerms.material_patch = materialPatch;
    } else {
      delete nextTerms.material_patch;
    }
    onAction('edit_terms', nextTerms);
  }

  return <div className="request-other-actions" aria-label="相談の条件">
    <p><strong>相談中</strong> — まだTaskは変わりません。文章の相談メモと、実際に反映する具体条件を分けて確認します。</p>
    <label>相談メモ（自動反映されません）<input aria-label="相談メモ" value={memo} onChange={(event) => setMemo(event.target.value)} placeholder="例：時間なら調整できそう" /></label>
    <label>変更後の作業期限（具体条件）<input aria-label="変更後の作業期限" type="datetime-local" value={workDue} disabled={weeklyAssignment} onChange={(event) => setWorkDue(event.target.value)} /></label>
    {weeklyAssignment && <p className="task-item-meta">「今週だけ」は複数のTaskを含むため、1つの期限で全件を書き換えません。担当変更だけをこの条件版で確認し、各日の期限変更は個別Taskの変更相談で扱います。</p>}
    {request.assignment_task_instance_id && <p className="task-item-meta">担当の具体条件: この依頼で固定された対象Taskを、依頼相手へ変更します。対象Taskとrevisionはサーバー発行の条件版から変更できません。</p>}
    <button type="button" className="secondary-button" disabled={busy || !dirty} onClick={propose}>具体条件を提案</button>
    <button type="button" disabled={busy || dirty} onClick={() => onAction('confirm_terms')}>表示中の条件版を確認する</button>
    <div className="task-item-meta" aria-label="反映される具体条件">
      <strong>この条件版で反映される内容</strong>
      <div>作業期限: {savedWorkDue ? `${request.due_at ? formatDateTimeJa(request.due_at) : '未設定'} → ${formatDateTimeJa(String(savedPatch?.work_due_at))}` : '変更なし'}</div>
      <div>担当: {request.assignment_task_instance_id ? (assignmentIsExplicit ? '固定された対象Task → 依頼相手' : '既存の担当変更条件') : '変更なし'}</div>
      <div>相談メモ: {savedMemo || 'なし（文章だけではTaskを変更しません）'}</div>
    </div>
    <p className="task-item-meta">現在: {attempt.state === 'awaiting_confirmation' ? 'もう一人の確認待ち' : '条件の提案・確認待ち'}（条件版 {attempt.terms_revision}）</p>
  </div>;
}

export function OutgoingRequestRow'''
requests = requests[:match.start()] + new_component + requests[match.end():]
write(requests_path, requests)


# ---------------------------------------------------------------------------
# Canonical docs: record the now-concrete structured consultation boundary and
# the LINE must-complete entry points without changing Requirements authority.
# ---------------------------------------------------------------------------
doc_path = "docs/design/current/03_STATE_MACHINES_AND_COMMANDS.md"
doc = Path(doc_path).read_text(encoding="utf-8")
marker = "<!-- XC-03-XC-05-CONVERGENCE -->"
if marker not in doc:
    doc += '''\n\n<!-- XC-03-XC-05-CONVERGENCE -->\n## XC-03 / XC-05 final convergence (2026-09-10)\n\n- LINE MUST-complete actions are thin transport adapters. They always carry the observed aggregate revision/terms revision where the target is revision-bearing and call the same canonical server command as PWA. A stale LINE message fails closed; the adapter never refetches the newest revision and applies an old tap to it.\n- Daily reconciliation uses `server_tx_reconcile_routine_session_v2` and exact-operation undo; individual answers continue through the canonical routine-item command. Waiting uses `server_tx_set_task_waiting`; anyone-owner shopping uses `server_tx_shopping_claim_v2`; Request consultation uses `server_tx_transition_request_v2`.\n- Request consultation prose (`candidate` / consultation memo) is discussion-only. It is never parsed into Task fields. A material pre-acceptance change is represented by `terms.material_patch` version 1. Supported material fields are work due date/time and the exact server-issued assignment-change target set to the request recipient.\n- The UI/LINE must show the concrete material patch before `confirm_terms`. The first confirmation does not mutate Task truth. When both parties confirm the same terms revision, acceptance and material Task application are one SQL transaction. A concurrent Task revision conflict rolls back acceptance and fails closed.\n- A single changed work deadline is intentionally rejected for a multi-occurrence `this_week` assignment scope; that scope may change assignment as one agreement, while per-occurrence date/time changes require individually represented Task changes. This prevents one free-text sentence from collapsing several distinct work deadlines.\n- Request reply deadline remains RequestAttempt-owned and is never rewritten by a work-deadline material patch.\n'''
write(doc_path, doc)

matrix_path = "docs/design/current/10_LINE_PWA_RESPONSIBILITY_MATRIX.md"
matrix = Path(matrix_path).read_text(encoding="utf-8")
if marker not in matrix:
    matrix += '''\n\n<!-- XC-03-XC-05-CONVERGENCE -->\n### LINE MUST-complete implementation boundary (2026-09-10)\n\nThe approved M04/M07/M09/M10/M12 routes are implemented as LINE entry -> observed revision/operation identity -> canonical command -> canonical readback. The transport does not own a second business state machine. The LINE-native entry vocabulary includes daily reconciliation (`入力`), Request state/consultation (`お願いの返事`, explicit `相談メモ: ...`, explicit `条件期限 YYYY-MM-DD HH:MM`), waiting (`待ち`), anyone-owner shopping (`買い物担当`), and one-user simulation (`1人テスト`). Buttons embed the target IDs/revisions used by the canonical command; stale buttons fail closed.\n\nFor XC-05, free prose is explicitly non-material. The concrete Task-changing portion of a consultation is rendered separately and both parties confirm the same terms revision before any Task change.\n'''
write(matrix_path, matrix)
