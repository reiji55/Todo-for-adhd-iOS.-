// Run with: node --test supabase/functions/horme/tools.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { handleMcp } from "./tools.ts";
import type { RecordStore } from "./tools.ts";
import { decodeValue, encodeValue, materialize } from "./records.ts";
import type { SyncRecord } from "./records.ts";

function memoryStore(initial: SyncRecord[] = []): RecordStore & { records: SyncRecord[] } {
  const records = structuredClone(initial);
  return {
    records,
    async load() { return structuredClone(records); },
    async merge(changes) {
      for (const change of changes) {
        const current = records.find((r) => r.id === change.id);
        if (!current) { records.push(structuredClone(change)); continue; }
        for (const [key, field] of Object.entries(change.fields)) {
          const old = current.fields[key];
          if (!old || field.stamp.tick > old.stamp.tick || (field.stamp.tick === old.stamp.tick && field.stamp.device > old.stamp.device)) {
            current.fields[key] = field;
          }
        }
      }
    },
  };
}

const call = (store: RecordStore, name: string, args: object, now = new Date("2026-10-31T01:00:00Z")) =>
  handleMcp({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name, arguments: args } }, store, now);
const payload = (reply: any) => JSON.parse(reply.result.content[0].text);

// A record exactly as the Swift app writes it (JSONEncoder: Data as base64, values as JSON fragments).
const appTask: SyncRecord = {
  version: 1, id: "task_11111111-1111-1111-1111-111111111111",
  fields: Object.fromEntries(Object.entries({
    alive: true, id: "11111111-1111-1111-1111-111111111111", title: "電話", plannedAt: "2026-10-31T03:00:00Z",
    scheduledTime: "10:00-10:30", isMust: false, effort: "light", project: "仕事", memo: "", handoff: "番号を調べて",
    resumeNote: "", createdAt: "2026-10-30T00:00:00Z", notify: true,
    "step.22222222-2222-2222-2222-222222222222.alive": true, "step.22222222-2222-2222-2222-222222222222.title": "番号を探す",
    "step.22222222-2222-2222-2222-222222222222.isDone": false, "step.22222222-2222-2222-2222-222222222222.rank": 0,
  }).map(([k, v]) => [k, { value: encodeValue(v), stamp: { tick: 1000, device: "PHONE" } }])),
};
const appRoutine: SyncRecord = {
  version: 1, id: "routine_33333333-3333-3333-3333-333333333333",
  fields: Object.fromEntries(Object.entries({
    alive: true, id: "33333333-3333-3333-3333-333333333333", title: "金フレ", project: "TOEIC", memo: "",
    weekdays: [2, 3, 4, 5, 6, 7], time: "19:00-20:30", notify: true, isBlock: false, isPaused: false,
    createdAt: "2026-10-01T00:00:00Z", "move.2026-10-30": { toDay: "2026-10-31", time: "21:00-22:30" },
  }).map(([k, v]) => [k, { value: encodeValue(v), stamp: { tick: 1000, device: "PHONE" } }])),
};

test("values round-trip as base64 JSON, including Japanese", () => {
  assert.equal(decodeValue(encodeValue("やり方")), "やり方");
  assert.equal(encodeValue(true), "dHJ1ZQ==");
});

test("today lists tasks and routines in time order, with the moved routine day", async () => {
  const store = memoryStore([appTask, appRoutine]);
  const today = payload(await call(store, "get_today", {}));
  assert.equal(today.date, "2026-10-31");
  assert.deepEqual(today.items.map((i: any) => [i.title, i.time]), [
    ["電話", "10:00-10:30"], ["金フレ", "19:00-20:30"], ["金フレ", "21:00-22:30"],
  ]);
  assert.equal(today.items[0].nextStep, "番号を探す");
  assert.equal(today.items[0].handoff, "番号を調べて");
  assert.equal(today.items[2].originalDay, "2026-10-30");
});

