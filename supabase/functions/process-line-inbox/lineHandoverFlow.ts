import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";
import { handleAssignmentPostback } from "./lineAssignmentFlow.ts";

interface Context {
  client: SupabaseClient;
  actorId: string;
  householdId: string;
  eventId: string;
  reply: (text: string, quickReplies?: LineQuickReplyAction[]) => Promise<void>;
}

function postback(label: string, data: string, displayText = label): LineQuickReplyAction {
  return { type: "postback", label, data, displayText };
}

async function deterministicOperationId(...parts: string[]): Promise<string> {
  const digest = new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(parts.join("|"))),
  );
  const bytes = digest.slice(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  const hex = [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

async function actorRefId(ctx: Context): Promise<string | null> {
  const { data, error } = await ctx.client
    .from("domain_actor_refs")
    .select("id")
    .eq("household_id", ctx.householdId)
    .eq("actor_kind", "real_user")
    .eq("real_user_id", ctx.actorId)
    .maybeSingle();
  if (error) return null;
  return typeof data?.id === "string" ? data.id : null;
}

function roleLabel(role: unknown): string | null {
  if (role === "papa") return "パパ";
  if (role === "mama") return "ママ";
  return null;
}

async function handoverAuthorLabel(
  ctx: Context,
  authorActorRefId: unknown,
  legacyAuthorId: unknown,
): Promise<string> {
  let userId = typeof legacyAuthorId === "string" ? legacyAuthorId : null;

  if (typeof authorActorRefId === "string") {
    const { data: actorRef } = await ctx.client
      .from("domain_actor_refs")
      .select("real_user_id,simulated_role")
      .eq("household_id", ctx.householdId)
      .eq("id", authorActorRefId)
      .maybeSingle();
    const simulated = roleLabel(actorRef?.simulated_role);
    if (simulated) return simulated;
    if (typeof actorRef?.real_user_id === "string") userId = actorRef.real_user_id;
  }

  if (userId) {
    const { data: member } = await ctx.client
      .from("household_members")
      .select("family_role")
      .eq("household_id", ctx.householdId)
      .eq("user_id", userId)
      .maybeSingle();
    const label = roleLabel(member?.family_role);
    if (label) return label;
  }

  return "家族";
}

export function isHandoverReviewText(text: string): boolean {
  return /^(共有確認|引き継ぎ確認|確認が必要な共有)$/u.test(text.normalize("NFKC").trim());
}

export async function openHandoverReview(ctx: Context): Promise<void> {
  const actorRef = await actorRefId(ctx);
  if (!actorRef) {
    await ctx.reply("共有の確認状態を読み込めませんでした。状態は変更していません。");
    return;
  }

  const { data: rows, error } = await ctx.client
    .from("handovers")
    .select("id,shared_text,info_kind,revision,created_at,author_actor_ref_id,author_id")
    .eq("household_id", ctx.householdId)
    .eq("status", "active")
    .eq("visibility", "household")
    .eq("ack_policy", "required")
    .is("test_context_id", null)
    .order("created_at", { ascending: false })
    .limit(10);
  if (error) {
    await ctx.reply("確認が必要な共有を読み込めませんでした。状態は変更していません。");
    return;
  }

  const ids = (rows ?? []).map((row) => row.id).filter((id): id is string => typeof id === "string");
  if (ids.length === 0) {
    await ctx.reply("いま「確認した」が必要な引き継ぎ・共有はありません。通常の共有は確認操作不要です。");
    return;
  }

  const { data: acknowledged } = await ctx.client
    .from("info_acknowledgements")
    .select("handover_id")
    .eq("actor_ref_id", actorRef)
    .in("handover_id", ids)
    .is("test_context_id", null);
  const done = new Set((acknowledged ?? []).map((row) => row.handover_id));
  const target = (rows ?? []).find((row) => !done.has(row.id));
  if (!target) {
    await ctx.reply("いま「確認した」が必要な引き継ぎ・共有はありません。");
    return;
  }

  const kind = target.info_kind === "share" ? "共有" : "引き継ぎ";
  const text = String(target.shared_text ?? "").trim() || "内容なし";
  const author = await handoverAuthorLabel(ctx, target.author_actor_ref_id, target.author_id);
  const params = new URLSearchParams({ action: "mc_handover_ack", handover_id: target.id });
  await ctx.reply(
    `確認が必要な${kind}\n${author} → 家族全員\n状態: あなたの確認待ち\n\n内容: ${text}\n\n必要: 下の「確認した」を押してください。これは関連ToDoの完了とは別です。`,
    [postback("確認した", params.toString())],
  );
}

export async function handleHandoverAckPostback(
  ctx: Context,
  fields: Record<string, string>,
): Promise<boolean> {
  // lineMustComplete already routes every remaining contextual postback here.
  // Keep assignment actions on that existing safe entry boundary instead of
  // adding a second generic postback dispatcher to the large inbox worker.
  if (await handleAssignmentPostback(ctx, fields)) return true;

  if (fields.action !== "mc_handover_ack") return false;
  const handoverId = fields.handover_id;
  if (!handoverId) return true;

  const operationId = await deterministicOperationId("line-handover-ack", ctx.eventId, handoverId, ctx.actorId);
  const { error } = await ctx.client.rpc("server_tx_ack_info_v1", {
    p_actor_id: ctx.actorId,
    p_operation_id: operationId,
    p_handover_id: handoverId,
  });
  if (error) {
    const code = error.message ?? "";
    if (/NOT_ACTIVE|NOT_FOUND|NOT_ACTIONABLE|CONFLICT|STALE/.test(code)) {
      await ctx.reply("この共有は状態が変わっています。最新の「今日」または「共有確認」を開き直してください。");
    } else {
      await ctx.reply("確認を記録できませんでした。状態は変更していません。");
    }
    return true;
  }
  await ctx.reply("✓ 「確認した」を記録しました。関連するToDoがある場合、その完了は別に記録します。");
  return true;
}
