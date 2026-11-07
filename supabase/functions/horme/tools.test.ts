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

test("events are scheduled but never to-dos", async () => {
  const store = memoryStore();
  const added = payload(await call(store, "add_tasks", { tasks: [
    { title: "友達に会う", date: "2026-10-31", time: "18:00-21:00", kind: "event", must: true, deadline: "2026-10-31" },
  ] })).added;
  const event = materialize(store.records).tasks[0];
  assert.equal(event.isEvent, true);
  assert.equal(event.isMust, false);
  assert.equal(event.deadline, undefined);
  const today = payload(await call(store, "get_today", {}));
  assert.equal(today.items[0].kind, "event");
  assert.equal(today.required.length, 0);
  assert.equal(today.musts.length, 0, "an event is never ★");
  await call(store, "set_done", { ids: added, done: true });
  assert.ok(materialize(store.records).tasks[0].completedAt, "an event can be marked as happened");
  const undated: any = await call(store, "add_tasks", { tasks: [{ title: "いつか会う", date: "anytime", kind: "event" }] });
  assert.equal(undated.result.isError, true);
  const plain = payload(await call(store, "add_tasks", { tasks: [{ title: "買い物", date: "2026-10-31", must: true }] })).added[0];
  await call(store, "update_task", { id: plain, kind: "event" });
  const changed = materialize(store.records).tasks.find((t) => t.id === plain)!;
  assert.equal(changed.isEvent, true);
  assert.equal(changed.isMust, false);
  const anytime = payload(await call(store, "add_tasks", { tasks: [{ title: "本を読む", date: "anytime" }] })).added[0];
  const refused: any = await call(store, "update_task", { id: anytime, kind: "event" });
  assert.equal(refused.result.isError, true);
});

test("pieces: the first takes the parent's day, the parent finishes with the last, and removing the parent takes them all", async () => {
  const store = memoryStore();
  const add = await call(store, "add_tasks", { tasks: [{ title: "提案書", date: "2026-10-31", time: "14:00-15:00", must: true }] });
  const parent = JSON.parse(add.result.content[0].text).added[0];
  const pieces = await call(store, "add_tasks", { tasks: [{ title: "見出し", parent }, { title: "本文", parent }] });
  const [first, second] = JSON.parse(pieces.result.content[0].text).added;
  let book = materialize(store.records);
  const top = book.tasks.find((t) => t.id === parent)!;
  assert.equal(top.plannedAt ?? null, null);
  assert.equal(top.isMust, true);
  const head = book.tasks.find((t) => t.id === first)!;
  assert.equal(head.plannedAt, "2026-10-31T03:00:00Z");
  assert.equal(head.scheduledTime, "14:00-15:00");
  assert.equal(book.tasks.find((t) => t.id === second)!.plannedAt ?? null, null);

  const read = await call(store, "get_task", { id: parent });
  assert.deepEqual(JSON.parse(read.result.content[0].text).pieces.map((p: any) => p.title), ["見出し", "本文"]);

  await call(store, "set_done", { ids: [first], done: true });
  assert.equal(materialize(store.records).tasks.find((t) => t.id === parent)!.completedAt ?? null, null);
  await call(store, "set_done", { ids: [second], done: true });
  assert.ok(materialize(store.records).tasks.find((t) => t.id === parent)!.completedAt);
  await call(store, "set_done", { ids: [second], done: false });
  assert.equal(materialize(store.records).tasks.find((t) => t.id === parent)!.completedAt ?? null, null);

  const dated = await call(store, "update_task", { id: parent, date: "2026-11-01" });
  assert.equal(dated.result.isError, true);

  await call(store, "remove_tasks", { ids: [parent] });
  book = materialize(store.records);
  assert.equal(book.tasks.length, 0);
});

test("★ alone never makes a task due today; it is listed with the musts until its deadline", async () => {
  const store = memoryStore();
  // `call` reads on 2026-10-31.
  await call(store, "add_tasks", { tasks: [
    { title: "申請書", date: "anytime", must: true, deadline: "2026-11-20" },
    { title: "更新", date: "anytime", must: true },
    { title: "支払い", date: "anytime", deadline: "2026-10-31" },
  ] });
  const read = payload(await call(store, "get_today", {}));
  assert.deepEqual(read.required.map((t: any) => t.title), ["支払い"]);
  assert.deepEqual(read.musts.map((t: any) => t.title), ["申請書", "更新"], "nearest deadline first, undated last");
});

test("routines: Claude can make one when asked, change it and pause it", async () => {
  const store = memoryStore();
  const id = payload(await call(store, "add_routine", { title: "英単語", time: "7:30-7:45", weekdays: [2, 3, 4, 5, 6], project: "TOEIC" })).added;
  let routine = materialize(store.records).routines.find((r) => r.id === id)!;
  assert.deepEqual(routine.weekdays, [2, 3, 4, 5, 6]);
  assert.equal(routine.time, "7:30-7:45");
  assert.equal(routine.isBlock, false);
  assert.equal(routine.notify, true);
  await call(store, "update_routine", { id, time: "8:00-8:15", paused: true });
  routine = materialize(store.records).routines.find((r) => r.id === id)!;
  assert.equal(routine.time, "8:00-8:15");
  assert.equal(routine.isPaused, true);
  const held = payload(await call(store, "add_routine", { title: "睡眠", time: "0:00-7:00", held: true })).added;
  const sleep = materialize(store.records).routines.find((r) => r.id === held)!;
  assert.deepEqual([sleep.isBlock, sleep.notify, sleep.weekdays.length], [true, false, 7]);
  const bad: any = await call(store, "add_routine", { title: "x", weekdays: [8] });
  assert.equal(bad.result.isError, true);
});

test("projects: read goal and checkpoints, make and change them, rename carries the tasks along", async () => {
  const store = memoryStore();
  const id = payload(await call(store, "set_project", { name: "TOEIC", goal: "本番で500点", deadline: "2026-12-20" })).added;
  await call(store, "add_tasks", { tasks: [{ title: "模試を解く", project: "TOEIC", date: "anytime" }] });
  const m1 = payload(await call(store, "set_milestone", { project: id, title: "単語帳を1周" })).added;
  const m2 = payload(await call(store, "set_milestone", { project: id, title: "模試", kind: "number", target: 450, current: 420, unit: "点" })).added;
  await call(store, "set_milestone", { project: id, milestone: m1, done: true });
  let read = payload(await call(store, "get_projects", {}));
  assert.equal(read[0].goal, "本番で500点");
  assert.equal(read[0].deadline, "2026-12-20");
  assert.deepEqual(read[0].milestones.map((m: any) => [m.title, m.done]), [["単語帳を1周", true], ["模試", false]]);
  assert.equal(read[0].milestones[1].current, 420);
  assert.deepEqual(read[0].openTasks.map((t: any) => t.title), ["模試を解く"]);
  await call(store, "set_project", { id, name: "英語" });
  const book = materialize(store.records);
  assert.equal(book.tasks[0].project, "英語");
  await call(store, "set_milestone", { project: id, milestone: m2, remove: true });
  read = payload(await call(store, "get_projects", {}));
  assert.deepEqual(read[0].milestones.map((m: any) => m.title), ["単語帳を1周"]);
  const dup: any = await call(store, "set_project", { name: "英語" });
  assert.equal(dup.result.isError, true);
});
