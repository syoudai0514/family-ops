import { assertEquals } from "jsr:@std/assert@1";
import { formatTodayTasks, mergeTodayBrief, type TodayTaskRow } from "./lineTodayTasks.ts";

const ME = "me";
const PARTNER = "her";
const at = (hhmm: string) => `2026-10-07T${hhmm}:00+09:00`;

const rows: TodayTaskRow[] = [
  { title: "朝ごはん", status: "completed", routine_phase: "morning", due_at: at("07:00"), planned_assignee_id: ME },
  { title: "送り", status: "todo", routine_phase: "morning", due_at: at("07:20"), planned_assignee_id: ME },
  { title: "詩乃（便秘）の薬", status: "skipped", outcome_reason: "could_not_do", routine_phase: "morning", due_at: at("07:00"), planned_assignee_id: ME },
  { title: "今回は不要のもの", status: "skipped", outcome_reason: "not_needed_this_occurrence", routine_phase: "morning", planned_assignee_id: ME },
  { title: "取り消したもの", status: "cancelled", routine_phase: "morning", planned_assignee_id: ME },
  { title: "食洗機を空ける", status: "todo", routine_phase: "morning", due_at: at("07:00"), assignment_mode: "anyone" },
  { title: "明日の保育園準備", status: "todo", routine_phase: "evening", due_at: at("21:00"), planned_assignee_id: ME },
  ...["お迎え", "夕食対応", "お風呂", "洗濯を畳む", "寝かしつけ"].map((title, i) => ({
    title, status: "todo", routine_phase: "evening", due_at: at(`1${8 + (i % 2)}:0${i}`), planned_assignee_id: PARTNER,
  })),
  { title: "コドモン入力", status: "completed", routine_phase: "morning", planned_assignee_id: PARTNER },
];

Deno.test("today: every one of my tasks is listed (done, できなかった, open), the partner's are summarised", () => {
  const text = formatTodayTasks(rows, ME, "パパ", "ママ");
  assertEquals(text, [
    "パパのタスク（5件・残り3）",
    "",
    "朝",
    "✓ 7:00 朝ごはん",
    "− 7:00 詩乃（便秘）の薬（できなかった）",
    "・ 7:00 食洗機を空ける（誰でもOK）",
    "・ 7:20 送り",
    "",
    "夜",
    "・ 21:00 明日の保育園準備",
    "",
    "ママの今日（残り5件・済み1件）",
    "・お迎え、お風呂、寝かしつけ ほか2件",
  ].join("\n"));
  assertEquals(text.includes("ほか") && !text.split("ママの今日")[0].includes("ほか"), true);
});

Deno.test("today: the brief keeps its other sections; its task sections are replaced in place", () => {
  const brief = "朝のおうちノート\n\n今日の予定\n・14:00 プール\n\n朝やること\n・送り\n\n夜にやること\n・準備\n\n相手の今日\n・お迎え\n・ほか 8件\n\nコドモン 9:15まで\n・残り: 朝食";
  assertEquals(mergeTodayBrief(brief, "TASKS"), "朝のおうちノート\n\n今日の予定\n・14:00 プール\n\nTASKS\n\nコドモン 9:15まで\n・残り: 朝食");
  // A brief without task sections gets the list right after its title.
  assertEquals(mergeTodayBrief("今日のおうちノート\n\n確認が必要な項目はありません。", "TASKS"), "今日のおうちノート\n\nTASKS\n\n確認が必要な項目はありません。");
});
