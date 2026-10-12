import { FamilyOpsError } from "../_shared/errors.ts";
import { mergePrivateExtendedProperties } from "../_shared/googleCalendar.ts";
import { withExclusiveEventTimes } from "../process-family-ops-calendar-outbox/eventTimePatch.ts";

export interface PatchFields {
  title?: string | null;
  description?: string | null;
  location?: string | null;
  start_date_time?: string;
  end_date_time?: string;
  start_date?: string;
  end_date?: string;
  busy_member_user_ids?: string[];
}

export function parsePatchFields(body: Record<string, unknown>): PatchFields {
  const out: PatchFields = {};
  for (const name of ["title", "description", "location"] as const) {
    if (!(name in body)) continue;
    const value = body[name];
    if (value !== null && typeof value !== "string") {
      throw new FamilyOpsError("INVALID_INPUT", `${name} must be a string or null`, 400);
    }
    out[name] = value;
  }
  const timed = "start_date_time" in body || "end_date_time" in body;
  const allDay = "start_date" in body || "end_date" in body;
  if (timed && allDay) {
    throw new FamilyOpsError("INVALID_INPUT", "timed and all-day fields cannot be combined", 400);
  }
  if (timed) {
    if (typeof body.start_date_time !== "string" || !body.start_date_time || typeof body.end_date_time !== "string" || !body.end_date_time) {
      throw new FamilyOpsError("INVALID_INPUT", "start_date_time and end_date_time are required together", 400);
    }
    out.start_date_time = body.start_date_time;
    out.end_date_time = body.end_date_time;
  }
  if (allDay) {
    if (typeof body.start_date !== "string" || !body.start_date || typeof body.end_date !== "string" || !body.end_date) {
      throw new FamilyOpsError("INVALID_INPUT", "start_date and end_date are required together", 400);
    }
    out.start_date = body.start_date;
    out.end_date = body.end_date;
  }
  if ("busy_member_user_ids" in body) {
    const value = body.busy_member_user_ids;
    if (!Array.isArray(value) || value.some((member) => typeof member !== "string")) {
      throw new FamilyOpsError("INVALID_INPUT", "busy_member_user_ids must be an array of strings", 400);
    }
    out.busy_member_user_ids = value;
  }
  return out;
}

export function buildPatchBody(fields: PatchFields, existingPrivate: Record<string, string> | undefined): Record<string, unknown> {
  const body: Record<string, unknown> = {};
  if ("title" in fields) body.summary = fields.title ?? null;
  if ("description" in fields) body.description = fields.description ?? null;
  if ("location" in fields) body.location = fields.location ?? null;
  if (fields.start_date_time && fields.end_date_time) {
    body.start = { dateTime: fields.start_date_time, timeZone: "Asia/Tokyo" };
    body.end = { dateTime: fields.end_date_time, timeZone: "Asia/Tokyo" };
  } else if (fields.start_date && fields.end_date) {
    body.start = { date: fields.start_date };
    body.end = { date: fields.end_date };
  }
  if (fields.busy_member_user_ids) {
    body.extendedProperties = {
      private: mergePrivateExtendedProperties(existingPrivate, {
        familyOpsBusyMemberIds: fields.busy_member_user_ids.join(","),
      }),
    };
  }
  return withExclusiveEventTimes(body);
}

// A timeout or 412 is reconciled only when every explicitly edited field
// matches, including the end of the event. Google can normalize an RFC3339
// timestamp to a different offset, so compare timed values as instants.
export function alreadyMatches(fields: PatchFields, remote: Record<string, unknown>): boolean {
  if ("title" in fields && (remote.summary ?? null) !== (fields.title ?? null)) return false;
  if ("description" in fields && (remote.description ?? null) !== (fields.description ?? null)) return false;
  if ("location" in fields && (remote.location ?? null) !== (fields.location ?? null)) return false;
  const start = remote.start as { date?: string; dateTime?: string } | undefined;
  const end = remote.end as { date?: string; dateTime?: string } | undefined;
  if (fields.start_date_time && !sameInstant(fields.start_date_time, start?.dateTime)) return false;
  if (fields.end_date_time && !sameInstant(fields.end_date_time, end?.dateTime)) return false;
  if (fields.start_date && start?.date !== fields.start_date) return false;
  if (fields.end_date && end?.date !== fields.end_date) return false;
  if (fields.busy_member_user_ids) {
    const remoteBusy = (remote.extendedProperties as { private?: Record<string, string> } | undefined)?.private?.familyOpsBusyMemberIds ?? "";
    if (remoteBusy !== fields.busy_member_user_ids.join(",")) return false;
  }
  return true;
}

function sameInstant(desired: string, remote: string | undefined): boolean {
  const expected = Date.parse(desired);
  return remote !== undefined && Number.isFinite(expected) && expected === Date.parse(remote);
}
