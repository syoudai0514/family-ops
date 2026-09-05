-- Q89-Q106: LINE nursery-image intake and human-reviewed orchestration.
-- This is deliberately an orchestration layer over DD9. Raw images stay in
-- private source_documents/storage; source-explicit facts and AI inference
-- remain separate. No task/rule/recurrence mutation happens before confirm.

create table private.nursery_line_image_intakes (
  id uuid primary key default gen_random_uuid(),
  provider_event_id text not null unique,
  line_message_id text not null unique,
  household_id uuid not null references public.households(id),
  actor_id uuid not null,
  actor_ref_id uuid not null,
  line_user_id text not null,
  status text not null default 'received' check (status in (
    'received','processing','ordinary_photo','needs_clarification','review_ready',
    'confirmed','cancelled','failed'
  )),
  revision bigint not null default 1 check (revision >= 1),
  source_document_id uuid null references private.source_documents(id),
  extraction_id uuid null references private.document_extractions(id),
  document_group_id uuid null,
  page_index smallint null check (page_index between 1 and 32),
  child_school_context_id uuid null,
  context_confidence text null check (context_confidence in ('high','medium','low')),
  ambiguity_fields text[] not null default '{}',
  raw_deleted_at timestamptz null,
  received_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (household_id, actor_id) references public.household_members(household_id,user_id),
  foreign key (household_id, actor_ref_id) references public.domain_actor_refs(household_id,id),
  foreign key (household_id, child_school_context_id) references public.child_school_contexts(household_id,id),
  check (ambiguity_fields <@ array['nursery','child','class','date','document_group']::text[])
);
revoke all on private.nursery_line_image_intakes from public,anon,authenticated;
grant select,insert,update,delete on private.nursery_line_image_intakes to service_role;
create index nursery_line_image_intakes_queue_idx on private.nursery_line_image_intakes(status,received_at);
create index nursery_line_image_intakes_actor_idx on private.nursery_line_image_intakes(household_id,actor_id,received_at desc);

create table private.nursery_document_groups (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id),
  line_user_id text not null,
  status text not null default 'open' check (status in ('open','review_ready','confirmed','split')),
  page_count smallint not null default 1 check (page_count between 1 and 12),
  revision bigint not null default 1 check (revision >= 1),
  first_received_at timestamptz not null,
  last_received_at timestamptz not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
revoke all on private.nursery_document_groups from public,anon,authenticated;
grant select,insert,update,delete on private.nursery_document_groups to service_role;
alter table private.nursery_line_image_intakes add constraint nursery_line_image_group_fk
  foreign key (document_group_id) references private.nursery_document_groups(id);

-- Minimal review metadata only. Content is capped structured data, never a
-- transcript/roster/contact dump. `origin` is the DB truth surfaced by PWA.
create table private.nursery_review_items (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id),
  intake_id uuid not null references private.nursery_line_image_intakes(id) on delete cascade,
  candidate_key text not null,
  origin text not null check (origin in ('source_explicit','ai_inference')),
  item_kind text not null check (item_kind in ('preparation','task','timetable','submission','url','recurrence','exception')),
  classification text null check (classification is null or classification in ('recommended','other')),
  source_document_id uuid not null references private.source_documents(id),
  source_page smallint not null check (source_page between 1 and 32),
  source_locator text null check (source_locator is null or octet_length(source_locator)<=128),
  proposed_value jsonb not null,
  confidence_band text not null check (confidence_band in ('high','medium','low')),
  created_at timestamptz not null default now(),
  unique (intake_id,candidate_key),
  check (octet_length(proposed_value::text) <= 2048)
);
revoke all on private.nursery_review_items from public,anon,authenticated;
grant select,insert,update,delete on private.nursery_review_items to service_role;

create table public.nursery_confirmed_items (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id),
  child_school_context_id uuid not null,
  intake_id uuid not null,
  review_item_id uuid null,
  item_kind text not null check (item_kind in ('preparation','task','timetable','submission','url','recurrence','exception')),
  classification text null check (classification is null or classification in ('recommended','other')),
  confirmed_value jsonb not null,
  source_document_id uuid not null,
  source_page smallint not null check (source_page between 1 and 32),
  origin text not null check (origin in ('source_explicit','ai_inference','human_edit')),
  supersedes_confirmed_item_id uuid null references public.nursery_confirmed_items(id),
  confirmed_by_actor_ref_id uuid not null,
  confirmed_at timestamptz not null default now(),
  created_task_id uuid null,
  foreign key (household_id, child_school_context_id) references public.child_school_contexts(household_id,id),
  foreign key (household_id, confirmed_by_actor_ref_id) references public.domain_actor_refs(household_id,id),
  foreign key (household_id, created_task_id) references public.task_instances(household_id,id),
  check (octet_length(confirmed_value::text) <= 4096)
);
alter table public.nursery_confirmed_items enable row level security;
grant select on public.nursery_confirmed_items to authenticated;
create policy nursery_confirmed_items_select on public.nursery_confirmed_items for select to authenticated
  using (public.is_household_member(household_id));
