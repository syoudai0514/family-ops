-- Appendix A Q110-Q112 closeout.
-- Google remains schedule-first and may update provider cache automatically, but a
-- Family Ops value protected by a human confirmation is never silently replaced.
-- Deletion and deterministic duplicate matches become explicit review candidates.

create table public.google_event_review_candidates (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id),
  family_event_id uuid not null,
  calendar_connection_id uuid not null references public.calendar_connections(id),
  google_event_id text not null check (length(btrim(google_event_id)) between 1 and 1024),
  candidate_kind text not null check (candidate_kind in ('protected_change','google_deleted','possible_duplicate')),
  google_title text null check (google_title is null or length(google_title) <= 240),
  google_status text not null,
  google_all_day boolean not null default false,
  google_starts_at timestamptz null,
  google_ends_at timestamptz null,
  google_starts_on date null,
  google_ends_on date null,
  google_location_text text null check (google_location_text is null or length(google_location_text) <= 500),
  changed_fields text[] not null default '{}'::text[]
    check (changed_fields <@ array['title','schedule','location','status','identity']::text[]),
  source_etag text null check (source_etag is null or length(source_etag) <= 1024),
  status text not null default 'pending' check (status in ('pending','resolved','superseded')),
  resolution text null check (resolution is null or resolution in ('accept_google','keep_family','same_event','different_event')),
  revision bigint not null default 1 check (revision >= 1),
  resolved_at timestamptz null,
  resolved_by_actor_ref_id uuid null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(household_id,id),
  foreign key(household_id,family_event_id) references public.family_events(household_id,id),
  foreign key(household_id,resolved_by_actor_ref_id) references public.domain_actor_refs(household_id,id),
  check (
    status='pending' and resolution is null and resolved_at is null and resolved_by_actor_ref_id is null
    or status='superseded' and resolution is null and resolved_by_actor_ref_id is null
    or status='resolved' and resolution is not null and resolved_at is not null and resolved_by_actor_ref_id is not null
  ),
  check (
    candidate_kind='google_deleted'
    or (google_all_day and google_starts_on is not null and google_ends_on is not null
        and google_starts_at is null and google_ends_at is null and google_ends_on >= google_starts_on)
    or (not google_all_day and google_starts_at is not null and google_ends_at is not null
        and google_starts_on is null and google_ends_on is null and google_ends_at >= google_starts_at)
  )
);
create unique index google_event_review_one_pending_idx
  on public.google_event_review_candidates(calendar_connection_id,google_event_id,family_event_id,candidate_kind)
  where status='pending';
create index google_event_review_household_pending_idx
  on public.google_event_review_candidates(household_id,status,created_at desc);
revoke all on table public.google_event_review_candidates from public,anon,authenticated;
grant select,insert,update on table public.google_event_review_candidates to service_role;

create trigger set_updated_at
  before update on public.google_event_review_candidates
  for each row execute function public.set_updated_at();

create or replace function private.fn_upsert_google_event_review_v1(
  p_household_id uuid,
  p_family_event_id uuid,
  p_calendar_connection_id uuid,
  p_google_event_id text,
  p_candidate_kind text,
  p_google_title text,
  p_google_status text,
  p_google_all_day boolean,
  p_google_starts_at timestamptz,
  p_google_ends_at timestamptz,
  p_google_starts_on date,
  p_google_ends_on date,
  p_google_location_text text,
  p_changed_fields text[],
  p_source_etag text
) returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare v_id uuid;
begin
  if p_candidate_kind not in ('protected_change','google_deleted','possible_duplicate') then
    raise exception 'GOOGLE_REVIEW_KIND_INVALID';
  end if;
  insert into public.google_event_review_candidates(
    household_id,family_event_id,calendar_connection_id,google_event_id,candidate_kind,
    google_title,google_status,google_all_day,google_starts_at,google_ends_at,
    google_starts_on,google_ends_on,google_location_text,changed_fields,source_etag
  ) values(
    p_household_id,p_family_event_id,p_calendar_connection_id,p_google_event_id,p_candidate_kind,
    left(p_google_title,240),coalesce(p_google_status,'confirmed'),coalesce(p_google_all_day,false),
    p_google_starts_at,p_google_ends_at,p_google_starts_on,p_google_ends_on,
    left(p_google_location_text,500),coalesce(p_changed_fields,'{}'::text[]),left(p_source_etag,1024)
  )
  on conflict(calendar_connection_id,google_event_id,family_event_id,candidate_kind)
    where status='pending'
  do update set
    google_title=excluded.google_title,
    google_status=excluded.google_status,
    google_all_day=excluded.google_all_day,
    google_starts_at=excluded.google_starts_at,
    google_ends_at=excluded.google_ends_at,
    google_starts_on=excluded.google_starts_on,
    google_ends_on=excluded.google_ends_on,
    google_location_text=excluded.google_location_text,
    changed_fields=excluded.changed_fields,
    source_etag=excluded.source_etag,
    revision=public.google_event_review_candidates.revision+1
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function private.fn_upsert_google_event_review_v1(uuid,uuid,uuid,text,text,text,text,boolean,timestamptz,timestamptz,date,date,text,text[],text)
  from public,anon,authenticated;
