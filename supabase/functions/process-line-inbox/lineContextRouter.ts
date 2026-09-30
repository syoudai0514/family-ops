// AI-first routing of LINE free text, WITH the conversation.
//
// Owner instruction 2026-09-30 ("基本AIかませてよ。文脈で渡さないと"). Live 22:27-22:29:
//   買うものは？          -> "どなたが何を買う予定か…教えていただけますか？"
//   おれ                  -> "「おれ」について、何かお困りごとや相談したいことがありますか？"
//   俺が買いたいもの      -> "ご家族に共有するためのメモとして、どのような内容を…"
//   いや、買うべきもの教えてよ -> "「さきほどの入力」は取り消し済みです。"
// Each message was judged alone by a chain of phrase patterns, and only the leftovers
// reached the AI -- as a single sentence, without the bot's own previous question,
// the pending draft or the shopping list. So "おれ" had nothing to answer.
//
// Here the model gets the last few turns (both sides), the pending draft and a compact
// view of the household (open shopping items, the sender's open tasks), and chooses ONE
// action. The code then runs that action through the same deterministic, undoable
// handlers as before (shopping list / purchase / completion / draft creation). The model
// never writes to the database itself and never claims something was done.
//
// Fixed shortcuts (今日, 入力, 共有, ...) stay deterministic and never reach this module.
// If the model is unavailable or answers with something unusable, `routeLineText`
// returns null and the caller falls back to the previous phrase-pattern chain.
import { callGemini } from "../_shared/gemini.ts";
import { claimsMutationWasPerformed } from "./lineAssistantConversation.ts";
import type { ShoppingWho } from "./lineShoppingList.ts";

export type RouterAction =
  | "shopping_list"
  | "schedule"
  | "purchase"
  | "done"
  | "create"
  | "cancel_draft"
  | "answer"
  | "clarify"
  | "pass";

export type RouterConfidence = "high" | "medium" | "low";

export interface RouterDecision {
  action: RouterAction;
  confidence: RouterConfidence;
  who?: ShoppingWho;
  range?: "today" | "tomorrow" | "week";
  hint?: string | null;
  all?: boolean;
  /** create: the request restated with the conversation resolved; done: a short completion report. */
  text?: string;
  /** answer / clarify: what to say. */
  reply?: string;
}

export interface Turn {
  role: "user" | "assistant";
  text: string;
}

export interface RouterContext {
  /** JST clock, e.g. { date: "2026-09-30", time: "22:29", weekday: "水" }. */
  now: { date: string; time: string; weekday: string };
  /** The sender's role in the household: パパ / ママ / 家族. */
  me: string;
  partner: string;
  /** Oldest first, NOT including the message being routed. */
  turns: Turn[];
  pendingDraft: { kind: string; title: string } | null;
  shopping: Array<{ title: string; who: "me" | "partner" | null }>;
  myTasks: string[];
  partnerOpenCount: number;
}

const ACTIONS = new Set<RouterAction>([
  "shopping_list", "schedule", "purchase", "done", "create", "cancel_draft", "answer", "clarify", "pass",
]);
const REPLY_MAX = 400;
const TURN_MAX_CHARS = 300;

function clip(value: string, max: number): string {
  return value.length <= max ? value : `${value.slice(0, max - 1)}…`;
}

