/**
 * One notification item as text. The daily brief's body already opens with its title
 * ("朝のおうちノート\n…"), so the title is not put in front of it a second time (live 2026-10-10:
 * the LINE brief showed its title twice).
 */
export function itemBlockText(title: string, body: string): string {
  if (!body) return title;
  return body.startsWith(title) ? body : `${title}\n${body}`;
}
