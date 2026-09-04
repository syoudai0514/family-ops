-- WP-DD5B canonical Shopping writer/read contract.
-- Shopping stays a separate aggregate. ActorRef responsibility, anyone claim,
-- actual/recorder evidence, expected revision, correction history and neutral
-- duplicate-safety intents are one transaction.

alter table public.shopping_items
  alter column created_by drop not null,
  add column created_by_actor_ref_id uuid null,
  add foreign key (household_id, created_by_actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  add constraint shopping_items_creator_identity_v2
    check (created_by is not null or created_by_actor_ref_id is not null);

update public.shopping_items s
set created_by_actor_ref_id = a.id
from public.domain_actor_refs a
where s.test_context_id is null
  and s.created_by is not null
  and a.household_id = s.household_id
  and a.actor_kind = 'real_user'
  and a.real_user_id = s.created_by
  and s.created_by_actor_ref_id is null;

create or replace function private.fn_enforce_shopping_creator_compatibility_v1()
returns trigger
language plpgsql security invoker set search_path = '' as $$
begin
  perform private.fn_assert_no_simulated_legacy_user_substitution(
    new.household_id, new.created_by_actor_ref_id, new.created_by,
    new.test_context_id
  );
  return new;
end;
$$;
revoke all on function private.fn_enforce_shopping_creator_compatibility_v1()
  from public, anon, authenticated;
grant execute on function private.fn_enforce_shopping_creator_compatibility_v1()
  to service_role;
create trigger shopping_items_creator_compat_guard_v1
  before insert or update of created_by_actor_ref_id, created_by, test_context_id
  on public.shopping_items
  for each row execute function private.fn_enforce_shopping_creator_compatibility_v1();
create trigger shopping_items_creator_scope_guard_v1
  before insert or update of created_by_actor_ref_id, test_context_id
  on public.shopping_items
  for each row execute function private.fn_enforce_existing_actor_scope('created_by_actor_ref_id');

alter table public.shopping_actual_participants
  add column action_kind text not null default 'purchased'
    check (action_kind in ('ordered', 'purchased', 'arrived'));
drop index public.shopping_actual_participants_active_idx;
create unique index shopping_actual_participants_active_idx
  on public.shopping_actual_participants (shopping_item_id, actor_ref_id, action_kind)
  where removed_at is null;

create table public.shopping_events (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id),
  shopping_item_id uuid not null,
  actor_ref_id uuid not null,
  event_type text not null check (event_type in (
    'created','assignment_changed','claimed','claim_released','claim_taken_over',
    'ordered','purchased','arrived','cancelled','reopened'
  )),
  aggregate_revision bigint not null check (aggregate_revision >= 1),
  payload jsonb not null default '{}'::jsonb,
  source text not null check (source in ('line','pwa','canonical')),
  idempotency_key text not null,
  test_context_id uuid null,
  created_at timestamptz not null default now(),
  unique (household_id, id),
  unique (shopping_item_id, idempotency_key),
  foreign key (household_id, shopping_item_id)
    references public.shopping_items (household_id, id),
  foreign key (household_id, actor_ref_id)
    references public.domain_actor_refs (household_id, id),
  foreign key (household_id, test_context_id)
    references public.test_simulation_contexts (household_id, id)
);
create index shopping_events_item_created_idx
  on public.shopping_events (household_id, shopping_item_id, created_at desc);
create index shopping_events_test_context_idx
  on public.shopping_events (test_context_id) where test_context_id is not null;
create trigger shopping_events_actor_scope_guard_v1
  before insert or update of actor_ref_id, test_context_id on public.shopping_events
  for each row execute function private.fn_enforce_existing_actor_scope('actor_ref_id');
create trigger shopping_events_test_context_guard_v1
  before insert or update of shopping_item_id, test_context_id on public.shopping_events
  for each row execute function private.fn_enforce_dd1b_child_test_context_v1();
alter table public.shopping_events enable row level security;
grant select on public.shopping_events to authenticated;
create policy shopping_events_production_select
  on public.shopping_events for select to authenticated
  using (test_context_id is null and public.is_household_member(household_id));
grant select, insert, update, delete on public.shopping_events to service_role;

-- Extend the shared parent-scope trigger for the DD5B audit child.
create or replace function private.fn_enforce_dd1b_child_test_context_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_parent_test_context_id uuid;
  v_parent_household_id uuid;
