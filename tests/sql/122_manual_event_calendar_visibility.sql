\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
  u1 uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
  hh uuid; ev uuid; chore uuid; pa uuid:=gen_random_uuid(); pa_done uuid:=gen_random_uuid(); r jsonb;
begin
  insert into auth.users(id) values(u1),(outsider);
  hh:=(public.server_tx_create_household(u1,gen_random_uuid(),'Event family','Owner')->>'household_id')::uuid;
  perform public.server_tx_create_household(outsider,gen_random_uuid(),'Other family','Other');

  -- Owner report 2026-10-11: a 9:00 appointment (morning band) confirmed as 予定 kept losing 'special'.
  ev:=(public.server_tx_create_task_with_calendar(u1,gen_random_uuid(),'詩乃の便秘通院','todo','2026-10-17',
    '09:00',null,'special',u1,'whole','morning','[]'::jsonb)->>'task_id')::uuid;
  if (select calendar_visibility from public.task_instances where id=ev)<>'special'
    or (select task_kind from public.task_instances where id=ev)<>'special' then
    raise exception 'FAIL: manual morning event was not kept as a special calendar event'; end if;

  -- Editing it to hidden and back (the PWA save) must stick each time.
  update public.task_instances set calendar_visibility='hidden' where id=ev;
  if (select calendar_visibility from public.task_instances where id=ev)<>'hidden' then
    raise exception 'FAIL: hiding a manual event did not stick'; end if;
  update public.task_instances set calendar_visibility='special' where id=ev;
  if (select calendar_visibility from public.task_instances where id=ev)<>'special'
    or (select task_kind from public.task_instances where id=ev)<>'special' then
    raise exception 'FAIL: re-saving as 予定 reverted to hidden'; end if;

  -- An ordinary hidden morning task stays a hidden morning chore.
  chore:=(public.server_tx_create_task_with_calendar(u1,gen_random_uuid(),'朝ごはん','todo','2026-10-17',
    '07:30',null,'hidden',u1,'whole','morning','[]'::jsonb)->>'task_id')::uuid;
  if (select calendar_visibility from public.task_instances where id=chore)<>'hidden'
    or (select task_kind from public.task_instances where id=chore)<>'morning_chore' then
    raise exception 'FAIL: hidden morning task changed domain'; end if;

  -- LINE 「Googleに入れない」 on a draft that has not run yet: the draft payload changes.
  insert into private.pending_actions(id,household_id,actor_id,source,action_type,normalized_payload,operation_id,status,expires_at)
    values(pa,hh,u1,'line','task_create_once',jsonb_build_object('title','歯医者','calendar_visibility','special'),gen_random_uuid(),'confirmed',now()+interval '1 day');
  r:=public.server_tx_set_line_pending_calendar_visibility(u1,pa,'hidden');
  if r->>'applied'<>'draft' or (select normalized_payload->>'calendar_visibility' from private.pending_actions where id=pa)<>'hidden' then
    raise exception 'FAIL: draft calendar choice not saved: %', r; end if;

  -- ...and on a draft that already created the task: the task changes, and back again.
  insert into private.pending_actions(id,household_id,actor_id,source,action_type,normalized_payload,operation_id,status,expires_at,result_type,result_id)
    values(pa_done,hh,u1,'line','task_create_once',jsonb_build_object('title','詩乃の便秘通院','calendar_visibility','special'),gen_random_uuid(),'succeeded',now()+interval '1 day','task',ev);
  r:=public.server_tx_set_line_pending_calendar_visibility(u1,pa_done,'hidden');
  if r->>'applied'<>'task' or (select calendar_visibility from public.task_instances where id=ev)<>'hidden' then
    raise exception 'FAIL: created task was not removed from Google: %', r; end if;
  r:=public.server_tx_set_line_pending_calendar_visibility(u1,pa_done,'special');
  if (select calendar_visibility from public.task_instances where id=ev)<>'special' then
    raise exception 'FAIL: やっぱり入れる did not restore the event'; end if;

  -- Another household cannot touch the draft.
  begin
    perform public.server_tx_set_line_pending_calendar_visibility(outsider,pa_done,'hidden');
    raise exception 'FAIL: outsider changed another household draft';
  exception when others then if sqlerrm<>'NOT_FOUND' then raise; end if; end;
  begin
    perform public.server_tx_set_line_pending_calendar_visibility(u1,pa_done,'transport');
    raise exception 'FAIL: invalid visibility accepted';
  exception when others then if sqlerrm<>'INVALID_INPUT' then raise; end if; end;
end $$;
rollback;
