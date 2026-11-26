import type { LinePostbackQuickReplyAction } from '../_shared/lineMessaging.ts';

export type RequestPayload = {
  request_id?: string;
  attempt_id?: string;
  revision?: number;
  terms_revision?: number;
  reply_due_at?: string | null;
  request_kind?: string;
  attempt_kind?: string;
  scope?: 'once' | 'this_week';
  due_at?: string | null;
  recipient_label?: string;
  shared_title?: string;
  shared_message?: string | null;
  followup?: string;
  reminder?: string;
  consultation_event?: 'started' | 'updated';
  confirmation_mode?: 'mutual';
  proposed_due_at?: string | null;
};

export type RequestNotificationItem = {
  type?: string;
  title?: string;
  body?: string;
  payload?: RequestPayload;
};

export function isRequestReceivedType(type: string | undefined): boolean {
  return type === 'request.received' || type === 'request_received';
}

export function findRequestReceivedItem<T extends RequestNotificationItem>(items: T[]): T | undefined {
  return items.find(
    (candidate) =>
      isRequestReceivedType(candidate.type) &&
      typeof candidate.payload?.request_id === 'string' &&
      candidate.payload.request_id.length > 0,
  );
}

export function formatJstMinute(value?: string | null): string | null {
  if (!value) return null;
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return null;
  return new Intl.DateTimeFormat("ja-JP", {
    timeZone: "Asia/Tokyo",
    month: "numeric",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(date);
}

export function requestReceivedContent(item: RequestNotificationItem) {
  const sharedTitle = item.payload?.shared_title?.trim();
  const assignment = item.payload?.request_kind === 'assignment_change';
  const originalTitle = item.title?.trim();
  const body = item.body?.trim();
  // Old outbox rows used the heading as title and the request title or message as body.
  const title = sharedTitle || body || originalTitle || 'お願い';
  const message = sharedTitle ? (item.payload?.shared_message?.trim() || '') : '';
  return { title, message: message === title ? '' : message, assignment };
}

export function requestReceivedText(item: RequestNotificationItem): string | null {
  if (!isRequestReceivedType(item.type)) return null;
  const { title, message, assignment } = requestReceivedContent(item);
  const due = formatJstMinute(item.payload?.due_at);
  const replyDue = formatJstMinute(item.payload?.reply_due_at);
  const heading = assignment
    ? `${item.payload?.scope === 'this_week' ? '今週だけ' : '今回だけ'}の担当変更のお願い`
    : 'お願いが届きました';
  return [
    heading,
    title === heading ? '' : title,
    message,
    due ? `${assignment ? '対象日時' : '作業期限'}：${due}` : '',
    replyDue ? `返事期限：${replyDue}` : '',
    assignment ? '引き受けが確定するまで担当は変わりません。' : '引き受けるまでタスクにはなりません。',
  ].filter(Boolean).join('\n');
}

export function requestOpenTargets(
  items: RequestNotificationItem[],
  cardRequestId?: string,
): Array<{ title: string; action: LinePostbackQuickReplyAction }> {
  const targets = new Map<string, { title: string; action: LinePostbackQuickReplyAction }>();
  for (const item of items) {
    const requestId = item.payload?.request_id;
    if (!requestId) continue;
    const consultation = item.type === 'request.consulting' || item.type === 'request.awaiting_confirmation';
    const receivedWithoutCard = isRequestReceivedType(item.type) && requestId !== cardRequestId;
    if (!consultation && !receivedWithoutCard && item.payload?.reminder !== 'final_confirmation') continue;
    const label = consultation ? '相談を開く' : 'お願いを開く';
    targets.set(requestId, {
      title: requestReceivedContent(item).title,
      action: {
        type: 'postback',
        label,
        displayText: label,
        data: new URLSearchParams({ action: 'mc_request_open', request_id: requestId }).toString(),
      },
    });
  }
  return Array.from(targets.values());
}

export function requestOutcomeText(item: RequestNotificationItem): string | null {
  const subject = item.payload?.shared_title?.trim() || item.body?.trim() || item.title?.trim() || "お願い";
  if (item.type === "request.accepted") {
    if (item.payload?.confirmation_mode === 'mutual') {
      if (item.payload.attempt_kind === 'change' || item.payload.attempt_kind === 'cancel') {
        const action = item.payload.attempt_kind === 'cancel' ? '取り消し' : '変更';
        return `二人が同じ案に同意しました。\n${subject}\n${action}を反映しました。`;
      }
      const result = item.payload.request_kind === 'assignment_change'
        ? '担当変更が確定しました。'
        : 'お願いが成立しました。';
      return `二人が同じ条件を確認しました。\n${subject}\n${result}`;
    }
    if (item.payload?.request_kind === "assignment_change") {
      const who = item.payload.recipient_label?.trim() || "依頼相手";
      const due = formatJstMinute(item.payload.due_at);
      const scope = item.payload.scope === "this_week" ? "今週だけ" : "今回だけ";
      return [
        `✓ ${who}が引き受けました`,
        `${due ? due + " " : ""}${subject}`,
        scope,
        "担当変更は確定しています。",
      ].join("\n");
    }
    return `お願いが引き受けられました。\n${subject}`;
  }
  if (item.type === 'request.followup_declined') {
    return `相手はこの案を見送りました。\n${subject}\n元の約束はそのままです。`;
  }
  if (item.type === "request.declined") {
    return `お願いは「難しい」と返されました。\n${subject}\nお願いは成立していません。`;
  }
  if (item.type === "request.checking") {
    if (item.payload?.reminder === 'final_confirmation') {
      return `最終確認が残っています。\n${subject}\n担当はまだ変わっていません。引き受ける場合は「お願いを開く」から確認してください。`;
    }
    if (item.payload?.followup === 'recipient_final_confirmation') {
      return `相手が「引き受ける」を押しました。\n${subject}\n最終確認待ちです。担当はまだ変わっていません。`;
    }
    return `相手が確認中です。\n${subject}\nまだ成立していません。`;
  }
  if (item.type === 'request.consulting' || item.type === 'request.awaiting_confirmation') {
    const heading = item.type === 'request.awaiting_confirmation'
      ? '相手が相談中の条件を確認しました。'
      : item.payload?.consultation_event === 'updated'
      ? '相手が相談内容を更新しました。'
      : '相手が相談を始めました。';
    const due = formatJstMinute(item.payload?.proposed_due_at);
    const status = item.payload?.attempt_kind === 'change' || item.payload?.attempt_kind === 'cancel'
      ? '二人が同じ案に同意するまで、元の約束のままです。'
      : item.payload?.request_kind === 'assignment_change'
      ? '二人が同じ条件を確認するまで担当は変わりません。'
      : '二人が同じ条件を確認するまでお願いは成立しません。';
    return [heading, subject, due ? `提案中の作業期限：${due}` : '', status, '「相談を開く」から内容を確認できます。']
      .filter(Boolean).join('\n');
  }
  if (item.type === "request.cancelled") {
    return `お願いが取り消されました。\n${subject}`;
  }
  return null;
}
