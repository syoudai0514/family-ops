// Resolve a transport directive to an actual occurrence. Generic old cards keep
// their read-only PWA recovery; new LINE input can open a server-bound preview.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { parseTransportAssignmentText } from "../_shared/transportAssignmentIntent.ts";
import { isPickupAssignmentChangeText } from "./lineIntent.ts";
export {
  parseTransportAssignmentText,
  type TransportAssignmentIntent,
} from "../_shared/transportAssignmentIntent.ts";

export type LineTransportAssignmentResult =
  | { kind: "not_applicable" }
  // The caller must continue to its existing canonical pickup request path;
  // it must not build an AI task/request draft first.
  | { kind: "legacy_pickup" }
  | { kind: "review"; taskId: string; assigneeUserId: string; expectedRevision: number }
  // Handled, including every failure. Do not fall through to generic creation.
  | { kind: "reply"; text: string };

type Context = {
  client: SupabaseClient;
  actorId: string;
  householdId: string;
  appBaseUrl: string;
  now?: Date;
  /** Server-read pending payload date; never re-interpret its old "明日". */
  scheduledDateOverride?: string;
  /** A generic pending card must not be confirmed through the legacy route. */
  forceReview?: boolean;
  /** Only fresh text may prepare the native explicit-agreement confirmation. */
  nativePreview?: boolean;
};

type Member = {
  household_id: string;
  user_id: string;
  family_role: string | null;
};
type Task = {
  id: string;
  household_id: string;
  task_definition_id: string;
  scheduled_date: string;
  test_context_id: string | null;
  planned_assignee_id: string | null;
  status: string;
  due_at: string | null;
  revision: number;
};

function roleLabel(member: Member | undefined, actorId: string): string {
  if (member?.family_role === "papa") return "パパ";
  if (member?.family_role === "mama") return "ママ";
  return member ? member.user_id === actorId ? "あなた" : "相手" : "担当未定";
}

