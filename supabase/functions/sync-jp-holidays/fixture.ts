// Bootstrap/fallback fixture mirroring docs/design/v6/fixtures/JP_HOLIDAYS_2026_2027.json
// verbatim (03_DOMAIN_AND_DATA_MODEL.md #20: "Checked-in fixture is
// bootstrap/fallback"). Used only when the live Cabinet Office CSV fetch
// fails or parses to zero rows. Source: https://www8.cao.go.jp/chosei/shukujitsu/gaiyou.html, verified 2026-08-19.
// Regenerate by re-running this same transform against a refreshed design
// fixture if the vendored fixture is ever updated — do not hand-edit the
// dates/names here independently of that file.

export interface FallbackHoliday {
  date: string;
  name: string;
}

export const FALLBACK_JP_HOLIDAYS: FallbackHoliday[] = [
  { date: "2026-01-01", name: "元日" },
  { date: "2026-01-12", name: "成人の日" },
  { date: "2026-02-11", name: "建国記念の日" },
  { date: "2026-02-23", name: "天皇誕生日" },
  { date: "2026-03-20", name: "春分の日" },
  { date: "2026-04-29", name: "昭和の日" },
  { date: "2026-05-03", name: "憲法記念日" },
  { date: "2026-05-04", name: "みどりの日" },
  { date: "2026-05-05", name: "こどもの日" },
  { date: "2026-05-06", name: "休日" },
  { date: "2026-07-20", name: "海の日" },
  { date: "2026-08-11", name: "山の日" },
  { date: "2026-09-21", name: "敬老の日" },
  { date: "2026-09-22", name: "休日" },
  { date: "2026-09-23", name: "秋分の日" },
  { date: "2026-10-12", name: "スポーツの日" },
  { date: "2026-11-03", name: "文化の日" },
  { date: "2026-11-23", name: "勤労感謝の日" },
  { date: "2027-01-01", name: "元日" },
  { date: "2027-01-11", name: "成人の日" },
  { date: "2027-02-11", name: "建国記念の日" },
  { date: "2027-02-23", name: "天皇誕生日" },
  { date: "2027-03-21", name: "春分の日" },
  { date: "2027-03-22", name: "休日" },
  { date: "2027-04-29", name: "昭和の日" },
  { date: "2027-05-03", name: "憲法記念日" },
  { date: "2027-05-04", name: "みどりの日" },
  { date: "2027-05-05", name: "こどもの日" },
  { date: "2027-07-19", name: "海の日" },
  { date: "2027-08-11", name: "山の日" },
  { date: "2027-09-20", name: "敬老の日" },
  { date: "2027-09-23", name: "秋分の日" },
  { date: "2027-10-11", name: "スポーツの日" },
  { date: "2027-11-03", name: "文化の日" },
  { date: "2027-11-23", name: "勤労感謝の日" },
];
