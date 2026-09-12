import type { LineQuickReplyAction } from "../_shared/lineMessaging.ts";

export type LineReadOnlyIntent =
  | "today"
  | "tomorrow"
  | "week"
  | "menu"
  | "input"
  | "add"
  | "share"
  | "other";
export type LineCreationKind = "event" | "task" | "request" | "shopping";

function normalized(text: string): string {
  return text.normalize("NFKC").replace(/\s+/g, "").trim();
}

export type LineNonMutationDisposition = "assistant_conversation" | "ambiguous";

type ClauseDisposition = "assistant_conversation" | "ambiguous" | "explicit_family_action" | null;

function semanticNormalized(text: string): string {
  return normalized(text).replace(/[。.!！?？]+$/g, "");
}

export function normalizeHiraganaMamaRole(value: string): string {
  const beforeTokens = [
    "今日", "明日", "明後日", "相手は",
    "いや", "いや違う", "やっぱ", "やっぱり", "訂正", "訂正して", "、", ",",
  ];
  const afterTokens = [
    "に", "へ", "が", "は", "じゃなくて", "ではなくて",
    "お願い", "おねがい", "頼", "たの", "迎え", "むかえ", "送り", "おくり",
    "、", ",",
  ];

  let cursor = 0;
  let result = "";
  while (cursor < value.length) {
    const index = value.indexOf("まま", cursor);
    if (index < 0) {
      result += value.slice(cursor);
      break;
    }
    result += value.slice(cursor, index);
    const before = value.slice(0, index);
    const after = value.slice(index + 2);
    const roleBefore = index === 0 || beforeTokens.some((token) => before.endsWith(token));
    const roleAfter = after.length === 0 || afterTokens.some((token) => after.startsWith(token));
    if (roleBefore && roleAfter) result += "ママ";
    cursor = index + 2;
  }
  return result;
}

function roleSafeValue(value: string): string {
  return normalizeHiraganaMamaRole(value);
}

function hasExplicitFamilyRole(value: string): boolean {
  return /(?:パパ|ぱぱ|父|お父さん|ママ|まま|母|お母さん|嫁さん|奥さん|妻)/u.test(roleSafeValue(value));
}

function hasConversationAdviceCue(value: string): boolean {
  return /(?:どう思う|どうおもう|どうかな|どうするのが(?:いい|良い|よい)(?:と思う|とおもう)?|どう(?:言|い)えば|どう(?:言|い)うのが(?:いい|良い|よい|自然)|なんて(?:言|い)えば|どう頼めば|どうたのめば|どう頼む|どうたのむ|どう(?:頼|たの)むのが(?:いい|良い|よい|自然)|どう伝える|どうつたえる|どんな言い方|どんないいかた|どういう言い方|どういういいかた|どんな感じ.*(?:角立たない|角が立たない)|(?:角立たない|角が立たない).*(?:言い方|いいかた|文章|文面)|お願いできる(?:と)?思う|お願いできる(?:と)?おもう|おねがいできる(?:と)?おもう|お願いできそう(?:かな|か)?|おねがいできそう(?:かな|か)?|お願いできるかな|おねがいできるかな|頼めそう(?:かな|か)?|たのめそう(?:かな|か)?|頼むなら.*(?:言い方|いいかた)|たのむなら.*(?:言い方|いいかた))/u.test(value);
}

function hasHardNoMutationCue(value: string): boolean {
  return /(?:まだ)?(?:送らないで|おくらないで|送らず|おくらず|送らない|おくらない)|(?:送信|そうしん)(?:は|を)?(?:しないで|しない|せず)|(?:通知|つうち)(?:は|を)?(?:しないで|しない|せず|なし)|(?:送る|おくる)(?:の|のは|のも)?まだ|(?:登録せず|登録しない|登録なし|とうろくせず|とうろくしない|とうろくなし)|(?:相談だけ|そうだんだけ)|(?:下書き|したがき)(?:だけ)?(?:作って|つくって|考えて|かんがえて|整えて|ととのえて)|(?:文章|文案|文面|言い方|いいかた)(?:だけ)?(?:一緒に|いっしょに)?(?:考えて|かんがえて|整えて|ととのえて)|(?:送る|おくる)か(?:は)?あとで(?:決める|きめる)|(?:送って|おくって|登録して|とうろくして)(?:じゃなくて|ではなくて)(?:相談|そうだん|質問|しつもん)/u.test(value);
}

