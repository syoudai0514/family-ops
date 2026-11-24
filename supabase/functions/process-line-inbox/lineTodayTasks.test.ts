import { assertEquals } from "jsr:@std/assert@1";
import { formatTodayTasks, hidePartnerWorkSections, loadTodayTaskBlock, mergeTodayBrief, type TodayTaskRow } from "./lineTodayTasks.ts";

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

Deno.test("today: every one of my tasks is listed without summarising the partner's work", () => {
  const text = formatTodayTasks(rows, ME, "パパ", "ママ");
  assertEquals(text, [
    "パパの担当（4件・残り2件）",
    "",
    "朝",
    "✓ 7:00 朝ごはん",
    "− 7:00 詩乃（便秘）の薬（今日はなし・実施せず）",
    "・ 7:20 送り",
    "",
    "夜",
    "・ 21:00 明日の保育園準備",
    "",
    "2人で分担（誰でもOK）",
    "朝",
    "・ 7:00 食洗機を空ける",
  ].join("\n"));
  assertEquals(text.includes("夕食対応") || text.includes("ママの今日") || text.includes("ほか"), false);
});

Deno.test("today: the brief keeps its other sections; its task sections are replaced in place", () => {
  const brief = "朝のおうちノート\n\n今日の予定\n・14:00 プール\n\n朝やること\n・送り\n\n夜にやること\n・準備\n\n相手の今日\n・お迎え\n・ほか 8件\n\nコドモン 9:15まで\n・残り: 朝食";
  assertEquals(mergeTodayBrief(brief, "TASKS"), "朝のおうちノート\n\n今日の予定\n・14:00 プール\n\nTASKS\n\nコドモン 9:15まで\n・残り: 朝食");
  // A brief without task sections gets the list right after its title.
  assertEquals(mergeTodayBrief("今日のおうちノート\n\n確認が必要な項目はありません。", "TASKS"), "今日のおうちノート\n\nTASKS\n\n確認が必要な項目はありません。");
});

Deno.test("today: task read failure still removes the old partner summary without dropping own tasks or appointments", () => {
  const brief = "今日のおうちノート\n\n今日の予定\n・プール\n\n朝やること\n・送り\n\n相手の担当で確認したいこと\n・相手の日課\n・ほか 8件\n\n買い物\n・牛乳";
  assertEquals(hidePartnerWorkSections(brief), "今日のおうちノート\n\n今日の予定\n・プール\n\n朝やること\n・送り\n\n買い物\n・牛乳");
  assertEquals(hidePartnerWorkSections("今日のおうちノート\n\n相手の今日\n・相手の日課"), "今日のおうちノート");
});

Deno.test("today: an optional task (掃除) is listed apart as 余裕があれば and never counted as left", () => {
  const rows: TodayTaskRow[] = [
    { title: "送り", status: "todo", routine_phase: "morning", due_at: at("08:00"), planned_assignee_id: ME },
    { title: "掃除（ルンバのほかにやったら）", status: "todo", routine_phase: "evening", assignment_mode: "anyone", expectation: "optional" },
    { title: "お迎え", status: "todo", routine_phase: "evening", due_at: at("18:20"), planned_assignee_id: PARTNER, task_code: "pickup", assignment_confirmed: true },
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
    "送り迎え",
    "・ 18:20 お迎え（ママ）",
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
  const mine = text.split("家族が対応中")[0];
  assertEquals(mine.includes("自分が始めた作業（パパ対応中）"), true);
  assertEquals(mine.includes("相手が始めた作業"), false);
  assertEquals(text.includes("家族が対応中\n・ 相手が始めた作業（ママ対応中）"), true);
  assertEquals(text.includes("21:00 10/15(木)の保育園準備"), true);
});

Deno.test("today: only agreed transport appears; tentative or missing consent stays hidden", () => {
  const transport = (title: string, assignment_confirmed?: boolean): TodayTaskRow => ({
    title, status: "todo", task_code: "pickup", planned_assignee_id: PARTNER, assignment_confirmed,
  });
  const text = formatTodayTasks([
    transport("合意済み", true), transport("未合意", false), transport("確認できない"),
    { title: "相手の普通の日課", status: "todo", planned_assignee_id: PARTNER, assignment_confirmed: true },
  ], ME, "パパ", "ママ");
  assertEquals(text.includes("送り迎え\n・ 合意済み（ママ）"), true);
  assertEquals(/未合意|確認できない|相手の普通の日課|残り1件・済み/.test(text), false);
  const named = formatTodayTasks([{ ...transport("お迎え", true), assigned_label: "パパ" }], ME, "自分", "相手");
  assertEquals(named.includes("お迎え（パパ）"), true);
  const manual = formatTodayTasks([{ title: "今日だけの迎え", status: "todo", task_kind: "transport",
    planned_assignee_id: PARTNER, assignment_confirmed: true }], ME, "パパ", "ママ");
  assertEquals(manual.includes("今日だけの迎え（ママ）"), true);
});

Deno.test("today: the agreed transport shows the actual assignee even with multiple other members", async () => {
  const client = {
    rpc: () => Promise.resolve({ data: [{ title: "お迎え", status: "todo", task_code: "pickup",
      planned_assignee_id: "another", assignment_confirmed: true }], error: null }),
    from: () => ({ select: () => ({ eq: () => Promise.resolve({ data: [
      { user_id: ME, family_role: "papa" }, { user_id: PARTNER, family_role: "mama" },
      { user_id: "another", family_role: null },
    ] }) }) }),
  };
  const text = await loadTodayTaskBlock(client as never, "household", ME, "2026-10-07");
  assertEquals(text?.includes("お迎え（家族）"), true);
  assertEquals(text?.includes("お迎え（ママ）"), false);
});

Deno.test("today: full task list replaces special, shared and optional sections without duplication", () => {
  const brief = "朝のおうちノート\n\n⭐ 今日、忘れずに\n・ゴミ出し\n\n朝やること\n先に家を出る人\n・食洗機\n\n余裕があれば\n◦掃除\n\n相手の担当で確認したいこと\n・お迎え\n\n明日 10/14(水)の予定・作業\n・10/15(木)の準備";
  assertEquals(mergeTodayBrief(brief, "TASKS"), "朝のおうちノート\n\nTASKS\n\n明日 10/14(水)の予定・作業\n・10/15(木)の準備");
  assertEquals(mergeTodayBrief(brief.replace("⭐ 今日、忘れずに", "⭐ 今日だけの予定"), "TASKS"),
    "朝のおうちノート\n\nTASKS\n\n明日 10/14(水)の予定・作業\n・10/15(木)の準備");
});
