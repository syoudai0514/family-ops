import { assertEquals, assertStringIncludes } from "jsr:@std/assert@1";
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  parseTransportAssignmentText,
  resolveLineTransportAssignment,
} from "./lineTransportAssignment.ts";

const NOW = new Date("2026-10-14T11:51:00Z");

Deno.test("transport directive: the real message and topic reset mean tomorrow's dropoff to self", () => {
  for (
    const text of [
      "明日の送りは私に変更してください",
      "別の話です。\n明日の送りは私に変更してください",
      "別件です。明日の送りは自分に変更して。",
    ]
  ) {
    assertEquals(parseTransportAssignmentText(text, NOW), {
      code: "dropoff",
      target: "self",
      scheduledDate: "2026-10-15",
    });
  }
});

Deno.test("transport directive: resolves explicit roles, partner and both transport legs", () => {
  const cases = [
    ["10/15の送り担当をパパに変更", "dropoff", "papa"],
    ["明日のお迎え担当をママに変更してください", "pickup", "mama"],
    ["明日の送りを相手にお願い", "dropoff", "partner"],
    ["明日の送りを妻にお願い", "dropoff", "partner"],
    ["明日のお迎え代わって", "pickup", "partner"],
    ["明日の送りは僕がやります", "dropoff", "self"],
  ] as const;
  for (const [text, code, target] of cases) {
    assertEquals(parseTransportAssignmentText(text, NOW), {
      code,
      target,
      scheduledDate: "2026-10-15",
    }, text);
  }
});

Deno.test("an affirmative prior-agreement prefix retains the exact transport intent without granting consent", () => {
  for (
    const prefix of [
      "調整済み。",
      "妻と話し合い済みです。",
      "すでに二人で合意済みです。",
      "別の話です。ママと調整済み。",
    ]
  ) {
    assertEquals(
      parseTransportAssignmentText(
        `${prefix}明日の送りは私に変更してください`,
        NOW,
      ),
      {
        code: "dropoff",
        target: "self",
        scheduledDate: "2026-10-15",
        agreementReported: true,
      },
    );
  }
});

Deno.test("conditional agreement, consultation, questions and negated changes remain outside the directive boundary", () => {
  for (
    const text of [
      "調整済みなら。明日の送りは私に変更してください",
      "妻と話し合い済みなら明日の送りは私に変更してください",
      "調整済みですか？明日の送りは私に変更してください",
      "相談済みです。明日の送りは私に変更してください",
      "相談です。明日の送りは私に変更してください",
      "調整済み。明日の送りは私に変更しないで",
      "妻と話し合い済みです。明日の送りは私に変更してください？",
    ]
  ) assertEquals(parseTransportAssignmentText(text, NOW), null, text);
});

Deno.test("transport directive: missing or conflicting dates stay unresolved, never default to today", () => {
  for (
    const text of [
      "送りは私に変更してください",
      "木曜の送りは私に変更してください",
      "2/30の送りを私に変更してください",
    ]
  ) {
    assertEquals(
      parseTransportAssignmentText(text, NOW)?.scheduledDate,
      null,
      text,
    );
  }
  assertEquals(
    parseTransportAssignmentText("明日の送りを変更してください", NOW)?.target,
    null,
  );
});

Deno.test("transport directive: excludes negation, consultation, questions, reports and unrelated corrections", () => {
  for (
    const text of [
      "明日の送りは私に変更しないで",
      "明日の送りは私に変更しなくていい",
      "明日の送りは私に変更してください？",
      "明日の送りは私に変更していい？",
      "明日の送りは私に変更したいんだけど相談したい",
      "明日の送りはどうしよう",
      "明日の送りを私に変更しました",
      "送りました",
      "明日の送りは私の担当です",
      "明日の送りの荷物をママにお願い",
      "明日の送りのコドモンをパパに変更してください",
      "タイトルを明日の送りに変更してください",
      "送りじゃなくて迎えに変更してください",
      "明日の送りを私に変更して。夕食はママにお願い",
      "「明日の送りを私に変更して」と伝えたい",
    ]
  ) assertEquals(parseTransportAssignmentText(text, NOW), null, text);
});

function task(overrides: Record<string, unknown> = {}) {
  return {
    id: "dropoff-oct15",
    household_id: "home",
    task_definition_id: "dropoff-def",
    scheduled_date: "2026-10-15",
    test_context_id: null,
    planned_assignee_id: "mama-id",
    status: "todo",
    revision: 7,
    due_at: "2026-10-14T22:30:00Z",
    ...overrides,
  };
}

