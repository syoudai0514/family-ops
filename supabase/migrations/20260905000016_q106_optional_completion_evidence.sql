-- Q106: completion remains the existing one-tap complete-task command.
-- Evidence is an entirely optional post-completion action so ordinary task
-- completion never requires a memo, photo, modal, or second confirmation.

create table public.task_completion_evidence (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id),
  task_instance_id uuid not null,
  added_by uuid not null,
  note text null check (note is null or octet_length(note) <= 2000),
  image_mime text null check (image_mime is null or image_mime in ('image/jpeg','image/png','image/webp')),
  image_bytes bytea null check (image_bytes is null or octet_length(image_bytes) <= 2097152),
  created_at timestamptz not null default now(),
  unique(household_id,id),
  foreign key (household_id,task_instance_id) references public.task_instances(household_id,id) on delete cascade,
  foreign key (household_id,added_by) references public.household_members(household_id,user_id),
  check (note is not null or image_bytes is not null),
  check ((image_bytes is null) = (image_mime is null))
);
create index task_completion_evidence_task_idx
  on public.task_completion_evidence(household_id,task_instance_id,created_at desc);
alter table public.task_completion_evidence enable row level security;
grant select on public.task_completion_evidence to authenticated;
create policy task_completion_evidence_select on public.task_completion_evidence
  for select to authenticated using (public.is_household_member(household_id));

create or replace function public.server_tx_add_task_completion_evidence(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_note text default null,
  p_image_mime text default null,
  p_image_base64 text default null
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_task public.task_instances%rowtype;
  v_note text := nullif(btrim(coalesce(p_note,'')),'');
  v_image bytea;
  v_hash text;
  v_receipt private.mutation_receipts%rowtype;
  v_evidence_id uuid;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if v_note is not null and octet_length(v_note)>2000 then raise exception 'EVIDENCE_NOTE_TOO_LONG'; end if;
  if p_image_base64 is not null then
    if p_image_mime not in ('image/jpeg','image/png','image/webp') then raise exception 'EVIDENCE_IMAGE_TYPE_INVALID'; end if;
    begin
      v_image:=decode(p_image_base64,'base64');
    exception when others then
      raise exception 'EVIDENCE_IMAGE_INVALID';
    end;
    if octet_length(v_image)>2097152 then raise exception 'EVIDENCE_IMAGE_TOO_LARGE'; end if;
  elsif p_image_mime is not null then
    raise exception 'EVIDENCE_IMAGE_INVALID';
  end if;
  if v_note is null and v_image is null then raise exception 'EVIDENCE_EMPTY'; end if;

  select t.* into v_task
  from public.task_instances t
  join public.household_members m on m.household_id=t.household_id and m.user_id=p_actor_id
  where t.id=p_task_id
  for update of t;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_task.status<>'completed' then raise exception 'EVIDENCE_TASK_NOT_COMPLETED'; end if;

  v_hash:=encode(sha256(convert_to(
    'add-task-completion-evidence|'||p_task_id::text||'|'||coalesce(v_note,'')||'|'||
    coalesce(p_image_mime,'')||'|'||coalesce(encode(sha256(coalesce(v_image,''::bytea)),'hex'),'')
  ,'UTF8')),'hex');

  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
    values(p_actor_id,p_operation_id,'add-task-completion-evidence',v_hash)
    on conflict(actor_id,operation_id) do nothing;
  if not found then
    select * into v_receipt from private.mutation_receipts
      where actor_id=p_actor_id and operation_id=p_operation_id
      for update;
    if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return v_receipt.result_payload;
  end if;

  insert into public.task_completion_evidence(
    household_id,task_instance_id,added_by,note,image_mime,image_bytes
  ) values(
    v_task.household_id,p_task_id,p_actor_id,v_note,p_image_mime,v_image
  ) returning id into v_evidence_id;

  v_result:=jsonb_build_object(
    'evidence_id',v_evidence_id,
    'task_id',p_task_id,
    'has_note',v_note is not null,
    'has_image',v_image is not null
  );
  update private.mutation_receipts
    set result_type='task_completion_evidence',result_id=v_evidence_id,result_payload=v_result
    where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end;
$$;
revoke all on function public.server_tx_add_task_completion_evidence(uuid,uuid,uuid,text,text,text)
  from public,anon,authenticated;
grant execute on function public.server_tx_add_task_completion_evidence(uuid,uuid,uuid,text,text,text)
  to service_role;
