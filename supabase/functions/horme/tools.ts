// Horme's MCP tools. Each call reads the records, writes only the fields it changes (stamped as "claude"),
// and lets the database merge them, so the app's own edits made at the same time survive.

import { addDays, agenda, dayKey, dayToISO, isAlive, materialize, newID, nowISO, taskItem, todayKey, Writer } from "./records.ts";
import type { Book, SyncRecord, Task } from "./records.ts";

export interface RecordStore {
  load(): Promise<SyncRecord[]>;
  merge(changes: SyncRecord[]): Promise<void>;
}

type Args = Record<string, any>;
type Tool = {
  name: string; title: string; description: string; inputSchema: Record<string, unknown>;
  run: (args: Args, ctx: { records: SyncRecord[]; book: Book; now: Date }) => { result: unknown; changes?: SyncRecord[] };
};

const DATE = { type: "string", description: 'YYYY-MM-DD（日本時間）。日付を決めないものは "anytime"' };
const TIME = { type: "string", description: '時間帯 "19:00-20:30"。開始だけなら "9:00"（1時間）。空文字で時間を消す' };
const IDS = { type: "array", items: { type: "string" }, minItems: 1, description: "id の配列" };

function find(book: Book, id: string): Task {
  const task = book.tasks.find((t) => t.id.toUpperCase() === String(id).toUpperCase());
  if (!task) throw new Error(`タスクが見つかりません: ${id}。先に get_today / get_days で id を確かめてください。`);
  return task;
}

function validDate(value: string) {
  if (value === "anytime") return;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value) || Number.isNaN(Date.parse(`${value}T00:00:00Z`))) {
    throw new Error(`日付は YYYY-MM-DD か "anytime" で渡してください: ${value}`);
  }
}

function validTime(value: string) {
  if (value === "" || /^\d{1,2}:\d{2}(\s*[-–~〜]\s*\d{1,2}:\d{2})?$/.test(value.trim())) return;
  throw new Error(`時間帯は "19:00-20:30" か "9:00" の形で渡してください: ${value}`);
}

function day(book: Book, key: string) {
  return { date: key, items: agenda(book, key) };
}

function leftovers(book: Book, today: string) {
  return book.tasks.filter((t) => !t.completedAt && t.plannedAt && dayKey(t.plannedAt) < today)
    .map((t) => ({ ...taskItem(t), plannedDay: dayKey(t.plannedAt!) }));
}

/** Overdue deadlines and must tasks that are not planned for today (those are already in today's list). */
function required(book: Book, today: string) {
  return book.tasks.filter((t) => {
    if (t.completedAt || (t.plannedAt && dayKey(t.plannedAt) === today)) return false;
    const due = t.deadline ? dayKey(t.deadline) <= today : false;
    const must = t.isMust && (!t.plannedAt || dayKey(t.plannedAt) <= today);
    return due || must;
  }).map(taskItem);
}