function hasAssistantAddressCue(value: string): boolean {
  return /(?:^|[、,])(?:あなた|おうちノート|AI|エーアイ|そっち)(?:に|へ)?(?:相談|そうだん|聞|き|言|い)/u.test(value) ||
    /(?:妻|ママ|まま|パパ|ぱぱ)(?:じゃなくて|ではなくて)(?:AI|エーアイ|あなた|おうちノート)(?:に|へ)?(?:聞|き|相談|そうだん)/u.test(roleSafeValue(value)) ||
    /(?:お願い|おねがい|依頼|いらい|送る|おくる|登録|とうろく)(?:じゃない|ではない|じゃなくて|ではなくて)[、,]?(?:あなた|AI|エーアイ|おうちノート)(?:(?:に|へ)?(?:相談|そうだん|聞|き)|の?意見)/u.test(value) ||
    /(?:家族|相手|パートナー)(?:に|へ)?(?:送る|おくる|伝える|つたえる)(?:ん|の)?(?:じゃなくて|ではなくて|ではなく)[、,]?(?:AI|エーアイ|あなた|おうちノート)(?:に|へ)?(?:相談|そうだん|聞|き)/u.test(value);
}

function hasDraftReviewCue(value: string): boolean {
  const prefix = "(?:まず|先に|ちょっと|一回|いったん)?";
  return new RegExp(`^${prefix}(?:この|その|あの)?(?:文章|文面|メッセージ|文案)(?:を)?(?:見て|みて|直して|なおして|整えて|ととのえて|チェックして|見てもらえる|みてもらえる)$`, "u").test(value) ||
    new RegExp(`^${prefix}(?:この|その|あの)?(?:言い方|いいかた)(?:を|だけ)?(?:見て|みて|直して|なおして|整えて|ととのえて|考えて|かんがえて|チェックして|見てもらえる|みてもらえる)$`, "u").test(value) ||
    /(?:言い方|いいかた)(?:だけ)?(?:一緒に|いっしょに)?(?:整えて|ととのえて|考えて|かんがえて)$/u.test(value) ||
    /(?:家族|相手|パートナー)(?:に|へ)?(?:送る|おくる)前に(?:この|その|あの)?(?:文章|文面|メッセージ|文案)(?:を)?(?:見て|みて|見てもらえる|みてもらえる)$/u.test(value);
}

function stripLeadingCorrectionCue(value: string): string {
  return value.replace(/^(?:違う違う|ちがうちがう|違うよ|ちがうよ|違う|ちがう|いやいや|いや|そうじゃなくて|そうではなくて|そうじゃない|そうじゃないよ)[、,]?/u, "");
}

function hasExplicitFamilyActionCue(value: string): boolean {
  if (hasConversationAdviceCue(value) || hasHardNoMutationCue(value)) return false;
  if (/(?:頼む|たのむ|お願いする|おねがいする)(?:ための)?(?:文章|文面|文案|メッセージ)$/u.test(value)) return false;
  if (/(?:もし)?(?:大丈夫|大丈夫そう|問題なさそう|よさそう|良さそう|できそう|可能そう)なら/u.test(value)) return false;
  if (/(?:するとしたら|するとすれば|頼むなら|たのむなら|お願いするなら|おねがいするなら)/u.test(value)) return false;

  const familyRole = hasExplicitFamilyRole(value);
  const explicitAction = /(?:お願い(?:して|したい|できる)?|おねがい(?:して|したい|できる)?|頼(?:む|んで|みたい)|たの(?:む|んで|みたい)|してほしい|して欲しい|やって|やっといて|買って|かって|聞いて|きいて|伝えて|つたえて|迎え|むかえ|送り|おくり)/u.test(value);
  if (familyRole && explicitAction) return true;
  if (/^(?:これ|それ|そっち|こっち)/u.test(value)) return false;
  return /(?:迎え|むかえ|送り|おくり|ゴミ出し|ごみ出し|洗濯|食器|風呂|ふろ|買い物|牛乳).*(?:お願い|おねがい|頼|たの|やって|して|買って|かって)/u.test(value);
}

