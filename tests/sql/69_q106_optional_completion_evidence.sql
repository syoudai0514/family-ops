-- Q106: standard completion remains the existing direct mutation; optional
-- memo/image evidence can be added afterwards without becoming a requirement.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  u1 uuid := '69000000-0000-0000-0000-000000000001';
  u2 uuid := '69000000-0000-0000-0000-000000000002';
  h1 uuid; h2 uuid; task1 uuid; task2 uuid; pending_task uuid;
  r1 jsonb; r2 jsonb; replay jsonb;
  failed boolean;
begin
  insert into auth.users(id) values(u1),(u2) on conflict do nothing;
  insert into public.profiles(user_id,display_name) values(u1,'Q106 A'),(u2,'Q106 B') on conflict do nothing;
  h1 := (public.server_tx_create_household(u1,'69000000-0000-0000-0000-000000000101','Q106 H1','Q106 A')->>'household_id')::uuid;
  h2 := (public.server_tx_create_household(u2,'69000000-0000-0000-0000-000000000102','Q106 H2','Q106 B')->>'household_id')::uuid;

  task1 := (public.server_tx_create_task(
    u1,'69000000-0000-0000-0000-000000000201','提出物を出す','nursery','2026-09-05',null,u1,'whole','anytime',null
  )->>'task_id')::uuid;
  pending_task := (public.server_tx_create_task(
    u1,'69000000-0000-0000-0000-000000000202','まだ終わっていない','nursery','2026-09-05',null,u1,'whole','anytime',null
  )->>'task_id')::uuid;
  task2 := (public.server_tx_create_task(
    u2,'69000000-0000-0000-0000-000000000203','別家庭の完了','nursery','2026-09-05',null,u2,'whole','anytime',null
  )->>'task_id')::uuid;

  -- Existing standard command: one mutation completes the task, with no
  -- evidence fields or evidence row required.
  perform public.server_tx_complete_task(u1,'69000000-0000-0000-0000-000000000301',task1,'self',false);
  perform public.server_tx_complete_task(u2,'69000000-0000-0000-0000-000000000302',task2,'self',false);
  if not exists(select 1 from public.task_instances where id=task1 and status='completed') then
    raise exception 'FAIL Q106 direct completion';
  end if;
  if exists(select 1 from public.task_completion_evidence where task_instance_id=task1) then
    raise exception 'FAIL Q106 completion unexpectedly required evidence';
  end if;

  r1 := public.server_tx_add_task_completion_evidence(
    u1,'69000000-0000-0000-0000-000000000401',task1,'提出完了・受付済み',null,null
  );
  if coalesce((r1->>'has_note')::boolean,false) is not true or coalesce((r1->>'has_image')::boolean,false) then
    raise exception 'FAIL Q106 note evidence result';
  end if;
  if not exists(
    select 1 from public.task_completion_evidence
    where id=(r1->>'evidence_id')::uuid and task_instance_id=task1 and household_id=h1
      and note='提出完了・受付済み' and image_bytes is null
  ) then raise exception 'FAIL Q106 note evidence persistence'; end if;

  r2 := public.server_tx_add_task_completion_evidence(
    u1,'69000000-0000-0000-0000-000000000402',task1,null,'image/png','YWJj'
  );
  if coalesce((r2->>'has_image')::boolean,false) is not true then raise exception 'FAIL Q106 image evidence result'; end if;
  if not exists(
    select 1 from public.task_completion_evidence
    where id=(r2->>'evidence_id')::uuid and image_mime='image/png' and image_bytes=decode('YWJj','base64')
  ) then raise exception 'FAIL Q106 image evidence persistence'; end if;

  replay := public.server_tx_add_task_completion_evidence(
    u1,'69000000-0000-0000-0000-000000000401',task1,'提出完了・受付済み',null,null
  );
  if replay is distinct from r1 then raise exception 'FAIL Q106 evidence idempotent replay'; end if;
  if (select count(*) from public.task_completion_evidence where task_instance_id=task1)<>2 then
    raise exception 'FAIL Q106 replay duplicated evidence';
  end if;

  failed:=false;
  begin
    perform public.server_tx_add_task_completion_evidence(
      u1,'69000000-0000-0000-0000-000000000403',pending_task,'早すぎる証跡',null,null
    );
  exception when others then failed:=position('EVIDENCE_TASK_NOT_COMPLETED' in sqlerrm)>0; end;
  if not failed then raise exception 'FAIL Q106 incomplete task accepted evidence'; end if;

  failed:=false;
  begin
    perform public.server_tx_add_task_completion_evidence(
      u1,'69000000-0000-0000-0000-000000000404',task2,'越境証跡',null,null
    );
  exception when others then failed:=position('CROSS_HOUSEHOLD_RESOURCE' in sqlerrm)>0; end;
  if not failed then raise exception 'FAIL Q106 cross-household evidence accepted'; end if;

  if exists(select 1 from public.task_completion_evidence where household_id=h2 and added_by=u1) then
    raise exception 'FAIL Q106 cross-household residue';
  end if;
end;
$$;
reset role;
select '69_q106_optional_completion_evidence: PASS' as result;
