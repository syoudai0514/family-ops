import { assertEquals } from "jsr:@std/assert@1";
import { parseStructuredWorkDue } from "./lineMustComplete.ts";

Deno.test("LINE material deadline parser accepts only explicit structured syntax", () => {
  assertEquals(
    parseStructuredWorkDue("条件期限 2026-09-11 18:30"),
    "2026-09-11T09:30:00.000Z",
  );
  assertEquals(
    parseStructuredWorkDue("条件期限　2026-09-11 18:30"),
    "2026-09-11T09:30:00.000Z",
  );
});

Deno.test("LINE consultation prose is never parsed into a Task mutation", () => {
  assertEquals(parseStructuredWorkDue("18:30ならできる"), null);
  assertEquals(parseStructuredWorkDue("明日は私、金曜は交代"), null);
  assertEquals(parseStructuredWorkDue("送りと迎えを交換"), null);
  assertEquals(parseStructuredWorkDue("条件期限 明日18:30"), null);
});

Deno.test("LINE material deadline parser rejects impossible dates", () => {
  assertEquals(parseStructuredWorkDue("条件期限 2026-02-31 18:30"), null);
  assertEquals(parseStructuredWorkDue("条件期限 2026-09-11 25:00"), null);
});