const FAMILY = [
  { household_id: "home", user_id: "papa-id", family_role: "papa" },
  { household_id: "home", user_id: "mama-id", family_role: "mama" },
];

function setup(options: {
  rows?: Record<string, unknown>[];
  members?: Record<string, unknown>[];
  errorTable?: string;
  throwTable?: string;
  appBaseUrl?: string;
} = {}) {
  const requests: Array<{ url: URL; method: string }> = [];
  const client = createClient("https://transport.test", "test-key", {
    auth: { persistSession: false, autoRefreshToken: false },
    global: {
      fetch: (input, init) => {
        const url = new URL(
          input instanceof Request ? input.url : String(input),
        );
        const method = (init as { method?: string } | undefined)?.method ??
          (input instanceof Request ? input.method : "GET");
        requests.push({ url, method });
        const table = url.pathname.split("/").at(-1);
        if (table === options.throwTable) {
          throw new Error("fixture read failure");
        }
        if (table === options.errorTable) {
          return Promise.resolve(
            new Response(
              JSON.stringify({ code: "P0001", message: "fixture read error" }),
              { status: 500 },
            ),
          );
        }
        const code = url.searchParams.get("code")?.replace("eq.", "") ??
          "dropoff";
        const data = table === "household_members"
          ? options.members ?? FAMILY
          : table === "task_definitions"
          ? { id: `${code}-def`, household_id: "home", code }
          : table === "task_instances"
          ? options.rows ?? [task()]
          : null;
        if (data === null || method !== "GET") {
          throw new Error(
            `Unexpected mutation/query: ${method} ${url.pathname}`,
          );
        }
        return Promise.resolve(
          new Response(JSON.stringify(data), {
            headers: { "Content-Type": "application/json" },
          }),
        );
      },
    },
  });
  return {
    ctx: {
      client,
      actorId: "papa-id",
      householdId: "home",
      appBaseUrl: options.appBaseUrl ?? "https://family.example",
      now: NOW,
    },
    requests,
  };
}

Deno.test("real transport occurrence is read in household/date/definition/production scope and linked to PWA", async () => {
  const { ctx, requests } = setup();
  const result = await resolveLineTransportAssignment(
    ctx,
    "明日の送りは私に変更してください",
  );
  assertEquals(result.kind, "reply");
  if (result.kind !== "reply") throw new Error("expected read-only reply");
  assertStringIncludes(result.text, "10/15(木) 07:30 送り");
  assertStringIncludes(result.text, "現在: ママ → 変更希望: パパ");
  assertStringIncludes(result.text, "適用範囲: 今回だけ");
  assertStringIncludes(result.text, "担当はまだ変更していません");
  assertStringIncludes(result.text, "事前に2人で調整済みなら");
  const url = new URL(result.text.split("\n").at(-1)!);
  assertEquals(url.origin, "https://family.example");
  assertEquals(Object.fromEntries(url.searchParams), {
    date: "2026-10-15",
    for: "papa-id",
    assignment_task: "dropoff-oct15",
    assignment_to: "papa-id",
  });
  const read =
    requests.find(({ url }) => url.pathname.endsWith("/task_instances"))!.url;
  assertEquals(read.searchParams.get("household_id"), "eq.home");
  assertEquals(read.searchParams.get("scheduled_date"), "eq.2026-10-15");
  assertEquals(read.searchParams.get("task_definition_id"), "eq.dropoff-def");
  assertEquals(read.searchParams.get("test_context_id"), "is.null");
  assertEquals(read.searchParams.get("limit"), "2");
  assertEquals(requests.every(({ method }) => method === "GET"), true);
});

Deno.test("missing transport time is never replaced by a fabricated 08:00", async () => {
  for (const due_at of [null, "invalid"]) {
    const { ctx } = setup({ rows: [task({ due_at })] });
    const result = await resolveLineTransportAssignment(
      ctx,
      "明日の送りを私に変更してください",
    );
    if (result.kind !== "reply") throw new Error("expected reply");
    assertStringIncludes(result.text, "10/15(木) 送り");
    assertEquals(result.text.includes("08:00"), false);
  }
});

Deno.test("fresh LINE input resolves a reviewed occurrence and revision for native confirmation without writing", async () => {
  const { ctx, requests } = setup();
  assertEquals(await resolveLineTransportAssignment({ ...ctx, nativePreview: true }, "明日の送りは私に変更してください"), {
    kind: "review", taskId: "dropoff-oct15", assigneeUserId: "papa-id", expectedRevision: 7,
  });
  assertEquals(requests.every(({ method }) => method === "GET"), true);
});