function clauseDisposition(text: string): ClauseDisposition {
  const value = semanticNormalized(text);
  if (!value) return null;
  if (hasHardNoMutationCue(value) || hasConversationAdviceCue(value) || hasAssistantAddressCue(value) || hasDraftReviewCue(value)) return "assistant_conversation";
  if (/(?:もし)?(?:大丈夫|大丈夫そう|問題なさそう|よさそう|良さそう|できそう|可能そう)なら.*(?:お願い|おねがい|頼|たの)/u.test(value)) return "assistant_conversation";
  if (hasExplicitFamilyActionCue(value)) return "explicit_family_action";
  if (/(?:これ|それ|そっち|こっち)(?:って)?(?:お願いできる|おねがいできる|頼める|たのめる|いける|任せていい|まかせていい|どう|どうする)$/u.test(value) || /^(?:今日|きょう)どうする$/u.test(value)) return "ambiguous";
  if (/^(?:これ|それ|そっち|こっち).*(?:どう思う|どうおもう|どう)$/u.test(value) || /^(?:この|その|あの)?文章(?:どう|どう思う|どうおもう)$/u.test(value)) return "assistant_conversation";
  return null;
}

function semanticClauses(text: string): string[] {
  const clauses = text.split(/[。！？!?、,]+/u).map((value) => value.trim()).filter(Boolean);
  return clauses.length > 0 ? clauses : [text.trim()];
}

function hasClearlyScopedNoMutationAndIndependentFamilyAction(text: string): boolean {
  const clauses = semanticClauses(text);
  const hasScopedNoMutation = clauses.some((clause) => {
    const value = semanticNormalized(clause);
    return hasHardNoMutationCue(value) &&
      /^(?:これ|それ|この(?:文|文章|文面|メッセージ)|その(?:文|文章|文面|メッセージ))/u.test(value);
  });
  const hasIndependentFamilyAction = clauses.some((clause) =>
    hasExplicitFamilyActionCue(semanticNormalized(clause))
  );
  const hasExplicitBoundary = /(?:それとは別に|これは別で|別件(?:で|だけど)?|別の(?:件|話)(?:で|だけど)?)/u.test(text);
  return hasIndependentFamilyAction && (hasScopedNoMutation || hasExplicitBoundary);
}

export function lineNonMutationDisposition(text: string): LineNonMutationDisposition | null {
  const wholeValue = semanticNormalized(text);
  if (
    hasHardNoMutationCue(wholeValue) &&
    !hasClearlyScopedNoMutationAndIndependentFamilyAction(text)
  ) return "assistant_conversation";
  const dispositions = semanticClauses(text).map(clauseDisposition);
  if (dispositions.includes("explicit_family_action")) return null;
  const whole = clauseDisposition(text);
  if (whole === "assistant_conversation") return "assistant_conversation";
  if (dispositions.includes("assistant_conversation")) return "assistant_conversation";
  if (dispositions.includes("ambiguous")) return "ambiguous";
  return null;
}

export function isConversationOnlyCandidateSource(text: string): boolean {
  const disposition = clauseDisposition(text);
  return disposition === "assistant_conversation" || disposition === "ambiguous";
}

