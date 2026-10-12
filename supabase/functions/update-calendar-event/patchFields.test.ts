import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { alreadyMatches, buildPatchBody, parsePatchFields } from "./patchFields.ts";
import { FamilyOpsError } from "../_shared/errors.ts";

Deno.test("reconciliation compares both timed endpoints and accepts equivalent offsets", () => {
  const fields = { start_date_time: "2026-10-24T09:00:00+09:00", end_date_time: "2026-10-24T10:00:00+09:00" };
  assertEquals(alreadyMatches(fields, { start: { dateTime: "2026-10-24T00:00:00Z" }, end: { dateTime: "2026-10-24T01:00:00Z" } }), true);
  assertEquals(alreadyMatches(fields, { start: { dateTime: fields.start_date_time }, end: { dateTime: "2026-10-24T11:00:00+09:00" } }), false);
  assertEquals(alreadyMatches(fields, { start: { dateTime: fields.start_date_time } }), false);
});

Deno.test("reconciliation compares both all-day endpoints", () => {
  const fields = { start_date: "2026-10-24", end_date: "2026-10-25" };
  assertEquals(alreadyMatches(fields, { start: { date: "2026-10-24" }, end: { date: "2026-10-25" } }), true);
  assertEquals(alreadyMatches(fields, { start: { date: "2026-10-24" }, end: { date: "2026-10-26" } }), false);
});

Deno.test("PATCH clears incompatible all-day/timed fields and preserves remote private properties", () => {
  assertEquals(buildPatchBody({ start_date_time: "2026-10-24T09:00:00+09:00", end_date_time: "2026-10-24T10:00:00+09:00", busy_member_user_ids: [] }, { familyOpsOperationId: "create-op", custom: "retained" }), {
    start: { dateTime: "2026-10-24T09:00:00+09:00", timeZone: "Asia/Tokyo", date: null },
    end: { dateTime: "2026-10-24T10:00:00+09:00", timeZone: "Asia/Tokyo", date: null },
    extendedProperties: { private: { familyOpsOperationId: "create-op", custom: "retained", familyOpsBusyMemberIds: "" } },
  });
  assertEquals(buildPatchBody({ start_date: "2026-10-24", end_date: "2026-10-25" }, undefined), {
    start: { date: "2026-10-24", dateTime: null, timeZone: null },
    end: { date: "2026-10-25", dateTime: null, timeZone: null },
  });
});

Deno.test("partial or mixed date edits are rejected instead of silently dropped", () => {
  for (const fields of [
    { title: "Appointment", start_date_time: "2026-10-24T09:00:00+09:00" },
    { end_date: "2026-10-25" },
    { start_date: "2026-10-24", end_date: "" },
    { start_date: "2026-10-24", end_date: "2026-10-25", start_date_time: null },
  ]) {
    assertThrows(() => parsePatchFields(fields), FamilyOpsError);
  }
});

Deno.test("reconciliation checks cleared fields and ignores untouched fields", () => {
  assertEquals(alreadyMatches({ description: null }, { summary: "Different untouched title" }), true);
  assertEquals(alreadyMatches({ title: null }, { summary: "Still titled" }), false);
  assertEquals(alreadyMatches({ busy_member_user_ids: [] }, {}), true);
  assertEquals(alreadyMatches({ busy_member_user_ids: [] }, { extendedProperties: { private: { familyOpsBusyMemberIds: "member" } } }), false);
});
