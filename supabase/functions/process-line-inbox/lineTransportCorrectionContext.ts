import { resolveJapanesePickupDate } from "../_shared/pickupDate.ts";
import {
  parseTransportAssignmentCorrection,
  parseTransportAssignmentText,
} from "../_shared/transportAssignmentIntent.ts";

export type TransportCorrectionContext =
  | { kind: "resolved"; text: string }
  | { kind: "clarify" }
  | { kind: "not_applicable" };

type Context = { code: "dropoff" | "pickup"; date: string };
const CONTEXT_WINDOW_MS = 15 * 60_000;
const CLOCK_SKEW_MS = 60_000;
const QUERY_DATE =
  "(?:今日|きょう|明日|あした|明後日|あさって|(?:\\d{4}年)?\\d{1,2}月\\d{1,2}日|(?:\\d{4}/)?\\d{1,2}/\\d{1,2})";
const SCHEDULE_QUERY = new RegExp(
  `^${QUERY_DATE}(?:の|は)?(?:送り迎え|送りとお?迎え|送迎|お?迎え|送り|予定|スケジュール)` +
    "(?:の予定)?(?:を|は)?(?:おしえて|教えて(?:ください|下さい)?|見せて(?:ください|下さい)?|どうなって(?:る|いますか)|[?？])[。.!！?？]*$",
  "u",
);

function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function scheduleQueryDate(text: string, clock: Date): string | null {
  const normalized = text.normalize("NFKC").trim().replace(/\s+/gu, "");
  if (!SCHEDULE_QUERY.test(normalized)) return null;
  return resolveJapanesePickupDate(
    normalized.replace(/きょう/gu, "今日").replace(/あした/gu, "明日")
      .replace(/あさって/gu, "明後日"),
    clock,
  );
}

/**
 * Resolve an omitted transport subject only from recent, ordered user turns.
 * Assistant text (including generated titles and dates) is never authority.
 * The output prepares a new review; neither prior agreement nor confirmation
 * is inherited from the old turn.
 */
export function resolveTransportCorrectionContext(
  turns: unknown,
  text: string,
  now = new Date(),
): TransportCorrectionContext {
  const correction = parseTransportAssignmentCorrection(text);
  if (!correction) return { kind: "not_applicable" };
  const clock = now.getTime();
  if (!Array.isArray(turns) || !Number.isFinite(clock)) {
    return { kind: "clarify" };
  }
  let context: Context | null = null;
  let previousTimestamp = -Infinity;
  for (const value of turns) {
    const turn = record(value);
    if (turn?.role === "assistant") continue;
    if (
      turn?.role !== "user" || typeof turn.text !== "string" ||
      !turn.text.trim() || typeof turn.at !== "string"
    ) {
      context = null;
      continue;
    }
    const timestamp = Date.parse(turn.at);
    if (!Number.isFinite(timestamp) || timestamp < previousTimestamp) {
      return { kind: "clarify" };
    }
    previousTimestamp = timestamp;
    if (timestamp < clock - CONTEXT_WINDOW_MS || timestamp > clock + CLOCK_SKEW_MS) {
      context = null;
      continue;
    }
    const turnClock = new Date(timestamp);
    const intent = parseTransportAssignmentText(turn.text, turnClock);
    if (intent) {
      context = intent.scheduledDate && intent.target
        ? { code: intent.code, date: intent.scheduledDate }
        : null;
      continue;
    }
    // Asking to see the same day's schedule does not change the user's last
    // explicit transport subject. A query cannot establish one by itself.
    if (context && scheduleQueryDate(turn.text, turnClock) === context.date) {
      continue;
    }
    // Repeating a role-only correction keeps an already established subject.
    // It can neither establish one nor inherit any earlier agreement.
    if (context && parseTransportAssignmentCorrection(turn.text)) continue;
    // A new subject, another date, or an unclear change ends this context.
    // Only a later complete directive can reset it.
    context = null;
  }
  if (!context) return { kind: "clarify" };
  const [year, month, day] = context.date.split("-").map(Number);
  const target = {
    self: "私", partner: "相手", papa: "パパ", mama: "ママ",
  }[correction.target];
  return {
    kind: "resolved",
    text: `${year}/${month}/${day}の${context.code === "pickup" ? "お迎え" : "送り"}を${target}に変更`,
  };
}