export function isLineCorrectionCue(text: string): boolean {
  const value = normalized(text).replace(/[。.!！?？]+$/g, "");
  return /^(?:違う違う|ちがうちがう|違うよ|ちがうよ|違う|ちがう|いやいや|いや|そうじゃなくて|そうではなくて|そうじゃない|そうじゃないよ)[、,]?/u.test(value) || isAssistantAddressCorrection(text);
}

export type LinePendingFollowUpKind = "referent_question" | "assistant_repair" | "cancel" | "edit" | null;

export function linePendingFollowUpKind(text: string): LinePendingFollowUpKind {
  const value = semanticNormalized(text);
  if (/^(?:なにを|何を|何を受け付けたの|さっきの何|それ)[？?]?$/u.test(value)) return "referent_question";
  if (isAssistantAddressCorrection(text)) return "assistant_repair";
  if (/(?:だけやめて|取り消|キャンセル|やっぱ(?:り)?(?:さっきの)?なし|さっきのなし|やっぱなし|やっぱ(?:り)?今の(?:お願い|おねがい)?なし(?:で)?)/u.test(value)) return "cancel";
  if (/(?:だった|じゃなくて|ではなくて|に変更|にして)/u.test(value) || isLineCorrectionCue(text)) return "edit";
  return null;
}

export function transportAssignmentCorrectionCode(title: string): "pickup" | "dropoff" | null {
  const value = semanticNormalized(title);
  if (/^(?:お?迎え|むかえ)$/u.test(value)) return "pickup";
  if (/^(?:送り|おくり)$/u.test(value)) return "dropoff";
  return null;
}

export function lineConversationalReplacementTitle(text: string): string | null {
  if (isAssistantAddressCorrection(text)) return null;
  const match = text.trim().match(/^(?:違う違う|ちがうちがう|違うよ|ちがうよ|違う|ちがう|いやいや|いや|そうじゃなくて|そうではなくて)[、,\s]*(.{1,40}?)[。！!？?]?$/u);
  if (!match) return null;
  const replacement = match[1].replace(/\s+/g, " ").trim();
  if (!replacement || /^(?:今日|明日|明後日|朝|昼|夕方|夜|\d{1,2}時)/u.test(replacement)) return null;
  if (/^(?:パパ|ぱぱ|ママ|まま|父|母|お父さん|お母さん|妻)$/u.test(replacement)) return null;
  return replacement;
}

export function isAssistantAddressCorrection(text: string): boolean {
  const value = semanticNormalized(text);
  const repaired = stripLeadingCorrectionCue(value);
  const candidates = repaired === value ? [value] : [value, repaired];
  return candidates.some((candidate) => {
    if (/^(?:(?:あなた|おうちノート|AI|そっち)(?:に|へ)?)(?:聞いてる|聞いている|聞いてんの|きいてる|相談(?:してる|している|中)?|そうだん(?:してる|している|中)?|言ってる|言っている|言ってんの)(?:んだけど|んだよ|んだけどね|よ)?$/u.test(candidate)) return true;
    if (/^(?:妻|ママ|まま|パパ|ぱぱ)(?:じゃなくて|ではなくて)(?:AI|あなた|おうちノート)(?:に|へ)?(?:聞いてる|聞いている|きいてる|相談(?:してる|している|中)?|そうだん(?:してる|している|中)?)(?:んだけど|んだよ|よ)?$/u.test(roleSafeValue(candidate))) return true;
    if (/^(?:お願い|おねがい|依頼|いらい|送って|おくって|送る|おくる|登録して|とうろくして|登録|とうろく)(?:じゃない|ではない|じゃなくて|ではなくて)[、,]?(?:あなた|AI|おうちノート)(?:(?:に|へ)?(?:相談(?:してる|している|中)?|そうだん(?:してる|している|中)?|質問|しつもん|聞いてる|きいてる)|の?意見(?:が)?(?:聞きたい|ききたい))?$/u.test(candidate)) return true;
    if (/^(?:家族|相手|パートナー)(?:に|へ)?(?:送る|おくる|伝える|つたえる)(?:ん|の)?(?:じゃなくて|ではなくて|ではなく)[、,]?(?:AI|エーアイ|あなた|おうちノート)(?:に|へ)?(?:相談(?:してる|している|中)?|そうだん(?:してる|している|中)?|聞いてる|きいてる)?$/u.test(candidate)) return true;
    return /^(?:送って|おくって|登録して|とうろくして)(?:じゃなくて|ではなくて)(?:相談|そうだん|質問|しつもん)$/u.test(candidate);
  });
}

