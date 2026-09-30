// "何を買えばいい？" over LINE is answered with the shopping list.
//
// Live (2026-09-29 review §2-5): "買い物きている。なに変えば良い?" and
// "パパか担当決まっていない買い物必要なもの出して" were turned into drafts
// ("買い物中" as an actual record, "買い物リストの作成依頼" as a shared note)
// that had to be cancelled by hand. Standing in a shop and asking what to buy is
// one of the most valuable questions the app can answer, and the answer is
// simply the list.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

export interface ShoppingListContext {
  client: SupabaseClient;
  actorId: string;
  householdId: string;
  reply: (text: string) => Promise<void>;
}

export interface ShoppingRow {
  title: string;
  status: string;
  assignee_id: string | null;
}

export interface ShoppingQuestion {
  /** "担当が決まっていない買い物…" — only the items nobody has taken. */
  unassignedOnly: boolean;
}

const MAX_LINES = 15;

function normalized(text: string): string {
  return text.normalize("NFKC").replace(/\s+/g, "").trim();
}

// 何を買えばいい / なに買う / 何買っていく. "何か" is deliberately not matched:
// "何か買っておいて" is a request to buy, not a question about the list.
// "変えば" is the typo actually seen in production for 買えば.
const WHAT_TO_BUY = /(?:何|なに)を?[買変](?:え(?:ば|る)|う|って(?:く|いく|行く|きて)?)/;
const LIST_NOUN = /^(?:買い物リスト|買うもの(?:リスト)?|買い物(?:リスト)?(?:を|は)?(?:見せて|出して|教えて|確認|見たい)|買うもの(?:を|は)?(?:見せて|出して|教えて|確認|見たい|ある(?:の|っけ)?|なに|何))[?？。.!！]*$/;
// 買い物必要なもの出して / 買い物で足りないものある？
const NEEDED = /買い物.{0,12}(?:必要なもの|いるもの|足りないもの|残って|何が(?:ある|必要))/;
// Anything that asks somebody to buy, add or record something is not a question.
const NOT_A_QUESTION = /(?:買って(?:きて|おいて|ほしい|欲しい|くれ)|追加|登録|お願い|頼|買った|買いました|してきた|行ってきた)/;

export function parseShoppingQuestion(text: string): ShoppingQuestion | null {
  const value = normalized(text);
  if (!value || value.length > 60) return null;
  const isQuestion = LIST_NOUN.test(value)
    || ((WHAT_TO_BUY.test(value) || NEEDED.test(value)) && !NOT_A_QUESTION.test(value));
  if (!isQuestion) return null;
  return { unassignedOnly: /担当.{0,6}(?:決まって(?:い)?ない|未定|なし|いない)/.test(value) };
}

function appUrl(path: string): string {
  const base = (Deno.env.get("APP_BASE_URL") ?? "").replace(/\/$/, "");
  return base ? `${base}${path}` : "";
}

export function buildShoppingListReply(
  rows: ShoppingRow[],
  opts: { actorId: string; roles: Map<string, string>; unassignedOnly: boolean; link?: string },
): string {
  const open = rows.filter((row) => row.status === "wanted" || row.status === "assigned");
  const waiting = rows.filter((row) => row.status === "ordered").length;
  const shown = opts.unassignedOnly ? open.filter((row) => !row.assignee_id) : open;
  const head = opts.unassignedOnly ? "担当が決まっていない買い物" : "買い物リスト";

  const lines: string[] = [];
  if (shown.length === 0) {
    lines.push(opts.unassignedOnly ? `${head}は、いまありません。` : "いま買うものはありません。");
  } else {
    lines.push(`${head}（${shown.length}件）`);
    for (const row of shown.slice(0, MAX_LINES)) {
      const who = !row.assignee_id ? "" : row.assignee_id === opts.actorId ? "（あなた）" : `（${opts.roles.get(row.assignee_id) ?? "相手"}）`;
      lines.push(`・${row.title}${who}`);
    }
    if (shown.length > MAX_LINES) lines.push(`ほか ${shown.length - MAX_LINES}件`);
  }
  if (waiting > 0 && !opts.unassignedOnly) lines.push("", `注文済みで届くのを待っているもの ${waiting}件`);
  if (opts.link) lines.push("", `▶ 買い物の画面: ${opts.link}`);
  return lines.join("\n");
}

async function loadShoppingRows(ctx: ShoppingListContext): Promise<ShoppingRow[] | null> {
  const { data, error } = await ctx.client
    .from("shopping_items")
    .select("title,status,assignee_id")
    .eq("household_id", ctx.householdId)
    .is("test_context_id", null)
    .in("status", ["wanted", "assigned", "ordered"])
    .order("created_at", { ascending: true })
    .limit(80);
  if (error) {
    console.warn("process-line-inbox: shopping list read failed", error.message);
    return null;
  }
  return (data ?? []) as ShoppingRow[];
}

async function loadRoles(ctx: ShoppingListContext): Promise<Map<string, string>> {
  const roles = new Map<string, string>();
  const { data } = await ctx.client
    .from("household_members")
    .select("user_id,family_role")
    .eq("household_id", ctx.householdId);
  for (const member of data ?? []) {
    if (member.family_role === "papa") roles.set(member.user_id, "パパ");
    if (member.family_role === "mama") roles.set(member.user_id, "ママ");
  }
  return roles;
}

/** Returns true when the message was a shopping-list question and has been answered. */
export async function tryHandleShoppingListQuestion(ctx: ShoppingListContext, text: string): Promise<boolean> {
  const question = parseShoppingQuestion(text);
  if (!question) return false;
  const rows = await loadShoppingRows(ctx);
  if (!rows) {
    await ctx.reply("買い物リストを読み込めませんでした。少し待ってからもう一度送ってください。");
    return true;
  }
  const roles = await loadRoles(ctx);
  await ctx.reply(buildShoppingListReply(rows, {
    actorId: ctx.actorId,
    roles,
    unassignedOnly: question.unassignedOnly,
    link: appUrl("/shopping"),
  }));
  return true;
}