export const tools: Tool[] = [
  {
    name: "get_today",
    title: "今日を読む",
    description:
      "今日の時間割（タスクとルーティン、時刻順）、今日中に必要なもの（締切・必須で今日の予定に入っていないもの）、" +
      "前の日から残っているタスクを返す。各項目の id を他のツールに渡す。書き換える前にまずこれを呼ぶ。" +
      "handoff は本人が「Claude にやってほしい」と書き残した依頼。held はルーティンのうち睡眠・仕事など時間を押さえているだけのもの。",
    inputSchema: { type: "object", properties: {} },
    run: (_, { book, now }) => {
      const today = todayKey(now);
      return { result: { ...day(book, today), required: required(book, today), leftovers: leftovers(book, today) } };
    },
  },
  {
    name: "get_days",
    title: "日付を指定して読む",
    description: "指定した日から数日分の時間割を返す（最大31日）。週の予定を見るときは days=7。",
    inputSchema: {
      type: "object",
      properties: { start: DATE, days: { type: "integer", minimum: 1, maximum: 31, description: "日数。既定は1" } },
      required: ["start"],
    },
    run: ({ start, days }, { book }) => {
      validDate(start);
      if (start === "anytime") throw new Error("日付なしのタスクは get_anytime で読めます。");
      const n = Math.max(1, Math.min(31, Number(days ?? 1)));
      return { result: Array.from({ length: n }, (_, i) => day(book, addDays(start, i))) };
    },
  },
  {
    name: "get_anytime",
    title: "日付なしのタスクを読む",
    description: "日付を決めていない未完了のタスク（「いつでも」）を返す。",
    inputSchema: { type: "object", properties: {} },
    run: (_, { book }) => ({ result: book.tasks.filter((t) => !t.completedAt && !t.plannedAt).map(taskItem) }),
  },
  {
    name: "add_tasks",
    title: "タスクを足す",
    description:
      "タスクを追加する。date を省くと今日、\"anytime\" で日付なし。同じものを二重に足さないよう、先に get_today / get_days で確認する。" +
      "くり返すものはタスクではなくルーティンなので、本人に確認してから。",
    inputSchema: {
      type: "object",
      properties: {
        tasks: {
          type: "array", minItems: 1,
          items: {
            type: "object",
            properties: {
              title: { type: "string" }, date: DATE, time: TIME, project: { type: "string" },
              must: { type: "boolean", description: "本人が必須と決めたものだけ true" },
              deadline: { type: "string", description: "締切 YYYY-MM-DD" },
              memo: { type: "string", description: "本人用のメモ" },
              handoff: { type: "string", description: "Claude への引き継ぎ" },
            },
            required: ["title"],
          },
        },
      },
      required: ["tasks"],
    },
    run: ({ tasks }, { records, now }) => {
      const writer = new Writer(records, "claude", now.getTime());
      const added: string[] = [];
      for (const input of tasks as Args[]) {
        const title = String(input.title ?? "").trim();
        if (!title) throw new Error("title が空のタスクがあります。");
        const date = input.date ?? todayKey(now);
        validDate(date); validTime(input.time ?? "");
        if (input.deadline) validDate(input.deadline);
        const id = newID();
        const values: Args = {
          alive: true, id, title, scheduledTime: date === "anytime" ? "" : String(input.time ?? "").trim(),
          isMust: !!input.must, effort: "medium", project: input.project ?? "", memo: input.memo ?? "",
          handoff: input.handoff ?? "", resumeNote: "", createdAt: nowISO(now), notify: true,
        };
        if (date !== "anytime") values.plannedAt = dayToISO(date);
        if (input.deadline && input.deadline !== "anytime") values.deadline = dayToISO(input.deadline);
        writer.set(`task_${id}`, values);
        added.push(id);
      }
      return { result: { added }, changes: writer.changes };
    },
  },
  {
    name: "update_task",
    title: "タスクを直す",
    description:
      "タスクの名前・日付・時間帯・プロジェクト・必須・締切・メモ・引き継ぎを書き換える。渡した欄だけ変わる。" +
      'date="anytime" で日付と時間を外す。引き継ぎ（handoff）は対応したら memo に何をしたか書いてから空にする。',
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string" }, title: { type: "string" }, date: DATE, time: TIME, project: { type: "string" },
        must: { type: "boolean" }, deadline: { type: "string", description: 'YYYY-MM-DD、空文字で締切を外す' },
        memo: { type: "string" }, handoff: { type: "string" },
      },
      required: ["id"],
    },
    run: (args, { records, book, now }) => {
      const task = find(book, args.id);
      const writer = new Writer(records, "claude", now.getTime());
      const values: Args = {};
      if (args.title !== undefined) {
        if (!String(args.title).trim()) throw new Error("タスク名は空にできません。");
        values.title = String(args.title).trim();
      }
      if (args.date !== undefined) {
        validDate(args.date);
        values.plannedAt = args.date === "anytime" ? null : dayToISO(args.date);
        if (args.date === "anytime") values.scheduledTime = "";
      }
      if (args.time !== undefined) { validTime(args.time); values.scheduledTime = String(args.time).trim(); }
      for (const key of ["project", "memo", "handoff"]) if (args[key] !== undefined) values[key] = String(args[key]);
      if (args.must !== undefined) values.isMust = !!args.must;
      if (args.deadline !== undefined) {
        if (args.deadline) validDate(args.deadline);
        values.deadline = args.deadline ? dayToISO(args.deadline) : null;
      }
      if (!Object.keys(values).length) return { result: { changed: false } };
      writer.set(`task_${task.id}`, values);
      return { result: { changed: true, id: task.id }, changes: writer.changes };
    },
  },
  {
    name: "set_done",
    title: "完了・未完了にする",
    description: "タスクを完了（done=true）または未完了に戻す。複数まとめて渡せる。",
    inputSchema: { type: "object", properties: { ids: IDS, done: { type: "boolean" } }, required: ["ids", "done"] },
    run: ({ ids, done }, { records, book, now }) => {
      const writer = new Writer(records, "claude", now.getTime());
      for (const id of ids as string[]) writer.set(`task_${find(book, id).id}`, { completedAt: done ? nowISO(now) : null });
      return { result: { updated: ids.length }, changes: writer.changes };
    },
  },
  {
    name: "remove_tasks",
    title: "タスクを消す",
    description: "タスクを削除する。終わったものは消さずに set_done。消すのは間違えて入れたときだけ。先に本人に確認する。",
    inputSchema: { type: "object", properties: { ids: IDS }, required: ["ids"] },
    run: ({ ids }, { records, book, now }) => {
      const writer = new Writer(records, "claude", now.getTime());
      for (const id of ids as string[]) writer.set(`task_${find(book, id).id}`, { alive: false });
      return { result: { removed: ids.length }, changes: writer.changes };
    },
  },
  {
    name: "get_routines",
    title: "ルーティンを読む",
    description: "ルーティン（くり返しの予定）の一覧。weekdays は 1=日曜〜7=土曜。isBlock は睡眠・仕事など時間を押さえるだけのもの。",
    inputSchema: { type: "object", properties: {} },
    run: (_, { book }) => ({ result: book.routines.map(({ doneDays, ...r }) => ({ ...r, recentDone: doneDays.slice(-14) })) }),
  },
  {
    name: "check_routine",
    title: "ルーティンにチェックする",
    description: "ルーティンのある日をやった（done=true）／やっていないにする。date はその回の元の日（get_today の originalDay）。",
    inputSchema: {
      type: "object",
      properties: { id: { type: "string" }, date: DATE, done: { type: "boolean" } },
      required: ["id", "date", "done"],
    },
    run: ({ id, date, done }, { records, book, now }) => {
      validDate(date);
      const routine = book.routines.find((r) => r.id.toUpperCase() === String(id).toUpperCase());
      if (!routine) throw new Error(`ルーティンが見つかりません: ${id}`);
      if (routine.isBlock) throw new Error("時間を押さえるだけのルーティンにはチェックを付けません。");
      const writer = new Writer(records, "claude", now.getTime());
      writer.set(`routine_${routine.id}`, { [`done.${date}`]: done ? true : null });
      return { result: { changed: true }, changes: writer.changes };
    },
  },
  {
    name: "get_board",
    title: "ボードを読む",
    description:
      "ボードのカード（やり方の書き置き）を全部返す。各カードは title・purpose（なぜ）・goal（どうなったら終わり）・detail（手順）。" +
      "タスクやルーティンの project とカードの title が同じ（片方に含まれる）ものは結びついている。進め方を聞かれたら、まずここを見る。",
    inputSchema: { type: "object", properties: {} },
    run: (_, { book }) => ({ result: book.cards.map(({ rank: _, ...c }) => c) }),
  },
  {
    name: "set_board_card",
    title: "カードを書く",
    description: "カードを1枚足す（id なし）か直す（id あり）。渡した欄だけ変わる。新しいカードは一覧の先頭に入る。",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string" }, title: { type: "string" }, purpose: { type: "string" },
        goal: { type: "string" }, detail: { type: "string" },
      },
    },
    run: (args, { records, book, now }) => {
      const writer = new Writer(records, "claude", now.getTime());
      const values: Args = {};
      for (const key of ["title", "purpose", "goal", "detail"]) if (args[key] !== undefined) values[key] = String(args[key]);
      if (values.title !== undefined && !values.title.trim()) throw new Error("見出しは空にできません。");
      if (args.id) {
        const card = book.cards.find((c) => c.id.toUpperCase() === String(args.id).toUpperCase());
        if (!card) throw new Error(`カードが見つかりません: ${args.id}`);
        writer.set(`card_${card.id}`, values);
        return { result: { changed: true, id: card.id }, changes: writer.changes };
      }
      if (!values.title) throw new Error("新しいカードには title が必要です。");
      const id = newID();
      const top = Math.min(0, ...book.cards.map((c) => c.rank)) - 1;
      writer.set(`card_${id}`, {
        alive: true, id, title: values.title.trim(), purpose: values.purpose ?? "", goal: values.goal ?? "",
        detail: values.detail ?? "", createdAt: nowISO(now), rank: top,
      });
      return { result: { added: id }, changes: writer.changes };
    },
  },
  {
    name: "add_idea",
    title: "アイデアを書き留める",
    description: "アイデア（まだタスクにしない思いつき）を足す。",
    inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] },
    run: ({ text }, { records, now }) => {
      const value = String(text ?? "").trim();
      if (!value) throw new Error("text が空です。");
      const writer = new Writer(records, "claude", now.getTime());
      const id = newID();
      writer.set(`idea_${id}`, { alive: true, id, text: value, createdAt: nowISO(now) });
      return { result: { added: id }, changes: writer.changes };
    },
  },
];

