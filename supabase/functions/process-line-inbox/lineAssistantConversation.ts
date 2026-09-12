import { callGemini } from "../_shared/gemini.ts";

export type AssistantConversationProvider = (text: string) => Promise<string | null>;

function parseReply(raw: string): string | null {
  try {
    const fenced = raw.match(/```(?:json)?\s*([\s\S]*?)```/i)?.[1] ?? raw;
    const parsed = JSON.parse(fenced.trim());
    if (!parsed || typeof parsed !== "object") return null;
    const reply = (parsed as Record<string, unknown>).reply;
    if (typeof reply !== "string") return null;
    const cleaned = reply.replace(/\s+/g, " ").trim();
    return cleaned.length > 0 ? cleaned.slice(0, 600) : null;
  } catch {
    return null;
  }
}

export function assistantConversationFallback(text: string): string {
  const value = text.normalize("NFKC").replace(/\s+/g, "");
  if (
    /(?:送らないで|送らず|おくらず|送信しない|送信せず|通知しない|通知せず|つうちなし|登録せず|登録しない|とうろくなし|相談だけ|そうだんだけ|下書きだけ|したがきだけ|文章だけ考えて|ぶんしょうだけかんがえて)/u
      .test(value)
  ) {
    return "了解。これは相談・下書きとして扱い、家族への送信・通知・登録はしません。伝えたい内容があれば、そのまま書いてください。";
  }
  if (/(?:どう言えば|どう言うのが|なんて言えば|どう頼めば|どう頼むのが|どんな言い方|角立たない)/u.test(value)) {
    return "家族へのお願いは「状況 → お願い → 難しければ言ってね」の順にすると伝わりやすいです。具体的な内容を教えてくれれば、相手には送らず文案だけ一緒に考えます。";
  }
  return "これは家族への送信や登録にはせず、私への相談として扱います。もう少し状況を教えてください。";
}

async function geminiConversationProvider(text: string): Promise<string | null> {
  const model = Deno.env.get("GEMINI_MODEL_LINE_DECOMPOSITION") ??
    Deno.env.get("GEMINI_MODEL_LINE_INTENT") ??
    Deno.env.get("GEMINI_MODEL_REWRITE") ?? "";
  if (!model) return null;

  const prompt = [
    "あなたは家族運営アプリ『おうちノート』の会話アシスタントです。",
    "この入力は家族への送信・登録・依頼を実行するためではなく、あなた自身への質問/相談として安全境界で判定済みです。",
    "ユーザーの質問へ自然な日本語で短く役立つ返答をしてください。",
    "家族への伝え方を相談されたら、責め・嫌味・罪悪感を避けつつ、実際の要望と理由を保った文案を提案してよいです。",
    "ただし『送信した』『通知した』『登録した』『依頼した』など、実行していないmutation/notificationを行ったように言ってはいけません。",
    "ユーザーが『送らない』『通知しない』『登録しない』『相談だけ』『文章だけ』『下書きだけ』と指定した場合は、その制約を短く確認してください。",
    "文脈不足なら、推測で家族・担当・日時を決めず、必要な確認を1つだけ聞いてください。",
    "家族向け文案を返してもよいが、あくまで文案であり自動送信しません。",
    'JSONのみ: {"reply":"ユーザーへの返答"}',
    `入力: ${JSON.stringify(text)}`,
  ].join("\n");

  try {
    return await callGemini(prompt, model);
  } catch (error) {
    console.warn("assistant conversation unavailable", {
      code: error instanceof Error ? error.message : "unknown",
    });
    return null;
  }
}

export async function buildAssistantConversationReply(
  text: string,
  provider: AssistantConversationProvider = geminiConversationProvider,
): Promise<string> {
  const raw = await provider(text);
  return (raw ? parseReply(raw) : null) ?? assistantConversationFallback(text);
}

export function ambiguousAddresseeReply(): string {
  return "これは私への相談ですか？それとも家族へのお願いですか？ 相手にはまだ送らず、通知・登録もしていません。";
}