function dayLabel(date: string, dueAt: string | null): string {
  const day = new Date(`${date}T00:00:00Z`);
  const label = `${day.getUTCMonth() + 1}/${day.getUTCDate()}(${
    "日月火水木金土"[day.getUTCDay()]
  })`;
  if (!dueAt || !Number.isFinite(Date.parse(dueAt))) return label;
  const time = new Intl.DateTimeFormat("ja-JP", {
    timeZone: "Asia/Tokyo",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(new Date(dueAt));
  return `${label} ${time}`;
}

function link(
  ctx: Context,
  date: string,
  taskId?: string,
  targetId?: string,
): string | null {
  try {
    const url = new URL("/today", ctx.appBaseUrl);
    if (
      !["https:", "http:"].includes(url.protocol) || url.username ||
      url.password
    ) return null;
    url.searchParams.set("date", date);
    url.searchParams.set("for", ctx.actorId);
    if (taskId) url.searchParams.set("assignment_task", taskId);
    if (targetId) url.searchParams.set("assignment_to", targetId);
    return url.toString();
  } catch {
    return null;
  }
}

function safeReply(
  ctx: Context,
  date: string | null,
  reason: string,
): LineTransportAssignmentResult {
  const url = date ? link(ctx, date) : null;
  return {
    kind: "reply",
    text: `${reason}\n担当は変更していません。${
      url
        ? `\n\n▶ 当日の予定を確認\n${url}`
        : "\nおうちノートで対象の日の予定を確認してください。"
    }`,
  };
}

function isIsoDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/u.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  return Number.isFinite(parsed.getTime()) &&
    parsed.toISOString().slice(0, 10) === value;
}

export async function resolveLineTransportAssignment(
  ctx: Context,
  text: string,
): Promise<LineTransportAssignmentResult> {
  const intent = parseTransportAssignmentText(text, ctx.now);
  if (!intent) return { kind: "not_applicable" };
  const noun = intent.code === "dropoff" ? "送り" : "お迎え";
  const date = ctx.scheduledDateOverride === undefined
    ? intent.scheduledDate
    : isIsoDate(ctx.scheduledDateOverride)
    ? ctx.scheduledDateOverride
    : null;
  if (!date) {
    return safeReply(
      ctx,
      null,
      `${noun}を変更する日を特定できませんでした。「明日」や「10/15」のように日付も教えてください。`,
    );
  }
  try {
    const { data: members, error: memberError } = await ctx.client.from(
      "household_members",
    )
      .select("household_id,user_id,family_role").eq(
        "household_id",
        ctx.householdId,
      ).limit(10);
    if (memberError || !Array.isArray(members)) {
      return safeReply(ctx, date, "家族の情報を読み込めませんでした。");
    }
    const family = (members as Member[]).filter((m) =>
      m.household_id === ctx.householdId && typeof m.user_id === "string"
    );
    if (!family.some((m) => m.user_id === ctx.actorId)) {
      return safeReply(ctx, date, "家族の情報を確認できませんでした。");
    }
    const targets = intent.target === "self"
      ? family.filter((m) => m.user_id === ctx.actorId)
      : intent.target === "partner"
      ? family.filter((m) => m.user_id !== ctx.actorId)
      : intent.target
      ? family.filter((m) => m.family_role === intent.target)
      : [];
    if (targets.length !== 1) {
      return safeReply(
        ctx,
        date,
        `変更後の${noun}担当を特定できませんでした。誰に変更するか確認してください。`,
      );
    }
    const target = targets[0];
    const { data: definition, error: definitionError } = await ctx.client.from(
      "task_definitions",
    )
      .select("id,household_id,code").eq("household_id", ctx.householdId).eq(
        "code",
        intent.code,
      ).maybeSingle();
    if (
      definitionError || !definition ||
      definition.household_id !== ctx.householdId ||
      definition.code !== intent.code || typeof definition.id !== "string"
    ) {
      return safeReply(
        ctx,
        date,
        `その日の${noun}予定を確認できませんでした。`,
      );
    }
    const { data: rows, error: taskError } = await ctx.client.from(
      "task_instances",
    )
      .select(
        "id,household_id,task_definition_id,scheduled_date,test_context_id,planned_assignee_id,status,due_at,revision",
      )
      .eq("household_id", ctx.householdId).eq(
        "task_definition_id",
        definition.id,
      )
      .eq("scheduled_date", date).is("test_context_id", null).limit(2);
    if (taskError || !Array.isArray(rows)) {
      return safeReply(
        ctx,
        date,
        `その日の${noun}予定を読み込めませんでした。`,
      );
    }
    const tasks = rows as Task[];
    if (
      tasks.length !== 1 ||
      tasks.some((t) =>
        t.household_id !== ctx.householdId ||
        t.task_definition_id !== definition.id || t.scheduled_date !== date ||
        t.test_context_id !== null || typeof t.id !== "string"
      )
    ) {
      return safeReply(
        ctx,
        date,
        tasks.length > 1
          ? `その日の${noun}予定が複数あり、対象を特定できませんでした。`
          : `その日の${noun}予定を特定できませんでした。`,
      );
    }
    const task = tasks[0];
    if (!["todo", "in_progress"].includes(task.status)) {
      return safeReply(
        ctx,
        date,
        `その日の${noun}はすでに終了しているため、担当変更の対象にはしませんでした。`,
      );
    }
    const current = family.find((m) => m.user_id === task.planned_assignee_id);
    if (task.planned_assignee_id && !current) {
      return safeReply(ctx, date, `現在の${noun}担当を確認できませんでした。`);
    }
    if (
      !ctx.forceReview && !intent.agreementReported &&
      intent.code === "pickup" &&
      task.planned_assignee_id === ctx.actorId &&
      target.user_id !== ctx.actorId && isPickupAssignmentChangeText(text)
    ) {
      return { kind: "legacy_pickup" };
    }
    const title = `${dayLabel(date, task.due_at)} ${noun}`;
    if (task.planned_assignee_id === target.user_id) {
      return safeReply(
        ctx,
        date,
        `${title}\nすでに${roleLabel(target, ctx.actorId)}担当です。`,
      );
    }
    if (ctx.nativePreview && !ctx.forceReview) {
      if (!Number.isSafeInteger(task.revision) || task.revision < 1) {
        return safeReply(ctx, date, "最新の担当状態を確認できませんでした。");
      }
      return {
        kind: "review",
        taskId: task.id,
        assigneeUserId: target.user_id,
        expectedRevision: task.revision,
      };
    }
    const url = link(ctx, date, task.id, target.user_id);
    return {
      kind: "reply",
      text: `${title}\n現在: ${roleLabel(current, ctx.actorId)} → 変更希望: ${
        roleLabel(target, ctx.actorId)
      }\n適用範囲: 今回だけ\n\n担当はまだ変更していません。\nおうちノートの「担当を調整」で確認してください。事前に2人で調整済みなら「すでに話し合い済みなので、そのまま担当を変更」を選べます。\n${
        url
          ? `\n▶ 担当を調整\n${url}`
          : "\nおうちノートで当日の作業を開いてください。"
      }`,
    };
  } catch {
    return safeReply(ctx, date, `その日の${noun}予定を読み込めませんでした。`);
  }
}
