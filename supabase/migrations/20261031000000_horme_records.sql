-- Horme's data for the Claude bridge, in the same per-field form the app syncs through iCloud.
-- Each record is one task, idea, board card or routine (or the active session). Every field carries a
-- stamp (tick, device); merging keeps the larger stamp per field, so the iPhone, the iPad and Claude can
-- write at the same time without overwriting each other's changes.

create table if not exists public.horme_records (
  id text primary key
    check (id = 'session' or id ~ '^(task|idea|card|routine)_[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$'),
  payload jsonb not null check (payload->>'id' = id and (payload->>'version')::int = 1 and jsonb_typeof(payload->'fields') = 'object'),
  updated_at timestamptz not null default now()
);

-- Only the edge function (service role) reads and writes; no public policies.
alter table public.horme_records enable row level security;

create or replace function public.horme_stamp_greater(a jsonb, b jsonb) returns boolean
language sql immutable as $$
  select (a->>'tick')::bigint > (b->>'tick')::bigint
      or ((a->>'tick')::bigint = (b->>'tick')::bigint and (a->>'device') collate "C" > (b->>'device') collate "C")
$$;

-- Merges incoming records field by field and returns the stored result of each.
create or replace function public.horme_merge(incoming jsonb) returns setof public.horme_records
language plpgsql security definer set search_path = public as $$
declare
  rec jsonb;
  current_fields jsonb;
  key text;
  field jsonb;
  merged jsonb;
begin
  for rec in select * from jsonb_array_elements(incoming) loop
    if (rec->>'version')::int is distinct from 1 or jsonb_typeof(rec->'fields') is distinct from 'object' then
      raise exception 'unsupported record %', rec->>'id';
    end if;
    select payload->'fields' into current_fields from horme_records where id = rec->>'id' for update;
    if current_fields is null then
      insert into horme_records (id, payload) values (rec->>'id', rec)
        on conflict (id) do nothing;
      if not found then
        select payload->'fields' into current_fields from horme_records where id = rec->>'id' for update;
      end if;
    end if;
    if current_fields is not null then
      merged := current_fields;
      for key, field in select * from jsonb_each(rec->'fields') loop
        if not (merged ? key) or horme_stamp_greater(field->'stamp', merged->key->'stamp') then
          merged := jsonb_set(merged, array[key], field);
        end if;
      end loop;
      if merged is distinct from current_fields then
        update horme_records set payload = jsonb_set(payload, '{fields}', merged), updated_at = now()
          where id = rec->>'id';
      end if;
    end if;
    return query select * from horme_records where id = rec->>'id';
  end loop;
end;
$$;

revoke all on function public.horme_merge(jsonb) from public, anon, authenticated;