begin
  if tg_table_name = 'task_subtask_instances' then
    select household_id, test_context_id into v_parent_household_id, v_parent_test_context_id
    from public.task_instances where household_id = new.household_id and id = new.task_instance_id;
  elsif tg_table_name in ('shopping_actual_participants', 'shopping_events') then
    select household_id, test_context_id into v_parent_household_id, v_parent_test_context_id
    from public.shopping_items where household_id = new.household_id and id = new.shopping_item_id;
  elsif tg_table_name in ('family_event_field_authorities', 'family_event_external_links') then
    select household_id, test_context_id into v_parent_household_id, v_parent_test_context_id
    from public.family_events where household_id = new.household_id and id = new.family_event_id;
  elsif tg_table_name = 'document_extractions' then
    select household_id, test_context_id into v_parent_household_id, v_parent_test_context_id
    from private.source_documents where household_id = new.household_id and id = new.source_document_id;
  elsif tg_table_name = 'document_facts' then
    select household_id, test_context_id into v_parent_household_id, v_parent_test_context_id
    from private.document_extractions where household_id = new.household_id and id = new.extraction_id;
  else
    raise exception 'UNSUPPORTED_DD1B_CHILD_SCOPE_TABLE';
  end if;
  if not found then raise exception 'CANONICAL_PARENT_NOT_FOUND'; end if;
  if new.test_context_id is distinct from v_parent_test_context_id then
    raise exception 'TEST_CONTEXT_PARENT_MISMATCH';
  end if;
  if tg_table_name = 'family_event_external_links' then
    if not exists (
      select 1 from public.calendar_connections c
      where c.id = new.calendar_connection_id and c.household_id = new.household_id
    ) then raise exception 'CALENDAR_CONNECTION_HOUSEHOLD_MISMATCH'; end if;
  end if;
  return new;
end;
$$;

create or replace function private.fn_notify_shopping_partners_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid,
  p_item_id uuid,
  p_item_title text,
  p_revision bigint,
  p_notification_kind text,
  p_body text,
  p_safety_class text
) returns void
language plpgsql security definer set search_path = '' as $$
declare r record;
begin
  for r in
    select a.id
    from public.domain_actor_refs a
    where a.household_id = p_household_id
      and a.id <> p_actor_ref_id
      and (
        (p_test_context_id is null and a.actor_kind = 'real_user')
        or (p_test_context_id is not null and (
          (a.actor_kind = 'simulated_member' and a.test_context_id = p_test_context_id)
          or (a.actor_kind = 'real_user' and a.real_user_id = p_operator_user_id)
        ))
      )
  loop
    perform private.fn_emit_notification_intent_v1(
      p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
      r.id, p_notification_kind, '買い物の状態が変わりました', p_body,
      jsonb_build_object('shopping_item_id', p_item_id, 'revision', p_revision),
      p_notification_kind || ':' || p_item_id::text || ':' || p_revision::text,
      'immediate', p_safety_class, 'shopping:' || p_item_id::text,
      now() + interval '24 hours', 'shopping', p_item_id, p_revision
    );
  end loop;
end;
$$;
revoke all on function private.fn_notify_shopping_partners_v1(
  uuid,uuid,uuid,uuid,uuid,text,bigint,text,text,text
) from public, anon, authenticated;
grant execute on function private.fn_notify_shopping_partners_v1(
  uuid,uuid,uuid,uuid,uuid,text,bigint,text,text,text
) to service_role;

create or replace function private.fn_command_create_shopping_item_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid,
  p_title text,
  p_purchase_method text,
  p_assignment_mode text,
  p_assignee_actor_ref_id uuid,
  p_duplicate_sensitivity text,
  p_url text,
  p_due_at timestamptz,
  p_operation_id uuid,
  p_source text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_claim jsonb; v_receipt_id uuid; v_item_id uuid;
  v_creator_user uuid; v_assignee_user uuid; v_status text; v_result jsonb;
