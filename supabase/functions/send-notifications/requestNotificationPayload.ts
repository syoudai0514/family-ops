type RequestPayload = {
  request_id?: string;
  attempt_id?: string;
  revision?: number;
  terms_revision?: number;
  reply_due_at?: string | null;
  request_kind?: string;
  scope?: 'once' | 'this_week';
  due_at?: string | null;
  accept_pending_action_id?: string;
  decline_pending_action_id?: string;
};

type RequestNotificationItem = {
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


export function requestOutcomeText(item: RequestNotificationItem): string | null {
  const subject = item.body?.trim() || item.title?.trim() || "お願い";
  if (item.type === "request.accepted") {
    return `お願いが引き受けられました。\n${subject}`;
  }
  if (item.type === "request.declined") {
    return `お願いは「難しい」と返されました。\n${subject}\nお願いは成立していません。`;
  }
  if (item.type === "request.checking") {
    return `相手が確認中です。\n${subject}\nまだ成立していません。`;
  }
  if (item.type === "request.cancelled") {
    return `お願いが取り消されました。\n${subject}`;
  }
  return null;
}