export const instructions =
  "Horme（本人のタスク管理アプリ）の中身を読み書きする。今日の時間割・タスク・ルーティン・ボード（やり方の書き置き）・アイデアがある。" +
  "日付は日本時間。書き換える前に get_today / get_days で id と現状を確かめる。" +
  "handoff は本人が「Claude にやってほしい」と残した依頼で、対応したら memo に結果を書いて handoff を空にする。" +
  "変更はアプリと iCloud に数十秒以内に反映される。本人が決めること（必須にする・消す・ルーティンを作る）は勝手にしない。";

/** Minimal MCP over HTTP (JSON responses, no sessions), enough for Claude's custom connectors. */
export async function handleMcp(message: any, store: RecordStore, now = new Date()): Promise<any | null> {
  const reply = (result: unknown) => ({ jsonrpc: "2.0", id: message.id, result });
  const fail = (code: number, text: string) => ({ jsonrpc: "2.0", id: message.id ?? null, error: { code, message: text } });
  if (!message || message.jsonrpc !== "2.0" || typeof message.method !== "string") return fail(-32600, "invalid request");
  if (message.id === undefined || message.id === null) return null; // notifications need no reply
  switch (message.method) {
    case "initialize":
      return reply({
        protocolVersion: message.params?.protocolVersion ?? "2025-06-18",
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: "horme", version: "1.0.0" },
        instructions,
      });
    case "ping":
      return reply({});
    case "tools/list":
      return reply({
        tools: tools.map(({ name, title, description, inputSchema }) => ({ name, title, description, inputSchema })),
      });
    case "tools/call": {
      const tool = tools.find((t) => t.name === message.params?.name);
      if (!tool) return fail(-32602, `unknown tool ${message.params?.name}`);
      try {
        const records = await store.load();
        const { result, changes } = tool.run(message.params?.arguments ?? {}, { records, book: materialize(records), now });
        if (changes?.length) await store.merge(changes);
        return reply({ content: [{ type: "text", text: JSON.stringify(result, null, 1) }] });
      } catch (e) {
        return reply({ isError: true, content: [{ type: "text", text: String((e as Error).message ?? e) }] });
      }
    }
    default:
      return fail(-32601, `method not found: ${message.method}`);
  }
}

export { isAlive };
