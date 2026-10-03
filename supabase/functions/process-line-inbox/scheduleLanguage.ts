// Calendar wording shared by the semantic and deterministic proposal paths.
export function formatScheduleDate(date: string): string {
  const parsed = new Date(`${date}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime())) return date;
  return `${parsed.getUTCMonth() + 1}/${parsed.getUTCDate()}(${'日月火水木金土'[parsed.getUTCDay()]})`;
}

export function leadingScheduleDates(text: string, now = new Date()): string[] {
  const value = text.normalize('NFKC');
  const leading = value.match(/^\s*((?:\d{1,2}[\/月]\d{1,2}日?)(?:\s*(?:と|、|,|・|及び|および)\s*\d{1,2}[\/月]\d{1,2}日?)*)/u)?.[1];
  if (!leading) return [];
  const year = new Date(now.getTime() + 9 * 3600_000).getUTCFullYear();
  return [...new Set([...leading.matchAll(/(\d{1,2})[\/月](\d{1,2})/gu)].flatMap((match) => {
    const date = new Date(Date.UTC(year, Number(match[1]) - 1, Number(match[2])));
    return date.getUTCMonth() + 1 === Number(match[1]) && date.getUTCDate() === Number(match[2]) ? [date.toISOString().slice(0, 10)] : [];
  }))];
}

export function inferredNight(title: string): boolean {
  return /飲み会|宴会|懇親会|ディナー|夕食会/u.test(title);
}
