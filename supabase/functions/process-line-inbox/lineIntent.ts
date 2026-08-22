import { callGemini } from '../_shared/gemini.ts';

export type LineIntentKind = 'task' | 'request' | 'shopping';
export type LineDaypart = 'morning' | 'noon' | 'evening' | 'night' | null;
export type LineTargetRole = 'papa' | 'mama' | null;

export type LineIntent = {
  kind: LineIntentKind;
  title: string;
  scheduledDate: string;
  daypart: LineDaypart;
  targetRole: LineTargetRole;
  sharedMessage: string | null;
  source: 'deterministic' | 'gemini';
};

const JST_OFFSET_MS = 9 * 60 * 60 * 1000;

function jstDateParts(now: Date): { year: number; month: number; day: number } {
  const shifted = new Date(now.getTime() + JST_OFFSET_MS);
  return {
    year: shifted.getUTCFullYear(),
    month: shifted.getUTCMonth() + 1,
    day: shifted.getUTCDate(),
  };
}

function dateToIso(year: number, month: number, day: number): string {
  return `${year.toString().padStart(4, '0')}-${month.toString().padStart(2, '0')}-${day
    .toString()
    .padStart(2, '0')}`;
}

function addJstDays(now: Date, days: number): string {
  const parts = jstDateParts(now);
  const utc = new Date(Date.UTC(parts.year, parts.month - 1, parts.day + days));
  return dateToIso(utc.getUTCFullYear(), utc.getUTCMonth() + 1, utc.getUTCDate());
}

function resolveFirstRelativeDate(text: string, now: Date): string {
  const match = text.match(/今夜|今朝|今日|明後日|明日/);
  if (!match) return addJstDays(now, 0);
  if (match[0] === '明後日') return addJstDays(now, 2);
  if (match[0] === '明日') return addJstDays(now, 1);
  return addJstDays(now, 0);
}

function resolveDaypart(text: string): LineDaypart {
  const first = text.match(/今朝|朝|昼|夕方|夜|今夜/);
  if (!first) return null;
  if (first[0] === '今朝' || first[0] === '朝') return 'morning';
  if (first[0] === '昼') return 'noon';
  if (first[0] === '夕方') return 'evening';
  return 'night';
}

export function daypartToLocalTime(daypart: LineDaypart): string | null {
  switch (daypart) {
    case 'morning':
      return '08:00';
    case 'noon':
      return '12:00';
    case 'evening':
      return '18:00';
    case 'night':
      return '20:00';
    default:
      return null;
  }
}

export function daypartLabel(daypart: LineDaypart): string {
  switch (daypart) {
    case 'morning':
      return '朝';
    case 'noon':
      return '昼';
    case 'evening':
      return '夕方';
    case 'night':
      return '夜';
    default:
      return '時刻なし';
  }
}

function targetRole(text: string): LineTargetRole {
  if (/(?:パパ|父|お父さん)/.test(text)) return 'papa';
  if (/(?:ママ|母|お母さん|嫁さん|奥さん|妻)/.test(text)) return 'mama';
  return null;
}

function cleanNoun(value: string): string {
  return value
    .replace(/^(?:嫁さん|奥さん|妻|ママ|パパ)[、,\s]*/u, '')
    .replace(/(?:今日|明日|明後日)(?:の)?(?:朝|昼|夕方|夜)?[に、,\s]*/gu, '')
    .replace(/今夜[に、,\s]*/gu, '')
    .replace(/^(?:朝|昼|夕方|夜)[に、,\s]*/u, '')
    .replace(/明日の(?=(?:病院|歯医者|保育園|幼稚園|学校))/gu, '')
    .trim();
}