Deno.test("a missing task revision cannot produce a native confirmation", async () => {
  const { ctx } = setup({ rows: [task({ revision: undefined })] });
  const result = await resolveLineTransportAssignment({ ...ctx, nativePreview: true }, "明日の送りは私に変更してください");
  assertEquals(result.kind, "reply");
  if (result.kind === "reply") assertStringIncludes(result.text, "最新の担当状態を確認できませんでした");
});

Deno.test("existing self-to-partner pickup request retains its canonical legacy flow", async () => {
  const { ctx, requests } = setup({
    rows: [
      task({
        id: "pickup-oct15",
        task_definition_id: "pickup-def",
        planned_assignee_id: "papa-id",
      }),
    ],
  });
  assertEquals(
    await resolveLineTransportAssignment(ctx, "明日のお迎え代わって"),
    { kind: "legacy_pickup" },
  );
  assertEquals(requests.every(({ method }) => method === "GET"), true);
});

Deno.test("stored pending date is preserved when an old 明日 card is reopened on a later day", async () => {
  const { ctx, requests } = setup();
  const result = await resolveLineTransportAssignment({
    ...ctx,
    now: new Date("2026-10-17T11:51:00Z"),
    scheduledDateOverride: "2026-10-15",
    forceReview: true,
  }, "明日の送りは私に変更してください");
  if (result.kind !== "reply") throw new Error("expected reply");
  assertStringIncludes(result.text, "date=2026-10-15");
  assertEquals(result.text.includes("2026-10-18"), false);
  const read =
    requests.find(({ url }) => url.pathname.endsWith("/task_instances"))!.url;
  assertEquals(read.searchParams.get("scheduled_date"), "eq.2026-10-15");
});

Deno.test("a previously generic pickup card cannot be confirmed through the legacy route", async () => {
  const { ctx } = setup({
    rows: [
      task({
        id: "pickup-oct15",
        task_definition_id: "pickup-def",
        planned_assignee_id: "papa-id",
      }),
    ],
  });
  const result = await resolveLineTransportAssignment({
    ...ctx,
    forceReview: true,
  }, "明日のお迎え代わって");
  if (result.kind !== "reply") throw new Error("expected reply");
  assertStringIncludes(result.text, "担当はまだ変更していません");
  assertStringIncludes(result.text, "assignment_task=pickup-oct15");
  assertStringIncludes(result.text, "assignment_to=mama-id");
});

Deno.test("an invalid stored pending date never falls back to today's interpretation", async () => {
  const { ctx, requests } = setup();
  const result = await resolveLineTransportAssignment({
    ...ctx,
    scheduledDateOverride: "2026-02-30",
  }, "明日の送りは私に変更してください");
  if (result.kind !== "reply") throw new Error("expected reply");
  assertEquals(requests.length, 0);
  assertEquals(result.text.includes("assignment_task="), false);
});

Deno.test("reverse pickup and all dropoff changes use the read-only adjustment guide", async () => {
  for (
    const [text, row] of [
      [
        "明日のお迎えを私に変更してください",
        task({ id: "pickup-oct15", task_definition_id: "pickup-def" }),
      ],
      ["明日の送りをママにお願い", task({ planned_assignee_id: "papa-id" })],
    ] as const
  ) {
    const { ctx } = setup({ rows: [row] });
    const result = await resolveLineTransportAssignment(ctx, text);
    assertEquals(result.kind, "reply");
    if (result.kind !== "reply") throw new Error("expected reply");
    assertStringIncludes(result.text, "担当を調整");
    assertStringIncludes(result.text, "assignment_task=");
  }
});

Deno.test("reported agreement still opens PWA with an explicit choice and never executes or sends another request", async () => {
  for (
    const [text, row] of [
      ["妻と話し合い済みです。明日の送りは私に変更してください", task()],
      [
        "調整済み。明日のお迎えをママにお願い",
        task({
          id: "pickup-oct15",
          task_definition_id: "pickup-def",
          planned_assignee_id: "papa-id",
        }),
      ],
    ] as const
  ) {
    const { ctx, requests } = setup({ rows: [row] });
    const result = await resolveLineTransportAssignment(ctx, text);
    if (result.kind !== "reply") {
      throw new Error("expected PWA confirmation guidance");
    }
    assertStringIncludes(result.text, "担当はまだ変更していません");
    assertStringIncludes(
      result.text,
      "すでに話し合い済みなので、そのまま担当を変更",
    );
    assertStringIncludes(result.text, "assignment_task=");
    assertEquals(requests.every(({ method }) => method === "GET"), true);
  }
});

