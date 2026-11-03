-- Projects (goal, deadline and checkpoints) travel as records of their own, like tasks and cards.
alter table public.horme_records drop constraint if exists horme_records_id_check;
alter table public.horme_records add constraint horme_records_id_check
  check (id = 'session' or id ~ '^(task|idea|card|routine|project)_[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$');