grant execute on function private.fn_upsert_google_event_review_v1(uuid,uuid,uuid,text,text,text,text,boolean,timestamptz,timestamptz,date,date,text,text[],text)
  to service_role;

create or replace function private.fn_reconcile_google_cache_row_to_family_event_v1(
  p_calendar_connection_id uuid,
  p_google_event_id text
) returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  v_cache public.calendar_events_cache%rowtype;
  v_link public.family_event_external_links%rowtype;
  v_event public.family_events%rowtype;
  v_dup public.family_events%rowtype;
  v_google_all_day boolean;
  v_google_ends_on date;
  v_title_auth text;
  v_schedule_auth text;
  v_location_auth text;
  v_title_diff boolean;
  v_schedule_diff boolean;
  v_location_diff boolean;
  v_protected_fields text[] := '{}'::text[];
  v_auto_title boolean := false;
  v_auto_schedule boolean := false;
  v_auto_location boolean := false;
begin
  select * into v_cache
  from public.calendar_events_cache c
  where c.calendar_connection_id=p_calendar_connection_id
    and c.google_event_id=p_google_event_id;
  if not found then return; end if;

  v_google_all_day := v_cache.all_day_start is not null;
  v_google_ends_on := case
    when v_cache.all_day_end_exclusive is null then null
    else v_cache.all_day_end_exclusive - 1
  end;

  select * into v_link
  from public.family_event_external_links l
  where l.calendar_connection_id=p_calendar_connection_id
    and l.google_event_id=p_google_event_id
    and l.test_context_id is null
  limit 1;

  if found then
    select * into v_event from public.family_events e
    where e.household_id=v_link.household_id and e.id=v_link.family_event_id
      and e.test_context_id is null;
    if not found then return; end if;

    if v_cache.status='cancelled' or v_cache.tombstone_kind is not null then
      perform private.fn_upsert_google_event_review_v1(
        v_event.household_id,v_event.id,p_calendar_connection_id,p_google_event_id,
        'google_deleted',v_cache.title,v_cache.status,v_google_all_day,
        v_cache.starts_at,v_cache.ends_at,v_cache.all_day_start,v_google_ends_on,
        v_cache.location,array['status']::text[],v_cache.etag
      );
      update public.family_event_external_links
        set last_external_etag=v_cache.etag,last_reconciled_at=now()
      where id=v_link.id;
      return;
    end if;

    update public.google_event_review_candidates
      set status='superseded',revision=revision+1
    where calendar_connection_id=p_calendar_connection_id and google_event_id=p_google_event_id
      and family_event_id=v_event.id and candidate_kind='google_deleted' and status='pending';

    v_title_auth := coalesce((select a.authority_mode from public.family_event_field_authorities a
      where a.family_event_id=v_event.id and a.field_name='title'),'human_protected');
    v_schedule_auth := coalesce((select a.authority_mode from public.family_event_field_authorities a
      where a.family_event_id=v_event.id and a.field_name='schedule'),'human_protected');
    v_location_auth := coalesce((select a.authority_mode from public.family_event_field_authorities a
      where a.family_event_id=v_event.id and a.field_name='location'),'human_protected');

    v_title_diff := v_event.title is distinct from v_cache.title;
    v_schedule_diff := v_event.all_day is distinct from v_google_all_day
      or (v_google_all_day and (v_event.starts_on is distinct from v_cache.all_day_start
          or v_event.ends_on is distinct from v_google_ends_on))
      or (not v_google_all_day and (v_event.starts_at is distinct from v_cache.starts_at
          or v_event.ends_at is distinct from v_cache.ends_at));
    v_location_diff := v_event.location_text is distinct from v_cache.location;

    if v_title_diff then
      if v_title_auth='external_follow' and v_cache.title is not null
         and length(btrim(v_cache.title)) between 1 and 240 then v_auto_title:=true;
      else v_protected_fields:=array_append(v_protected_fields,'title'); end if;
    end if;
    if v_schedule_diff then
      if v_schedule_auth='external_follow'
         and ((v_google_all_day and v_cache.all_day_start is not null and v_google_ends_on is not null)
           or (not v_google_all_day and v_cache.starts_at is not null and v_cache.ends_at is not null))
      then v_auto_schedule:=true;
      else v_protected_fields:=array_append(v_protected_fields,'schedule'); end if;
    end if;
    if v_location_diff then
      if v_location_auth='external_follow' then v_auto_location:=true;
      else v_protected_fields:=array_append(v_protected_fields,'location'); end if;
    end if;

    if v_auto_title or v_auto_schedule or v_auto_location then
      update public.family_events e set
        title=case when v_auto_title then v_cache.title else e.title end,
        all_day=case when v_auto_schedule then v_google_all_day else e.all_day end,
        starts_on=case when v_auto_schedule then case when v_google_all_day then v_cache.all_day_start else null end else e.starts_on end,
        ends_on=case when v_auto_schedule then case when v_google_all_day then v_google_ends_on else null end else e.ends_on end,
        starts_at=case when v_auto_schedule then case when v_google_all_day then null else v_cache.starts_at end else e.starts_at end,
        ends_at=case when v_auto_schedule then case when v_google_all_day then null else v_cache.ends_at end else e.ends_at end,
        location_text=case when v_auto_location then v_cache.location else e.location_text end,
        revision=e.revision+1
      where e.household_id=v_event.household_id and e.id=v_event.id;
    end if;

    if cardinality(v_protected_fields)>0 then
      perform private.fn_upsert_google_event_review_v1(
        v_event.household_id,v_event.id,p_calendar_connection_id,p_google_event_id,
        'protected_change',v_cache.title,v_cache.status,v_google_all_day,
        v_cache.starts_at,v_cache.ends_at,v_cache.all_day_start,v_google_ends_on,
        v_cache.location,v_protected_fields,v_cache.etag
      );
    else
      update public.google_event_review_candidates
        set status='superseded',revision=revision+1
      where calendar_connection_id=p_calendar_connection_id and google_event_id=p_google_event_id
        and family_event_id=v_event.id and candidate_kind='protected_change' and status='pending';
    end if;

    update public.family_event_external_links
      set last_external_etag=v_cache.etag,last_reconciled_at=now()
    where id=v_link.id;
    return;
  end if;

  -- An unlinked Google item is never auto-merged. Only deterministic exact
  -- schedule+normalized-title matches are offered as possible duplicates.
  if v_cache.status='cancelled' or v_cache.tombstone_kind is not null or v_cache.title is null then
    return;
  end if;
  for v_dup in
    select e.* from public.family_events e
    where e.household_id=v_cache.household_id
      and e.test_context_id is null and e.status<>'cancelled'
      and lower(regexp_replace(btrim(e.title),'[[:space:]]+',' ','g'))
          = lower(regexp_replace(btrim(v_cache.title),'[[:space:]]+',' ','g'))
      and (
        (v_google_all_day and e.all_day and e.starts_on=v_cache.all_day_start and e.ends_on=v_google_ends_on)
        or
        (not v_google_all_day and not e.all_day and e.starts_at=v_cache.starts_at and e.ends_at=v_cache.ends_at)
      )
  loop
    -- A reviewed "different event" decision remains sticky for the same Google
    -- version. A later provider edit (new etag) may legitimately raise it again.
    if exists(
      select 1 from public.google_event_review_candidates r
      where r.calendar_connection_id=p_calendar_connection_id and r.google_event_id=p_google_event_id
        and r.family_event_id=v_dup.id and r.candidate_kind='possible_duplicate'
        and r.status='resolved' and r.resolution='different_event'
        and r.source_etag is not distinct from v_cache.etag
    ) then continue; end if;
    perform private.fn_upsert_google_event_review_v1(
      v_dup.household_id,v_dup.id,p_calendar_connection_id,p_google_event_id,
      'possible_duplicate',v_cache.title,v_cache.status,v_google_all_day,
      v_cache.starts_at,v_cache.ends_at,v_cache.all_day_start,v_google_ends_on,
      v_cache.location,array['identity']::text[],v_cache.etag
    );
  end loop;
