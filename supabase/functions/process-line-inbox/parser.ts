// Deterministic (non-AI) natural-language command grammar for a small,
// unambiguous subset of docs/design/v6/06_LINE_INTEGRATION.md #4's examples:
// shopping-item add ("オムツAmazonで買う") and a one-off task add ("明日ク
// リーニング出さないと"). This intentionally does NOT attempt the full
// example set:
//   - partner-request rewrite ("ママに明日上履きお願い") is WP5's Gemini
//     invariant-tested pipeline (propose-ai-draft/confirm-request-draft,
//     user-JWT only, #5 "soft rewrite -> sender preview -> explicit
//     confirm"). Re-implementing a second, unauthenticated, non-invariant-
//     checked path to it from a cron worker would bypass those guarantees,
//     so it is deliberately out of scope here.
//   - recurrence/reassignment edits ("木曜の送り、今週だけパパにする") need
//     the recurrence-role-resolver's disambiguation (once vs recurring) and
//     are deferred to PWA for now (06_LINE_INTEGRATION.md #4 "Ambiguous
//     recurrence vs once must ask confirmation" — safer to require the
//     richer PWA UI than to guess).
// Anything outside this grammar is surfaced to the caller as `null` and
// handled as a "needs_pwa_review" draft, never auto-confirmed/executed.
export interface ParsedCommand {
  actionType: "shopping_item_add" | "task_create_once";
  payload: Record<string, unknown>;
}

// e.g. "オムツをAmazonで買う" / "オムツAmazonで買う" / "牛乳買う" / "パンを買っておいて"
const SHOPPING_RE =
  /^(.+?)を?(Amazon|amazon|アマゾン)?で?買(?:う|って|っておいて)。?$/;

// e.g. "明日クリーニング出さないと" / "今日ゴミ出さないと" / "明後日書類出さないと"
const TASK_RELATIVE_DATE_RE =
  /^(明日|今日|明後日)(.+?)(?:出さないと|しないと|やらないと|忘れずに)。?$/;

function scheduledDateFor(relative: string): string {
  // The worker environment's clock is UTC; offset to Asia/Tokyo (households
  // are fixed to Asia/Tokyo, 20260819000012_evening_routine_setup.sql /
  // households.timezone CHECK) before taking the local calendar date.
  const jstNow = new Date(Date.now() + 9 * 60 * 60 * 1000);
  const offsetDays = relative === "今日" ? 0 : relative === "明日" ? 1 : 2;
  jstNow.setUTCDate(jstNow.getUTCDate() + offsetDays);
  return jstNow.toISOString().slice(0, 10);
}

export function parseLineText(rawText: string): ParsedCommand | null {
  const text = rawText.trim();
  if (text.length === 0) return null;

  const shopping = text.match(SHOPPING_RE);
  if (shopping) {
    const title = shopping[1].trim();
    if (title.length > 0) {
      return {
        actionType: "shopping_item_add",
        payload: {
          title,
          purchase_method: shopping[2] ? "online" : "store",
        },
      };
    }
  }

  const task = text.match(TASK_RELATIVE_DATE_RE);
  if (task) {
    const title = task[2].trim();
    if (title.length > 0) {
      return {
        actionType: "task_create_once",
        payload: {
          title,
          scheduled_date: scheduledDateFor(task[1]),
        },
      };
    }
  }

  return null;
}