create index nursery_confirmed_items_context_idx on public.nursery_confirmed_items(household_id,child_school_context_id,confirmed_at desc);

create table public.nursery_recurrence_series (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id),
  child_school_context_id uuid not null,
  rule_spec jsonb not null,
  effective_from date not null,
  effective_to date not null,
  active boolean not null default true,
  source_document_id uuid not null,
  source_page smallint not null check (source_page between 1 and 32),
  confirmed_by_actor_ref_id uuid not null,
  revision bigint not null default 1 check (revision>=1),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (household_id, child_school_context_id) references public.child_school_contexts(household_id,id),
  foreign key (household_id, confirmed_by_actor_ref_id) references public.domain_actor_refs(household_id,id),
  check (effective_to >= effective_from and effective_to <= effective_from + 366),
  check (octet_length(rule_spec::text)<=2048)
);
alter table public.nursery_recurrence_series enable row level security;
grant select on public.nursery_recurrence_series to authenticated;
create policy nursery_recurrence_series_select on public.nursery_recurrence_series for select to authenticated
  using (public.is_household_member(household_id));

create table public.nursery_recurrence_exceptions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id),
  series_id uuid not null references public.nursery_recurrence_series(id),
  occurrence_date date not null,
  exception_value jsonb not null,
  source_document_id uuid not null,
  source_page smallint not null check (source_page between 1 and 32),
  confirmed_by_actor_ref_id uuid not null,
  created_at timestamptz not null default now(),
  unique(series_id,occurrence_date),
  foreign key (household_id, confirmed_by_actor_ref_id) references public.domain_actor_refs(household_id,id),
  check (octet_length(exception_value::text)<=2048)
);
alter table public.nursery_recurrence_exceptions enable row level security;
grant select on public.nursery_recurrence_exceptions to authenticated;
create policy nursery_recurrence_exceptions_select on public.nursery_recurrence_exceptions for select to authenticated
  using (public.is_household_member(household_id));

create table private.nursery_confirmation_receipts (
  actor_id uuid not null,
  operation_id uuid not null,
  intake_id uuid not null,
  request_hash text not null,
  result jsonb null,
  created_at timestamptz not null default now(),
  primary key(actor_id,operation_id)
);
revoke all on private.nursery_confirmation_receipts from public,anon,authenticated;
grant select,insert,update on private.nursery_confirmation_receipts to service_role;

create or replace function private.fn_nursery_safe_confirmed_value(p_value jsonb)
returns void language plpgsql immutable set search_path='' as $$
declare v_text text:=coalesce(p_value::text,'');
begin
  if octet_length(v_text)>4096 then raise exception 'NURSERY_VALUE_TOO_LARGE'; end if;
  if v_text ~* '"(class_roster|other_children|third_party_contact|phone|email|raw_text|transcript)"\s*:' then
    raise exception 'NURSERY_THIRD_PARTY_DATA_FORBIDDEN';
  end if;
end $$;
revoke all on function private.fn_nursery_safe_confirmed_value(jsonb) from public,anon,authenticated;
grant execute on function private.fn_nursery_safe_confirmed_value(jsonb) to service_role;