end;
$$;
revoke all on function private.fn_reconcile_google_cache_row_to_family_event_v1(uuid,text)
  from public,anon,authenticated;
grant execute on function private.fn_reconcile_google_cache_row_to_family_event_v1(uuid,text) to service_role;

create or replace function private.fn_google_cache_family_event_review_trigger_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  perform private.fn_reconcile_google_cache_row_to_family_event_v1(new.calendar_connection_id,new.google_event_id);
  return new;
end;
$$;
revoke all on function private.fn_google_cache_family_event_review_trigger_v1() from public,anon,authenticated;
grant execute on function private.fn_google_cache_family_event_review_trigger_v1() to service_role;

drop trigger if exists google_cache_family_event_review_v1 on public.calendar_events_cache;
create trigger google_cache_family_event_review_v1
  after insert or update of title,location,starts_at,ends_at,all_day_start,all_day_end_exclusive,status,tombstone_kind,etag
  on public.calendar_events_cache
  for each row execute function private.fn_google_cache_family_event_review_trigger_v1();

create or replace function public.server_read_google_event_reviews(p_actor_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare v_context jsonb; v_household_id uuid; v_result jsonb;
begin
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',r.id,'revision',r.revision,'candidate_kind',r.candidate_kind,
    'family_event_id',r.family_event_id,'family_event_title',e.title,
    'google_event_id',r.google_event_id,'google_title',r.google_title,
    'google_status',r.google_status,'google_all_day',r.google_all_day,
    'google_starts_at',r.google_starts_at,'google_ends_at',r.google_ends_at,
    'google_starts_on',r.google_starts_on,'google_ends_on',r.google_ends_on,
    'google_location_text',r.google_location_text,'changed_fields',to_jsonb(r.changed_fields),
    'detected_at',r.created_at
  ) order by r.created_at desc),'[]'::jsonb) into v_result
  from public.google_event_review_candidates r
  join public.family_events e on e.household_id=r.household_id and e.id=r.family_event_id
  where r.household_id=v_household_id and r.status='pending';
  return v_result;
