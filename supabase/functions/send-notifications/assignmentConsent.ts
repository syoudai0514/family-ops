import type { SupabaseClient } from 'npm:@supabase/supabase-js@2';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu;
const DAY = ['月', '火', '水', '木', '金', '土', '日'];
const STRATEGY: Record<string, string> = {
  fixed: 'あなたの担当',
  dropoff_assignee: '送りを担当する人',
  pickup_assignee: '迎えを担当する人',
  nonpickup_adult: '迎えを担当しない人',
  next_day_nondropoff_adult: '翌日の送りを担当しない人',
  previous_evening_assignee: '前日の迎え担当（いなければ前日の夜の担当）',
};
const PHASE: Record<string, string> = { morning: '朝', evening: '夜', anytime: '時間帯未指定' };

type BriefItem = { type?: string; title?: string; body?: string; user_notification_id?: string };
type Offer = { offer_id: string; kind: 'rule' | 'transport'; snapshot: Record<string, unknown> };
const iso = (v: unknown): v is string => typeof v === 'string' && /^\d{4}-\d{2}-\d{2}$/u.test(v);
const time = (v: unknown): string | null => v === null ? '時間未設定' : typeof v === 'string' && /^\d{2}:\d{2}(:\d{2}(\.\d+)?)?$/u.test(v) ? v.slice(0, 5) : null;
const short = (v: unknown): v is string => typeof v === 'string' && v.length > 0 && Array.from(v).length <= 120;
const obj = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

/** Render every meaningful part of the promise; never silently clip it. */
export function consentOfferText(offer: Offer): string[] | null {
  const s = offer.snapshot;
  if (offer.kind === 'rule') {
    if (!short(s.title) || typeof s.strategy !== 'string' || !STRATEGY[s.strategy] || typeof s.phase !== 'string' || !PHASE[s.phase] ||
      !Array.isArray(s.group_rules) || s.group_rules.length < 1 || s.group_rules.length > 14 ||
      !Array.isArray(s.subtasks) || s.subtasks.length > 8) return null;
    if (s.fallback_assignee_id !== null && typeof s.recipient_is_fallback !== 'boolean') return null;
    const fallback = s.fallback_assignee_id === null ? '' : s.recipient_is_fallback
      ? '（担当が決まらない日はあなたが予備）' : '（担当が決まらない日は別の予備担当）';
    const lines = [`「${s.title}」`, `担当：${STRATEGY[s.strategy]}${fallback}`];
    for (const rule of s.group_rules) {
      if (!obj(rule) || rule.title !== s.title || rule.strategy !== s.strategy || rule.phase !== s.phase ||
        typeof rule.weekday !== 'number' || rule.weekday < 1 || rule.weekday > 7 || !Number.isInteger(rule.weekday) ||
        !iso(rule.effective_from) || !(rule.effective_to === null || iso(rule.effective_to))) return null;
      const at = time(rule.scheduled_local_time);
      if (!at) return null;
      lines.push(`毎週${DAY[rule.weekday - 1]}曜 ${PHASE[s.phase]} ${at}（${rule.effective_from}〜${rule.effective_to ?? '終了日なし'}）`);
    }
    if (s.subtasks.length) {
      lines.push('内容：');
      for (const item of s.subtasks) {
        if (!obj(item) || !short(item.title) || typeof item.required !== 'boolean') return null;
        lines.push(`・${item.title}${item.required ? '' : '（任意）'}`);
      }
    }
    return lines;
  }
  if (offer.kind !== 'transport' || !iso(s.valid_from) || !(s.valid_to === null || iso(s.valid_to)) ||
    !Array.isArray(s.days) || s.days.length < 1 || s.days.length > 7) return null;
  const lines = ['「送り迎え」', `期間：${s.valid_from}〜${s.valid_to ?? '終了日なし'}`];
  for (const item of s.days) {
    if (!obj(item) || typeof item.weekday !== 'number' || item.weekday < 1 || item.weekday > 7 ||
      !Number.isInteger(item.weekday) || (item.dropoff !== true && item.pickup !== true)) return null;
    const parts: string[] = [];
    if (item.dropoff === true) { const at = time(item.dropoff_time); if (!at) return null; parts.push(`送り ${at}`); }
    if (item.pickup === true) { const at = time(item.pickup_time); if (!at) return null; parts.push(`迎え ${at}`); }
    lines.push(`${DAY[item.weekday - 1]}曜：${parts.join(' ／ ')}`);
  }
  return lines;
}

/** The entire proposal and each answer are bound to server-issued offers. */
export function buildConsentCarousel(raw: unknown): Record<string, unknown> | null {
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > 3) return null;
  const bubbles: Record<string, unknown>[] = [];
  for (const value of raw) {
    if (!obj(value) || typeof value.offer_id !== 'string' || !UUID.test(value.offer_id) ||
      (value.kind !== 'rule' && value.kind !== 'transport') || !obj(value.snapshot)) return null;
    const offer: Offer = { offer_id: value.offer_id, kind: value.kind, snapshot: value.snapshot };
    const lines = consentOfferText(offer);
    if (!lines) return null;
    const buttons = [
      { label: 'いいよ', answer: 'agree' }, { label: '変えたい', answer: 'change' }, { label: 'あとで', answer: 'later' },
    ].map(({ label, answer }) => ({ type: 'button', style: 'secondary', height: 'sm', action: {
      type: 'postback', label, displayText: label,
      data: new URLSearchParams({ action: 'assignment_consent', offer_id: offer.offer_id, answer }).toString(),
    } }));
    bubbles.push({ type: 'bubble', size: 'mega', body: { type: 'box', layout: 'vertical', spacing: 'sm', contents: [
      { type: 'text', text: 'この担当でいい？', weight: 'bold', size: 'md', wrap: true },
      ...lines.map((line) => ({ type: 'text', text: line, size: 'sm', wrap: true })),
    ] }, footer: { type: 'box', layout: 'vertical', spacing: 'sm', contents: buttons } });
  }
  return { type: 'flex', altText: '担当についての相談があります', contents: { type: 'carousel', contents: bubbles } };
}

export async function loadConsentCarousel(client: SupabaseClient, actorId: string,
  payload: { items?: BriefItem[] } | null, now = new Date()): Promise<Record<string, unknown> | null> {
  const jst = new Date(now.getTime() + 9 * 3600_000);
  if (jst.getUTCDay() !== 0) return null;
  const items = payload?.items ?? [];
  const item = items[0];
  if (!item || item.type !== 'daily_brief.v2' || item.title !== '朝のおうちノート' ||
    typeof item.body !== 'string' || Array.from(item.body).length >= 5000 ||
    !UUID.test(item.user_notification_id ?? '') || items.filter((x) => x.type === 'daily_brief.v2').length !== 1) return null;
  try {
    const { data, error } = await client.rpc('server_tx_prepare_weekly_assignment_consent_v1', {
      p_actor_id: actorId, p_notification_id: item.user_notification_id,
    });
    return error ? null : buildConsentCarousel(data);
  } catch { return null; }
}
