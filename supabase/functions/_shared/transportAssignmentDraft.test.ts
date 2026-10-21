import { assertEquals } from "jsr:@std/assert@1";
import {
  detectTransportAssignmentDraft,
  detectTransportAssignmentPending,
} from "./transportAssignmentDraft.ts";

const NOW = new Date("2026-10-21T04:22:00Z");

Deno.test("transport draft guard recognizes the original father pickup request regardless of the model's year", () => {
  const raw_text = "11/5の迎えを父に変更して。合意済みです。";
  assertEquals(
    detectTransportAssignmentDraft({
      raw_text,
      title: "11/5のお迎えを父に変更",
      scheduled_date: "2025-11-05",
    }, NOW),
    {
      intent: {
        code: "pickup",
        target: "papa",
        scheduledDate: "2026-11-05",
        agreementReported: true,
      },
      source: "raw",
      text: raw_text,
    },
  );
});

Deno.test("transport draft guard catches an elliptical correction with a matching generated transport title", () => {
  const result = detectTransportAssignmentDraft({
    raw_text: "だからパパに変えてって言ったじゃん",
    title: "お迎えをパパに変更",
    scheduled_date: "2026-11-05",
  }, NOW);
  assertEquals(result, {
    intent: { code: "pickup", target: "papa", scheduledDate: null },
    source: "title",
    text: "お迎えをパパに変更",
  });
});

Deno.test("transport draft guard blocks a conflicting model target without offering that title for execution", () => {
  assertEquals(
    detectTransportAssignmentDraft({
      raw_text: "だからパパに変えてって言ったじゃん",
      title: "お迎えをママに変更",
    }, NOW),
    {
      intent: { code: "pickup", target: null, scheduledDate: null },
      source: "title",
      text: null,
      targetConflict: true,
    },
  );
});

Deno.test("transport draft guard retains blank raw title recovery and does not invent a date", () => {
  assertEquals(
    detectTransportAssignmentDraft({
      raw_text: " ",
      title: "お迎えを父に変更",
      scheduled_date: "2025-11-05",
    }, NOW),
    {
      intent: { code: "pickup", target: "papa", scheduledDate: null },
      source: "title",
      text: "お迎えを父に変更",
    },
  );
});

Deno.test("transport draft titles block generic creation when positive source wording is outside the directive grammar", () => {
  for (
    const raw_text of ["11/5は父が迎えに行きます", "今度の木曜は迎え担当パパで"]
  ) {
    assertEquals(
      detectTransportAssignmentDraft({
        raw_text,
        title: "お迎えをパパに変更",
        scheduled_date: "2025-11-05",
      }, NOW),
      {
        intent: { code: "pickup", target: "papa", scheduledDate: null },
        source: "title",
        text: "お迎えをパパに変更",
      },
      raw_text,
    );
  }
});

Deno.test("transport draft guard does not use model assignment titles over non-directive source text", () => {
  for (
    const raw_text of [
      "送りの変更についてママに話すメモを作る",
      "「パパに変更して」と伝えたい",
      "パパに変更しないで",
      "パパに変更していい？",
      "パパに変更したいけど相談したい",
      "だからパパに変えてって言ったの？",
    ]
  ) {
    assertEquals(
      detectTransportAssignmentDraft({
        raw_text,
        title: "明日の送りをパパに変更して",
      }, NOW),
      null,
      raw_text,
    );
  }
});

Deno.test("multi-intent guard scans each active generic candidate without inheriting a parent's memo framing", () => {
  const result = detectTransportAssignmentPending("line_multi_intent_review", {
    raw_text: "メモです。買い物と担当変更です。",
    candidates: [
      {
        status: "draft",
        action_type: "shopping_item_add",
        title: "牛乳",
        source_text: "牛乳を買って",
        payload: {},
      },
      {
        candidate_id: "transport",
        status: "draft",
        action_type: "task_create_once",
        source_text: "11/5の迎えを父に変更して。合意済みです。",
        title: "迎えを父に変更",
        payload: { title: "お迎えを父に変更", scheduled_date: "2025-11-05" },
      },
    ],
  }, NOW);
  assertEquals(result?.intent, {
    code: "pickup",
    target: "papa",
    scheduledDate: "2026-11-05",
    agreementReported: true,
  });
  assertEquals(result?.candidateId, "transport");
  assertEquals(result?.source, "raw");
});

Deno.test("multi-intent guard respects candidate cancellation and canonical non-generic actions", () => {
  assertEquals(
    detectTransportAssignmentPending("line_multi_intent_review", {
      candidates: [
        {
          status: "cancelled",
          action_type: "task_create_once",
          source_text: "11/5の迎えを父に変更して",
          payload: { title: "お迎えをパパに変更" },
        },
        {
          status: "draft",
          action_type: "assignment_change_request",
          source_text: "11/5の迎えを父に変更して",
          payload: { title: "お迎えをパパに変更" },
        },
        {
          status: "draft",
          action_type: "request_create",
          source_text: "牛乳を買って",
          payload: { title: "牛乳を買う" },
        },
      ],
    }, NOW),
    null,
  );
});

Deno.test("multi-intent guard prefers each source_text and falls back only to that candidate's own payload", () => {
  assertEquals(
    detectTransportAssignmentPending("line_multi_intent_review", {
      raw_text: "お迎えをパパに変更",
      candidates: [{
        status: "draft",
        action_type: "task_create_once",
        source_text: "変更について話すメモを作る",
        payload: {
          raw_text: "お迎えをパパに変更",
          title: "お迎えをパパに変更",
        },
      }],
    }, NOW),
    null,
  );
  assertEquals(
    detectTransportAssignmentPending("line_multi_intent_review", {
      raw_text: "これはメモです",
      candidates: [{
        status: "draft",
        action_type: "request_create",
        title: "お迎えをパパに変更",
        payload: { raw_text: "だからパパに変えてって言ったじゃん" },
      }],
    }, NOW)?.source,
    "title",
  );
});

Deno.test("multi-intent guard does not let missing or unknown status/action metadata bypass classification", () => {
  for (
    const metadata of [{}, {
      status: "future_status",
      action_type: "future_generic_type",
    }]
  ) {
    const result = detectTransportAssignmentPending(
      "line_multi_intent_review",
      {
        candidates: [{ ...metadata, title: "お迎えをパパに変更", payload: {} }],
      },
      NOW,
    );
    assertEquals(result?.intent, {
      code: "pickup",
      target: "papa",
      scheduledDate: null,
    });
  }
  assertEquals(
    detectTransportAssignmentPending("assignment_change_request", {
      raw_text: "11/5の迎えを父に変更して",
    }, NOW),
    null,
  );
});
