// The app's sync records, read and written outside the app. Mirrors TaskCore/SyncReplica.swift:
// one record per task / idea / card / routine, each field a JSON value (base64 of its UTF-8 JSON) with a
// stamp. Larger stamp wins per field. Steps, routine days and moves are separate fields so they merge alone.

export type Stamp = { tick: number; device: string };
export type Field = { value: string; stamp: Stamp };
export type SyncRecord = { version: 1; id: string; fields: Record<string, Field> };

export type Step = { id: string; title: string; isDone: boolean };
export type Task = {
  id: string; title: string; plannedAt?: string | null; scheduledTime: string; deadline?: string | null;
  isMust: boolean; effort: string; project: string; memo: string; handoff: string; resumeNote: string;
  steps: Step[]; createdAt: string; completedAt?: string | null; notify?: boolean;
  /** Something happening that day, not a to-do (TaskItem.isEvent in the app). */
  isEvent?: boolean;
  /** The task this one is a piece of (one level only). A parent keeps only its deadline and must;
   *  days belong to its pieces, and it is done exactly when they all are. */
  parentID?: string | null;
  /** Order among the pieces of one parent. */
  rank?: number;
  /** Made from a whole list (a shopping trip): done when nothing on the list is left open. */
  listID?: string | null;
  /** Made from one thing on a list: when done, that thing moves to the list's history. */
  listItemID?: string | null;
};
/** A list of concrete things kept for later (places, books, groceries). Not a plan. */
export type StockList = { id: string; name: string; createdAt: string };
/** One thing on a list. Each is its own record (`item_<id>`). Done ones are the list's history. */
export type ListItem = {
  id: string; listID: string; title: string; memo: string; link: string; place: string; createdAt: string;
  doneAt?: string | null;
  /** An optional heading it is listed under (a dish or aisle, an area, a genre). */
  group?: string;
};
export type Idea = { id: string; text: string; createdAt: string };
export type Card = { id: string; title: string; purpose: string; goal: string; detail: string; createdAt: string; rank: number };
export type Move = { toDay: string; time: string };
export type Routine = {
  id: string; title: string; project: string; memo: string; weekdays: number[]; time: string; notify: boolean;
  isBlock: boolean; isPaused: boolean; createdAt: string; doneDays: string[]; moves: Record<string, Move>;
};
export type Milestone = {
  id: string; title: string; kind: "check" | "count" | "number" | "tasks"; target: number; current: number; unit: string;
  isDone: boolean; dueDate?: string | null; createdAt: string; rank: number;
};
/** A project: a goal (到達点), a deadline, an overview, and checkpoints on the way. Tasks, routines and cards
 *  belong to it by name (their `project`). Each checkpoint is its own field (`ms.<id>`), null once removed. */
export type Project = {
  id: string; name: string; goal: string; deadline?: string | null; overview: string; origin: string; createdAt: string;
  milestones: Milestone[];
};
export type Book = {
  tasks: Task[]; ideas: Idea[]; cards: Card[]; routines: Routine[]; projects: Project[]; lists: StockList[]; items: ListItem[];
};

const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function encodeValue(value: unknown): string {
  const bytes = encoder.encode(JSON.stringify(value ?? null));
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary);
}

export function decodeValue(value: string | undefined): unknown {
  if (value === undefined) return null;
  const binary = atob(value);
  const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
  return JSON.parse(decoder.decode(bytes));
}

export const isAlive = (r: SyncRecord) => decodeValue(r.fields.alive?.value) === true;

