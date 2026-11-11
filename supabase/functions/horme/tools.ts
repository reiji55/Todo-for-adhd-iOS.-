// Horme's MCP tools. Each call reads the records, writes only the fields it changes (stamped as "claude"),
// and lets the database merge them, so the app's own edits made at the same time survive.

import { addDays, agenda, dayKey, dayToISO, isAlive, listProgress, materialize, newID, nowISO, piecesOf, taskItem, todayKey, Writer } from "./records.ts";
import type { Book, ListItem, Milestone, Project, StockList, SyncRecord, Task } from "./records.ts";

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

function validWeekdays(value: unknown): number[] | undefined {
  if (value === undefined || value === null) return undefined;
  if (!Array.isArray(value) || !value.length || !value.every((d) => Number.isInteger(d) && d >= 1 && d <= 7)) {
    throw new Error("weekdays は 1（日曜）〜7（土曜）の数の配列で渡してください。");
  }
  return [...new Set(value as number[])].sort();
}

function findProject(book: Book, id: string): Project {
  const project = book.projects.find((p) => p.id.toUpperCase() === String(id).toUpperCase());
  if (!project) throw new Error(`プロジェクトが見つかりません: ${id}。先に get_projects で id を確かめてください。`);
  return project;
}

/** How far a checkpoint has come, as the app counts it. */
function progress(book: Book, project: Project, m: Milestone) {
  const linked = book.tasks.filter((t: any) => sameID(t.milestoneID, m.id));
  const routines = book.routines.filter((r: any) => sameID(r.milestoneID, m.id));
  switch (m.kind) {
    case "check": return { done: m.isDone };
    case "number": return { current: m.current, target: m.target, unit: m.unit, done: m.current >= m.target };
    case "count": {
      const count = m.current + linked.filter((t) => t.completedAt).length + routines.reduce((n, r) => n + r.doneDays.length, 0);
      return { current: count, target: m.target, unit: m.unit, done: count >= m.target };
    }
    case "tasks": {
      const done = linked.filter((t) => t.completedAt).length;
      return { current: done, target: linked.length, done: linked.length > 0 && done === linked.length };
    }
  }
}

const sameKey = (a: string, b: string) => a.replace(/\s+/g, "").toLowerCase() === b.replace(/\s+/g, "").toLowerCase();

const sameID = (a: string | null | undefined, b: string) => !!a && a.toUpperCase() === b.toUpperCase();
const hasPieces = (book: Book, t: Task) => book.tasks.some((k) => sameID(k.parentID, t.id));

/** The first day among a parent's open pieces. */
function firstPieceDay(book: Book, t: Task): string | undefined {
  const days = piecesOf(book, t.id).filter((p) => !p.completedAt && p.plannedAt).map((p) => dayKey(p.plannedAt!));
  return days.sort()[0];
}

/** After pieces change, a parent is done exactly when all its (remaining) pieces are. */
function settle(writer: Writer, book: Book, parentID: string, done: Map<string, boolean>, removed: Set<string>, now: Date) {
  const parent = book.tasks.find((t) => sameID(t.id, parentID));
  if (!parent || removed.has(parent.id.toUpperCase())) return;
  const kids = piecesOf(book, parent.id).filter((k) => !removed.has(k.id.toUpperCase()));
  if (!kids.length) return;
  const all = kids.every((k) => done.get(k.id.toUpperCase()) ?? !!k.completedAt);
  const was = done.get(parent.id.toUpperCase()) ?? !!parent.completedAt;
  if (all && !was) writer.set(`task_${parent.id}`, { completedAt: nowISO(now) });
  if (!all && was) writer.set(`task_${parent.id}`, { completedAt: null });
}

function findList(book: Book, id: string): StockList {
  const list = book.lists.find((l) => sameID(l.id, id));
  if (!list) throw new Error(`リストが見つかりません: ${id}。先に get_lists で id を確かめてください。`);
  return list;
}

function findItem(book: Book, id: string): ListItem {
  const item = book.items.find((i) => sameID(i.id, id));
  if (!item) throw new Error(`リストの項目が見つかりません: ${id}。先に get_lists で id を確かめてください。`);
  return item;
}

/** Mirrors Notebook.setItemDone in Lists.swift. A trip made from the whole list is done when the last open
 *  thing is checked off, and opens again if that check is undone. `doneNow` carries this batch's checks. */