function normalizedScheduleInquiry(text: string): string {
  return normalized(text)
    .replace(/[。.!！?？]+$/g, "")
    .replace(/^(?:違う違う|ちがうちがう|違うよ|ちがうよ|違う|ちがう|いやいや|いや|そうじゃなくて|そうではなくて|そうじゃない|そうじゃないよ)[、,]*/u, "")
    .replace(/^ただ/u, "")
    .replace(/きょう/gu, "今日")
    .replace(/あした/gu, "明日")
    .replace(/こんしゅう/gu, "今週")
    .replace(/よてい/gu, "予定")
    .replace(/おしえて/gu, "教えて")
    .replace(/しりたい/gu, "知りたい")
    .replace(/みたい/gu, "見たい")
    .replace(/かくにんしたい/gu, "確認したい")
    .replace(/なに/gu, "何")
    .replace(/なんかか予定/gu, "なんか予定");
}

function scheduleReadOnlyIntent(text: string): "today" | "tomorrow" | "week" | null {
  const value = normalizedScheduleInquiry(text);
  const match = value.match(/^(今日|明日|今週)(.*)$/u);
  if (!match) return null;
  const kind = match[1] === "今日" ? "today" : match[1] === "明日" ? "tomorrow" : "week";
  const rest = match[2];
  if (/(?:追加|登録|作って|作成|変更|消して|削除|送って|お願い|頼んで)/u.test(rest)) return null;
  if (rest === "") return kind;
  if (/^(?:って)?(?:(?:なんか|何か))?(?:の)?予定(?:は|を|が)?(?:教えて|知りたい|見たい|確認したい|何(?:が)?ある|何だっけ|なんだっけ|ある|あるの|あるっけ|あった|あったっけ|どう|どうなってる|どうだっけ)?(?:だけ)?$/u.test(rest)) return kind;
  if (/^(?:って)?(?:なんか|何か)?(?:何(?:が)?ある|どうなってる|どうだっけ)(?:の)?$/u.test(rest)) return kind;
  if (/^(?:って)?(?:なんか|何か)?ある(?:の|っけ)?$/u.test(rest)) return kind;
  return null;
}

export function conversationalScheduleLead(text: string, intent: "today" | "tomorrow" | "week", correction = false): string | null {
  const value = normalized(text).replace(/[。.!！?？]+$/g, "");
  if ((intent === "today" && value === "今日") || (intent === "tomorrow" && value === "明日") || (intent === "week" && value === "今週")) return null;
  if (correction) {
    return intent === "today" ? "了解。登録じゃなくて、今日の予定の確認ね。見てみたよ👇" : intent === "tomorrow" ? "了解。登録じゃなくて、明日の予定の確認ね。見てみたよ👇" : "了解。登録じゃなくて、今週の予定の確認ね。見てみたよ👇";
  }
  return intent === "today" ? "うん、今日の予定見てみたよ！こんな感じ👇" : intent === "tomorrow" ? "うん、明日の予定見てみたよ！こんな感じ👇" : "うん、今週の予定見てみたよ！こんな感じ👇";
}

export function lineLinkWelcomeText(): string {
  return ["✅ LINE連携が完了しました。", "", "このLINEには、普段の言葉でそのまま話しかけて大丈夫です。", "・「今日なんか予定あったっけ？」→ 今日の状況を確認", "・「お願いを送りたい」→ 家族へのお願い", "・「牛乳買って」→ 買い物の追加候補", "・「共有」→ 引き継ぎ・共有", "", "まずは「今日」と送ってみてください。"].join("\n");
}

