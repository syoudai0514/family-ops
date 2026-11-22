-- Summarize the recipient's transport-linked morning work in the scheduled
-- LINE brief only. The interactive 今日 list and the underlying tasks are not
-- modified. Apply before the existing special-today split so weekly duties
-- are included too, while unrelated special tasks remain prominent.
alter function private.fn_daily_brief_for_line_v1(jsonb,uuid,timestamptz,text)
  rename to fn_daily_brief_for_line_before_duty_v1;

create function private.fn_daily_brief_for_line_v1(
  p_brief jsonb, p_recipient uuid, p_at timestamptz, p_mode text
) returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare
  brief jsonb:=p_brief;
  groups jsonb;
  duties uuid[];
  total integer;
  first_timed jsonb;
  last_timed jsonb;
  first_label text;
  last_label text;
  caption text;
  summary jsonb;
  morning jsonb;
begin
  if p_mode='morning' and p_recipient is not null then
    -- Rely on the actual task and rule, never on user-provided display text.
    -- Shared, optional, completed, other people's and other dates' work stays
    -- outside this block. A claimed task belonging to the other adult stays
    -- separate, as in the original renderer.
    with candidates as (
      select t.id, t.due_at, item || jsonb_build_object('due_at',t.due_at) item, ord
      from jsonb_array_elements(coalesce(brief->'own_task_groups'->'morning','[]'::jsonb))
        with ordinality x(item,ord)
      join public.task_instances t on t.id=nullif(item->>'task_id','')::uuid
      join public.recurrence_rules r on r.household_id=t.household_id and r.id=t.recurrence_rule_id
      left join public.task_definitions d on d.household_id=t.household_id and d.id=t.task_definition_id
      left join public.domain_actor_refs ar on ar.household_id=t.household_id and ar.id=t.active_claimant_actor_ref_id
      join public.household_members m on m.household_id=t.household_id and m.user_id=p_recipient
      where t.test_context_id is null and t.scheduled_date=(p_at at time zone 'Asia/Tokyo')::date
        and t.routine_phase='morning' and t.planned_assignee_id=p_recipient
        and t.assignment_mode is distinct from 'anyone' and coalesce(t.expectation,'normal')<>'optional'
        and t.status in ('todo','in_progress') and r.assignee_strategy='dropoff_assignee'
        and (t.active_claimant_actor_ref_id is null or ar.real_user_id=p_recipient)
    )
    select array_agg(id order by ord),count(*)::integer,
      (array_agg(item order by due_at,ord) filter(where due_at is not null))[1],
      (array_agg(item order by due_at desc,ord desc) filter(where due_at is not null))[1]
    into duties,total,first_timed,last_timed from candidates;
    if total>0 then
      first_label:=case when first_timed is null then null else
        coalesce(nullif(first_timed->>'display_title',''),first_timed->>'title','作業') end;
      last_label:=case when last_timed is null then null else
        to_char((last_timed->>'due_at')::timestamptz at time zone 'Asia/Tokyo','HH24:MI')||' '||
        coalesce(nullif(last_timed->>'display_title',''),last_timed->>'title','作業') end;
      caption:='朝の当番（'||total::text||'件）';
      if first_label is not null then
        caption:=caption||' '||first_label||case when first_timed->>'task_id' is distinct from last_timed->>'task_id' then '〜'||last_label else '' end;
      end if;
      summary:=jsonb_build_object('title',caption,'display_title',caption,'assignment_mode','person',
        'due_at',first_timed->>'due_at');
      select coalesce(jsonb_agg(item order by ord),'[]'::jsonb) into morning
      from (
        select summary item,0::bigint ord
        union all
        select x.item,x.ord
        from jsonb_array_elements(coalesce(brief->'own_task_groups'->'morning','[]'::jsonb)) with ordinality x(item,ord)
        left join public.task_instances t on t.id=nullif(x.item->>'task_id','')::uuid
        left join public.task_definitions d on d.household_id=t.household_id and d.id=t.task_definition_id
        -- Keep the Codmon send deadline visible as a separate item.
        where t.id is null or not (t.id=any(duties)) or d.code='codmon_submit'
      ) kept;
      groups:=coalesce(brief->'own_task_groups','{}'::jsonb)||jsonb_build_object('morning',morning);
      brief:=brief||jsonb_build_object('own_task_groups',groups);
    end if;
  end if;
  return private.fn_daily_brief_for_line_before_duty_v1(brief,p_recipient,p_at,p_mode);
end $$;
revoke all on function private.fn_daily_brief_for_line_v1(jsonb,uuid,timestamptz,text) from public,anon,authenticated;
grant execute on function private.fn_daily_brief_for_line_v1(jsonb,uuid,timestamptz,text) to service_role;