function checkItem(writer: Writer, book: Book, item: ListItem, done: boolean, now: Date, doneNow: Map<string, string | null>) {
  const previous = doneNow.has(item.id.toUpperCase()) ? doneNow.get(item.id.toUpperCase()) : item.doneAt ?? null;
  if (!!previous === done) return;
  const stamp = done ? nowISO(now) : null;
  writer.set(`item_${item.id}`, { doneAt: stamp });
  doneNow.set(item.id.toUpperCase(), stamp);
  const trips = book.tasks.filter((t) => sameID(t.listID, item.listID));
  if (done) {
    const open = book.items.some((i) => sameID(i.listID, item.listID)
      && !(doneNow.has(i.id.toUpperCase()) ? doneNow.get(i.id.toUpperCase()) : i.doneAt));
    if (open) return;
    for (const t of trips) if (!t.completedAt && t.createdAt <= stamp!) writer.set(`task_${t.id}`, { completedAt: stamp });
  } else if (previous) {
    for (const t of trips) if (t.completedAt === previous) writer.set(`task_${t.id}`, { completedAt: null });
  }
}

function listView(book: Book, list: StockList, history: boolean) {
  const mine = book.items.filter((i) => sameID(i.listID, list.id));
  const plan = (item: ListItem) => {
    const t = book.tasks.filter((t) => sameID(t.listItemID, item.id) && !t.completedAt)
      .sort((a, b) => (a.plannedAt ?? "9999").localeCompare(b.plannedAt ?? "9999"))[0];
    return t ? { id: t.id, kind: t.isEvent ? "event" : "task", date: t.plannedAt ? dayKey(t.plannedAt) : "anytime" } : undefined;
  };
  const brief = (item: ListItem) => ({
    id: item.id, title: item.title, memo: item.memo || undefined, link: item.link || undefined, place: item.place || undefined,
    plan: plan(item),
  });
  const trip = book.tasks.find((t) => sameID(t.listID, list.id) && !t.completedAt);
  const done = mine.filter((i) => i.doneAt).sort((a, b) => b.doneAt!.localeCompare(a.doneAt!));
  return {
    id: list.id, name: list.name,
    open: mine.filter((i) => !i.doneAt).map(brief),
    trip: trip ? { id: trip.id, date: trip.plannedAt ? dayKey(trip.plannedAt) : "anytime", ...listProgress(book, trip) } : undefined,
    doneCount: done.length,
    done: history ? done.slice(0, 30).map((i) => ({ id: i.id, title: i.title, doneDay: dayKey(i.doneAt!) })) : undefined,
  };
}

function day(book: Book, key: string) {
  return { date: key, items: agenda(book, key) };
}

function leftovers(book: Book, today: string) {
  return book.tasks.filter((t) => !t.completedAt && !t.isEvent && t.plannedAt && dayKey(t.plannedAt) < today)
    .map((t) => ({ ...taskItem(t, book), plannedDay: dayKey(t.plannedAt!) }));
}

/** Mirrors Notebook.projectDeadline: a top-level task without its own deadline goes by its project's. */
function projectDeadline(book: Book, t: Task): string | undefined {
  if (t.deadline || t.parentID || t.isEvent || !t.project) return undefined;
  return book.projects.find((p) => sameKey(p.name, t.project))?.deadline ?? undefined;
}

/** Due today or earlier and not planned for today (those are already in today's list). ★ alone never
 * makes a task due: it marks what cannot be dropped, as in the app. A task without its own deadline goes by
 * its project's (marked `projectDeadline`). */
function required(book: Book, today: string) {
  return book.tasks.filter((t) => {
    if (t.completedAt || t.isEvent || (t.plannedAt && dayKey(t.plannedAt) === today)) return false;
    // A task in pieces with a piece today is already in today's list.
    if (hasPieces(book, t) && firstPieceDay(book, t) === today) return false;
    const due = t.deadline ?? projectDeadline(book, t);
    return due ? dayKey(due) <= today : false;
  }).map((t) => {
    const fromProject = projectDeadline(book, t);
    return fromProject ? { ...taskItem(t, book), deadline: dayKey(fromProject), projectDeadline: true } : taskItem(t, book);
  });
}

/** ★ tasks still open and not due yet, nearest deadline first: kept together below today's plan in the app. */
function musts(book: Book, today: string) {
  return book.tasks.filter((t) => t.isMust && !t.completedAt && !t.isEvent && !t.parentID
    && !(t.deadline && dayKey(t.deadline) <= today))
    .sort((a, b) => (a.deadline ? dayKey(a.deadline) : "9999").localeCompare(b.deadline ? dayKey(b.deadline) : "9999"))
    .map((t) => taskItem(t, book));
}