export function readOnlyLineIntent(text: string): LineReadOnlyIntent | null {
  const value = normalized(text);
  if (/^(?:入力|今日の入力|朝の入力|夜の入力)$/.test(value)) return "input";
  if (/^(?:追加|追加したい|登録)$/.test(value)) return "add";
  if (/^(?:共有|引き継ぎ|共有したい)$/.test(value)) return "share";
  if (/^(?:その他|管理|設定)$/.test(value)) return "other";
  if (/^(?:メニュー(?:を)?(?:出して|見せて|表示して)?|何(?:が|を)?できる(?:んだっけ|の|こと)?|何できる(?:んだっけ)?|できること(?:は|教えて)?|使い方(?:は|教えて)?|ヘルプ(?:お願い)?)[？?。!！]*$/.test(value)) return "menu";
  const scheduleIntent = scheduleReadOnlyIntent(text);
  if (scheduleIntent) return scheduleIntent;
  return null;
}

export function lineCreationStarterKind(text: string): LineCreationKind | null {
  const value = normalized(text).replace(/[。.!！?？]+$/g, "");
  const prefix = "(?:(?:パパ|ママ|父|母|お父さん|お母さん|嫁さん|奥さん|妻)に)?(?:(?:今日|明日|明後日)(?:の)?(?:朝|昼|夕方|夜)?(?:の|に)?)?";
  if (new RegExp(`^${prefix}(?:予定|単発予定)(?:を)?(?:追加|登録)(?:したい|して|する|お願い)?$`).test(value)) return "event";
  if (new RegExp(`^${prefix}タスク(?:を)?(?:追加|登録)(?:したい|して|する|お願い)?$`).test(value)) return "task";
  if (new RegExp(`^${prefix}(?:お願い|依頼)(?:を)?(?:送りたい|したい|送って|する)$`).test(value)) return "request";
  if (/^(?:買い物|買うもの)(?:を)?(?:追加|登録)(?:したい|して|する|お願い)?$/.test(value)) return "shopping";
  return null;
}

const message = (label: string, text = label): LineQuickReplyAction => ({ type: "message", label, text });

export function menuQuickReplies(): LineQuickReplyAction[] {
  return [message("今日", "今日の予定は？"), message("入力", "入力"), message("追加", "追加したい"), message("お願い", "お願いを送りたい"), message("共有", "共有"), message("その他", "その他")];
}

export function completionHint(text: string): string {
  return `${text}\n\n💡 次もそのまま文章でOKです。「メニュー」でできることを確認できます。`;
}

export function pendingConfirmationMessage(actionType: string): string {
  if (actionType === "assignment_change_request") return "✓ お願いを送りました。\n相手の返事を待っています。担当はまだ変わっていません。";
  if (actionType === "request_create") return "✓ お願いを送りました。\n相手の返事を待っています。";
  return "✓ 登録しました。";
}

export type CompactScheduleEntry = { title: string; startsAt: string | null; roleLabel?: string | null; conflict?: boolean };

export function formatScheduleReply(title: string, entries: CompactScheduleEntry[]): string {
  if (entries.length === 0) return `${title}\n\n予定はありません。`;
  const rendered = entries.slice(0, 8).map((entry) => {
    const time = entry.startsAt ? new Intl.DateTimeFormat("ja-JP", { timeZone: "Asia/Tokyo", hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(entry.startsAt)) : "終日";
    return `${time} ${entry.title}${entry.roleLabel ? `（${entry.roleLabel}）` : ""}${entry.conflict ? " ⚠️" : ""}`;
  });
  const remaining = entries.length - rendered.length;
  return `${title}\n\n${rendered.join("\n")}${remaining > 0 ? `\nほか${remaining}件` : ""}`;
}
