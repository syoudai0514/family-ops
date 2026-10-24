import { assertEquals } from "jsr:@std/assert@1";
import { isCodmonSubmitTask } from "./codmonSubmit.ts";

type Row = Record<string, unknown> | null;

// Minimal stand-in for the two single-row reads the helper makes.
function stubClient(tables: Record<string, { data: Row; error?: unknown }>) {
  return {
    from: (table: string) => ({
      select: () => ({
        eq: () => ({ maybeSingle: () => Promise.resolve({ error: null, ...tables[table] }) }),
      }),
    }),
  } as unknown as Parameters<typeof isCodmonSubmitTask>[0];
}

Deno.test("the codmon_submit task is recognised", async () => {
  const client = stubClient({
    task_instances: { data: { task_definition_id: "def-1" } },
    task_definitions: { data: { code: "codmon_submit" } },
  });
  assertEquals(await isCodmonSubmitTask(client, "task-1"), true);
});

Deno.test("other tasks, unknown tasks and lookup errors take the ordinary completion path", async () => {
  assertEquals(await isCodmonSubmitTask(stubClient({
    task_instances: { data: { task_definition_id: "def-1" } },
    task_definitions: { data: { code: "codmon_shino_pickup_input" } },
  }), "task-1"), false);
  assertEquals(await isCodmonSubmitTask(stubClient({
    task_instances: { data: null },
    task_definitions: { data: { code: "codmon_submit" } },
  }), "task-1"), false);
  assertEquals(await isCodmonSubmitTask(stubClient({
    task_instances: { data: { task_definition_id: "def-1" }, error: { message: "boom" } },
    task_definitions: { data: { code: "codmon_submit" } },
  }), "task-1"), false);
  assertEquals(await isCodmonSubmitTask(stubClient({
    task_instances: { data: { task_definition_id: "def-1" } },
    task_definitions: { data: null, error: { message: "boom" } },
  }), "task-1"), false);
});