export const tools: Tool[] = [
  {
    name: "get_today",
    title: "今日を読む",
    description:
      "今日の時間割（タスク・イベント・ルーティン、時刻順。kind で見分ける）、今日中に必要なもの（締切が今日・過ぎたもので今日の予定に入っていないもの）、" +
      "必須（★＝本人が落とせないと決めたもの。締切が来るまでは今日に割り込まない。締切の近い順）、前の日から残っているタスクを返す。各項目の id を他のツールに渡す。書き換える前にまずこれを呼ぶ。" +
      "handoff は本人が「Claude にやってほしい」と書き残した依頼。held はルーティンのうち睡眠・仕事など時間を押さえているだけのもの。",
    inputSchema: { type: "object", properties: {} },
    run: (_, { book, now }) => {
      const today = todayKey(now);
      return { result: { ...day(book, today), required: required(book, today), musts: musts(book, today), leftovers: leftovers(book, today) } };
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
    description: "日付を決めていない未完了のタスク（「いつでも」）を返す。子タスクは parent に親が入る（親タスク自体は日付を持たないので、get_task で読む）。",
    inputSchema: { type: "object", properties: {} },
    run: (_, { book }) => ({
      result: book.tasks.filter((t) => !t.completedAt && !t.isEvent && !t.plannedAt && !hasPieces(book, t)).map((t) => taskItem(t, book)),
    }),
  },
  {
    name: "get_task",
    title: "タスクを1つ詳しく読む",
    description: "1つのタスクを読む。子タスクに分かれたタスク（親）なら pieces に子タスクが順に入る。子タスクなら parent に親が入る。",
    inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] },
    run: ({ id }, { book }) => ({ result: taskItem(find(book, id), book) }),
  },
  {
    name: "add_tasks",
    title: "タスク・イベントを足す",
    description:
      "タスクかイベントを追加する。date を省くと今日、\"anytime\" で日付なし（タスクのみ）。同じものを二重に足さないよう、先に get_today / get_days で確認する。" +
      "kind=\"event\" はその日にある予定（買い物、人に会う）で、必須や締切はなく、やり残しにもならない。くり返すものは add_routine でルーティンにする。" +
      "parent にタスクの id を渡すと、そのタスクの子タスクとして足す（子タスクの date を省くと日付なし。ただし最初の子タスクは親の日付と時間を引き継ぎ、親は締切と必須だけを持つ形になる）。",
    inputSchema: {
      type: "object",
      properties: {
        tasks: {
          type: "array", minItems: 1,
          items: {
            type: "object",
            properties: {
              title: { type: "string" }, date: DATE, time: TIME, project: { type: "string" },
              kind: { type: "string", enum: ["task", "event"], description: "task（既定）か event" },
              must: { type: "boolean", description: "本人が必須と決めたものだけ true（タスクのみ）" },
              deadline: { type: "string", description: "締切 YYYY-MM-DD" },
              memo: { type: "string", description: "本人用のメモ" },
              handoff: { type: "string", description: "Claude への引き継ぎ" },
              parent: { type: "string", description: "子タスクにするときの親タスクの id" },
              from_item: { type: "string", description: "リストの項目から予定にするときのその項目の id。予定が済むと項目は履歴に移る" },
              from_list: { type: "string", description: "リスト全体をチェックしながら進めるタスク（買い物など）にするときのリストの id。全部チェックすると完了（タスクのみ）" },
            },
            required: ["title"],
          },
        },
      },
      required: ["tasks"],
    },
    run: ({ tasks }, { records, book, now }) => {
      const writer = new Writer(records, "claude", now.getTime());
      const added: string[] = [];
      const newPieces = new Map<string, number>();
      for (const input of tasks as Args[]) {
        const title = String(input.title ?? "").trim();
        if (!title) throw new Error("title が空のタスクがあります。");
        const parent = input.parent ? find(book, input.parent) : undefined;
        const isEvent = input.kind === "event";
        if (parent) {
          if (parent.parentID) throw new Error("子タスクの下に子タスクは作れません。親タスクの id を渡してください。");
          if (parent.isEvent || isEvent) throw new Error("イベントには子タスクを作れません。");
        }
        const earlier = parent ? piecesOf(book, parent.id) : [];
        const count = parent ? (newPieces.get(parent.id) ?? 0) : 0;
        const first = !!parent && earlier.length === 0 && count === 0;
        // A piece without a date has none, except the first, which takes over its parent's day and time.
        let date = input.date ?? (parent ? (first && parent.plannedAt ? dayKey(parent.plannedAt) : "anytime") : todayKey(now));
        let time = input.time ?? (first && parent && input.date === undefined ? parent.scheduledTime ?? "" : "");
        validDate(date); validTime(time);
        if (isEvent && date === "anytime") throw new Error("イベントには日付が必要です。");
        if (input.deadline) validDate(input.deadline);
        const item = input.from_item ? findItem(book, input.from_item) : undefined;
        const list = input.from_list ? findList(book, input.from_list) : undefined;
        if (list && (isEvent || parent)) throw new Error("リスト全体からはタスク（子タスクでないもの）だけを作れます。");
        const id = newID();
        const values: Args = {
          alive: true, id, title, scheduledTime: date === "anytime" ? "" : String(time).trim(),
          isMust: isEvent || parent ? false : !!input.must, isEvent, effort: "medium",
          project: parent ? parent.project ?? "" : input.project ?? "", memo: input.memo ?? item?.memo ?? "",
          handoff: input.handoff ?? "", resumeNote: "", createdAt: nowISO(now), notify: true,
        };
        if (date !== "anytime") values.plannedAt = dayToISO(date);
        if (item) values.listItemID = item.id;
        if (list) values.listID = list.id;
        if (!isEvent && !parent && input.deadline && input.deadline !== "anytime") values.deadline = dayToISO(input.deadline);
        if (parent) {
          values.parentID = parent.id;
          values.rank = Math.max(-1, ...earlier.map((p) => p.rank ?? 0)) + 1 + count;
          newPieces.set(parent.id, count + 1);
          const parentValues: Args = {};
          if (first) Object.assign(parentValues, { plannedAt: null, scheduledTime: "" });
          if (parent.completedAt) parentValues.completedAt = null;
          if (Object.keys(parentValues).length) writer.set(`task_${parent.id}`, parentValues);
        }
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
      "タスクやイベントの名前・日付・時間帯・プロジェクト・必須・締切・メモ・引き継ぎ・種類を書き換える。渡した欄だけ変わる。" +
      'date="anytime" で日付と時間を外す。引き継ぎ（handoff）は対応したら memo に何をしたか書いてから空にする。',
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string" }, title: { type: "string" }, date: DATE, time: TIME, project: { type: "string" },
        must: { type: "boolean" }, deadline: { type: "string", description: 'YYYY-MM-DD、空文字で締切を外す' },
        memo: { type: "string" }, handoff: { type: "string" },
        kind: { type: "string", enum: ["task", "event"], description: "種類を変える。event にすると必須と締切は外れる" },
      },
      required: ["id"],
    },
    run: (args, { records, book, now }) => {
      const task = find(book, args.id);
      if (hasPieces(book, task) && (args.date !== undefined || args.time !== undefined || args.kind === "event")) {
        throw new Error("子タスクに分かれたタスクには日付がありません。子タスクの日付を変えてください（get_task で子タスクの id がわかります）。");
      }
      if (task.parentID && (args.must !== undefined || args.deadline !== undefined || args.project !== undefined || args.kind === "event")) {
        throw new Error("子タスクには必須・締切・プロジェクトはありません（親タスクのものを使います）。");
      }
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
      if (args.kind !== undefined) values.isEvent = args.kind === "event";
      if (args.kind !== undefined ? args.kind === "event" : task.isEvent) {
        const planned = "plannedAt" in values ? values.plannedAt : task.plannedAt;
        if (!planned) throw new Error("イベントには日付が必要です。");
        for (const key of ["isMust", "deadline"]) delete values[key];
        if (args.kind === "event") Object.assign(values, { isMust: false, deadline: null });
      }
      if (!Object.keys(values).length) return { result: { changed: false } };
      writer.set(`task_${task.id}`, values);
      return { result: { changed: true, id: task.id }, changes: writer.changes };
    },
  },
  {
    name: "set_done",
    title: "完了・未完了にする",
    description:
      "タスクを完了（done=true）または未完了に戻す。イベントには「済んだ」印として付く。複数まとめて渡せる。" +
      "子タスクがすべて済むと親タスクも完了になる。親タスクを完了にすると残りの子タスクもまとめて完了になる。",
    inputSchema: { type: "object", properties: { ids: IDS, done: { type: "boolean" } }, required: ["ids", "done"] },
    run: ({ ids, done }, { records, book, now }) => {
      const writer = new Writer(records, "claude", now.getTime());
      const state = new Map<string, boolean>();
      const parents = new Set<string>();
      for (const id of ids as string[]) {
        const task = find(book, id);
        const pieces = piecesOf(book, task.id);
        if (pieces.length) {
          if (done) {
            for (const p of pieces) if (!p.completedAt) { writer.set(`task_${p.id}`, { completedAt: nowISO(now) }); state.set(p.id.toUpperCase(), true); }
          } else if (task.completedAt) {
            // Reopen the pieces finished together with it, or else the last one finished.
            const together = pieces.filter((p) => p.completedAt === task.completedAt);
            const last = [...pieces].filter((p) => p.completedAt).sort((a, b) => b.completedAt!.localeCompare(a.completedAt!))[0];
            for (const p of together.length ? together : last ? [last] : []) {
              writer.set(`task_${p.id}`, { completedAt: null }); state.set(p.id.toUpperCase(), false);
            }
          }
        }
        writer.set(`task_${task.id}`, { completedAt: done ? nowISO(now) : null });
        state.set(task.id.toUpperCase(), !!done);
        if (task.parentID) parents.add(task.parentID);
      }
      for (const parent of parents) settle(writer, book, parent, state, new Set(), now);
      // Mirrors Notebook.settleListItems: a thing a plan was made from follows it into the list's history.
      for (const [key, isDone] of state) {
        const task = book.tasks.find((t) => t.id.toUpperCase() === key);
        const item = task?.listItemID ? book.items.find((i) => sameID(i.id, task.listItemID!)) : undefined;
        if (!task || !item || isDone === !!task.completedAt) continue;
        if (isDone && !item.doneAt) writer.set(`item_${item.id}`, { doneAt: nowISO(now) });
        if (!isDone && item.doneAt && item.doneAt === task.completedAt) writer.set(`item_${item.id}`, { doneAt: null });
      }
      return { result: { updated: ids.length }, changes: writer.changes };
    },
  },
  {
    name: "remove_tasks",
    title: "タスクを消す",
    description: "タスクを削除する。親タスクを消すと子タスクも消える。終わったものは消さずに set_done。消すのは間違えて入れたときだけ。先に本人に確認する。",
    inputSchema: { type: "object", properties: { ids: IDS }, required: ["ids"] },
    run: ({ ids }, { records, book, now }) => {
      const writer = new Writer(records, "claude", now.getTime());
      const removed = new Set<string>();
      const parents = new Set<string>();
      for (const id of ids as string[]) {
        const task = find(book, id);
        for (const t of [task, ...piecesOf(book, task.id)]) { writer.set(`task_${t.id}`, { alive: false }); removed.add(t.id.toUpperCase()); }
        if (task.parentID) parents.add(task.parentID);
      }
      for (const parent of parents) settle(writer, book, parent, new Map(), removed, now);
      return { result: { removed: ids.length }, changes: writer.changes };
    },
  },
  {
    name: "add_routine",
    title: "ルーティンを作る",
    description:
      "くり返しの予定（ルーティン）を作る。weekdays は 1=日曜〜7=土曜（省くと毎日）、time は時間帯 \"19:00-20:30\"（省くと時間なし）。" +
      "held=true は睡眠・仕事など時間を押さえるだけのもの（チェックも通知もない）。本人に頼まれたときに作る。",
    inputSchema: {
      type: "object",
      properties: {
        title: { type: "string" }, time: TIME, project: { type: "string" }, memo: { type: "string" },
        weekdays: { type: "array", items: { type: "integer", minimum: 1, maximum: 7 }, description: "1=日曜〜7=土曜" },
        held: { type: "boolean", description: "時間を押さえるだけ（睡眠・仕事）" },
        notify: { type: "boolean", description: "通知する（既定は true）" },
      },
      required: ["title"],
    },
    run: (args, { records, now }) => {
      const title = String(args.title ?? "").trim();
      if (!title) throw new Error("title が空です。");
      const time = String(args.time ?? "").trim();
      validTime(time);
      const weekdays = validWeekdays(args.weekdays) ?? [1, 2, 3, 4, 5, 6, 7];
      const held = !!args.held;
      const writer = new Writer(records, "claude", now.getTime());
      const id = newID();
      writer.set(`routine_${id}`, {
        alive: true, id, title, project: String(args.project ?? ""), memo: String(args.memo ?? ""), weekdays, time,
        notify: held ? false : args.notify !== false, isBlock: held, isPaused: false, createdAt: nowISO(now),
      });
      return { result: { added: id }, changes: writer.changes };
    },
  },
  {
    name: "update_routine",
    title: "ルーティンを直す",
    description: "ルーティンの名前・曜日・時間帯・プロジェクト・メモ・通知・一時停止（paused）を書き換える。渡した欄だけ変わる。やめるときは paused=true（記録は残る）。",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string" }, title: { type: "string" }, time: TIME, project: { type: "string" }, memo: { type: "string" },
        weekdays: { type: "array", items: { type: "integer", minimum: 1, maximum: 7 } },
        notify: { type: "boolean" }, paused: { type: "boolean" },
      },
      required: ["id"],
    },
    run: (args, { records, book, now }) => {
      const routine = book.routines.find((r) => r.id.toUpperCase() === String(args.id).toUpperCase());
      if (!routine) throw new Error(`ルーティンが見つかりません: ${args.id}`);
      const values: Args = {};
      if (args.title !== undefined) {
        if (!String(args.title).trim()) throw new Error("名前は空にできません。");
        values.title = String(args.title).trim();
      }
      if (args.time !== undefined) { validTime(String(args.time)); values.time = String(args.time).trim(); }
      if (args.weekdays !== undefined) values.weekdays = validWeekdays(args.weekdays) ?? routine.weekdays;
      for (const key of ["project", "memo"]) if (args[key] !== undefined) values[key] = String(args[key]);
      if (args.notify !== undefined) values.notify = !!args.notify;
      if (args.paused !== undefined) values.isPaused = !!args.paused;
      if (!Object.keys(values).length) return { result: { changed: false } };
      const writer = new Writer(records, "claude", now.getTime());
      writer.set(`routine_${routine.id}`, values);
      return { result: { changed: true, id: routine.id }, changes: writer.changes };
    },
  },
  {
    name: "get_projects",
    title: "プロジェクトを読む",
    description:
      "プロジェクトの一覧。goal は到達点、deadline は期限、overview は概要、milestones は途中の到達点（チェックポイント）を順に。" +
      "kind は check（できたら印）・count（○回やる）・number（数値を目指す）・tasks（つないだタスクの完了数）。" +
      "タスク・ルーティン・カードは project の名前でプロジェクトにつながる（openTasks に未完了のタスク）。",
    inputSchema: { type: "object", properties: {} },
    run: (_, { book }) => ({
      result: book.projects.map((p) => ({
        id: p.id, name: p.name, goal: p.goal, deadline: p.deadline ? dayKey(p.deadline) : undefined, overview: p.overview || undefined,
        milestones: p.milestones.map((m) => ({
          id: m.id, title: m.title, kind: m.kind, due: m.dueDate ? dayKey(m.dueDate) : undefined, ...progress(book, p, m),
        })),
        openTasks: book.tasks.filter((t) => !t.completedAt && !t.isEvent && !t.parentID && sameKey(t.project ?? "", p.name))
          .map((t) => ({ id: t.id, title: t.title })),
      })),
    }),
  },
  {
    name: "set_project",
    title: "プロジェクトを作る・直す",
    description:
      "プロジェクトを作る（id なし、name 必須）か直す（id あり）。渡した欄だけ変わる。deadline は YYYY-MM-DD、空文字で外す。" +
      "名前を変えると、その名前でつながっているタスク・ルーティン・カードの project も新しい名前に移す。本人に頼まれたときに行う。",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string" }, name: { type: "string" }, goal: { type: "string", description: "到達点" },
        deadline: { type: "string", description: "期限 YYYY-MM-DD、空文字で外す" }, overview: { type: "string", description: "概要" },
      },
    },
    run: (args, { records, book, now }) => {
      const writer = new Writer(records, "claude", now.getTime());
      const values: Args = {};
      if (args.name !== undefined) {
        if (!String(args.name).trim()) throw new Error("名前は空にできません。");
        values.name = String(args.name).trim();
      }
      for (const key of ["goal", "overview"]) if (args[key] !== undefined) values[key] = String(args[key]);
      if (args.deadline !== undefined) {
        if (args.deadline) validDate(args.deadline);
        values.deadline = args.deadline ? dayToISO(args.deadline) : null;
      }
      if (args.id) {
        const project = findProject(book, args.id);
        if (values.name && book.projects.some((p) => p.id !== project.id && sameKey(p.name, values.name))) {
          throw new Error(`「${values.name}」という名前のプロジェクトがすでにあります。`);
        }
        if (!Object.keys(values).length) return { result: { changed: false } };
        writer.set(`project_${project.id}`, values);
        if (values.name && values.name !== project.name) {
          for (const t of book.tasks) if (sameKey(t.project ?? "", project.name)) writer.set(`task_${t.id}`, { project: values.name });
          for (const r of book.routines) if (sameKey(r.project ?? "", project.name)) writer.set(`routine_${r.id}`, { project: values.name });
          for (const c of book.cards as any[]) if (sameKey(c.project ?? "", project.name)) writer.set(`card_${c.id}`, { project: values.name });
        }
        return { result: { changed: true, id: project.id }, changes: writer.changes };
      }
      if (!values.name) throw new Error("新しいプロジェクトには name が必要です。");
      if (book.projects.some((p) => sameKey(p.name, values.name))) throw new Error(`「${values.name}」という名前のプロジェクトがすでにあります。`);
      const id = newID();
      writer.set(`project_${id}`, { alive: true, id, goal: "", overview: "", origin: "", createdAt: nowISO(now), ...values });
      return { result: { added: id }, changes: writer.changes };
    },
  },
  {
    name: "set_milestone",
    title: "途中の到達点を足す・直す",
    description:
      "プロジェクトの途中の到達点（チェックポイント）を足す（milestone なし、title 必須、最後に入る）か直す（milestone に id）。" +
      "kind は check・count・number・tasks（既定 check）。target は目標の数、current は number なら今の値・count なら手で数えた分。" +
      "done は check の完了、due は YYYY-MM-DD（空文字で外す）。remove=true で消す。本人に頼まれたときに行う。",
    inputSchema: {
      type: "object",
      properties: {
        project: { type: "string", description: "プロジェクトの id" }, milestone: { type: "string", description: "直すときの id" },
        title: { type: "string" }, kind: { type: "string", enum: ["check", "count", "number", "tasks"] },
        target: { type: "number" }, current: { type: "number" }, unit: { type: "string" },
        done: { type: "boolean" }, due: { type: "string" }, remove: { type: "boolean" },
      },
      required: ["project"],
    },
    run: (args, { records, book, now }) => {
      const project = findProject(book, args.project);
      const writer = new Writer(records, "claude", now.getTime());
      if (args.due) validDate(args.due);
      const existing = args.milestone ? project.milestones.find((m) => sameID(m.id, args.milestone)) : undefined;
      if (args.milestone && !existing) throw new Error(`途中の到達点が見つかりません: ${args.milestone}`);
      if (existing && args.remove) {
        writer.set(`project_${project.id}`, { [`ms.${existing.id}`]: null });
        for (const t of book.tasks as any[]) if (sameID(t.milestoneID, existing.id)) writer.set(`task_${t.id}`, { milestoneID: null });
        for (const r of book.routines as any[]) if (sameID(r.milestoneID, existing.id)) writer.set(`routine_${r.id}`, { milestoneID: null });
        return { result: { removed: existing.id }, changes: writer.changes };
      }
      const base: Milestone = existing ?? {
        id: newID(), title: "", kind: "check", target: 1, current: 0, unit: "", isDone: false, createdAt: nowISO(now),
        rank: Math.max(-1, ...project.milestones.map((m) => m.rank)) + 1,
      };
      const next: Milestone = { ...base };
      if (args.title !== undefined) next.title = String(args.title).trim();
      if (!next.title) throw new Error("title が空です。");
      if (args.kind !== undefined) next.kind = args.kind;
      if (args.target !== undefined) next.target = Number(args.target);
      if (args.current !== undefined) next.current = Number(args.current);
      if (args.unit !== undefined) next.unit = String(args.unit);
      if (args.done !== undefined) next.isDone = !!args.done;
      if (args.due !== undefined) next.dueDate = args.due ? dayToISO(args.due) : null;
      const { dueDate, ...rest } = next;
      writer.set(`project_${project.id}`, { [`ms.${next.id}`]: dueDate ? { ...rest, dueDate } : rest });
      return { result: existing ? { changed: true, id: next.id } : { added: next.id }, changes: writer.changes };
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
    name: "get_lists",
    title: "リストを読む",
    description:
      "ストックのリスト（行きたいところ・読みたい本・買うものなど、予定ではない具体的なもののストック）を読む。" +
      "open にまだの項目、plan にその項目から作った予定、trip にリスト全体から作ったタスク（買い物など）とチェックの進み具合が入る。" +
      "list に id を渡すと、そのリストの済んだ項目（履歴）も入る。",
    inputSchema: { type: "object", properties: { list: { type: "string", description: "履歴まで読みたいリストの id" } } },
    run: ({ list }, { book }) => ({
      result: { lists: book.lists.map((l) => listView(book, l, !!list && sameID(l.id, list))) },
    }),
  },
  {
    name: "add_list_items",
    title: "リストに項目を足す",
    description:
      "リストに項目を足す。list にリストの id、または new_list に新しいリストの名前（同じ名前のリストがあればそこに足す）。" +
      "項目は title（必須）と memo・link（URL）・place（店名や住所）。同じものを二重に足さないよう、先に get_lists で確認する。",
    inputSchema: {
      type: "object",
      properties: {
        list: { type: "string" }, new_list: { type: "string" },
        items: {
          type: "array", minItems: 1,
          items: {
            type: "object",
            properties: { title: { type: "string" }, memo: { type: "string" }, link: { type: "string" }, place: { type: "string" } },
            required: ["title"],
          },
        },
      },
      required: ["items"],
    },
    run: ({ list, new_list, items }, { records, book, now }) => {
      const writer = new Writer(records, "claude", now.getTime());
      let target: StockList | undefined = list ? findList(book, list) : undefined;
      let created = false;
      if (!target) {
        const name = String(new_list ?? "").trim();
        if (!name) throw new Error("list（リストの id）か new_list（新しいリストの名前）を渡してください。");
        target = book.lists.find((l) => sameKey(l.name, name));
        if (!target) {
          target = { id: newID(), name, createdAt: nowISO(now) };
          writer.set(`list_${target.id}`, { alive: true, ...target });
          created = true;
        }
      }
      const added: string[] = [];
      (items as Args[]).forEach((input, index) => {
        const title = String(input.title ?? "").trim();
        if (!title) throw new Error("title が空の項目があります。");
        const id = newID();
        // A second apart keeps them in the order given (the app reads whole seconds).
        writer.set(`item_${id}`, {
          alive: true, id, listID: target!.id, title, memo: String(input.memo ?? ""), link: String(input.link ?? "").trim(),
          place: String(input.place ?? "").trim(), createdAt: nowISO(new Date(now.getTime() + index * 1000)),
        });
        added.push(id);
      });
      return { result: { list: target.id, createdList: created || undefined, added }, changes: writer.changes };
    },
  },
  {
    name: "update_list_item",
    title: "リストの項目を直す・消す",
    description:
      "リストの項目の名前・メモ・リンク・場所を書き換える。渡した欄だけ変わる。remove=true で項目を消す（本人に頼まれたときだけ。" +
      "済んだものは消さずに check_list_items で済みにする）。",
    inputSchema: {
      type: "object",
      properties: {
        id: { type: "string" }, title: { type: "string" }, memo: { type: "string" }, link: { type: "string" }, place: { type: "string" },
        remove: { type: "boolean" },
      },
      required: ["id"],
    },
    run: (args, { records, book, now }) => {
      const item = findItem(book, args.id);
      const writer = new Writer(records, "claude", now.getTime());
      if (args.remove) {
        writer.set(`item_${item.id}`, { alive: false });
        return { result: { removed: item.id }, changes: writer.changes };
      }
      const values: Args = {};
      if (args.title !== undefined) {
        if (!String(args.title).trim()) throw new Error("名前は空にできません。");
        values.title = String(args.title).trim();
      }
      for (const key of ["memo", "link", "place"]) if (args[key] !== undefined) values[key] = String(args[key]).trim();
      if (!Object.keys(values).length) return { result: { changed: false } };
      writer.set(`item_${item.id}`, values);
      return { result: { changed: true, id: item.id }, changes: writer.changes };
    },
  },
  {
    name: "check_list_items",
    title: "リストの項目を済みにする・戻す",
    description:
      "リストの項目を済み（done=true、履歴に移る）にするか、リストに戻す。複数まとめて渡せる。" +
      "リスト全体から作ったタスク（買い物など）は、まだの項目がなくなると完了になる。",
    inputSchema: { type: "object", properties: { ids: IDS, done: { type: "boolean" } }, required: ["ids", "done"] },
    run: ({ ids, done }, { records, book, now }) => {
      const writer = new Writer(records, "claude", now.getTime());
      const doneNow = new Map<string, string | null>();
      for (const id of ids as string[]) checkItem(writer, book, findItem(book, id), !!done, now, doneNow);
      return { result: { updated: ids.length }, changes: writer.changes };
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
  "Horme（本人のタスク管理アプリ）の中身を読み書きする。種類はタスク（その日にやる・単発で終わる）、イベント（その日にある予定。済んだら印を付けられるが、やり残しにはならない）、" +
  "ルーティン（くり返し）、アイデア（まだ決めていない思いつき）、リスト（行きたいところ・読みたい本・買うものなど、予定ではない具体的なもののストック。" +
  "予定にするときは add_tasks の from_item / from_list でつなぐ）。ほかにボード（やり方の書き置き）と、プロジェクト（到達点・期限・途中の到達点を持つ大きな枠）がある。" +
  "大きなタスクは子タスクに分かれていることがある（pieces / parent）。日付と時間は子タスクが持ち、親タスクは締切と必須だけを持つ。子タスクがすべて済むと親も完了になる。" +
  "日付は日本時間。書き換える前に get_today / get_days で id と現状を確かめる。" +
  "handoff は本人が「Claude にやってほしい」と残した依頼で、対応したら memo に結果を書いて handoff を空にする。" +
  "変更はアプリと iCloud に数十秒以内に反映される。タスク・イベント・ルーティン・プロジェクト・リストの追加や変更は本人に頼まれたときに行う。頼まれていないのに必須にしたり消したりはしない。";

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
