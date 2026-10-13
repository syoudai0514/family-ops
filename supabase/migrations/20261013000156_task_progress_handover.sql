-- Optional observations and partial work preserve the task's actual outcome.
-- A machine cycle starting is progress, not task completion. Sharing creates
-- related information and notification intents in this same transaction.
create or replace function private.fn_command_record_task_progress_v1(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_expected_revision bigint,
  p_observed_note text default null,
  p_work_done_note text default null,
  p_remaining_note text default null,
  p_next_step_note text default null,
  p_share_with_household boolean default false,
  p_ack_policy text default 'none',
  p_valid_until timestamptz default null
) returns jsonb
-- The receipt claim is deliberately owner-only. This narrowly scoped command
-- derives the real ActorRef and household before entering that internal helper.
language plpgsql security definer set search_path = '' as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_claim jsonb;
  v_receipt_id uuid;
  v_task public.task_instances%rowtype;
  v_observed text := nullif(regexp_replace(coalesce(p_observed_note,''), '^[[:space:]　]+|[[:space:]　]+$', '', 'g'), '');
  v_work_done text := nullif(regexp_replace(coalesce(p_work_done_note,''), '^[[:space:]　]+|[[:space:]　]+$', '', 'g'), '');
  v_remaining text := nullif(regexp_replace(coalesce(p_remaining_note,''), '^[[:space:]　]+|[[:space:]　]+$', '', 'g'), '');
  v_next_step text := nullif(regexp_replace(coalesce(p_next_step_note,''), '^[[:space:]　]+|[[:space:]　]+$', '', 'g'), '');
  v_event_id uuid;
  v_handover_id uuid;
  v_shared_text text;
  v_author_label text;
  v_revision bigint;
  v_recipient record;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null
     or p_expected_revision is null or p_expected_revision < 1
     or p_share_with_household is null or p_ack_policy is null
     or p_ack_policy not in ('none','required') then
    raise exception 'INVALID_INPUT';
  end if;
  if v_observed is null and v_work_done is null and v_remaining is null and v_next_step is null then
    raise exception 'INVALID_INPUT';
  end if;
  if length(coalesce(p_observed_note,'')) > 2000
     or length(coalesce(p_work_done_note,'')) > 2000
     or length(coalesce(p_remaining_note,'')) > 2000
     or length(coalesce(p_next_step_note,'')) > 2000
     or length(coalesce(p_observed_note,'') || coalesce(p_work_done_note,'') ||
               coalesce(p_remaining_note,'') || coalesce(p_next_step_note,'')) > 8000
     or (not p_share_with_household and (p_ack_policy <> 'none' or p_valid_until is not null)) then
    raise exception 'INVALID_INPUT';
  end if;

  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (v_context->>'household_id')::uuid;
  v_actor_ref_id := (v_context->>'actor_ref_id')::uuid;
  v_claim := private.fn_claim_canonical_operation_v1(
    v_household_id, p_actor_id, v_actor_ref_id, null, p_operation_id,
    'task.progress.record', private.fn_canonical_request_hash_v1(jsonb_build_object(
      'household_id', v_household_id, 'task_id', p_task_id,
      'expected_revision', p_expected_revision,
      'observed_note', v_observed, 'work_done_note', v_work_done,
      'remaining_note', v_remaining, 'next_step_note', v_next_step,
      'share_with_household', p_share_with_household, 'ack_policy', p_ack_policy,
      'valid_until', case when p_valid_until is not null then
        to_char(p_valid_until at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') end
    ))
  );
  -- A lost-response retry remains successful after a later task change or
  -- expiry. Scope is revalidated by the canonical receipt helper first.
  if v_claim->>'disposition' = 'replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  select * into v_task from public.task_instances
  where household_id = v_household_id and id = p_task_id and test_context_id is null
  for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_task.revision <> p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if v_task.status not in ('todo','in_progress','completed') then raise exception 'TASK_TERMINAL'; end if;
  if p_valid_until is not null and p_valid_until <= now() then raise exception 'INVALID_INPUT'; end if;

  update public.task_instances set revision = revision + 1
  where household_id = v_household_id and id = p_task_id
  returning revision into v_revision;

  if p_share_with_household then
    select coalesce(case m.family_role when 'papa' then 'パパ' when 'mama' then 'ママ' end,
      nullif(btrim(p.display_name),''),'家族') into v_author_label
    from public.household_members m left join public.profiles p on p.user_id=m.user_id
    where m.household_id=v_household_id and m.user_id=p_actor_id;
    v_shared_text := v_author_label || E'からの引き継ぎ\n' || v_task.title ||
      E'\n対象の作業日：' || to_char(v_task.scheduled_date, 'YYYY/MM/DD') ||
      case when p_ack_policy='required' then E'\n確認の返答が必要です。LINEで「共有確認」と送って確認してください。' else '' end ||
      case when v_next_step is not null then E'\n次の作業への影響・伝えること：' || v_next_step else '' end ||
      case when v_remaining is not null then E'\n今の状態・残っていること：' || v_remaining else '' end ||
      case when v_observed is not null then E'\n見つけた状況：' || v_observed else '' end ||
      case when v_work_done is not null then E'\n行ったこと：' || v_work_done else '' end;
    insert into public.handovers (
      household_id, author_id, author_actor_ref_id, test_context_id,
      shared_text, period, categories, occurred_on, info_kind, visibility,
      valid_from, valid_until, ack_policy, related_task_id, status, revision
    ) values (
      v_household_id, p_actor_id, v_actor_ref_id, null, v_shared_text,
      case when v_task.routine_phase in ('morning','evening') then v_task.routine_phase
           when v_task.routine_phase = 'daytime' then 'day' else 'other' end,
      array[v_task.category], (now() at time zone 'Asia/Tokyo')::date,
      'handover', 'household', now(), p_valid_until, p_ack_policy, p_task_id, 'active', 1
    ) returning id into v_handover_id;

    for v_recipient in
      select a.id from public.domain_actor_refs a
      join public.household_members m on m.household_id = a.household_id and m.user_id = a.real_user_id
      where a.household_id = v_household_id and a.actor_kind = 'real_user' and a.id <> v_actor_ref_id
    loop
      perform private.fn_emit_notification_intent_v1(
        v_household_id, p_actor_id, v_actor_ref_id, null, v_recipient.id,
        'handover_created', '作業の状況・引き継ぎ', v_shared_text,
        jsonb_build_object('handover_id', v_handover_id, 'task_id', p_task_id, 'ack_policy', p_ack_policy),
        'task-progress:' || v_actor_ref_id::text || ':' || p_operation_id::text || ':' || v_recipient.id::text,
        'immediate', 'normal', null, p_valid_until, 'handover', v_handover_id, 1
      );
    end loop;
  end if;

  insert into public.task_events (
    household_id, task_instance_id, actor_id, actor_ref_id, test_context_id,
    event_type, payload, source, idempotency_key
  ) values (
    v_household_id, p_task_id, p_actor_id, v_actor_ref_id, null,
    'work_progress_recorded', jsonb_build_object(
      'observed_note', v_observed, 'work_done_note', v_work_done,
      'remaining_note', v_remaining, 'next_step_note', v_next_step,
      'work_performer_actor_ref_id', case when v_work_done is not null then v_actor_ref_id end,
      'task_date', v_task.scheduled_date, 'task_title', v_task.title,
      'share_with_household', p_share_with_household, 'handover_id', v_handover_id,
      'previous_revision', v_task.revision, 'revision', v_revision
    ), 'pwa', 'task-progress:' || v_actor_ref_id::text || ':' || p_operation_id::text
  ) returning id into v_event_id;

  v_result := jsonb_build_object('task_id', p_task_id, 'task_event_id', v_event_id,
    'revision', v_revision, 'handover_id', v_handover_id);
  perform private.fn_complete_canonical_operation_v1(v_receipt_id, 'task', p_task_id, v_result);
  return v_result;
end;
$$;
revoke all on function private.fn_command_record_task_progress_v1(uuid,uuid,uuid,bigint,text,text,text,text,boolean,text,timestamptz)
  from public, anon, authenticated;
grant execute on function private.fn_command_record_task_progress_v1(uuid,uuid,uuid,bigint,text,text,text,text,boolean,text,timestamptz)
  to service_role;

create or replace function public.server_tx_record_task_progress(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_expected_revision bigint,
  p_observed_note text default null,
  p_work_done_note text default null,
  p_remaining_note text default null,
  p_next_step_note text default null,
  p_share_with_household boolean default false,
  p_ack_policy text default 'none',
  p_valid_until timestamptz default null
) returns jsonb
language sql security invoker set search_path = '' as $$
  select private.fn_command_record_task_progress_v1(
    p_actor_id,p_operation_id,p_task_id,p_expected_revision,
    p_observed_note,p_work_done_note,p_remaining_note,p_next_step_note,
    p_share_with_household,p_ack_policy,p_valid_until
  );
$$;
revoke all on function public.server_tx_record_task_progress(uuid,uuid,uuid,bigint,text,text,text,text,boolean,text,timestamptz)
  from public, anon, authenticated;
grant execute on function public.server_tx_record_task_progress(uuid,uuid,uuid,bigint,text,text,text,text,boolean,text,timestamptz)
  to service_role;
