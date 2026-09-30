// LINE free text: the AI understands first, then the code acts.
//
// Owner instruction 2026-09-30: "初めに条件分岐でどうにかしようとかじゃなくって、基本AIに
// 何の内容を言っているのか、どういうことを対応すれば良いか、の判断を初めにさせる".
// Live 22:27-22:29 ("買うものは？" -> "おれ" -> "俺が買いたいもの" -> "いや、買うべきもの教えてよ")
// every message was judged alone by a chain of phrase patterns; the AI saw only the
// leftovers, one sentence at a time, without the bot's own previous question.
//
// Now every free-text message goes to the model FIRST, with:
//   - the conversation so far (both sides, oldest first),
//   - the draft waiting for confirmation,
//   - the household as it is right now: today's tasks and open shopping items, each
//     with a short reference (t1, s1, ...), the children, active shared notes, the clock.
// The model returns what the message means, the reply to send (in its own words), and at
// most a few actions that point at those references. The code checks every reference and
// runs the actions through the existing, undoable handlers. The model never writes to the
// database and never gets to claim that something was done.
//
// Only the fixed button words (今日, 入力, 共有, ...) skip the model. If the model is
// unavailable or returns something unusable, the caller falls back to the old handlers.
import { callGemini } from "../_shared/gemini.ts";
import { claimsMutationWasPerformed } from "./lineAssistantConversation.ts";
import { daypartToLocalTime } from "./lineIntent.ts";
import type { ShoppingWho } from "./lineShoppingList.ts";

export interface Turn {
  role: "user" | "assistant";
  text: string;
}

export interface SnapshotTask {
  ref: string;
  id: string;
  title: string;
  who: "me" | "partner" | "anyone" | null;
  due: string | null; // "07:05" (JST) or null
  status: "todo" | "done";
  code: string | null;
}

export interface SnapshotShopping {
  ref: string;
  id: string;
  title: string;
  who: "me" | "partner" | null;
  revision: number;
}

export type Daypart = "morning" | "noon" | "evening" | "night";

/** The draft waiting for confirmation, as the model sees it (so an edit can keep what is there). */
export interface SnapshotDraft {
  kind: string;
  title: string;
  date?: string | null;
  time?: string | null;
  daypart?: Daypart | null;
  who?: "me" | "partner" | null;
}

/** Who takes the children to / picks them up from nursery, today and tomorrow. */
export interface SnapshotTransport {
  date: string;
  dropoff: { who: "me" | "partner" | null; time: string | null } | null;
  pickup: { who: "me" | "partner" | null; time: string | null } | null;
}

export interface Snapshot {
  now: { date: string; time: string; weekday: string };
  me: string;
  partner: string;
  children: Array<{ name: string; school: string; className: string | null }>;
  /** Oldest first, NOT including the message being understood. */
  turns: Turn[];
  pendingDraft: SnapshotDraft | null;
  tasks: SnapshotTask[];
  shopping: SnapshotShopping[];
  sharedNotes: string[];
  transport?: SnapshotTransport[];
}

/**
 * What to register, filled in by the model from the whole conversation. Live 2026-09-30
 * 23:17: the model understood "明日、将生の保育園に下着2こ … 朝担当の人で" correctly, but
 * only a sentence was handed on, and a second parse of that sentence dropped the child,
 * the count, the morning and the person. The fields now go into the draft as they are.
 */
export interface DraftSpec {
  kind: "task" | "event" | "request" | "shopping";
  title: string;
  date: string | null; // YYYY-MM-DD
  time: string | null; // HH:MM
  daypart: Daypart | null;
  who: "me" | "partner" | null;
  /** For a request: what the partner reads. */
  message: string | null;
}

export type Action =
  | { type: "show_shopping"; who: ShoppingWho }
  | { type: "show_schedule"; range: "today" | "tomorrow" | "week" }
  | { type: "mark_bought"; refs: string[] }
  | { type: "complete_task"; ref: string; by: "self" | "partner" }
  | { type: "create"; text: string; draft?: DraftSpec }
  | { type: "edit_draft"; text: string; draft?: DraftSpec }
  | { type: "cancel_draft" }
  | { type: "legacy" };

export interface Plan {
  understanding: string;
  reply: string;
  actions: Action[];
  confidence: "high" | "medium" | "low";
}

const REPLY_MAX = 500;
const TURNS_SENT = 12;
const TURN_MAX_CHARS = 300;
const MAX_ACTIONS = 4;

function clip(value: string, max: number): string {
  const flat = value.replace(/\s+/g, " ").trim();
  return flat.length <= max ? flat : `${flat.slice(0, max - 1)}…`;
}