create or replace function public.server_tx_enqueue_nursery_line_image(
  p_provider_event_id text,p_line_message_id text,p_line_user_id text,p_received_at timestamptz default now()
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_link private.line_user_links%rowtype; v_actor_ref uuid; v_id uuid;
begin
  if nullif(btrim(coalesce(p_provider_event_id,'')),'') is null or nullif(btrim(coalesce(p_line_message_id,'')),'') is null
     or nullif(btrim(coalesce(p_line_user_id,'')),'') is null then raise exception 'INVALID_INPUT'; end if;
  select * into v_link from private.line_user_links where line_user_id=p_line_user_id and status='active';
  if not found then return jsonb_build_object('disposition','unlinked'); end if;
  select id into v_actor_ref from public.domain_actor_refs where household_id=v_link.household_id and actor_kind='real_user' and real_user_id=v_link.user_id;
  if v_actor_ref is null then raise exception 'LINE_ACTOR_REF_NOT_FOUND'; end if;
  insert into private.nursery_line_image_intakes(provider_event_id,line_message_id,household_id,actor_id,actor_ref_id,line_user_id,received_at)
  values(p_provider_event_id,p_line_message_id,v_link.household_id,v_link.user_id,v_actor_ref,p_line_user_id,coalesce(p_received_at,now()))
  on conflict(provider_event_id) do nothing returning id into v_id;
  if v_id is null then select id into v_id from private.nursery_line_image_intakes where provider_event_id=p_provider_event_id; end if;
  return jsonb_build_object('disposition',case when found then 'existing' else 'created' end,'intake_id',v_id);
end $$;
revoke all on function public.server_tx_enqueue_nursery_line_image(text,text,text,timestamptz) from public,anon,authenticated;
grant execute on function public.server_tx_enqueue_nursery_line_image(text,text,text,timestamptz) to service_role;

create or replace function public.server_tx_claim_nursery_line_images(p_limit int,p_worker text)
returns setof private.nursery_line_image_intakes language plpgsql security invoker set search_path='' as $$
begin
  return query
  update private.nursery_line_image_intakes i set status='processing',revision=revision+1,updated_at=now()
  where i.id in (select q.id from private.nursery_line_image_intakes q where q.status='received' order by q.received_at for update skip locked limit greatest(1,least(coalesce(p_limit,5),20)))
  returning i.*;
end $$;
revoke all on function public.server_tx_claim_nursery_line_images(int,text) from public,anon,authenticated;
grant execute on function public.server_tx_claim_nursery_line_images(int,text) to service_role;

create or replace function public.server_tx_finish_nursery_image_review(
  p_intake_id uuid,p_expected_revision bigint,p_status text,p_source_document_id uuid,p_extraction_id uuid,
  p_child_school_context_id uuid,p_context_confidence text,p_ambiguity_fields text[],p_review_items jsonb,p_raw_deleted boolean default false
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_i private.nursery_line_image_intakes%rowtype; v_item jsonb; v_origin text; v_kind text; v_class text; v_page int; v_value jsonb;
begin
  if p_status not in ('ordinary_photo','needs_clarification','review_ready','failed') then raise exception 'NURSERY_STATUS_INVALID'; end if;
  select * into v_i from private.nursery_line_image_intakes where id=p_intake_id for update;
  if not found then raise exception 'NURSERY_INTAKE_NOT_FOUND'; end if;
  if v_i.status<>'processing' or v_i.revision<>p_expected_revision then raise exception 'NURSERY_INTAKE_STALE'; end if;
  if coalesce(p_ambiguity_fields,'{}')::text[] <@ array['nursery','child','class','date','document_group']::text[] is not true then raise exception 'NURSERY_AMBIGUITY_INVALID'; end if;
  if p_child_school_context_id is not null and not exists(select 1 from public.child_school_contexts c where c.household_id=v_i.household_id and c.id=p_child_school_context_id) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if p_source_document_id is not null and not exists(select 1 from private.source_documents d where d.household_id=v_i.household_id and d.id=p_source_document_id) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if p_status in ('review_ready','needs_clarification') and (p_source_document_id is null or p_extraction_id is null) then raise exception 'NURSERY_SOURCE_REQUIRED'; end if;
  delete from private.nursery_review_items where intake_id=p_intake_id;
  if jsonb_typeof(coalesce(p_review_items,'[]'::jsonb))<>'array' or jsonb_array_length(coalesce(p_review_items,'[]'::jsonb))>64 then raise exception 'NURSERY_REVIEW_ITEMS_INVALID'; end if;
  for v_item in select value from jsonb_array_elements(coalesce(p_review_items,'[]'::jsonb)) loop
    v_origin:=v_item->>'origin'; v_kind:=v_item->>'item_kind'; v_class:=nullif(v_item->>'classification',''); v_page:=coalesce((v_item->>'source_page')::int,1); v_value:=v_item->'proposed_value';
    perform private.fn_nursery_safe_confirmed_value(v_value);
    if v_origin not in ('source_explicit','ai_inference') or v_kind not in ('preparation','task','timetable','submission','url','recurrence','exception') then raise exception 'NURSERY_REVIEW_ITEM_INVALID'; end if;
    if v_kind='timetable' and v_class not in ('recommended','other') then raise exception 'NURSERY_TIMETABLE_CLASS_REQUIRED'; end if;
    insert into private.nursery_review_items(household_id,intake_id,candidate_key,origin,item_kind,classification,source_document_id,source_page,source_locator,proposed_value,confidence_band)
    values(v_i.household_id,p_intake_id,v_item->>'candidate_key',v_origin,v_kind,v_class,p_source_document_id,v_page,nullif(v_item->>'source_locator',''),v_value,coalesce(nullif(v_item->>'confidence_band',''),'medium'));
  end loop;
  update private.nursery_line_image_intakes set status=p_status,source_document_id=p_source_document_id,extraction_id=p_extraction_id,
    child_school_context_id=p_child_school_context_id,context_confidence=p_context_confidence,ambiguity_fields=coalesce(p_ambiguity_fields,'{}'),
    raw_deleted_at=case when p_raw_deleted then now() else raw_deleted_at end,revision=revision+1,updated_at=now()
  where id=p_intake_id returning * into v_i;
  return jsonb_build_object('intake_id',v_i.id,'status',v_i.status,'revision',v_i.revision);
end $$;
revoke all on function public.server_tx_finish_nursery_image_review(uuid,bigint,text,uuid,uuid,uuid,text,text[],jsonb,boolean) from public,anon,authenticated;
grant execute on function public.server_tx_finish_nursery_image_review(uuid,bigint,text,uuid,uuid,uuid,text,text[],jsonb,boolean) to service_role;

create or replace function public.server_tx_group_nursery_image_pages(p_previous_id uuid,p_current_id uuid,p_expected_current_revision bigint)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare a private.nursery_line_image_intakes%rowtype; b private.nursery_line_image_intakes%rowtype; g private.nursery_document_groups%rowtype;
begin
  select * into a from private.nursery_line_image_intakes where id=p_previous_id for update;
  select * into b from private.nursery_line_image_intakes where id=p_current_id for update;
  if not found or a.id is null then raise exception 'NURSERY_INTAKE_NOT_FOUND'; end if;
  if b.revision<>p_expected_current_revision then raise exception 'NURSERY_INTAKE_STALE'; end if;
  if a.household_id<>b.household_id or a.line_user_id<>b.line_user_id then raise exception 'NURSERY_GROUP_SCOPE_CONFLICT'; end if;
  if b.received_at<a.received_at or b.received_at-a.received_at>interval '10 minutes' then raise exception 'NURSERY_GROUP_WINDOW_CONFLICT'; end if;
  if a.document_group_id is null then
    insert into private.nursery_document_groups(household_id,line_user_id,page_count,first_received_at,last_received_at)
      values(a.household_id,a.line_user_id,2,a.received_at,b.received_at) returning * into g;
    update private.nursery_line_image_intakes set document_group_id=g.id,page_index=1,revision=revision+1,updated_at=now() where id=a.id;
  else
    select * into g from private.nursery_document_groups where id=a.document_group_id for update;
    if g.page_count>=12 then raise exception 'NURSERY_GROUP_PAGE_LIMIT'; end if;
    update private.nursery_document_groups set page_count=page_count+1,last_received_at=b.received_at,revision=revision+1,updated_at=now() where id=g.id returning * into g;
  end if;
  update private.nursery_line_image_intakes set document_group_id=g.id,page_index=g.page_count,revision=revision+1,updated_at=now() where id=b.id returning * into b;
  return jsonb_build_object('group_id',g.id,'page_index',b.page_index,'revision',b.revision);
end $$;
revoke all on function public.server_tx_group_nursery_image_pages(uuid,uuid,bigint) from public,anon,authenticated;
grant execute on function public.server_tx_group_nursery_image_pages(uuid,uuid,bigint) to service_role;

create or replace function public.server_read_nursery_review(p_actor_id uuid,p_intake_id uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare v_i private.nursery_line_image_intakes%rowtype; v_items jsonb;
begin
  select i.* into v_i from private.nursery_line_image_intakes i join public.household_members m on m.household_id=i.household_id
    where i.id=p_intake_id and m.user_id=p_actor_id;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'candidate_key',r.candidate_key,'origin',r.origin,'item_kind',r.item_kind,'classification',r.classification,
    'source_document_id',r.source_document_id,'source_page',r.source_page,'source_locator',r.source_locator,'proposed_value',r.proposed_value,'confidence_band',r.confidence_band) order by r.source_page,r.created_at),'[]'::jsonb)
    into v_items from private.nursery_review_items r where r.intake_id=v_i.id;
  return jsonb_build_object('intake_id',v_i.id,'status',v_i.status,'revision',v_i.revision,'child_school_context_id',v_i.child_school_context_id,
    'context_confidence',v_i.context_confidence,'ambiguity_fields',to_jsonb(v_i.ambiguity_fields),'source_document_id',v_i.source_document_id,
    'raw_available',v_i.raw_deleted_at is null and v_i.source_document_id is not null,'items',v_items);
