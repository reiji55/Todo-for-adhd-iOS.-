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
};
export type Idea = { id: string; text: string; createdAt: string };
export type Card = { id: string; title: string; purpose: string; goal: string; detail: string; createdAt: string; rank: number };
export type Move = { toDay: string; time: string };
export type Routine = {
  id: string; title: string; project: string; memo: string; weekdays: number[]; time: string; notify: boolean;
  isBlock: boolean; isPaused: boolean; createdAt: string; doneDays: string[]; moves: Record<string, Move>;
};
export type Book = { tasks: Task[]; ideas: Idea[]; cards: Card[]; routines: Routine[] };

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
  const book: Book = { tasks: [], ideas: [], cards: [], routines: [] };
  for (const record of records) {
    if (!isAlive(record)) continue;
    const plain: Record<string, unknown> = {};
    for (const [key, field] of Object.entries(record.fields)) {
      if (key === "alive" || key.startsWith("step.") || key.startsWith("done.") || key.startsWith("move.")) continue;
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
    } else if (record.id.startsWith("card_")) {
      book.cards.push({ purpose: "", goal: "", detail: "", rank: 0, ...(plain as Card) });
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

export type AgendaItem = {
  id: string; kind: "task" | "routine"; title: string; time: string; done: boolean; must: boolean;
  project: string; held?: boolean; originalDay?: string; deadline?: string; nextStep?: string;
  resumeNote?: string; memo?: string; handoff?: string;
};

/** Mirrors Agenda.items in Schedule.swift. */
export function agenda(book: Book, key: string): AgendaItem[] {
  const items: AgendaItem[] = [];
  for (const t of book.tasks) {
    if (!t.plannedAt || dayKey(t.plannedAt) !== key) continue;
    items.push(taskItem(t));
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

export function taskItem(t: Task): AgendaItem {
  const next = t.steps.find((s) => !s.isDone);
  return {
    id: t.id, kind: "task", title: t.title, time: t.scheduledTime ?? "", done: !!t.completedAt, must: !!t.isMust,
    project: t.project ?? "", deadline: t.deadline ? dayKey(t.deadline) : undefined, nextStep: next?.title,
    resumeNote: t.resumeNote || undefined, memo: t.memo || undefined, handoff: t.handoff || undefined,
  };
}
