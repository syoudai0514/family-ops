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
    "パパの担当（4件・残り2件）",
    "",
    "朝",
    "✓ 7:00 朝ごはん",
    "− 7:00 詩乃（便秘）の薬（できなかった）",
    "・ 7:20 送り",
    "",
    "夜",
    "・ 21:00 明日の保育園準備",
    "",
    "2人で分担（誰でもOK）",
    "朝",
    "・ 7:00 食洗機を空ける",
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

Deno.test("today: an optional task (掃除) is listed apart as 余裕があれば and never counted as left", () => {
  const rows: TodayTaskRow[] = [
    { title: "送り", status: "todo", routine_phase: "morning", due_at: at("08:00"), planned_assignee_id: ME },
    { title: "掃除（ルンバのほかにやったら）", status: "todo", routine_phase: "evening", assignment_mode: "anyone", expectation: "optional" },
    { title: "お迎え", status: "todo", routine_phase: "evening", due_at: at("18:20"), planned_assignee_id: PARTNER },
    { title: "partner optional", status: "todo", routine_phase: "evening", planned_assignee_id: PARTNER, expectation: "optional" },
  ];
  assertEquals(formatTodayTasks(rows, ME, "パパ", "ママ"), [
    "パパの担当（1件・残り1件）",
    "",
    "朝",
    "・ 8:00 送り",
    "",
    "余裕があれば",
    "◦ 掃除（ルンバのほかにやったら）",
    "",
    "ママの今日（残り1件・済み0件）",
    "・お迎え",
  ].join("\n"));
  // Done optional work is shown as done.
  const done = formatTodayTasks([{ ...rows[1], status: "completed" }], ME, "パパ", "ママ");
  assertEquals(done.includes("✓ 掃除（ルンバのほかにやったら）") && done.includes("パパの担当（0件・残り0件）"), true);
});

Deno.test("today: first departure and unrestricted sharing are distinct, without repeated 誰でもOK", () => {
  const text = formatTodayTasks([
    { title: "食洗機を空ける（先に家を出る人）", display_title: "食洗機を空ける", responsibility_hint: "先に家を出る人", status: "todo", routine_phase: "morning", assignment_mode: "anyone" },
    { title: "コープ申し込み", display_title: "コープ申し込み", responsibility_hint: "2人で分担（誰でもOK）", status: "todo", routine_phase: "evening", assignment_mode: "anyone" },
  ], ME, "パパ", "ママ");
  assertEquals(text.includes("先に家を出る人\n朝\n・ 食洗機を空ける"), true);
  assertEquals(text.includes("2人で分担（誰でもOK）\n夜\n・ コープ申し込み"), true);
  assertEquals(text.match(/誰でもOK/g)?.length, 1);
  assertEquals(text.includes("食洗機を空ける（先に家を出る人）"), false);
});

Deno.test("today: claimed shared work follows the current taker, and display dates are preserved", () => {
  const text = formatTodayTasks([
    { title: "自分が始めた作業", status: "in_progress", routine_phase: "morning", assignment_mode: "anyone", active_claimant_user_id: ME, active_claimant_label: "パパ" },
    { title: "相手が始めた作業", status: "in_progress", routine_phase: "morning", assignment_mode: "anyone", active_claimant_user_id: PARTNER, active_claimant_label: "ママ" },
    { title: "明日の保育園準備", display_title: "10/15(木)の保育園準備", status: "todo", routine_phase: "evening", planned_assignee_id: ME, due_at: at("21:00") },
  ], ME, "パパ", "ママ");
  const mine = text.split("ママの今日")[0];
  assertEquals(mine.includes("自分が始めた作業（パパ対応中）"), true);
  assertEquals(mine.includes("相手が始めた作業"), false);
  assertEquals(text.includes("ママの今日（残り1件・済み0件）\n・相手が始めた作業（ママ対応中）"), true);
  assertEquals(text.includes("21:00 10/15(木)の保育園準備"), true);
});

Deno.test("today: full task list replaces special, shared and optional sections without duplication", () => {
  const brief = "朝のおうちノート\n\n⭐ 今日、忘れずに\n・ゴミ出し\n\n朝やること\n先に家を出る人\n・食洗機\n\n余裕があれば\n◦掃除\n\n相手の担当で確認したいこと\n・お迎え\n\n明日 10/14(水)の予定・作業\n・10/15(木)の準備";
  assertEquals(mergeTodayBrief(brief, "TASKS"), "朝のおうちノート\n\nTASKS\n\n明日 10/14(水)の予定・作業\n・10/15(木)の準備");
});