export function deterministicLineIntent(text: string, now = new Date()): LineIntent | null {
  const normalized = text
    .normalize('NFKC')
    .replace(/よやく/g, '予約')
    .replace(/\s+/g, ' ')
    .trim();
  if (!normalized) return null;

  const scheduledDate = resolveFirstRelativeDate(normalized, now);
  const daypart = resolveDaypart(normalized);
  const role = targetRole(normalized);
  const requestSignal =
    /(?:してほしい|して欲しい|お願い|頼め|頼み|やってほしい|やって欲しい|してくれる|してもら|お願いでき)/.test(
      normalized,
    );
  const shoppingSignal = /(?:買って|買う|購入|注文して|注文する)/.test(normalized);

  if (shoppingSignal) {
    const item = cleanNoun(
      normalized
        .replace(/(?:Amazon|アマゾン)で?/gi, '')
        .replace(/(?:買って|買う|購入して|購入する|注文して|注文する).*/u, ''),
    );
    if (item.length >= 1 && item.length <= 80) {
      return {
        kind: 'shopping',
        title: item,
        scheduledDate,
        daypart,
        targetRole: role,
        sharedMessage: null,
        source: 'deterministic',
      };
    }
  }

  const reservation = normalized.match(/(.{1,50}?)の予約(?:を)?(?:して|し|お願い)/u);
  if (reservation) {
    const noun = cleanNoun(reservation[1]);
    if (noun) {
      const title = `${noun}の予約`;
      return {
        kind: role || requestSignal ? 'request' : 'task',
        title,
        scheduledDate,
        daypart,
        targetRole: role,
        sharedMessage: `${title}をお願いできますか？`,
        source: 'deterministic',
      };
    }
  }

  const insurance = normalized.match(/(.{0,40}?)(?:の)?保険証(?:の)?準備/u);
  if (insurance) {
    let prefix = cleanNoun(insurance[1] ?? '')
      .replace(/(?:しなくちゃ.*|しないと.*)$/u, '')
      .trim();
    prefix = prefix.replace(/(?:今日|明日|明後日)(?:の)?/gu, '').trim();
    const title = `${prefix ? `${prefix}の` : ''}保険証を準備`;
    return {
      kind: role && requestSignal ? 'request' : 'task',
      title,
      scheduledDate,
      daypart,
      targetRole: role,
      sharedMessage: role && requestSignal ? `${title}をお願いできますか？` : null,
      source: 'deterministic',
    };
  }

  const preparation = normalized.match(/(.{1,60}?)(?:を|の)?準備(?:し|して)/u);
  if (preparation) {
    const noun = cleanNoun(preparation[1]);
    if (noun) {
      const title = `${noun}を準備`;
      return {
        kind: role && requestSignal ? 'request' : 'task',
        title,
        scheduledDate,
        daypart,
        targetRole: role,
        sharedMessage: role && requestSignal ? `${title}をお願いできますか？` : null,
        source: 'deterministic',
      };
    }
  }

  return null;
}

function parseJson(text: string): Record<string, unknown> {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/i)?.[1] ?? text;
  return JSON.parse(fenced.trim()) as Record<string, unknown>;
}

async function geminiLineIntent(text: string, now: Date): Promise<LineIntent | null> {
  const model = Deno.env.get('GEMINI_MODEL_REWRITE') ?? '';
  if (!model) return null;
  const today = addJstDays(now, 0);
  const prompt = [
    '家庭内タスク管理LINEの日本語入力を構造化してください。',
    `今日(Asia/Tokyo)は ${today} です。`,
    '重要: 「今日の夜に明日の病院の保険証を準備」は、作業日は今日・夜です。「明日の病院」は理由です。',
    'kind は task/request/shopping のいずれか。相手に「してほしい」「お願い」なら request。',
    'target_role は papa/mama/null。嫁さん・妻・奥さんは mama。',
    'daypart は morning/noon/evening/night/null。',
    'scheduled_date は YYYY-MM-DD。明示が無い場合は今日。',
    'title は短い行動名。メタ文言「タスクとして追加して」は入れない。',
    'shared_message は request のときだけ、事実を増やさず柔らかい依頼文。それ以外null。',
    '必ずJSONのみ: {"kind":"task|request|shopping","title":"...","scheduled_date":"YYYY-MM-DD","daypart":"morning|noon|evening|night|null","target_role":"papa|mama|null","shared_message":"...|null"}',
    '',
    `入力: ${JSON.stringify(text)}`,
  ].join('\n');
  try {
    const raw = await callGemini(prompt, model);
    const p = parseJson(raw);
    if (!['task', 'request', 'shopping'].includes(String(p.kind))) return null;
    const title = typeof p.title === 'string' ? p.title.trim() : '';
    const scheduledDate = typeof p.scheduled_date === 'string' ? p.scheduled_date : '';
    if (!title || title.length > 100 || !/^\d{4}-\d{2}-\d{2}$/.test(scheduledDate)) return null;
    const daypart = ['morning', 'noon', 'evening', 'night'].includes(String(p.daypart))
      ? (p.daypart as Exclude<LineDaypart, null>)
      : null;
    const role = ['papa', 'mama'].includes(String(p.target_role))
      ? (p.target_role as Exclude<LineTargetRole, null>)
      : null;
    return {
      kind: p.kind as LineIntentKind,
      title,
      scheduledDate,
      daypart,
      targetRole: role,
      sharedMessage:
        typeof p.shared_message === 'string' && p.shared_message.trim()
          ? p.shared_message.trim()
          : null,
      source: 'gemini',
    };
  } catch (error) {
    console.warn('process-line-inbox: Gemini intent extraction unavailable', {
      code: error instanceof Error ? error.message : 'unknown',
    });
    return null;
  }
}

export async function extractLineIntent(
  text: string,
  now = new Date(),
): Promise<LineIntent | null> {
  return deterministicLineIntent(text, now) ?? (await geminiLineIntent(text, now));
}
