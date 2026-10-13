/** LINE accepts at most 5 messages per API call and 5,000 UTF-16 units per text. */
export const LINE_TEXT_MAX_CHARS = 5000;
export const LINE_MAX_MESSAGES = 5;

function safeEnd(text: string, end: number): number {
  if (end > 0 && end < text.length) {
    const before = text.charCodeAt(end - 1);
    const after = text.charCodeAt(end);
    if (before >= 0xD800 && before <= 0xDBFF && after >= 0xDC00 && after <= 0xDFFF) return end - 1;
  }
  return end;
}

function detailFooter(text: string): string {
  for (const marker of ['\n\n詳しく見る\n', '\n\n▶ ']) {
    const index = text.lastIndexOf(marker);
    if (index >= 0 && text.length - index <= 2000) return text.slice(index + 2);
  }
  const url = text.match(/https?:\/\/[^\s]+\s*$/u)?.[0]?.trim();
  return url && url.length <= 2000 ? url : '';
}

function clippedText(body: string, capacity: number, fallbackFooter: string): string {
  const footer = detailFooter(body) || fallbackFooter;
  const suffix = `\n\n…続きはアプリで確認してください。${footer ? `\n\n${footer}` : ''}`;
  const room = capacity - suffix.length;
  let end = safeEnd(body, Math.max(0, room));
  const newline = body.lastIndexOf('\n', end - 1);
  if (newline >= Math.max(0, end - LINE_TEXT_MAX_CHARS / 2)) end = newline;
  return body.slice(0, end) + suffix;
}

/**
 * Preserve every character within the API's budget. Prefer whole lines, but
 * split very long lines safely. Over-budget replies explain the omission and
 * retain the detail link rather than silently cutting off the final tasks.
 */
export function splitLineText(text: string, maxMessages = LINE_MAX_MESSAGES, fallbackFooter = ''): string[] {
  const count = Math.max(1, Math.min(LINE_MAX_MESSAGES, Math.floor(maxMessages)));
  const capacity = count * LINE_TEXT_MAX_CHARS;
  let body = text || '内容をアプリで確認してください。';
  if (body.length > capacity) body = clippedText(body, capacity, fallbackFooter);
  const chunks: string[] = [];
  let start = 0;
  while (start < body.length && chunks.length < count) {
    let end = safeEnd(body, Math.min(start + LINE_TEXT_MAX_CHARS, body.length));
    if (end < body.length) {
      const remainingSlots = count - chunks.length - 1;
      const minimumEnd = Math.max(start + LINE_TEXT_MAX_CHARS / 2, body.length - remainingSlots * LINE_TEXT_MAX_CHARS);
      const newline = body.lastIndexOf('\n', end - 1);
      if (newline + 1 >= minimumEnd) end = newline + 1;
    }
    chunks.push(body.slice(start, end));
    start = end;
  }
  // A surrogate pair can leave one unused UTF-16 unit at a message boundary.
  // If an exactly-full payload cannot fit safely, explain that omission too.
  if (start < body.length) return splitLineText(clippedText(text, capacity - count * 2, fallbackFooter), count, fallbackFooter);
  return chunks;
}