end;
$$;
revoke all on function public.server_read_google_event_reviews(uuid) from public,anon,authenticated;
grant execute on function public.server_read_google_event_reviews(uuid) to service_role;

create or replace function public.server_tx_resolve_google_event_review(
  p_actor_id uuid,
  p_operation_id uuid,
  p_candidate_id uuid,
  p_expected_revision bigint,
  p_resolution text
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_candidate public.google_event_review_candidates%rowtype;
  v_hash text;
  v_receipt private.mutation_receipts%rowtype;
  v_result jsonb;
  v_link_id uuid;
begin
  if p_actor_id is null or p_operation_id is null or p_candidate_id is null
     or p_expected_revision is null or p_resolution not in ('accept_google','keep_family','same_event','different_event') then
    raise exception 'INVALID_INPUT';
  end if;
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid;
  v_actor_ref_id:=(v_context->>'actor_ref_id')::uuid;
  v_hash:=encode(sha256(convert_to(
    'google-event-review|'||p_candidate_id::text||'|'||p_expected_revision::text||'|'||p_resolution,'UTF8'
  )),'hex');

  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
      values(p_actor_id,p_operation_id,'google-event-review',v_hash)
      on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts
      where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if;
    return v_receipt.result_payload;
  end loop;

  select * into v_candidate from public.google_event_review_candidates r
  where r.id=p_candidate_id and r.household_id=v_household_id for update;
  if not found then raise exception 'GOOGLE_REVIEW_NOT_FOUND'; end if;
  if v_candidate.status<>'pending' then raise exception 'GOOGLE_REVIEW_NOT_PENDING'; end if;
  if v_candidate.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;

  if v_candidate.candidate_kind='possible_duplicate' then
    if p_resolution not in ('same_event','different_event') then raise exception 'GOOGLE_REVIEW_RESOLUTION_INVALID'; end if;
    if p_resolution='same_event' then
      insert into public.family_event_external_links(
        household_id,family_event_id,provider,calendar_connection_id,google_event_id,
        link_mode,last_external_etag,last_reconciled_at,writer_enabled,ownership_transfer_state
      ) values(
        v_household_id,v_candidate.family_event_id,'google',v_candidate.calendar_connection_id,
        v_candidate.google_event_id,'external_follow',v_candidate.source_etag,now(),false,'inactive'
      ) on conflict(calendar_connection_id,google_event_id) do nothing
      returning id into v_link_id;
      if v_link_id is null and not exists(
        select 1 from public.family_event_external_links l
        where l.calendar_connection_id=v_candidate.calendar_connection_id
          and l.google_event_id=v_candidate.google_event_id
          and l.family_event_id=v_candidate.family_event_id
      ) then raise exception 'GOOGLE_EVENT_ALREADY_LINKED'; end if;

      update public.google_event_review_candidates
        set status='superseded',revision=revision+1
      where calendar_connection_id=v_candidate.calendar_connection_id
        and google_event_id=v_candidate.google_event_id
        and candidate_kind='possible_duplicate' and status='pending' and id<>v_candidate.id;
    end if;
  elsif v_candidate.candidate_kind='protected_change' then
    if p_resolution not in ('accept_google','keep_family') then raise exception 'GOOGLE_REVIEW_RESOLUTION_INVALID'; end if;
    if p_resolution='accept_google' then
      update public.family_events e set
        title=case when 'title'=any(v_candidate.changed_fields) then coalesce(nullif(btrim(v_candidate.google_title),''),e.title) else e.title end,
        all_day=case when 'schedule'=any(v_candidate.changed_fields) then v_candidate.google_all_day else e.all_day end,
        starts_on=case when 'schedule'=any(v_candidate.changed_fields) then case when v_candidate.google_all_day then v_candidate.google_starts_on else null end else e.starts_on end,
        ends_on=case when 'schedule'=any(v_candidate.changed_fields) then case when v_candidate.google_all_day then v_candidate.google_ends_on else null end else e.ends_on end,
        starts_at=case when 'schedule'=any(v_candidate.changed_fields) then case when v_candidate.google_all_day then null else v_candidate.google_starts_at end else e.starts_at end,
        ends_at=case when 'schedule'=any(v_candidate.changed_fields) then case when v_candidate.google_all_day then null else v_candidate.google_ends_at end else e.ends_at end,
        location_text=case when 'location'=any(v_candidate.changed_fields) then v_candidate.google_location_text else e.location_text end,
        revision=e.revision+1
      where e.household_id=v_household_id and e.id=v_candidate.family_event_id;
    end if;
  elsif v_candidate.candidate_kind='google_deleted' then
    if p_resolution not in ('accept_google','keep_family') then raise exception 'GOOGLE_REVIEW_RESOLUTION_INVALID'; end if;
    if p_resolution='accept_google' then
      update public.family_events set status='cancelled',revision=revision+1
      where household_id=v_household_id and id=v_candidate.family_event_id;
    end if;
  end if;

  update public.google_event_review_candidates
    set status='resolved',resolution=p_resolution,resolved_at=now(),
        resolved_by_actor_ref_id=v_actor_ref_id,revision=revision+1
  where id=v_candidate.id;

  if v_candidate.candidate_kind='possible_duplicate' and p_resolution='same_event' then
    perform private.fn_reconcile_google_cache_row_to_family_event_v1(
      v_candidate.calendar_connection_id,v_candidate.google_event_id
    );
  end if;

  v_result:=jsonb_build_object(
    'candidate_id',v_candidate.id,'candidate_kind',v_candidate.candidate_kind,
    'resolution',p_resolution,'status','resolved'
  );
  update private.mutation_receipts
    set result_type='google_event_review',result_id=v_candidate.id,result_payload=v_result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end;
$$;
revoke all on function public.server_tx_resolve_google_event_review(uuid,uuid,uuid,bigint,text)
  from public,anon,authenticated;
grant execute on function public.server_tx_resolve_google_event_review(uuid,uuid,uuid,bigint,text)
  to service_role;
