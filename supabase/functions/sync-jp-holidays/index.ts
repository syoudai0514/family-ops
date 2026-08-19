// verify_jwt=false — cron worker (docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md
// #19 "Japan holiday sync": weekly Sunday 03:00 JST, fetch Cabinet Office
// CSV, upsert private.jp_holidays, "partial/failure never deletes known
// future rows" — checked-in fixture fallback per
// 03_DOMAIN_AND_DATA_MODEL.md #20).
//
// JP_HOLIDAY_CSV_URL (docs/design/v6/ENV_TEMPLATE.md) is a public, non-secret
// URL: https://www8.cao.go.jp/chosei/shukujitsu/syukujitsu_kyujitsu.csv.
// The live fetch itself cannot be exercised from this dev environment
// (same documented limitation as every other external provider call in
// this codebase — LINE, Google) — the Cabinet Office CSV is historically
// Shift-JIS encoded with occasional UTF-8 re-publications, so decoding
// tries UTF-8 first and falls back to Shift-JIS if the result looks
// garbled (no recognizable Japanese-era digits/parseable date column).
// This should be verified against the live CSV in production; see
// MANUAL_SETUP_REQUIRED.md.
import { createServiceRoleClient, requireWorkerToken } from "../_shared/auth.ts";
import { withServiceHandler, jsonResponse } from "../_shared/handler.ts";
import { FALLBACK_JP_HOLIDAYS } from "./fixture.ts";

interface HolidayRow {
  date: string; // YYYY-MM-DD
  name: string;
}

function looksGarbled(text: string): boolean {
  // A properly-decoded CSV should contain at least one recognizable Japanese
  // holiday-name character (CJK ideograph or kana) in its first few KB; if
  // every byte decoded to the Unicode replacement character or pure ASCII
  // noise, the wrong encoding was used.
  const sample = text.slice(0, 2000);
  return !/[぀-ヿ一-鿿]/.test(sample) || sample.includes("�");
}

async function fetchAndDecodeCsv(url: string): Promise<string> {
  const res = await fetch(url, { signal: AbortSignal.timeout(15_000) });
  if (!res.ok) throw new Error(`CSV fetch failed: HTTP ${res.status}`);
  const buf = new Uint8Array(await res.arrayBuffer());

  const utf8 = new TextDecoder("utf-8", { fatal: false }).decode(buf);
  if (!looksGarbled(utf8)) return utf8;

  try {
    const sjis = new TextDecoder("shift-jis", { fatal: false }).decode(buf);
    if (!looksGarbled(sjis)) return sjis;
  } catch {
    // Shift-JIS decoder unavailable in this runtime — fall through to the
    // (possibly garbled) UTF-8 decode; parseCsv below will simply find no
    // valid rows and the caller falls back to the checked-in fixture.
  }
  return utf8;
}

// Cabinet Office CSV shape: a header row, then "date,name" per row, where
// date is either M/D/YYYY or YYYY/M/D (the exact header text and date
// column order have varied over the years) — this parses generically:
// skip any row whose first column doesn't parse as a date.
function parseCsv(text: string): HolidayRow[] {
  const rows: HolidayRow[] = [];
  for (const line of text.split(/\r?\n/)) {
    const cols = line.split(",");
    if (cols.length < 2) continue;
    const rawDate = cols[0].trim();
    const name = cols[1].trim();
    if (!rawDate || !name) continue;

    let iso: string | null = null;
    const ymd = rawDate.match(/^(\d{4})[/\-](\d{1,2})[/\-](\d{1,2})$/);
    const mdy = rawDate.match(/^(\d{1,2})[/\-](\d{1,2})[/\-](\d{4})$/);
    if (ymd) {
      iso = `${ymd[1]}-${ymd[2].padStart(2, "0")}-${ymd[3].padStart(2, "0")}`;
    } else if (mdy) {
      iso = `${mdy[3]}-${mdy[1].padStart(2, "0")}-${mdy[2].padStart(2, "0")}`;
    }
    if (!iso) continue;
    rows.push({ date: iso, name });
  }
  return rows;
}

Deno.serve(withServiceHandler(async (req: Request) => {
  requireWorkerToken(req); // throws EDGE_WORKER_UNAUTHORIZED before any DB access

  const csvUrl = Deno.env.get("JP_HOLIDAY_CSV_URL")
    ?? "https://www8.cao.go.jp/chosei/shukujitsu/syukujitsu_kyujitsu.csv";

  let holidays: HolidayRow[] = [];
  let source = "cao_csv";
  let fetchError: string | null = null;

  try {
    const text = await fetchAndDecodeCsv(csvUrl);
    holidays = parseCsv(text);
    if (holidays.length === 0) throw new Error("CSV parsed to zero valid rows");
  } catch (err) {
    fetchError = err instanceof Error ? err.message : String(err);
    console.error("sync-jp-holidays: live fetch failed, using checked-in fixture", fetchError);
    holidays = FALLBACK_JP_HOLIDAYS;
    source = "fixture_fallback";
  }

  const serviceClient = createServiceRoleClient();
  const { data, error } = await serviceClient.rpc("server_tx_upsert_jp_holidays", {
    p_holidays: holidays,
    p_source: source,
  });
  if (error) {
    console.error("sync-jp-holidays: upsert RPC failed", error.message);
    return new Response(JSON.stringify({ error: { code: "INTERNAL_ERROR", message: "internal error" } }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  return jsonResponse({ source, fetch_error: fetchError, ...(data as object) });
}));