end $$;
revoke all on function public.server_read_nursery_review(uuid,uuid) from public,anon,authenticated;
grant execute on function public.server_read_nursery_review(uuid,uuid) to service_role;

create or replace function public.server_tx_confirm_nursery_review(p_actor_id uuid,p_operation_id uuid,p_intake_id uuid,p_expected_revision bigint,p_selected_items jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_i private.nursery_line_image_intakes%rowtype; v_actor_ref uuid; v_hash text; v_receipt private.nursery_confirmation_receipts%rowtype;
  v_item jsonb; v_review private.nursery_review_items%rowtype; v_value jsonb; v_title text; v_date date; v_task jsonb; v_task_id uuid; v_confirmed_id uuid; v_series_id uuid;
begin
  if p_actor_id is null or p_operation_id is null or jsonb_typeof(p_selected_items)<>'array' or jsonb_array_length(p_selected_items)>64 then raise exception 'INVALID_INPUT'; end if;
  v_hash:=encode(sha256(convert_to(p_intake_id::text||'|'||p_expected_revision::text||'|'||p_selected_items::text,'UTF8')),'hex');
  insert into private.nursery_confirmation_receipts(actor_id,operation_id,intake_id,request_hash) values(p_actor_id,p_operation_id,p_intake_id,v_hash) on conflict do nothing;
  if not found then
    select * into v_receipt from private.nursery_confirmation_receipts where actor_id=p_actor_id and operation_id=p_operation_id;
    if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return v_receipt.result;
  end if;
  select i.* into v_i from private.nursery_line_image_intakes i join public.household_members m on m.household_id=i.household_id
    where i.id=p_intake_id and m.user_id=p_actor_id for update of i;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_i.status not in ('review_ready','needs_clarification') or v_i.revision<>p_expected_revision then raise exception 'NURSERY_INTAKE_STALE'; end if;
  if v_i.child_school_context_id is null or cardinality(v_i.ambiguity_fields)>0 then raise exception 'NURSERY_CLARIFICATION_REQUIRED'; end if;
  select id into v_actor_ref from public.domain_actor_refs where household_id=v_i.household_id and actor_kind='real_user' and real_user_id=p_actor_id;
  for v_item in select value from jsonb_array_elements(p_selected_items) loop
    select * into v_review from private.nursery_review_items where intake_id=v_i.id and id=(v_item->>'review_item_id')::uuid;
    if not found then raise exception 'NURSERY_REVIEW_ITEM_STALE'; end if;
    v_value:=coalesce(v_item->'confirmed_value',v_review.proposed_value); perform private.fn_nursery_safe_confirmed_value(v_value);
    if v_review.item_kind='url' and coalesce(v_value->>'url','') !~* '^https?://[^[:space:]]+$' then raise exception 'NURSERY_UNSAFE_URL'; end if;
    if v_review.item_kind='recurrence' then
      if (v_value->>'effective_to')::date < (v_value->>'effective_from')::date or (v_value->>'effective_to')::date > (v_value->>'effective_from')::date+366 then raise exception 'NURSERY_RECURRENCE_UNBOUNDED'; end if;
      insert into public.nursery_recurrence_series(household_id,child_school_context_id,rule_spec,effective_from,effective_to,source_document_id,source_page,confirmed_by_actor_ref_id)
      values(v_i.household_id,v_i.child_school_context_id,v_value->'rule_spec',(v_value->>'effective_from')::date,(v_value->>'effective_to')::date,v_review.source_document_id,v_review.source_page,v_actor_ref) returning id into v_series_id;
    elsif v_review.item_kind='exception' then
      v_series_id:=(v_value->>'series_id')::uuid;
      if not exists(select 1 from public.nursery_recurrence_series s where s.id=v_series_id and s.household_id=v_i.household_id and s.child_school_context_id=v_i.child_school_context_id) then raise exception 'NURSERY_SERIES_SCOPE_CONFLICT'; end if;
      insert into public.nursery_recurrence_exceptions(household_id,series_id,occurrence_date,exception_value,source_document_id,source_page,confirmed_by_actor_ref_id)
      values(v_i.household_id,v_series_id,(v_value->>'occurrence_date')::date,v_value,v_review.source_document_id,v_review.source_page,v_actor_ref);
    elsif v_review.item_kind in ('task','submission','url') then
      v_title:=nullif(btrim(coalesce(v_value->>'title','')),''); v_date:=coalesce(nullif(v_value->>'due_date','')::date,(now() at time zone 'Asia/Tokyo')::date);
      if v_title is null then raise exception 'NURSERY_TASK_TITLE_REQUIRED'; end if;
      select public.server_tx_create_task_with_calendar(p_actor_id,gen_random_uuid(),v_title,'nursery',v_date,null::time,null::time,'hidden',null::uuid,'whole','anytime',null::jsonb) into v_task;
      v_task_id:=(v_task->>'task_id')::uuid;
    elsif v_review.item_kind='preparation' then
      perform private.fn_command_confirm_school_preparation_rule_v1(v_i.household_id,p_actor_id,v_actor_ref,null,gen_random_uuid(),v_i.child_school_context_id,
        coalesce(v_value->'trigger_spec','{}'::jsonb),coalesce(v_value->'preparation_template',v_value),coalesce(nullif(v_value->>'effective_from','')::date,(now() at time zone 'Asia/Tokyo')::date),null,'pwa');
    end if;
    insert into public.nursery_confirmed_items(household_id,child_school_context_id,intake_id,review_item_id,item_kind,classification,confirmed_value,source_document_id,source_page,origin,confirmed_by_actor_ref_id,created_task_id)
    values(v_i.household_id,v_i.child_school_context_id,v_i.id,v_review.id,v_review.item_kind,v_review.classification,v_value,v_review.source_document_id,v_review.source_page,
      case when v_value is distinct from v_review.proposed_value then 'human_edit' else v_review.origin end,v_actor_ref,v_task_id) returning id into v_confirmed_id;
    v_task_id:=null;
  end loop;
  update private.nursery_line_image_intakes set status='confirmed',revision=revision+1,updated_at=now() where id=v_i.id;
  update private.nursery_confirmation_receipts set result=jsonb_build_object('confirmed',true,'intake_id',v_i.id) where actor_id=p_actor_id and operation_id=p_operation_id;
  return jsonb_build_object('confirmed',true,'intake_id',v_i.id);
end $$;
revoke all on function public.server_tx_confirm_nursery_review(uuid,uuid,uuid,bigint,jsonb) from public,anon,authenticated;
grant execute on function public.server_tx_confirm_nursery_review(uuid,uuid,uuid,bigint,jsonb) to service_role;

create or replace function public.server_tx_mark_nursery_raw_deleted(p_actor_id uuid,p_intake_id uuid,p_expected_revision bigint)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_i private.nursery_line_image_intakes%rowtype;
begin
  select i.* into v_i from private.nursery_line_image_intakes i join public.household_members m on m.household_id=i.household_id where i.id=p_intake_id and m.user_id=p_actor_id for update of i;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_i.revision<>p_expected_revision then raise exception 'NURSERY_INTAKE_STALE'; end if;
  if v_i.source_document_id is not null then update private.source_documents set raw_deleted_at=coalesce(raw_deleted_at,now()) where id=v_i.source_document_id and household_id=v_i.household_id; end if;
  update private.nursery_line_image_intakes set raw_deleted_at=coalesce(raw_deleted_at,now()),revision=revision+1,updated_at=now() where id=v_i.id returning * into v_i;
  return jsonb_build_object('deleted',true,'revision',v_i.revision);
end $$;
revoke all on function public.server_tx_mark_nursery_raw_deleted(uuid,uuid,bigint) from public,anon,authenticated;
grant execute on function public.server_tx_mark_nursery_raw_deleted(uuid,uuid,bigint) to service_role;

-- Keep source bucket private when running under a real Supabase stack. Plain
-- postgres CI has no storage schema, so this is intentionally conditional.
do $$ begin
  if to_regclass('storage.buckets') is not null then
    execute $q$insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
      values ('nursery-source','nursery-source',false,10485760,array['image/jpeg','image/png','image/heic','image/webp'])
      on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types$q$;
  end if;
end $$;