export function materialize(records: SyncRecord[]): Book {
  const book: Book = { tasks: [], ideas: [], cards: [], routines: [], projects: [], lists: [], items: [] };
  for (const record of records) {
    if (!isAlive(record)) continue;
    const plain: Record<string, unknown> = {};
    for (const [key, field] of Object.entries(record.fields)) {
      if (key === "alive" || key.startsWith("step.") || key.startsWith("done.") || key.startsWith("move.") || key.startsWith("ms.")) continue;
      plain[key] = decodeValue(field.value);
    }
    if (record.id.startsWith("task_")) {
      const steps: (Step & { rank: number })[] = [];
      const stepIDs = new Set(Object.keys(record.fields).filter((k) => k.startsWith("step.")).map((k) => k.split(".")[1]));
      for (const id of stepIDs) {
        const f = (name: string) => decodeValue(record.fields[`step.${id}.${name}`]?.value);
        if (f("alive") !== true) continue;
        steps.push({ id, title: String(f("title") ?? ""), isDone: f("isDone") === true, rank: Number(f("rank") ?? 0) });
      }
      steps.sort((a, b) => a.rank - b.rank || a.id.localeCompare(b.id));
      book.tasks.push({ ...(plain as Task), steps: steps.map(({ rank: _, ...s }) => s) });
    } else if (record.id.startsWith("idea_")) {
      book.ideas.push(plain as Idea);
    } else if (record.id.startsWith("list_")) {
      book.lists.push(plain as StockList);
    } else if (record.id.startsWith("item_")) {
      book.items.push({ memo: "", link: "", place: "", group: "", ...(plain as ListItem) });
    } else if (record.id.startsWith("card_")) {
      book.cards.push({ purpose: "", goal: "", detail: "", rank: 0, ...(plain as Card) });
    } else if (record.id.startsWith("project_")) {
      const milestones: Milestone[] = [];
      for (const [key, field] of Object.entries(record.fields)) {
        if (!key.startsWith("ms.")) continue;
        const value = decodeValue(field.value);
        if (value && typeof value === "object") milestones.push({ unit: "", current: 0, target: 1, isDone: false, kind: "check", rank: 0, ...(value as Milestone) });
      }
      milestones.sort((a, b) => a.rank - b.rank || a.id.localeCompare(b.id));
      book.projects.push({ goal: "", overview: "", origin: "", ...(plain as Project), milestones });
    } else if (record.id.startsWith("routine_")) {
      const doneDays: string[] = [];
      const moves: Record<string, Move> = {};
      for (const [key, field] of Object.entries(record.fields)) {
        const value = decodeValue(field.value);
        if (key.startsWith("done.") && value === true) doneDays.push(key.slice(5));
        if (key.startsWith("move.") && value && typeof value === "object") moves[key.slice(5)] = value as Move;
      }
      book.routines.push({
        project: "", memo: "", weekdays: [1, 2, 3, 4, 5, 6, 7], time: "", notify: true, isBlock: false, isPaused: false,
        ...(plain as Routine), doneDays: doneDays.sort(), moves,
      });
    }
  }
  book.tasks.sort((a, b) => a.createdAt.localeCompare(b.createdAt) || a.id.localeCompare(b.id));
  book.cards.sort((a, b) => a.rank - b.rank || a.id.localeCompare(b.id));
  book.lists.sort((a, b) => a.createdAt.localeCompare(b.createdAt) || a.id.localeCompare(b.id));
  book.items.sort((a, b) => a.createdAt.localeCompare(b.createdAt) || a.id.localeCompare(b.id));
  return book;
}

/** A writer for one batch of edits: every field it touches gets the same new stamp. */
export class Writer {
  readonly stamp: Stamp;
  private records = new Map<string, SyncRecord>();
  constructor(existing: SyncRecord[], device = "claude", now = Date.now()) {
    let max = 0;
    for (const r of existing) for (const f of Object.values(r.fields)) max = Math.max(max, f.stamp.tick);
    this.stamp = { tick: Math.max(max + 1, now), device };
  }
  set(id: string, values: Record<string, unknown>) {
    const record = this.records.get(id) ?? { version: 1 as const, id, fields: {} };
    for (const [key, value] of Object.entries(values)) {
      record.fields[key] = { value: encodeValue(value), stamp: this.stamp };
    }
    this.records.set(id, record);
  }
  get changes(): SyncRecord[] { return [...this.records.values()]; }
}