export function buildRouterPrompt(ctx: RouterContext, message: string): string {
  const turns = ctx.turns.slice(-10).map((turn) => ({
    speaker: turn.role === "user" ? `${ctx.me}(ユーザー)` : "おうちノート",
    text: clip(turn.text.replace(/\s+/g, " ").trim(), TURN_MAX_CHARS),
  }));
  const facts = {
    いま: `${ctx.now.date}(${ctx.now.weekday}) ${ctx.now.time}`,
    ユーザー: ctx.me,
    相手: ctx.partner,
    確認待ちの下書き: ctx.pendingDraft,
    買い物リスト_未購入: ctx.shopping.slice(0, 20).map((item) => ({
      品名: item.title,
      担当: item.who === "me" ? "ユーザー" : item.who === "partner" ? "相手" : "未定",
    })),
    ユーザーの今日の未完了タスク: ctx.myTasks.slice(0, 20),
    相手の今日の未完了件数: ctx.partnerOpenCount,
  };
  return [
    "あなたは家族運営アプリ『おうちノート』のLINE窓口です。",
    `ユーザー(${ctx.me})の最新の1通に、次の会話の流れと家庭の状況を踏まえて、どう対応するかを決めます。`,
    "",
    "## 判断の原則",
    "- 最新の1通だけで決めない。直前のおうちノートの質問への答え（例:「おれ」「ママ」「牛乳」「うん」）は、その質問の続きとして読む。",
    "- 「いや」「違う」「間違えた」は、直前の自分の発言の言い直し。言い直した内容に答える。登録の取り消しと決めつけない。",
    "- 質問・確認・相談には答える。頼まれていない登録・送信・変更はしない。新しく登録・お願い・共有をしたいときだけ create にする。",
    "- 分からないときは推測せず clarify（聞き返すのは1つだけ。すでに分かったことは聞き直さない）。",
    "- 与えた情報にないこと（予定・担当・在庫など）を作らない。",
    "- 『登録した』『送った』『通知した』など、実行していないことを実行したように言わない。",
    "",
    "## action（1つだけ選ぶ）",
    "- shopping_list: 買い物リストを見せる。who = me（ユーザーが買うもの。担当なしを含む）/ partner / unassigned（担当なし）/ any。",
    "- schedule: 予定を見せる。range = today / tomorrow / week。",
    "- purchase: 買い物リストの品物を「買った」にする。hint = 品名の一部（例: 牛乳、Tシャツ）。全部なら all=true。品名が無い『買ったよ』は hint=null。",
    "- done: 今日のタスクを『やった』にする。text = 「洗濯した」のような短い完了報告（コドモンの送信は「コドモン送りました」）。",
    "- create: 予定・タスク・買い物・お願い・共有を新しく登録したい。text = 会話の文脈を補って、代名詞を具体化し、一文で言い切った依頼文。",
    "- cancel_draft: 確認待ちの下書きを取り消したい（『やっぱりなし』『さっきのやめて』）。下書きがあるときだけ。",
    "- answer: 質問・相談・雑談に、与えた情報だけを使って答える。reply に返答（日本語、200字以内、やわらかく）。",
    "- clarify: 1つだけ聞き返す。reply に質問。",
    "- pass: 上のどれにも当てはまらない、または下書きの内容を直したい。（従来の処理に任せる）",
    "",
    "## 例（入力 → 出力）",
    '- 「買うものは？」→ {"action":"shopping_list","confidence":"high","who":"any"}',
    '- 「俺が買うべきもの教えて」→ {"action":"shopping_list","confidence":"high","who":"me"}',
    '- 「今日なんか予定ある？」→ {"action":"schedule","confidence":"high","range":"today"}',
    '- 「Tシャツ買ったよ」→ {"action":"purchase","confidence":"high","hint":"Tシャツ"}',
    '- 「買ったよ」（直前が買い物リストの話）→ {"action":"purchase","confidence":"medium","hint":null}',
    '- 「洗濯終わった」→ {"action":"done","confidence":"high","text":"洗濯した"}',
    '- 「牛乳買っといて」→ {"action":"create","confidence":"high","text":"牛乳買っといて"}',
    '- 「それ、明日の朝ママにお願い」（直前が「ゴミ出し」の話）→ {"action":"create","confidence":"high","text":"明日の朝、ゴミ出しをママにお願い"}',
    '- 直前のおうちノートが「どなたの分ですか？」で、ユーザーが「おれ」→ {"action":"shopping_list","confidence":"high","who":"me"}（質問の続きとして読む）',
    '- 「これどう言えば角立たない？」→ {"action":"answer","confidence":"high","reply":"…（文案だけ示す。送らない）"}',
    '- 下書きがあるときの「やっぱりさっきのなし」→ {"action":"cancel_draft","confidence":"high"}',
    '- 下書きがあるときの「時間は7時にして」→ {"action":"pass","confidence":"high"}',
    "",
    "## 出力（JSONのみ）",
    '{"action":"...","confidence":"high|medium|low","who":null,"range":null,"hint":null,"all":false,"text":null,"reply":null}',
    "使わない項目は null。confidence は自信の度合い。登録や記録を伴う action（purchase / done / create / cancel_draft）で自信が低いときは clarify にする。",
    "",
    "## 会話（古い順）",
    JSON.stringify(turns),
    "",
    "## 家庭の状況",
    JSON.stringify(facts),
    "",
    "## 最新の1通",
    JSON.stringify(message),
  ].join("\n");
}

