-- Scheduled notes keep shared transport and claimed shared work, but do not
-- turn the other parent's ordinary work into a list to monitor. Resolve the
-- assignee against live consent, including when an old outbox note is rebuilt.
create or replace function private.fn_daily_brief_for_line_v1(p_brief jsonb,p_recipient uuid,p_at timestamptz,p_mode text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare hh uuid; brief jsonb; critical jsonb;
begin
  select household_id into hh from public.household_members where user_id=p_recipient;
  if hh is null then return '{}'::jsonb; end if;
  brief:=private.fn_daily_brief_before_consent_v1(
    private.fn_filter_unagreed_line_brief_v1(p_brief,hh,p_recipient),p_recipient,p_at,p_mode);
  if jsonb_typeof(brief#>'{partner_summary,critical_items}')='array' then
    select coalesce(jsonb_agg(item || jsonb_build_object(
      'task_kind',coalesce(t.task_kind,item->>'task_kind'),
      'task_code',coalesce(d.code,item->>'task_code'),
      'transport_assignment_confirmed',coalesce(private.fn_task_assignment_consent_v1(hh,t.planned_assignee_id,t.id),false),
      'transport_assignee_label',case hm.family_role when 'papa' then 'パパ' when 'mama' then 'ママ' else '家族' end
    ) order by ord),'[]'::jsonb) into critical
    from jsonb_array_elements(brief#>'{partner_summary,critical_items}') with ordinality x(item,ord)
    left join public.task_instances t on t.household_id=hh and t.test_context_id is null
      and t.id=case when coalesce(item->>'task_id','') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
        then (item->>'task_id')::uuid else null end
    left join public.task_definitions d on d.household_id=hh and d.id=t.task_definition_id
    left join public.household_members hm on hm.household_id=hh and hm.user_id=t.planned_assignee_id
    where t.id is null or (t.status in ('todo','in_progress') and t.scheduled_date=(p_at at time zone 'Asia/Tokyo')::date);
    brief:=jsonb_set(brief,'{partner_summary,critical_items}',critical);
  end if;
  return brief;
end $$;
revoke all on function private.fn_daily_brief_for_line_v1(jsonb,uuid,timestamptz,text) from public,anon,authenticated;
grant execute on function private.fn_daily_brief_for_line_v1(jsonb,uuid,timestamptz,text) to service_role;

create or replace function private.fn_render_daily_brief_text_v4(p_brief jsonb,p_mode text)
returns text language plpgsql immutable security invoker set search_path='' as $$
declare filtered jsonb:=p_brief; body text; critical jsonb;
begin
  if p_mode='evening' and jsonb_typeof(filtered->'own_task_groups')='object' then
    filtered:=jsonb_set(filtered,'{own_task_groups,morning}','[]'::jsonb,true);
    filtered:=jsonb_set(filtered,'{own_task_groups,daytime}','[]'::jsonb,true);
  end if;
  if jsonb_typeof(filtered#>'{partner_summary,critical_items}')='array' then
    select coalesce(jsonb_agg(item || jsonb_build_object('display_title',
      coalesce(nullif(item->>'display_title',''),nullif(item->>'title',''),'送り迎え') ||
      case when item->>'transport_assignment_confirmed'='true' and item->>'transport_assignee_label' in ('パパ','ママ','家族')
        then '（担当: '||(item->>'transport_assignee_label')||'）' else '（担当は未確認）' end
    ) order by ord),'[]'::jsonb) into critical
    from jsonb_array_elements(filtered#>'{partner_summary,critical_items}') with ordinality x(item,ord)
    where item->>'task_kind'='transport' or item->>'task_code' in ('pickup','dropoff');
    filtered:=jsonb_set(filtered,'{partner_summary,critical_items}',critical);
  end if;
  body:=private.fn_render_daily_brief_before_evening_calm_v1(filtered,p_mode);
  body:=replace(body,E'\n\n相手の担当で確認したいこと\n',E'\n\n家族の共有事項\n');
  return replace(body,E'\n\n⭐ 今日、忘れずに\n',E'\n\n⭐ 今日だけの予定\n');
end $$;
revoke all on function private.fn_render_daily_brief_text_v4(jsonb,text) from public,anon,authenticated;
grant execute on function private.fn_render_daily_brief_text_v4(jsonb,text) to service_role;
