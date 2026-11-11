-- Lists (ストック) and the things on them travel as records of their own, one per thing, so two people
-- checking off one shopping list both count.
alter table public.horme_records drop constraint if exists horme_records_id_check;
alter table public.horme_records add constraint horme_records_id_check
  check (id = 'session' or id ~ '^(task|idea|card|routine|project|list|item)_[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$');