Deno.test("missing/multiple/terminal occurrences are handled without a pretend task link or generic request", async () => {
  for (
    const rows of [[], [task(), task({ id: "duplicate" })], [
      task({ status: "completed" }),
    ], [task({ status: "cancelled" })]]
  ) {
    const { ctx } = setup({ rows });
    const result = await resolveLineTransportAssignment(
      ctx,
      "明日の送りを私に変更してください",
    );
    assertEquals(result.kind, "reply");
    if (result.kind !== "reply") throw new Error("expected reply");
    assertStringIncludes(result.text, "担当は変更していません");
    assertEquals(result.text.includes("assignment_task="), false);
  }
});

Deno.test("foreign-household, other-date and test occurrence readbacks are rejected", async () => {
  for (
    const patch of [
      { household_id: "other-home" },
      { scheduled_date: "2026-10-16" },
      { task_definition_id: "other-def" },
      { test_context_id: "simulation" },
    ]
  ) {
    const { ctx } = setup({ rows: [task(patch)] });
    const result = await resolveLineTransportAssignment(
      ctx,
      "明日の送りを私に変更してください",
    );
    assertEquals(result.kind, "reply");
    if (result.kind !== "reply") throw new Error("expected reply");
    assertEquals(result.text.includes("assignment_task="), false);
  }
});

Deno.test("read failures stop safely and never become generic creation", async () => {
  for (
    const errorTable of [
      "household_members",
      "task_definitions",
      "task_instances",
    ]
  ) {
    const { ctx, requests } = setup({ errorTable });
    const result = await resolveLineTransportAssignment(
      ctx,
      "明日の送りを私に変更してください",
    );
    assertEquals(result.kind, "reply");
    if (result.kind !== "reply") throw new Error("expected reply");
    assertStringIncludes(result.text, "担当は変更していません");
    assertEquals(requests.every(({ method }) => method === "GET"), true);
  }
});

Deno.test("membership and recipient ambiguity cannot manufacture a current or future assignee", async () => {
  for (
    const members of [
      [FAMILY[1]],
      [FAMILY[0], {
        household_id: "other-home",
        user_id: "mama-id",
        family_role: "mama",
      }],
      [...FAMILY, {
        household_id: "home",
        user_id: "other-adult",
        family_role: "mama",
      }],
    ]
  ) {
    const { ctx } = setup({ members });
    const result = await resolveLineTransportAssignment(
      ctx,
      "明日の送りをママに変更してください",
    );
    assertEquals(result.kind, "reply");
    if (result.kind !== "reply") throw new Error("expected reply");
    assertEquals(result.text.includes("assignment_to="), false);
  }
});

Deno.test("already current assignee is explained without proposing a duplicate change", async () => {
  const { ctx } = setup({ rows: [task({ planned_assignee_id: "papa-id" })] });
  const result = await resolveLineTransportAssignment(
    ctx,
    "明日の送りを私に変更してください",
  );
  if (result.kind !== "reply") throw new Error("expected reply");
  assertStringIncludes(result.text, "すでにパパ担当です");
  assertEquals(result.text.includes("assignment_task="), false);
});

Deno.test("missing date or target is handled without any guessed task or assignment", async () => {
  for (
    const text of ["送りを私に変更してください", "明日の送りを変更してください"]
  ) {
    const { ctx } = setup();
    const result = await resolveLineTransportAssignment(ctx, text);
    if (result.kind !== "reply") throw new Error("expected reply");
    assertStringIncludes(result.text, "担当は変更していません");
    assertEquals(result.text.includes("assignment_task="), false);
  }
});

Deno.test("unrelated utterances are not intercepted and an unavailable app URL is not invented", async () => {
  const { ctx, requests } = setup({ appBaseUrl: "" });
  assertEquals(await resolveLineTransportAssignment(ctx, "明日の送りは誰？"), {
    kind: "not_applicable",
  });
  assertEquals(requests.length, 0);
  const result = await resolveLineTransportAssignment(
    ctx,
    "明日の送りは私に変更してください",
  );
  if (result.kind !== "reply") throw new Error("expected reply");
  assertEquals(result.text.includes("https://"), false);
  assertStringIncludes(result.text, "当日の作業を開いてください");
});