test("edits touch only their fields and keep the app's other changes", async () => {
  const store = memoryStore([appTask]);
  await call(store, "update_task", { id: appTask.id.slice(5).toLowerCase(), memo: "調べて番号を書いた", handoff: "" });
  // Meanwhile the app renamed the task with an older stamp than Claude's but a different field.
  await store.merge([{ version: 1, id: appTask.id, fields: { title: { value: encodeValue("歯医者に電話"), stamp: { tick: 1001, device: "PAD" } } } }]);
  const task = materialize(store.records).tasks[0];
  assert.equal(task.title, "歯医者に電話");
  assert.equal(task.memo, "調べて番号を書いた");
  assert.equal(task.handoff, "");
  assert.equal(store.records[0].fields.memo.stamp.device, "claude");
  assert.ok(store.records[0].fields.memo.stamp.tick > 1001);
});

test("adding, completing and removing tasks", async () => {
  const store = memoryStore([appTask]);
  const added = payload(await call(store, "add_tasks", { tasks: [
    { title: "資料を読む", date: "2026-11-02", time: "9:00", project: "TOEIC" },
    { title: "いつか", date: "anytime" },
  ] })).added;
  assert.equal(added.length, 2);
  assert.match(added[0], /^[0-9A-F-]{36}$/);
  const book = materialize(store.records);
  const read = book.tasks.find((t) => t.title === "資料を読む")!;
  assert.equal(read.plannedAt, "2026-11-02T03:00:00Z");
  assert.equal(read.scheduledTime, "9:00");
  assert.equal(book.tasks.find((t) => t.title === "いつか")!.plannedAt, undefined);
  await call(store, "set_done", { ids: [added[0]], done: true });
  assert.match(materialize(store.records).tasks.find((t) => t.id === added[0])!.completedAt!, /^2026-10-31T01:00:00Z$/);
  await call(store, "remove_tasks", { ids: [added[1]] });
  assert.equal(materialize(store.records).tasks.some((t) => t.id === added[1]), false);
});

test("invalid input is refused with a readable message", async () => {
  const reply: any = await call(memoryStore(), "add_tasks", { tasks: [{ title: "x", date: "11/2" }] });
  assert.equal(reply.result.isError, true);
  assert.match(reply.result.content[0].text, /YYYY-MM-DD/);
});

test("routine days, board cards and ideas", async () => {
  const store = memoryStore([appRoutine]);
  await call(store, "check_routine", { id: appRoutine.id.slice(8), date: "2026-10-30", done: true });
  assert.deepEqual(materialize(store.records).routines[0].doneDays, ["2026-10-30"]);
  await call(store, "check_routine", { id: appRoutine.id.slice(8), date: "2026-10-30", done: false });
  assert.deepEqual(materialize(store.records).routines[0].doneDays, []);
  const card = payload(await call(store, "set_board_card", { title: "TOEIC対策", detail: "1. 単語" })).added;
  await call(store, "set_board_card", { id: card, goal: "650点" });
  const board = payload(await call(store, "get_board", {}));
  assert.equal(board[0].goal, "650点");
  assert.equal(board[0].detail, "1. 単語");
  await call(store, "add_idea", { text: "散歩中に単語" });
  assert.equal(materialize(store.records).ideas[0].text, "散歩中に単語");
});

test("protocol: initialize, list, notifications and unknown methods", async () => {
  const store = memoryStore();
  const init: any = await handleMcp({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } }, store);
  assert.equal(init.result.serverInfo.name, "horme");
  const list: any = await handleMcp({ jsonrpc: "2.0", id: 2, method: "tools/list" }, store);
  assert.ok(list.result.tools.some((t: any) => t.name === "get_today"));
  assert.equal(await handleMcp({ jsonrpc: "2.0", method: "notifications/initialized" }, store), null);
  const unknown: any = await handleMcp({ jsonrpc: "2.0", id: 3, method: "nope" }, store);
  assert.equal(unknown.error.code, -32601);
});