begin
  if nullif(btrim(coalesce(p_title,'')), '') is null then raise exception 'INVALID_INPUT'; end if;
  if p_purchase_method not in ('store','online','either','undecided') then raise exception 'INVALID_INPUT'; end if;
  if p_assignment_mode not in ('person','unassigned','anyone') then raise exception 'ASSIGNMENT_MODE_INVALID'; end if;
  if p_duplicate_sensitivity not in ('normal','avoid_duplicate','safety_critical') then raise exception 'INVALID_INPUT'; end if;
  if p_source not in ('line','pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;
  if (p_assignment_mode='person' and p_assignee_actor_ref_id is null)
     or (p_assignment_mode<>'person' and p_assignee_actor_ref_id is not null) then
    raise exception 'ASSIGNMENT_MODE_ACTOR_MISMATCH';
  end if;

  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_actor_ref_id,p_test_context_id,
    p_operation_id,'shopping.create',private.fn_canonical_request_hash_v1(jsonb_build_object(
      'title',btrim(p_title),'purchase_method',p_purchase_method,
      'assignment_mode',p_assignment_mode,'assignee_actor_ref_id',p_assignee_actor_ref_id,
      'duplicate_sensitivity',p_duplicate_sensitivity,'url',nullif(btrim(coalesce(p_url,'')),''),
      'due_at',p_due_at,'source',p_source
    ))
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;
  perform private.fn_assert_actor_ref_scope(p_household_id,p_assignee_actor_ref_id,p_test_context_id);
  v_creator_user := private.fn_legacy_user_for_actor_ref_v1(p_household_id,p_actor_ref_id,p_test_context_id);
  v_assignee_user := case when p_assignee_actor_ref_id is null then null else
    private.fn_legacy_user_for_actor_ref_v1(p_household_id,p_assignee_actor_ref_id,p_test_context_id) end;
  v_status := case when p_assignment_mode='person' then 'assigned' else 'wanted' end;

  insert into public.shopping_items (
    household_id,title,purchase_method,status,assignee_id,url,due_at,created_by,
    assignment_mode,assignee_actor_ref_id,active_claimant_actor_ref_id,claimed_at,
    duplicate_sensitivity,revision,test_context_id,created_by_actor_ref_id
  ) values (
    p_household_id,btrim(p_title),p_purchase_method,v_status,
    case when p_test_context_id is null then v_assignee_user else null end,
    nullif(btrim(coalesce(p_url,'')),''),p_due_at,
    case when p_test_context_id is null then v_creator_user else null end,
    p_assignment_mode,p_assignee_actor_ref_id,null,null,p_duplicate_sensitivity,1,
    p_test_context_id,p_actor_ref_id
  ) returning id into v_item_id;
  insert into public.shopping_events (
    household_id,shopping_item_id,actor_ref_id,event_type,aggregate_revision,
    payload,source,idempotency_key,test_context_id
  ) values (
    p_household_id,v_item_id,p_actor_ref_id,'created',1,
    jsonb_build_object('assignment_mode',p_assignment_mode,'purchase_method',p_purchase_method),
    p_source,'canonical:'||p_operation_id::text,p_test_context_id
  );
  v_result := jsonb_build_object('shopping_item_id',v_item_id,'status',v_status,'revision',1);
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'shopping',v_item_id,v_result);
  return v_result;
end;
$$;

