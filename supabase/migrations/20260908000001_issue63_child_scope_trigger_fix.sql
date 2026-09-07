-- Issue #63 production remediation.
--
-- private.fn_enforce_dd1b_child_test_context_v1 is shared by several child
-- tables. Its family_event_external_links-only calendar check referenced
-- NEW.calendar_connection_id directly. PostgreSQL resolves that field against
-- the actual trigger row type before the branch can short-circuit, so inserts
-- on task_subtask_instances failed with:
--   record "new" has no field "calendar_connection_id"
--
-- Read the table-specific field through to_jsonb(NEW) instead. This preserves
-- the existing household/test-context guard and calendar-connection invariant
-- without requiring every child table to expose the calendar column.

create or replace function private.fn_enforce_dd1b_child_test_context_v1()
returns trigger
language plpgsql
set search_path = ''
as $function$
declare
  v_parent_test_context_id uuid;
  v_parent_household_id uuid;
  v_calendar_connection_id uuid;
begin
  if tg_table_name = 'task_subtask_instances' then
    select household_id, test_context_id
      into v_parent_household_id, v_parent_test_context_id
      from public.task_instances
     where household_id = new.household_id
       and id = new.task_instance_id;
  elsif tg_table_name in ('shopping_actual_participants', 'shopping_events') then
    select household_id, test_context_id
      into v_parent_household_id, v_parent_test_context_id
      from public.shopping_items
     where household_id = new.household_id
       and id = new.shopping_item_id;
  elsif tg_table_name in ('family_event_field_authorities', 'family_event_external_links') then
    select household_id, test_context_id
      into v_parent_household_id, v_parent_test_context_id
      from public.family_events
     where household_id = new.household_id
       and id = new.family_event_id;
  elsif tg_table_name = 'document_extractions' then
    select household_id, test_context_id
      into v_parent_household_id, v_parent_test_context_id
      from private.source_documents
     where household_id = new.household_id
       and id = new.source_document_id;
  elsif tg_table_name = 'document_facts' then
    select household_id, test_context_id
      into v_parent_household_id, v_parent_test_context_id
      from private.document_extractions
     where household_id = new.household_id
       and id = new.extraction_id;
  else
    raise exception 'UNSUPPORTED_DD1B_CHILD_SCOPE_TABLE';
  end if;

  if not found then
    raise exception 'CANONICAL_PARENT_NOT_FOUND';
  end if;

  if new.test_context_id is distinct from v_parent_test_context_id then
    raise exception 'TEST_CONTEXT_PARENT_MISMATCH';
  end if;

  if tg_table_name = 'family_event_external_links' then
    v_calendar_connection_id := nullif(to_jsonb(new) ->> 'calendar_connection_id', '')::uuid;
    if not exists (
      select 1
        from public.calendar_connections c
       where c.id = v_calendar_connection_id
         and c.household_id = new.household_id
    ) then
      raise exception 'CALENDAR_CONNECTION_HOUSEHOLD_MISMATCH';
    end if;
  end if;

  return new;
end;
$function$;