// Days are Japan time, like the app's owner. Japan has no daylight saving, so a fixed offset is exact.
const TOKYO = 9 * 3600 * 1000;
export const dayKey = (iso: string | Date) => new Date(new Date(iso).getTime() + TOKYO).toISOString().slice(0, 10);
export const todayKey = (now = new Date()) => dayKey(now);
/** Noon in Tokyo on that day, written without fractional seconds as the app's ISO 8601 decoder expects. */
export const dayToISO = (key: string) => `${key}T03:00:00Z`;
export const nowISO = (now = new Date()) => now.toISOString().replace(/\.\d{3}Z$/, "Z");
export const newID = () => crypto.randomUUID().toUpperCase();
export const addDays = (key: string, n: number) => {
  const d = new Date(`${key}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
};
const weekday = (key: string) => new Date(`${key}T00:00:00Z`).getUTCDay() + 1; // 1 = Sunday, as in Calendar

export function startMinute(time: string): number {
  const m = /^(\d{1,2}):(\d{2})/.exec(time.trim());
  return m ? Number(m[1]) * 60 + Number(m[2]) : Number.MAX_SAFE_INTEGER;
}

export type Piece = { id: string; title: string; done: boolean; date: string; time?: string };

export type AgendaItem = {
  id: string; kind: "task" | "event" | "routine"; title: string; time: string; done: boolean; must: boolean;
  project: string; held?: boolean; originalDay?: string; deadline?: string; nextStep?: string;
  resumeNote?: string; memo?: string; handoff?: string;
  /** For a piece of a bigger task: that task. */
  parent?: { id: string; title: string };
  /** For a task in pieces: its pieces, in order. */
  pieces?: Piece[];
  /** For a task made from a whole list: the list and how much of it is checked off since. */
  list?: { id: string; name: string; done: number; total: number };
  /** For a task or event made from one thing on a list: that thing. */
  fromItem?: { id: string; title: string; list: string };
};

const same = (a: string | null | undefined, b: string) => !!a && a.toUpperCase() === b.toUpperCase();

/** Mirrors Notebook.listProgress in Lists.swift: checked off since the task was made, of those plus what is open. */
export function listProgress(book: Book, t: Task): { done: number; total: number } | undefined {
  if (!t.listID || !book.lists.some((l) => same(l.id, t.listID!))) return undefined;
  const mine = book.items.filter((i) => same(i.listID, t.listID!));
  const open = mine.filter((i) => !i.doneAt).length;
  const done = mine.filter((i) => i.doneAt && i.doneAt >= t.createdAt).length;
  return { done, total: done + open };
}

/** The pieces of a task, in order. */
export function piecesOf(book: Book, id: string): Task[] {
  return book.tasks.filter((t) => same(t.parentID, id))
    .sort((a, b) => (a.rank ?? 0) - (b.rank ?? 0) || a.createdAt.localeCompare(b.createdAt) || a.id.localeCompare(b.id));
}

/** Mirrors Agenda.items in Schedule.swift. */
export function agenda(book: Book, key: string): AgendaItem[] {
  const items: AgendaItem[] = [];
  for (const t of book.tasks) {
    if (!t.plannedAt || dayKey(t.plannedAt) !== key) continue;
    items.push(taskItem(t, book));
  }
  for (const r of book.routines) {
    if (r.isPaused) continue;
    const days: string[] = [];
    if (dayKey(r.createdAt) <= key && r.weekdays.includes(weekday(key)) && !r.moves[key]) days.push(key);
    for (const [from, move] of Object.entries(r.moves)) if (move.toDay === key && from !== key) days.push(from);
    if (r.moves[key]?.toDay === key) days.push(key);
    for (const original of days) {
      items.push({
        id: r.id, kind: "routine", title: r.title, time: r.moves[original]?.time ?? r.time,
        done: r.doneDays.includes(original), must: false, project: r.project, held: r.isBlock || undefined,
        originalDay: original,
      });
    }
  }
  return items.sort((a, b) => startMinute(a.time) - startMinute(b.time) || Number(b.must) - Number(a.must));
}

export function taskItem(t: Task, book?: Book): AgendaItem {
  const pieces = book ? piecesOf(book, t.id) : [];
  const parent = book && t.parentID ? book.tasks.find((p) => same(t.parentID, p.id)) : undefined;
  const next = pieces.find((p) => !p.completedAt)?.title ?? t.steps.find((s) => !s.isDone)?.title;
  return {
    id: t.id, kind: t.isEvent ? "event" : "task", title: t.title, time: t.scheduledTime ?? "", done: !!t.completedAt, must: !!t.isMust,
    project: t.project ?? "", deadline: t.deadline ? dayKey(t.deadline) : undefined, nextStep: next,
    resumeNote: t.resumeNote || undefined, memo: t.memo || undefined, handoff: t.handoff || undefined,
    parent: parent ? { id: parent.id, title: parent.title } : undefined,
    list: book && t.listID ? (() => {
      const list = book.lists.find((l) => same(l.id, t.listID!));
      const progress = listProgress(book, t);
      return list && progress ? { id: list.id, name: list.name, ...progress } : undefined;
    })() : undefined,
    fromItem: book && t.listItemID ? (() => {
      const item = book.items.find((i) => same(i.id, t.listItemID!));
      const list = item && book.lists.find((l) => same(l.id, item.listID));
      return item ? { id: item.id, title: item.title, list: list?.name ?? "" } : undefined;
    })() : undefined,
    pieces: pieces.length ? pieces.map((p) => ({
      id: p.id, title: p.title, done: !!p.completedAt, date: p.plannedAt ? dayKey(p.plannedAt) : "anytime",
      time: p.scheduledTime || undefined,
    })) : undefined,
  };
}