create or replace function private.fn_command_set_shopping_assignment_v1(
  p_household_id uuid,p_operator_user_id uuid,p_actor_ref_id uuid,p_test_context_id uuid,
  p_shopping_item_id uuid,p_assignment_mode text,p_assignee_actor_ref_id uuid,
  p_expected_revision bigint,p_operation_id uuid,p_source text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_claim jsonb; v_receipt_id uuid; v_item public.shopping_items%rowtype;
  v_assignee_user uuid; v_status text; v_revision bigint; v_result jsonb;
begin
  if p_assignment_mode not in ('person','unassigned','anyone') then raise exception 'ASSIGNMENT_MODE_INVALID'; end if;
  if (p_assignment_mode='person' and p_assignee_actor_ref_id is null)
     or (p_assignment_mode<>'person' and p_assignee_actor_ref_id is not null) then raise exception 'ASSIGNMENT_MODE_ACTOR_MISMATCH'; end if;
  if p_source not in ('line','pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;
  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_actor_ref_id,p_test_context_id,p_operation_id,
    'shopping.assignment.set',private.fn_canonical_request_hash_v1(jsonb_build_object(
      'shopping_item_id',p_shopping_item_id,'assignment_mode',p_assignment_mode,
      'assignee_actor_ref_id',p_assignee_actor_ref_id,'expected_revision',p_expected_revision,'source',p_source
    ))
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;
  perform private.fn_assert_actor_ref_scope(p_household_id,p_assignee_actor_ref_id,p_test_context_id);
  select * into v_item from public.shopping_items where household_id=p_household_id and id=p_shopping_item_id for update;
  if not found then raise exception 'SHOPPING_ITEM_NOT_FOUND'; end if;
  if v_item.test_context_id is distinct from p_test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_item.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if v_item.status not in ('wanted','assigned') then raise exception 'INVALID_SHOPPING_TRANSITION'; end if;
  v_assignee_user := case when p_assignee_actor_ref_id is null then null else
    private.fn_legacy_user_for_actor_ref_v1(p_household_id,p_assignee_actor_ref_id,p_test_context_id) end;
  v_status := case when p_assignment_mode='person' then 'assigned' else 'wanted' end;
  update public.shopping_items set
    assignment_mode=p_assignment_mode,assignee_actor_ref_id=p_assignee_actor_ref_id,
    assignee_id=case when p_test_context_id is null then v_assignee_user else null end,
    status=v_status,active_claimant_actor_ref_id=null,claimed_at=null,revision=revision+1
  where id=p_shopping_item_id returning revision into v_revision;
  insert into public.shopping_events (
    household_id,shopping_item_id,actor_ref_id,event_type,aggregate_revision,
    payload,source,idempotency_key,test_context_id
  ) values (
    p_household_id,p_shopping_item_id,p_actor_ref_id,
    'assignment_changed',v_revision,jsonb_build_object('assignment_mode',p_assignment_mode,
      'assignee_actor_ref_id',p_assignee_actor_ref_id),p_source,
    'canonical:'||p_operation_id::text,p_test_context_id
  );
  v_result:=jsonb_build_object('shopping_item_id',p_shopping_item_id,'status',v_status,
    'assignment_mode',p_assignment_mode,'revision',v_revision);
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'shopping',p_shopping_item_id,v_result);
  return v_result;
end;
$$;

create or replace function private.fn_command_shopping_claim_v1(
  p_household_id uuid,p_operator_user_id uuid,p_actor_ref_id uuid,p_test_context_id uuid,
  p_shopping_item_id uuid,p_action text,p_expected_revision bigint,p_operation_id uuid,p_source text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_claim jsonb; v_receipt_id uuid; v_item public.shopping_items%rowtype;
  v_revision bigint; v_event text; v_result jsonb;
begin
  if p_action not in ('claim','release','takeover') then raise exception 'SHOPPING_CLAIM_ACTION_INVALID'; end if;
  if p_source not in ('line','pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;
  v_claim:=private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_actor_ref_id,p_test_context_id,p_operation_id,
    'shopping.claim.'||p_action,private.fn_canonical_request_hash_v1(jsonb_build_object(
      'shopping_item_id',p_shopping_item_id,'action',p_action,
      'expected_revision',p_expected_revision,'source',p_source
    ))
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;
  select * into v_item from public.shopping_items where household_id=p_household_id and id=p_shopping_item_id for update;
  if not found then raise exception 'SHOPPING_ITEM_NOT_FOUND'; end if;
  if v_item.test_context_id is distinct from p_test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_item.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if v_item.assignment_mode<>'anyone' or v_item.status<>'wanted' then raise exception 'SHOPPING_NOT_CLAIMABLE'; end if;
  if p_action='claim' and v_item.active_claimant_actor_ref_id is not null then raise exception 'SHOPPING_ALREADY_CLAIMED'; end if;
  if p_action='release' and v_item.active_claimant_actor_ref_id is distinct from p_actor_ref_id then raise exception 'SHOPPING_CLAIM_NOT_OWNED'; end if;
  if p_action='takeover' and (v_item.active_claimant_actor_ref_id is null or v_item.active_claimant_actor_ref_id=p_actor_ref_id) then raise exception 'SHOPPING_TAKEOVER_NOT_REQUIRED'; end if;
  update public.shopping_items set
    active_claimant_actor_ref_id=case when p_action='release' then null else p_actor_ref_id end,
    claimed_at=case when p_action='release' then null else now() end,
    revision=revision+1
  where id=p_shopping_item_id returning revision into v_revision;
  v_event:=case p_action when 'claim' then 'claimed' when 'release' then 'claim_released' else 'claim_taken_over' end;
  insert into public.shopping_events (
    household_id,shopping_item_id,actor_ref_id,event_type,aggregate_revision,payload,source,idempotency_key,test_context_id
  ) values (
    p_household_id,p_shopping_item_id,p_actor_ref_id,v_event,v_revision,
    jsonb_build_object('previous_claimant_actor_ref_id',v_item.active_claimant_actor_ref_id),
    p_source,'canonical:'||p_operation_id::text,p_test_context_id
  );
  v_result:=jsonb_build_object('shopping_item_id',p_shopping_item_id,'action',p_action,
    'claimant_actor_ref_id',case when p_action='release' then null else p_actor_ref_id end,
    'revision',v_revision);
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'shopping',p_shopping_item_id,v_result);
  return v_result;
end;
$$;

create or replace function private.fn_command_complete_shopping_item_v1(
  p_household_id uuid,p_operator_user_id uuid,p_recorder_actor_ref_id uuid,p_test_context_id uuid,
  p_shopping_item_id uuid,p_action_kind text,p_performer_actor_ref_id uuid,
  p_expected_revision bigint,p_operation_id uuid,p_source text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_claim jsonb; v_receipt_id uuid; v_item public.shopping_items%rowtype;
  v_performer_user uuid; v_status text; v_revision bigint; v_result jsonb;
begin
  if p_action_kind not in ('ordered','purchased','arrived') then raise exception 'INVALID_SHOPPING_TRANSITION'; end if;
  if p_source not in ('line','pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;
  v_claim:=private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_recorder_actor_ref_id,p_test_context_id,p_operation_id,
    'shopping.complete.'||p_action_kind,private.fn_canonical_request_hash_v1(jsonb_build_object(
      'shopping_item_id',p_shopping_item_id,'action_kind',p_action_kind,
      'performer_actor_ref_id',p_performer_actor_ref_id,
      'expected_revision',p_expected_revision,'source',p_source
    ))
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;
  perform private.fn_assert_actor_ref_scope(p_household_id,p_performer_actor_ref_id,p_test_context_id);
  select * into v_item from public.shopping_items where household_id=p_household_id and id=p_shopping_item_id for update;
  if not found then raise exception 'SHOPPING_ITEM_NOT_FOUND'; end if;
  if v_item.test_context_id is distinct from p_test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_item.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if p_action_kind='ordered' and (v_item.status not in ('wanted','assigned') or v_item.purchase_method not in ('online','either','undecided')) then raise exception 'INVALID_SHOPPING_TRANSITION'; end if;
  if p_action_kind='purchased' and (v_item.status not in ('wanted','assigned') or v_item.purchase_method not in ('store','either','undecided')) then raise exception 'INVALID_SHOPPING_TRANSITION'; end if;
  if p_action_kind='arrived' and v_item.status<>'ordered' then raise exception 'INVALID_SHOPPING_TRANSITION'; end if;
  if v_item.assignment_mode='person' and v_item.assignee_actor_ref_id is distinct from p_performer_actor_ref_id then raise exception 'SHOPPING_PERFORMER_NOT_ASSIGNEE'; end if;
  if v_item.assignment_mode='anyone' and v_item.active_claimant_actor_ref_id is not null
     and v_item.active_claimant_actor_ref_id is distinct from p_performer_actor_ref_id then raise exception 'SHOPPING_CLAIMED_BY_OTHER'; end if;
  v_performer_user:=private.fn_legacy_user_for_actor_ref_v1(p_household_id,p_performer_actor_ref_id,p_test_context_id);
  v_status:=p_action_kind;
  update public.shopping_items set status=v_status,
    ordered_at=case when p_action_kind='ordered' then now() else ordered_at end,
    purchased_at=case when p_action_kind='purchased' then now() else null end,
    arrived_at=case when p_action_kind='arrived' then now() else null end,
    assignee_id=case when assignment_mode='person' and p_test_context_id is null then v_performer_user else assignee_id end,
    active_claimant_actor_ref_id=null,claimed_at=null,revision=revision+1
  where id=p_shopping_item_id returning revision into v_revision;
  insert into public.shopping_actual_participants (
    household_id,shopping_item_id,actor_ref_id,recorded_by_actor_ref_id,source,
    test_context_id,action_kind
  ) values (
    p_household_id,p_shopping_item_id,p_performer_actor_ref_id,p_recorder_actor_ref_id,
    'canonical',p_test_context_id,p_action_kind
  ) on conflict (shopping_item_id,actor_ref_id,action_kind) where removed_at is null do nothing;
  insert into public.shopping_events (
    household_id,shopping_item_id,actor_ref_id,event_type,aggregate_revision,payload,source,idempotency_key,test_context_id
  ) values (
    p_household_id,p_shopping_item_id,p_recorder_actor_ref_id,p_action_kind,v_revision,
    jsonb_build_object('performer_actor_ref_id',p_performer_actor_ref_id),p_source,
    'canonical:'||p_operation_id::text,p_test_context_id
  );
  if p_action_kind in ('ordered','purchased') and v_item.duplicate_sensitivity<>'normal' then
    perform private.fn_notify_shopping_partners_v1(
      p_household_id,p_operator_user_id,p_recorder_actor_ref_id,p_test_context_id,
      p_shopping_item_id,v_item.title,v_revision,'shopping.handled_neutral',
      v_item.title||'は対応済みです',
      case when v_item.duplicate_sensitivity='safety_critical' then 'safety_critical' else 'duplicate_sensitive' end
    );
  end if;
  v_result:=jsonb_build_object('shopping_item_id',p_shopping_item_id,'status',v_status,
    'performer_actor_ref_id',p_performer_actor_ref_id,'revision',v_revision);
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'shopping',p_shopping_item_id,v_result);
  return v_result;
end;
$$;

create or replace function private.fn_command_reopen_shopping_item_v1(
  p_household_id uuid,p_operator_user_id uuid,p_actor_ref_id uuid,p_test_context_id uuid,
  p_shopping_item_id uuid,p_reason text,p_expected_revision bigint,p_operation_id uuid,p_source text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_claim jsonb; v_receipt_id uuid; v_item public.shopping_items%rowtype;
  v_status text; v_revision bigint; v_result jsonb;
begin
  if nullif(btrim(coalesce(p_reason,'')),'') is null then raise exception 'CORRECTION_REASON_REQUIRED'; end if;
  if p_source not in ('line','pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;
  v_claim:=private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_actor_ref_id,p_test_context_id,p_operation_id,
    'shopping.reopen',private.fn_canonical_request_hash_v1(jsonb_build_object(
      'shopping_item_id',p_shopping_item_id,'reason',btrim(p_reason),
      'expected_revision',p_expected_revision,'source',p_source
    ))
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;
  select * into v_item from public.shopping_items where household_id=p_household_id and id=p_shopping_item_id for update;
  if not found then raise exception 'SHOPPING_ITEM_NOT_FOUND'; end if;
  if v_item.test_context_id is distinct from p_test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_item.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if v_item.status not in ('ordered','purchased','arrived') then raise exception 'INVALID_SHOPPING_TRANSITION'; end if;
  v_status:=case when v_item.assignment_mode='person' then 'assigned' else 'wanted' end;
  update public.shopping_items set status=v_status,ordered_at=null,purchased_at=null,arrived_at=null,
    active_claimant_actor_ref_id=null,claimed_at=null,revision=revision+1
  where id=p_shopping_item_id returning revision into v_revision;
  update public.shopping_actual_participants set removed_at=now(),removed_by_actor_ref_id=p_actor_ref_id
  where household_id=p_household_id and shopping_item_id=p_shopping_item_id
    and test_context_id is not distinct from p_test_context_id and removed_at is null;
  insert into public.shopping_events (
    household_id,shopping_item_id,actor_ref_id,event_type,aggregate_revision,payload,source,idempotency_key,test_context_id
  ) values (
    p_household_id,p_shopping_item_id,p_actor_ref_id,'reopened',v_revision,
    jsonb_build_object('from_status',v_item.status,'reason',btrim(p_reason)),p_source,
    'canonical:'||p_operation_id::text,p_test_context_id
  );
  perform private.fn_notify_shopping_partners_v1(
    p_household_id,p_operator_user_id,p_actor_ref_id,p_test_context_id,p_shopping_item_id,
    v_item.title,v_revision,'shopping.reopened_neutral',v_item.title||'は未対応に戻りました',
    case when v_item.duplicate_sensitivity='safety_critical' then 'safety_critical' else 'duplicate_sensitive' end
  );
  v_result:=jsonb_build_object('shopping_item_id',p_shopping_item_id,'status',v_status,'revision',v_revision);
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'shopping',p_shopping_item_id,v_result);
  return v_result;
end;
$$;

create or replace function private.fn_command_cancel_shopping_item_v1(
  p_household_id uuid,p_operator_user_id uuid,p_actor_ref_id uuid,p_test_context_id uuid,
  p_shopping_item_id uuid,p_expected_revision bigint,p_operation_id uuid,p_source text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_claim jsonb; v_receipt_id uuid; v_item public.shopping_items%rowtype;
  v_revision bigint; v_result jsonb;
begin
  if p_source not in ('line','pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;
  v_claim:=private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_actor_ref_id,p_test_context_id,p_operation_id,
    'shopping.cancel',private.fn_canonical_request_hash_v1(jsonb_build_object(
      'shopping_item_id',p_shopping_item_id,'expected_revision',p_expected_revision,'source',p_source
    ))
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;
  select * into v_item from public.shopping_items where household_id=p_household_id and id=p_shopping_item_id for update;
  if not found then raise exception 'SHOPPING_ITEM_NOT_FOUND'; end if;
  if v_item.test_context_id is distinct from p_test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_item.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if v_item.status not in ('wanted','assigned','ordered') then raise exception 'INVALID_SHOPPING_TRANSITION'; end if;
  update public.shopping_items set status='cancelled',ordered_at=null,purchased_at=null,arrived_at=null,
    active_claimant_actor_ref_id=null,claimed_at=null,revision=revision+1
  where id=p_shopping_item_id returning revision into v_revision;
  insert into public.shopping_events (
    household_id,shopping_item_id,actor_ref_id,event_type,aggregate_revision,payload,source,idempotency_key,test_context_id
  ) values (p_household_id,p_shopping_item_id,p_actor_ref_id,'cancelled',v_revision,'{}',p_source,
    'canonical:'||p_operation_id::text,p_test_context_id);
  v_result:=jsonb_build_object('shopping_item_id',p_shopping_item_id,'status','cancelled','revision',v_revision);
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'shopping',p_shopping_item_id,v_result);
  return v_result;
end;
$$;

-- Public production adapters used by PWA and existing LINE pending actions.
create or replace function public.server_tx_add_shopping_item_v2(
  p_actor_id uuid,p_operation_id uuid,p_title text,p_purchase_method text,
  p_assignment_mode text,p_assignee_user_id uuid,p_duplicate_sensitivity text,
  p_url text,p_due_at timestamptz
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare c jsonb; a uuid;
begin
  c:=private.fn_require_production_actor_context_v1(p_actor_id);
  if p_assignee_user_id is not null then
    select id into a from public.domain_actor_refs where household_id=(c->>'household_id')::uuid
      and actor_kind='real_user' and real_user_id=p_assignee_user_id;
    if a is null then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  end if;
  return private.fn_command_create_shopping_item_v1(
    (c->>'household_id')::uuid,p_actor_id,(c->>'actor_ref_id')::uuid,null,
    p_title,p_purchase_method,p_assignment_mode,a,p_duplicate_sensitivity,p_url,p_due_at,
    p_operation_id,'pwa'
  );
end; $$;

create or replace function public.server_tx_set_shopping_assignment_v2(
  p_actor_id uuid,p_operation_id uuid,p_shopping_item_id uuid,p_assignment_mode text,
  p_assignee_user_id uuid,p_expected_revision bigint
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare c jsonb; a uuid;
begin
  c:=private.fn_require_production_actor_context_v1(p_actor_id);
  if p_assignee_user_id is not null then
    select id into a from public.domain_actor_refs where household_id=(c->>'household_id')::uuid
      and actor_kind='real_user' and real_user_id=p_assignee_user_id;
    if a is null then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  end if;
  return private.fn_command_set_shopping_assignment_v1(
    (c->>'household_id')::uuid,p_actor_id,(c->>'actor_ref_id')::uuid,null,
    p_shopping_item_id,p_assignment_mode,a,p_expected_revision,p_operation_id,'pwa'
  );
end; $$;

create or replace function public.server_tx_shopping_claim_v2(
  p_actor_id uuid,p_operation_id uuid,p_shopping_item_id uuid,p_action text,p_expected_revision bigint
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare c jsonb;
begin c:=private.fn_require_production_actor_context_v1(p_actor_id);
  return private.fn_command_shopping_claim_v1((c->>'household_id')::uuid,p_actor_id,
    (c->>'actor_ref_id')::uuid,null,p_shopping_item_id,p_action,p_expected_revision,p_operation_id,'pwa');
end; $$;

create or replace function public.server_tx_shopping_action_v2(
  p_actor_id uuid,p_operation_id uuid,p_shopping_item_id uuid,p_action text,
  p_expected_revision bigint,p_reason text default null
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare c jsonb;
begin c:=private.fn_require_production_actor_context_v1(p_actor_id);
  if p_action in ('ordered','purchased','arrived') then
    return private.fn_command_complete_shopping_item_v1((c->>'household_id')::uuid,p_actor_id,
      (c->>'actor_ref_id')::uuid,null,p_shopping_item_id,p_action,(c->>'actor_ref_id')::uuid,
      p_expected_revision,p_operation_id,'pwa');
  elsif p_action='reopen' then
    return private.fn_command_reopen_shopping_item_v1((c->>'household_id')::uuid,p_actor_id,
      (c->>'actor_ref_id')::uuid,null,p_shopping_item_id,p_reason,p_expected_revision,p_operation_id,'pwa');
  elsif p_action='cancel' then
    return private.fn_command_cancel_shopping_item_v1((c->>'household_id')::uuid,p_actor_id,
      (c->>'actor_ref_id')::uuid,null,p_shopping_item_id,p_expected_revision,p_operation_id,'pwa');
  end if;
  raise exception 'INVALID_SHOPPING_TRANSITION';
end; $$;

-- Compatibility signatures remain callable but delegate to the same canonical
-- commands. New clients use v2 and send expected_revision.
create or replace function public.server_tx_add_shopping_item(
  p_actor_id uuid,p_operation_id uuid,p_title text,p_purchase_method text,
  p_assignee_user_id uuid,p_url text,p_due_at timestamptz
) returns jsonb language sql security invoker set search_path='' as $$
  select public.server_tx_add_shopping_item_v2($1,$2,$3,$4,
    case when $5 is null then 'unassigned' else 'person' end,$5,'avoid_duplicate',$6,$7);
$$;
create or replace function public.server_tx_assign_shopping_item(
  p_actor_id uuid,p_operation_id uuid,p_shopping_item_id uuid,p_assignee_user_id uuid,p_unassign boolean
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare r bigint;
begin select revision into r from public.shopping_items where id=p_shopping_item_id;
  return public.server_tx_set_shopping_assignment_v2(p_actor_id,p_operation_id,p_shopping_item_id,
    case when coalesce(p_unassign,false) then 'unassigned' else 'person' end,
    case when coalesce(p_unassign,false) then null else p_assignee_user_id end,r);
end; $$;
create or replace function public.server_tx_order_shopping_item(p_actor_id uuid,p_operation_id uuid,p_shopping_item_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$ declare r bigint;
begin select revision into r from public.shopping_items where id=p_shopping_item_id;
return public.server_tx_shopping_action_v2(p_actor_id,p_operation_id,p_shopping_item_id,'ordered',r,null); end; $$;
create or replace function public.server_tx_purchase_shopping_item(p_actor_id uuid,p_operation_id uuid,p_shopping_item_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$ declare r bigint;
begin select revision into r from public.shopping_items where id=p_shopping_item_id;
return public.server_tx_shopping_action_v2(p_actor_id,p_operation_id,p_shopping_item_id,'purchased',r,null); end; $$;
create or replace function public.server_tx_arrive_shopping_item(p_actor_id uuid,p_operation_id uuid,p_shopping_item_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$ declare r bigint;
begin select revision into r from public.shopping_items where id=p_shopping_item_id;
return public.server_tx_shopping_action_v2(p_actor_id,p_operation_id,p_shopping_item_id,'arrived',r,null); end; $$;
create or replace function public.server_tx_cancel_shopping_item(p_actor_id uuid,p_operation_id uuid,p_shopping_item_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$ declare r bigint;
begin select revision into r from public.shopping_items where id=p_shopping_item_id;
return public.server_tx_shopping_action_v2(p_actor_id,p_operation_id,p_shopping_item_id,'cancel',r,null); end; $$;

revoke all on function public.server_tx_add_shopping_item_v2(uuid,uuid,text,text,text,uuid,text,text,timestamptz) from public,anon,authenticated;
revoke all on function public.server_tx_set_shopping_assignment_v2(uuid,uuid,uuid,text,uuid,bigint) from public,anon,authenticated;
revoke all on function public.server_tx_shopping_claim_v2(uuid,uuid,uuid,text,bigint) from public,anon,authenticated;
revoke all on function public.server_tx_shopping_action_v2(uuid,uuid,uuid,text,bigint,text) from public,anon,authenticated;
grant execute on function public.server_tx_add_shopping_item_v2(uuid,uuid,text,text,text,uuid,text,text,timestamptz) to service_role;
grant execute on function public.server_tx_set_shopping_assignment_v2(uuid,uuid,uuid,text,uuid,bigint) to service_role;
grant execute on function public.server_tx_shopping_claim_v2(uuid,uuid,uuid,text,bigint) to service_role;
grant execute on function public.server_tx_shopping_action_v2(uuid,uuid,uuid,text,bigint,text) to service_role;

-- All private command signatures are service-role only.
revoke all on function private.fn_command_create_shopping_item_v1(uuid,uuid,uuid,uuid,text,text,text,uuid,text,text,timestamptz,uuid,text) from public,anon,authenticated;
revoke all on function private.fn_command_set_shopping_assignment_v1(uuid,uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,text) from public,anon,authenticated;
revoke all on function private.fn_command_shopping_claim_v1(uuid,uuid,uuid,uuid,uuid,text,bigint,uuid,text) from public,anon,authenticated;
revoke all on function private.fn_command_complete_shopping_item_v1(uuid,uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,text) from public,anon,authenticated;
revoke all on function private.fn_command_reopen_shopping_item_v1(uuid,uuid,uuid,uuid,uuid,text,bigint,uuid,text) from public,anon,authenticated;
revoke all on function private.fn_command_cancel_shopping_item_v1(uuid,uuid,uuid,uuid,uuid,bigint,uuid,text) from public,anon,authenticated;
grant execute on function private.fn_command_create_shopping_item_v1(uuid,uuid,uuid,uuid,text,text,text,uuid,text,text,timestamptz,uuid,text) to service_role;
grant execute on function private.fn_command_set_shopping_assignment_v1(uuid,uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,text) to service_role;
grant execute on function private.fn_command_shopping_claim_v1(uuid,uuid,uuid,uuid,uuid,text,bigint,uuid,text) to service_role;
grant execute on function private.fn_command_complete_shopping_item_v1(uuid,uuid,uuid,uuid,uuid,text,uuid,bigint,uuid,text) to service_role;
grant execute on function private.fn_command_reopen_shopping_item_v1(uuid,uuid,uuid,uuid,uuid,text,bigint,uuid,text) to service_role;
grant execute on function private.fn_command_cancel_shopping_item_v1(uuid,uuid,uuid,uuid,uuid,bigint,uuid,text) to service_role;