const WHO_LABEL = (snapshot: Snapshot, who: string | null) =>
  who === "me" ? snapshot.me : who === "partner" ? snapshot.partner : who === "anyone" ? "誰でも" : "未定";

function addDays(isoDate: string, days: number): string {
  const d = new Date(`${isoDate}T00:00:00Z`);
  if (Number.isNaN(d.getTime())) return isoDate;
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

export function buildUnderstandPrompt(snapshot: Snapshot, message: string): string {
  const today = snapshot.now.date;
  const tomorrow = addDays(today, 1);
  const turns =snapshot.turns.slice(-TURNS_SENT).map((turn) =>
    `${turn.role === "user" ? `${snapshot.me}` : "おうちノート"}: ${clip(turn.text, TURN_MAX_CHARS)}`
  );
  const facts = {
    いま: `${snapshot.now.date}(${snapshot.now.weekday}) ${snapshot.now.time}`,
    話している人: snapshot.me,
    相手: snapshot.partner,
    子ども: snapshot.children.map((c) => `${c.name}（${c.school}${c.className ? `・${c.className}` : ""}）`),
    確認待ちの下書き: snapshot.pendingDraft
      ? {
        種類: snapshot.pendingDraft.kind,
        題名: snapshot.pendingDraft.title,
        日付: snapshot.pendingDraft.date ?? null,
        時刻: snapshot.pendingDraft.time ?? null,
        時間帯: snapshot.pendingDraft.daypart ?? null,
        担当: snapshot.pendingDraft.who === undefined ? null : WHO_LABEL(snapshot, snapshot.pendingDraft.who),
      }
      : null,
    送迎: (snapshot.transport ?? []).map((d) => ({
      日付: d.date,
      送り: d.dropoff ? `${WHO_LABEL(snapshot, d.dropoff.who)}${d.dropoff.time ? ` ${d.dropoff.time}` : ""}` : "なし",
      お迎え: d.pickup ? `${WHO_LABEL(snapshot, d.pickup.who)}${d.pickup.time ? ` ${d.pickup.time}` : ""}` : "なし",
    })),
    今日のタスク:snapshot.tasks.slice(0, 50).map((t) => ({
      ref: t.ref,
      タスク: t.title,
      担当: WHO_LABEL(snapshot, t.who),
      時刻: t.due,
      状態: t.status === "done" ? "完了" : "未完了",
    })),
    買い物リスト_未購入: snapshot.shopping.slice(0, 30).map((s) => ({
      ref: s.ref,
      品物: s.title,
      担当: WHO_LABEL(snapshot, s.who),
    })),
    共有中のメモ: snapshot.sharedNotes.slice(0, 10),
  };
  return [
    "あなたは家族の段取りアプリ『おうちノート』のLINEアシスタントです。夫婦（パパ・ママ）と子どもの毎日の家事・予定・買い物・お願いを手伝います。",
    `いま ${snapshot.me} から届いた最新のメッセージについて、①何を言っているのか（会話の流れを踏まえて）、②何をすればよいか、を判断し、③返事を書いてください。`,
    "",
    "## 判断のしかた",
    "- 最新の1通だけで判断しない。会話の流れで読む。おうちノートの直前の質問への答え（例:「おれ」「ママ」「牛乳」「うん」「それ」）は、その続きとして読む。",
    "- 「いや」「違う」「間違えた」は、ユーザー自身の直前の発言の言い直し。言い直した内容に応える。下書きの取り消しと決めつけない。",
    "- 聞かれたことには、下の『家庭の状況』だけを使って答える。そこに無いことは作らない（分からなければ、分からないと言うか、予定の表示をすすめる）。",
    "- 頼まれていない登録・送信・変更はしない。登録・お願い・共有を新しくしたいと言っているときだけ create。",
    "- 対象がはっきりしないときは推測せず、1つだけ聞き返す（actions は空、reply に質問）。分かっていることは聞き直さない。",
    "- 1通に複数の用件があれば、actions を複数並べてよい（最大4つ）。",
    "- 相手と中身がはっきりした依頼（「ママに〜お願いしたい」「〜を代わってほしいって頼みたい」「〜してって伝えて」）は create（確認カードが出て、送る前に確かめられる）。『どう言えば』『言い方』『どう頼めば』と文面を相談しているときだけ相談として答える。",
    "- 相談（伝え方・頼み方など）は、ユーザーの立場と目的をまず正しくつかむ（例:「今週ずっと俺がお迎え」＝ユーザーが負担を抱えている側。相手に代わってほしい／分かってほしい）。そのうえで「状況 → お願い → 相手を気づかう一言」の順の文案を1つ示す。立場を逆にしない。文案は送らない。",
    "- コドモンの送信（コドモン送信のタスク）を完了にすると、まだの入力も自動でまとめて完了になる。相手が済ませていた入力（「朝食はやってあった」など）は、その入力のタスクを by=partner で並べる。",
    "",
    "## actions（refは『家庭の状況』にあるものだけ）",
    '- {"type":"show_shopping","who":"me|partner|unassigned|any"} 買い物リストを見せる。me = 話している人が買うもの（担当なしを含む）。',
    '- {"type":"show_schedule","range":"today|tomorrow|week"} 予定の一覧を見せる。',
    '- {"type":"mark_bought","refs":["s1"]} 買い物を「買った」にする。',
    '- {"type":"complete_task","ref":"t3","by":"self|partner"} 今日のタスクを「やった」にする。by = 実際にやった人（相手がやってくれたなら partner）。',
    '- {"type":"create","text":"…","draft":{…}} 予定・タスク・買い物・お願い・共有を新しく登録したい。text は会話の文脈を補い、「それ」「さっきの」を具体的にした一文（例:「明日の朝、ゴミ出しをママにお願い」）。',
    '- {"type":"edit_draft","text":"…","draft":{…}} 確認待ちの下書きの中身を直したい（例:「時間は7時」「担当はママ」「将生のね」）。',
    "",
    "## draft（create と edit_draft に必ず付ける。登録される中身そのもの）",
    '{"kind":"task|event|request|shopping","title":"…","date":"YYYY-MM-DD","time":"HH:MM"|null,"daypart":"morning|noon|evening|night"|null,"who":"me|partner"|null,"message":"…"|null}',
    "- title: 何をするかが一目で分かる短い一文。言われた具体的な情報（子どもの名前・数・持ち物・場所）は落とさない（例:「将生の保育園に下着を2枚持っていく」）。「〜しないと」「入れといて」などの言い回しは入れない。買い物は品物名だけ（例:「牛乳」）。",
    "- date: 日付。「明日」なら『いま』の翌日。言われていなければ今日。",
    "- time: 言われた時刻だけ（「7時」→ 07:00）。言われていなければ null。時刻を作らない。",
    "- daypart: 「朝」「昼」「夕方」「夜」と言われたら morning / noon / evening / night。「朝担当の人」のように朝のことだと分かるときも morning。",
    "- who: それをする人。me = 話している人、partner = 相手。「朝担当の人」「送りの人」「お迎えの人」は『送迎』のその日の担当で決める。保育園に持っていく物のように送りのときに要ることは、言われていなくてもその日の送り担当。それ以外で言われていなければ null（話している人）。",
    "- kind: task = やること、event = カレンダーに載せる予定（通院・行事など）、request = 相手にお願いして通知する、shopping = 買い物リスト。やるのが相手（who=partner）なら request。",
    "- message: request のとき相手に届く一文（例:「明日の朝、将生の保育園に下着を2枚持っていってもらえる？」）。それ以外は null。",
    "- edit_draft の draft は、確認待ちの下書きに今回の修正を反映した『全体』。直していない項目（子どもの名前・日付など）は下書きのまま残す。",
    '- {"type":"cancel_draft"} 確認待ちの下書きを取り消したい（「やっぱりなし」「さっきのやめて」）。下書きがあるときだけ。',
    '- {"type":"legacy"} 上のどれにも当てはまらない操作（担当の交代、お迎えの交代の相談など）。従来の処理に任せる。',
    "- 質問への答え・相談・雑談・聞き返しは actions を空にして reply だけ。",
    "",
    "## reply（返事）",
    "- 日本語。家族向けのやわらかい口調で、1〜3文。絵文字は0〜1個。",
    "- show_shopping / show_schedule のときは、一覧はアプリが続けて表示するので、前置きの一言だけ（例:「パパが買うものはこれだよ👇」）。",
    "- mark_bought / complete_task / create / cancel_draft のときは、記録の結果はアプリが続けて表示するので、短い相づちだけ（例:「了解！」）。『登録しました』『送りました』『完了にしました』など、結果を先取りする言い方はしない。",
    "",
    "## 例",
    '- 「買うものは？」→ {"understanding":"買い物リストを見たい","reply":"いまの買い物リストはこれだよ👇","actions":[{"type":"show_shopping","who":"any"}],"confidence":"high"}',
    '- 直前のおうちノート「どなたの分を見ますか？」→「おれ」→ {"understanding":"自分が買うものを知りたい（直前の質問への答え）","reply":"了解、パパが買うものはこれ👇","actions":[{"type":"show_shopping","who":"me"}],"confidence":"high"}',
    '- 「いや、買うべきもの教えてよ」→ {"understanding":"自分が買うべきものを知りたい（言い直し）","reply":"ごめんね、パパが買うものはこれだよ👇","actions":[{"type":"show_shopping","who":"me"}],"confidence":"high"}',
    '- 「Tシャツ買った！」（s1 が Tシャツ）→ {"understanding":"s1を買った","reply":"ありがとう！","actions":[{"type":"mark_bought","refs":["s1"]}],"confidence":"high"}',
    '- 「洗濯終わった、あと牛乳も買ってきた」→ {"understanding":"洗濯をやった・牛乳を買った","reply":"おつかれさま！","actions":[{"type":"complete_task","ref":"t4","by":"self"},{"type":"mark_bought","refs":["s2"]}],"confidence":"high"}',
    '- 「ママが洗濯やってくれてた」→ {"understanding":"相手が洗濯をやった","reply":"了解！","actions":[{"type":"complete_task","ref":"t4","by":"partner"}],"confidence":"high"}',
    '- 「今日お迎え誰だっけ？」（お迎えの担当がママ）→ {"understanding":"今日のお迎え担当を知りたい","reply":"今日のお迎えはママだよ（18:20）。","actions":[],"confidence":"high"}',
    `- 「牛乳買っといて」→ {"understanding":"牛乳を買い物に追加したい","reply":"了解！","actions":[{"type":"create","text":"牛乳を買う","draft":{"kind":"shopping","title":"牛乳","date":"${today}","time":null,"daypart":null,"who":null,"message":null}}],"confidence":"high"}`,
    `- 「明日、詩乃の保育園に着替え持っていかないと。入れといて」（送迎: 明日の送りはママ）→ {"understanding":"明日の朝、詩乃の着替えを保育園に持っていく。送りのママがやる","reply":"了解！","actions":[{"type":"create","text":"明日の朝、詩乃の保育園に着替えを持っていくのをママにお願い","draft":{"kind":"request","title":"詩乃の保育園に着替えを持っていく","date":"${tomorrow}","time":null,"daypart":"morning","who":"partner","message":"明日の朝、詩乃の保育園に着替えを持っていってもらえる？"}}],"confidence":"high"}`,
    `- 確認待ちの下書き（お願い・ママ・明日の朝）「保育園に下着を持っていく」→「将生のね。2枚だよ」→ {"understanding":"下書きに将生の・2枚を足す","reply":"了解！","actions":[{"type":"edit_draft","text":"将生の保育園に下着を2枚持っていく","draft":{"kind":"request","title":"将生の保育園に下着を2枚持っていく","date":"${tomorrow}","time":null,"daypart":"morning","who":"partner","message":"明日の朝、将生の保育園に下着を2枚持っていってもらえる？"}}],"confidence":"high"}`,
    '- 「今週ずっと俺がお迎えなんだけど、妻にどう言えば角立たない？」→ {"understanding":"お迎えが続いて負担。ママに代わってほしいが、角を立てずに頼みたい","reply":"こんな感じはどうかな？「今週お迎えずっと続いてて、ちょっとバテ気味で…。金曜だけ代わってもらえると助かるんだけど、どうかな？無理なら言ってね」（送ってはいないよ）","actions":[],"confidence":"high"}',
    '- 「金曜のお迎え代わってほしいってママに頼みたい」→ {"understanding":"金曜のお迎えをママに代わってほしいと依頼したい","reply":"了解！","actions":[{"type":"create","text":"金曜のお迎えをママに代わってほしい"}],"confidence":"high"}',
    '- 「コドモン送りました。朝食はやってあった」（t1=コドモン送信、t2=詩乃：朝食の入力）→ {"understanding":"コドモン送信済み。朝食の入力は相手が済ませていた","reply":"おつかれさま！","actions":[{"type":"complete_task","ref":"t1","by":"self"},{"type":"complete_task","ref":"t2","by":"partner"}],"confidence":"high"}',
    '- 「やった」（該当しそうなタスクが複数）→ {"understanding":"どれをやったか不明","reply":"どれをやったのかな？「洗濯」「送り」みたいに教えてね。","actions":[],"confidence":"medium"}',
    "",
    "## 出力（JSONのみ）",
    '{"understanding":"…","reply":"…","actions":[…],"confidence":"high|medium|low"}',
    "",
    "## 会話（古い順。最後の行の次が最新のメッセージ）",
    turns.length ? turns.join("\n") : "（まだ会話はありません）",
    "",
    "## 家庭の状況",
    JSON.stringify(facts),
    "",
    "## 最新のメッセージ",
    `${snapshot.me}: ${message}`,
  ].join("\n");
}

function str(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

const DAYPARTS: readonly Daypart[] = ["morning", "noon", "evening", "night"];

function isoDateOrNull(value: unknown): string | null {
  if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(value)) return null;
  const d = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === value ? value : null;
}

function localTimeOrNull(value: unknown): string | null {
  const m = typeof value === "string" ? value.trim().match(/^(\d{1,2}):(\d{2})$/) : null;
  if (!m || Number(m[1]) > 23 || Number(m[2]) > 59) return null;
  return `${m[1].padStart(2, "0")}:${m[2]}`;
}

/** A draft the code can use as it is, or undefined (then the sentence takes the old path). */
export function parseDraft(raw: unknown): DraftSpec | undefined {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return undefined;
  const d = raw as Record<string, unknown>;
  const kind = (["task", "event", "request", "shopping"] as const).find((k) => k === d.kind);
  const title = str(d.title)?.replace(/\s+/g, " ");
  if (!kind || !title || title.length > 80) return undefined;
  return {
    kind,
    title,
    date: isoDateOrNull(d.date),
    time: localTimeOrNull(d.time),
    daypart: DAYPARTS.find((p) => p === d.daypart) ?? null,
    who: d.who === "me" || d.who === "partner" ? d.who : null,
    message: str(d.message)?.slice(0, 200) ?? null,
  };
}

function parseAction(raw: unknown): Action | null {
  if (!raw || typeof raw !== "object") return null;
  const a = raw as Record<string, unknown>;
  switch (a.type) {
    case "show_shopping":
      return { type: "show_shopping", who: (["me", "partner", "unassigned", "any"] as const).find((w) => w === a.who) ?? "any" };
    case "show_schedule":
      return { type: "show_schedule", range: (["today", "tomorrow", "week"] as const).find((r) => r === a.range) ?? "today" };
    case "mark_bought": {
      const refs = Array.isArray(a.refs) ? a.refs.filter((r): r is string => typeof r === "string") : [];
      return refs.length ? { type: "mark_bought", refs } : null;
    }
    case "complete_task": {
      const ref = str(a.ref);
      return ref ? { type: "complete_task", ref, by: a.by === "partner" ? "partner" : "self" } : null;
    }
    case "create":
    case "edit_draft": {
      const text = str(a.text);
      if (!text) return null;
      const draft = parseDraft(a.draft);
      return draft ? { type: a.type, text: text.slice(0, 500), draft } : { type: a.type, text: text.slice(0, 500) };
    }
    case "cancel_draft":
      return { type: "cancel_draft" };
    case "legacy":
      return { type: "legacy" };
    default:
      return null;
  }
}

/** Strict: anything unusable is null, and the message takes the old path. */
export function parsePlan(raw: string): Plan | null {
  let parsed: unknown;
  try {
    const fenced = raw.match(/```(?:json)?\s*([\s\S]*?)```/i)?.[1] ?? raw;
    parsed = JSON.parse(fenced.trim());
  } catch {
    return null;
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return null;
  const p = parsed as Record<string, unknown>;
  const reply = str(p.reply);
  const actions = Array.isArray(p.actions) ? p.actions.map(parseAction) : [];
  if (actions.some((action) => action === null)) return null; // an unknown action: do not guess
  if (!reply && actions.length === 0) return null;
  return {
    understanding: str(p.understanding)?.slice(0, 200) ?? "",
    reply: (reply ?? "").slice(0, REPLY_MAX),
    actions: (actions as Action[]).slice(0, MAX_ACTIONS),
    confidence: p.confidence === "high" || p.confidence === "medium" ? p.confidence : "low",
  };
}

const RECORDING = new Set<Action["type"]>(["mark_bought", "complete_task", "create", "cancel_draft"]);

/**
 * The safety net. Returns the plan to run, or null for the old path.
 *  - every reference must exist; a ref to something else is dropped, never guessed;
 *  - a reply may not claim a record the actions do not make;
 *  - a record on a hunch (low confidence) becomes the question in `reply`, if any;
 *  - cancel/edit need a draft.
 */
export function guardPlan(plan: Plan, snapshot: Snapshot): Plan | null {
  const taskRefs = new Set(snapshot.tasks.map((t) => t.ref));
  const shopRefs = new Set(snapshot.shopping.map((s) => s.ref));
  const actions: Action[] = [];
  for (const action of plan.actions) {
    if (action.type === "mark_bought") {
      const refs = [...new Set(action.refs.filter((r) => shopRefs.has(r)))];
      if (refs.length) actions.push({ ...action, refs });
      continue;
    }
    if (action.type === "complete_task") {
      if (taskRefs.has(action.ref)) actions.push(action);
      continue;
    }
    if ((action.type === "cancel_draft" || action.type === "edit_draft") && !snapshot.pendingDraft) continue;
    actions.push(action);
  }
  // Something was asked for but nothing valid is left: do not pretend.
  if (plan.actions.length > 0 && actions.length === 0) return null;

  const records = actions.some((a) => RECORDING.has(a.type));
  if (records && plan.confidence === "low") {
    return plan.reply && !claimsMutationWasPerformed(plan.reply)
      ? { ...plan, actions: [], reply: plan.reply }
      : null;
  }
  // A reply that says something was done, when nothing will be done, is a lie.
  if (!records && plan.reply && claimsMutationWasPerformed(plan.reply)) return null;
  // With records, a claiming lead is dropped: the handlers print the real outcome.
  const reply = records && claimsMutationWasPerformed(plan.reply) ? "" : plan.reply;
  if (!reply && actions.length === 0) return null;
  return { ...plan, reply, actions };
}

export type UnderstandProvider = (prompt: string) => Promise<string | null>;

export function understandModel(): string {
  return Deno.env.get("GEMINI_MODEL_LINE_UNDERSTAND") ??
    Deno.env.get("GEMINI_MODEL_LINE_DECOMPOSITION") ??
    Deno.env.get("GEMINI_MODEL_LINE_INTENT") ??
    Deno.env.get("GEMINI_MODEL_REWRITE") ?? "";
}

// One retry for a transient failure (an empty answer or a 5xx; 1 in 10 in the first
// production evaluation). Never on 429: the free tier's limit is per minute (15 RPM for
// Gemini 3.1 Flash Lite), so asking again seconds later only spends another request.
// Every call -- the retry included -- first asks the shared budget (server_tx_reserve_ai_call);
// when it says no, the message simply takes the old path.
function isTransient(code: string): boolean {
  return code === "GEMINI_EMPTY_RESPONSE" || /^GEMINI_HTTP_5\d\d$/.test(code) || /fetch|network|timed out|connection/i.test(code);
}

export type ReserveAiCall = () => Promise<boolean>;

export function makeGeminiProvider(reserve: ReserveAiCall): UnderstandProvider {
  return async (prompt: string) => {
    const model = understandModel();
    if (!model) return null;
    for (let attempt = 1; attempt <= 2; attempt++) {
      if (!(await reserve())) {
        console.warn("process-line-inbox: AI budget for this minute is used up; using the fallback", { attempt });
        return null;
      }
      try {
        return await callGemini(prompt, model);
      } catch (error) {
        const code = error instanceof Error ? error.message : "unknown";
        console.warn("process-line-inbox: understand unavailable", { code, attempt });
        if (attempt === 2 || !isTransient(code)) return null;
        await new Promise((resolve) => setTimeout(resolve, 700));
      }
    }
    return null;
  };
}

/** Without a budget (tests, tools): never call the model. */
const noModel: UnderstandProvider = () => Promise.resolve(null);

export interface UnderstandResult {
  raw: string | null;
  parsed: Plan | null;
  plan: Plan | null;
}

export async function understandLineText(
  snapshot: Snapshot,
  message: string,
  provider: UnderstandProvider = noModel,
): Promise<UnderstandResult> {
  const raw = await provider(buildUnderstandPrompt(snapshot, message));
  const parsed = raw ? parsePlan(raw) : null;
  return { raw, parsed, plan: parsed ? guardPlan(parsed, snapshot) : null };
}

// ---------------------------------------------------------------------------
// Running a plan. Everything a plan can touch goes through these effects, which
// index.ts wires to the existing handlers. Text results are collected and sent as ONE
// reply: LINE gives one free reply per message, and a second send would become a
// quota-counted push (or be dropped as a duplicate).
// ---------------------------------------------------------------------------

export interface ReplyPart {
  text: string;
  quick?: unknown[];
}

export interface PlanEffects {
  /** Each returns the text it would have replied with (collected, not sent). */
  showShopping(who: ShoppingWho): Promise<ReplyPart[]>;
  markBought(items: SnapshotShopping[]): Promise<ReplyPart[]>;
  /** For the Codmon submit task, `partnerInputCodes` lists the inputs the other adult did. */
  completeTask(task: SnapshotTask, by: "self" | "partner", partnerInputCodes?: string[]): Promise<ReplyPart[]>;
  cancelDraft(): Promise<ReplyPart[]>;
  /** These send their own message (a Flex card or the schedule view); `lead` goes in front. */
  showSchedule(range: "today" | "tomorrow" | "week", lead: string): Promise<void>;
  /** Sends the combined text reply. */
  send(text: string, quick?: unknown[]): Promise<void>;
}

export type PlanOutcome =
  | { done: true }
  | { done: false; continueWith: HandOff; pendingReply: string };

export interface HandOff {
  text: string;
  mode: "create" | "edit" | "legacy";
  /** The model's filled-in draft (create/edit); used as it is instead of re-parsing `text`. */
  draft?: DraftSpec;
}

export async function runPlan(plan: Plan, snapshot: Snapshot, effects: PlanEffects, original: string): Promise<PlanOutcome> {
  const parts: ReplyPart[] = [];
  let schedule: "today" | "tomorrow" | "week" | null = null;
  let handOff: HandOff | null = null;

  // Completing the Codmon submit closes every open input in the same transaction
  // (server_tx_acknowledge_codmon_submission_v1). Inputs the model also lists are folded
  // into that one call -- the ones done "by partner" become its partner codes -- instead of
  // being completed separately and then reported as "already done".
  const submit = plan.actions.find((a) =>
    a.type === "complete_task" && snapshot.tasks.find((t) => t.ref === a.ref)?.code === "codmon_submit"
  );
  const isCodmonInput = (ref: string) => /^codmon_.+_input$/.test(snapshot.tasks.find((t) => t.ref === ref)?.code ?? "");
  const partnerInputCodes = submit
    ? plan.actions
      .filter((a): a is Extract<Action, { type: "complete_task" }> => a.type === "complete_task" && a.by === "partner" && isCodmonInput(a.ref))
      .map((a) => snapshot.tasks.find((t) => t.ref === a.ref)!.code!)
    : [];
  const actions = submit
    ? plan.actions.filter((a) => !(a.type === "complete_task" && isCodmonInput(a.ref)))
    : plan.actions;

  for (const action of actions) {
    switch (action.type) {
      case "show_shopping":
        parts.push(...await effects.showShopping(action.who));
        break;
      case "mark_bought":
        parts.push(...await effects.markBought(snapshot.shopping.filter((s) => action.refs.includes(s.ref))));
        break;
      case "complete_task": {
        const task = snapshot.tasks.find((t) => t.ref === action.ref);
        if (task) {
          parts.push(...await effects.completeTask(task, action.by, task.code === "codmon_submit" ? partnerInputCodes : undefined));
        }
        break;
      }
      case "cancel_draft":
        parts.push(...await effects.cancelDraft());
        break;
      case "show_schedule":
        schedule ??= action.range;
        break;
      case "create":
        handOff ??= action.draft ? { text: action.text, mode: "create", draft: action.draft } : { text: action.text, mode: "create" };
        break;
      case "edit_draft":
        handOff ??= action.draft ? { text: action.text, mode: "edit", draft: action.draft } : { text: action.text, mode: "edit" };
        break;
      case "legacy":
        handOff ??= { text: original, mode: "legacy" };
        break;
    }
  }

  const combined = [plan.reply, ...parts.map((p) => p.text)].filter((t) => t && t.trim()).join("\n\n");
  const quick = [...parts].reverse().find((p) => p.quick?.length)?.quick;

  if (schedule) {
    await effects.showSchedule(schedule, combined);
    return { done: true };
  }
  if (handOff) {
    // The draft card (or the old path) sends its own message. Anything collected so far
    // is handed back so the caller can put it in front, instead of sending it twice.
    return { done: false, continueWith: handOff, pendingReply: parts.length ? combined : "" };
  }
  if (combined) await effects.send(combined, quick);
  return { done: true };
}

// ---------------------------------------------------------------------------
// The model's draft -> the pending action the confirmation card shows. Pure. The same
// payload shapes the old path builds (task_create_once / request_create /
// shopping_item_add), so confirming, editing and executing are unchanged.
// ---------------------------------------------------------------------------

export interface DraftContext {
  actorId: string;
  partnerId: string | null;
  /** "パパ" / "ママ" for the card's 相手 line; anything else shows as パートナー. */
  partnerLabel: string;
  today: string;
}

const DRAFT_OWNED_KEYS = [
  "line_edit_mode", "clarification_stage", "clarification_kind", "recipient_user_id",
  "planned_assignee_user_id", "assignee_user_id", "target_label", "explicit_kind", "shared_message",
];

/**
 * `base` is the draft being edited (its other fields are kept), or {} for a new one.
 * Null when it cannot be built (a request with no partner in the household): the caller
 * then takes the old path, which explains how to invite the partner.
 */
export function draftToPending(
  spec: DraftSpec,
  ctx: DraftContext,
  base: Record<string, unknown> = {},
): { actionType: "task_create_once" | "request_create" | "shopping_item_add"; payload: Record<string, unknown> } | null {
  const payload: Record<string, unknown> = { ...base };
  for (const key of DRAFT_OWNED_KEYS) delete payload[key];
  payload.title = spec.title;
  payload.scheduled_date = spec.date ?? (typeof base.scheduled_date === "string" ? base.scheduled_date : ctx.today);
  // A daypart becomes the usual time for it (朝 = 08:00), as the 朝/夜 buttons do: the
  // task itself only stores a time.
  payload.due_local_time = spec.time ?? daypartToLocalTime(spec.daypart);
  payload.daypart = spec.daypart;
  const partnerLabel = ctx.partnerLabel === "パパ" || ctx.partnerLabel === "ママ" ? ctx.partnerLabel : null;
  const whoId = spec.who === "partner" ? ctx.partnerId : spec.who === "me" ? ctx.actorId : null;

  if (spec.kind === "shopping") {
    payload.purchase_method = typeof base.purchase_method === "string" ? base.purchase_method : "store";
    payload.assignee_user_id = whoId;
    return { actionType: "shopping_item_add", payload };
  }
  if (spec.who === "partner" && spec.kind !== "event") {
    if (!ctx.partnerId) return null;
    payload.recipient_user_id = ctx.partnerId;
    if (partnerLabel) payload.target_label = partnerLabel;
    payload.shared_message = spec.message ?? `${spec.title}をお願いできますか？`;
    return { actionType: "request_create", payload };
  }
  if (spec.who === "partner" && !ctx.partnerId) return null;
  payload.category = typeof base.category === "string" ? base.category : "todo";
  payload.routine_phase = typeof base.routine_phase === "string" ? base.routine_phase : "anytime";
  payload.subtasks = Array.isArray(base.subtasks) ? base.subtasks : [];
  payload.context = typeof base.context === "string" ? base.context : null;
  payload.planned_assignee_user_id = whoId ?? ctx.actorId;
  payload.target_label = spec.who === "partner" && partnerLabel ? partnerLabel : "自分";
  if (spec.kind === "event") {
    payload.explicit_kind = "event";
    payload.calendar_visibility = "special";
  } else {
    payload.calendar_visibility = "hidden";
  }
  return { actionType: "task_create_once", payload };
}

// ---------------------------------------------------------------------------
// Evaluation against the real model (worker-token endpoint in index.ts). Pure: builds
// snapshots from the request, calls the model, returns what it decided. No side effects.
// ---------------------------------------------------------------------------

function evalSnapshot(input: Record<string, unknown>): Snapshot {
  const tasks = Array.isArray(input.tasks) ? input.tasks : [];
  const shopping = Array.isArray(input.shopping) ? input.shopping : [];
  const turns = Array.isArray(input.turns) ? input.turns : [];
  return {
    now: (input.now as Snapshot["now"]) ?? { date: "2026-09-30", time: "22:27", weekday: "水" },
    me: String(input.me ?? "パパ"),
    partner: String(input.partner ?? "ママ"),
    children: Array.isArray(input.children) ? input.children as Snapshot["children"] : [],
    turns: turns
      .filter((x): x is Record<string, unknown> => Boolean(x) && typeof x === "object")
      .map((x) => ({ role: x.role === "assistant" ? "assistant" : "user", text: String(x.text ?? "") })),
    pendingDraft: (input.pendingDraft as Snapshot["pendingDraft"]) ?? null,
    tasks: tasks.map((x, i) => {
      const r = x as Record<string, unknown>;
      return {
        ref: `t${i + 1}`, id: `t${i + 1}`, title: String(r.title ?? ""),
        who: (["me", "partner", "anyone"] as const).find((w) => w === r.who) ?? null,
        due: typeof r.due === "string" ? r.due : null,
        status: r.status === "done" ? "done" : "todo",
        code: typeof r.code === "string" ? r.code : null,
      };
    }),
    shopping: shopping.map((x, i) => {
      const r = x as Record<string, unknown>;
      return { ref: `s${i + 1}`, id: `s${i + 1}`, title: String(r.title ?? ""), who: r.who === "me" ? "me" : r.who === "partner" ? "partner" : null, revision: 1 };
    }),
    sharedNotes: Array.isArray(input.sharedNotes) ? input.sharedNotes.map(String) : [],
    transport: Array.isArray(input.transport) ? input.transport as SnapshotTransport[] : [],
  };
}

// At most 5 cases per request: evaluation must never eat the family's per-minute budget.
export async function evaluateUnderstanding(cases: unknown, provider: UnderstandProvider = noModel) {
  const list = Array.isArray(cases) ? cases.slice(0, 5) : [];
  const results = [];
  for (const c of list) {
    const r = (c ?? {}) as Record<string, unknown>;
    const snapshot = evalSnapshot((r.snapshot ?? {}) as Record<string, unknown>);
    const message = String(r.message ?? "");
    const started = Date.now();
    const result = await understandLineText(snapshot, message, provider);
    results.push({ id: r.id ?? null, message, ms: Date.now() - started, raw: result.raw, plan: result.plan, rejected: Boolean(result.parsed) && !result.plan });
  }
  return { model: understandModel(), results };
}
