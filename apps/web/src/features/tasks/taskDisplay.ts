import type { TaskInstance } from '../../lib/types';

/** Keep direct table reads (including past days) consistent with the brief projection. */
export function getTaskDisplay(task: Pick<TaskInstance, 'title' | 'assignment_mode' | 'display_title' | 'responsibility_hint' | 'scheduled_date' | 'origin'>) {
  let displayTitle = task.display_title ?? task.title;
  let responsibilityHint = task.responsibility_hint ?? null;
  if (!task.display_title && task.title === '燃えるゴミのゴミ出し') displayTitle = '燃えるゴミを出す';
  if (!task.display_title && task.title === '缶・ペットボトル・段ボールのゴミ出し') displayTitle = '缶・ペットボトル・段ボールを出す';
  if (!task.display_title && task.origin === 'recurring' && task.title === 'コドモン送信（将生・詩乃がそろってから）') {
    displayTitle = 'コドモンを送信（2人分の入力がそろってから）';
  }
  if (!task.display_title && ['明日の保育園準備', '明日の保育園準備（持ち物・着替え）'].includes(task.title)) {
    const target = new Date(`${task.scheduled_date}T00:00:00+09:00`);
    if (Number.isFinite(target.getTime())) {
      target.setUTCDate(target.getUTCDate() + 1);
      const monthDay = new Intl.DateTimeFormat('ja-JP', { timeZone: 'Asia/Tokyo', month: 'numeric', day: 'numeric' }).format(target);
      const weekday = new Intl.DateTimeFormat('ja-JP', { timeZone: 'Asia/Tokyo', weekday: 'short' }).format(target);
      displayTitle = `${monthDay}(${weekday})の保育園準備${task.title.endsWith('（持ち物・着替え）') ? '（持ち物・着替え）' : ''}`;
    }
  }
  if (task.assignment_mode === 'anyone' && task.title === '食洗機を空ける（先に家を出る人）') {
    if (!task.display_title) displayTitle = '食洗機を空ける';
    responsibilityHint ??= '先に家を出る人';
  }
  return { displayTitle, responsibilityHint };
}