function asString(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

/** Strict parse: anything unusable is null, which sends the message down the old path. */
export function parseRouterDecision(raw: string): RouterDecision | null {
  let parsed: unknown;
  try {
    const fenced = raw.match(/```(?:json)?\s*([\s\S]*?)```/i)?.[1] ?? raw;
    parsed = JSON.parse(fenced.trim());
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== "object") return null;
  const p = parsed as Record<string, unknown>;
  const action = p.action;
  if (typeof action !== "string" || !ACTIONS.has(action as RouterAction)) return null;
  const confidence: RouterConfidence = p.confidence === "high" || p.confidence === "medium" || p.confidence === "low"
    ? p.confidence
    : "low";
  const decision: RouterDecision = { action: action as RouterAction, confidence };
  if (p.who === "me" || p.who === "partner" || p.who === "unassigned" || p.who === "any") decision.who = p.who;
  if (p.range === "today" || p.range === "tomorrow" || p.range === "week") decision.range = p.range;
  if (typeof p.hint === "string") decision.hint = p.hint.trim() || null;
  if (p.all === true) decision.all = true;
  const text = asString(p.text);
  if (text) decision.text = text.slice(0, 500);
  const reply = asString(p.reply);
  if (reply) decision.reply = reply.slice(0, REPLY_MAX);
  return decision;
}

const RECORDING_ACTIONS = new Set<RouterAction>(["purchase", "done", "create", "cancel_draft"]);

/**
 * The safety net around the model's choice. Returns the decision to run, or null to fall
 * back to the previous handlers.
 */
export function guardDecision(decision: RouterDecision, ctx: RouterContext): RouterDecision | null {
  // Recording something on a hunch is worse than asking: a low-confidence record becomes a question.
  if (RECORDING_ACTIONS.has(decision.action) && decision.confidence === "low") {
    return decision.reply && !claimsMutationWasPerformed(decision.reply)
      ? { action: "clarify", confidence: "low", reply: decision.reply }
      : null;
  }
  switch (decision.action) {
    case "answer":
    case "clarify": {
      const reply = decision.reply;
      if (!reply || claimsMutationWasPerformed(reply)) return null;
      return decision;
    }
    case "create":
      return decision.text ? decision : null;
    case "done":
      return decision.text ? decision : null;
    case "cancel_draft":
      // Nothing to cancel -> say nothing was pending instead of pretending.
      return ctx.pendingDraft ? decision : null;
    case "schedule":
      return decision.range ? decision : { ...decision, range: "today" };
    case "shopping_list":
      return { ...decision, who: decision.who ?? "any" };
    default:
      return decision;
  }
}

export type RouterProvider = (prompt: string) => Promise<string | null>;

async function geminiRouterProvider(prompt: string): Promise<string | null> {
  const model = Deno.env.get("GEMINI_MODEL_LINE_ROUTER") ??
    Deno.env.get("GEMINI_MODEL_LINE_DECOMPOSITION") ??
    Deno.env.get("GEMINI_MODEL_LINE_INTENT") ??
    Deno.env.get("GEMINI_MODEL_REWRITE") ?? "";
  if (!model) return null;
  try {
    return await callGemini(prompt, model);
  } catch (error) {
    console.warn("process-line-inbox: context router unavailable", {
      code: error instanceof Error ? error.message : "unknown",
    });
    return null;
  }
}

/** Asks the model what to do. null = unavailable or unusable -> use the previous handlers. */
export async function routeLineText(
  ctx: RouterContext,
  message: string,
  provider: RouterProvider = geminiRouterProvider,
): Promise<RouterDecision | null> {
  const raw = await provider(buildRouterPrompt(ctx, message));
  if (!raw) return null;
  const decision = parseRouterDecision(raw);
  return decision ? guardDecision(decision, ctx) : null;
}

/** What running a decision can touch. Wired to the real handlers in index.ts; faked in tests. */
export interface RouterEffects {
  showShoppingList(who: ShoppingWho): Promise<void>;
  showSchedule(range: "today" | "tomorrow" | "week"): Promise<void>;
  purchase(report: { hint: string | null; all: boolean }): Promise<void>;
  /** true when the report matched a task and was handled. */
  done(text: string): Promise<boolean>;
  reply(text: string): Promise<void>;
  cancelDraft(): Promise<void>;
}

export type RouterOutcome = { handled: true } | { handled: false; createText?: string };

/** Runs one decision. `create` and unhandled `done` are handed back to the caller. */
export async function runRouterDecision(
  decision: RouterDecision,
  effects: RouterEffects,
  original: string,
): Promise<RouterOutcome> {
  switch (decision.action) {
    case "shopping_list":
      await effects.showShoppingList(decision.who ?? "any");
      return { handled: true };
    case "schedule":
      await effects.showSchedule(decision.range ?? "today");
      return { handled: true };
    case "purchase":
      await effects.purchase({ hint: decision.hint ?? null, all: decision.all === true });
      return { handled: true };
    case "done":
      return (await effects.done(decision.text ?? original)) ? { handled: true } : { handled: false };
    case "cancel_draft":
      await effects.cancelDraft();
      return { handled: true };
    case "answer":
    case "clarify":
      await effects.reply(decision.reply ?? "");
      return { handled: true };
    case "create":
      return { handled: false, createText: decision.text };
    default:
      return { handled: false };
  }
}
