-- Repeat the stalled final-confirmation reminder once after an hour.
-- Daily Briefs continue to show the unresolved request on every scheduled send.
create or replace function public.server_tx_dispatch_request_checking_reminders_v1(
  p_now_utc timestamptz default now(),
  p_row_limit integer default 200
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_row record;
  v_count integer := 0;
  v_stage integer;
begin
  if p_now_utc is null or p_row_limit < 1 then
    raise exception 'INVALID_INPUT';
  end if;

  for v_row in
    select
      a.household_id,
      a.id as attempt_id,
      a.revision as attempt_revision,
      a.reply_due_at,
      a.updated_at as checking_started_at,
      r.id as request_id,
      r.shared_title,
      r.due_at,
      r.requester_actor_ref_id,
      r.recipient_actor_ref_id,
      requester.real_user_id as requester_user_id
    from public.request_attempts a
    join public.requests r
      on r.household_id = a.household_id
     and r.id = a.request_id
    join public.domain_actor_refs requester
      on requester.household_id = r.household_id
     and requester.id = r.requester_actor_ref_id
    where a.test_context_id is null
      and r.test_context_id is null
      and r.request_kind = 'assignment_change'
      and a.state = 'checking'
      and a.acceptance_intent = true
      and a.updated_at <= p_now_utc - interval '10 minutes'
      and (a.reply_due_at is null or a.reply_due_at > p_now_utc)
      and requester.actor_kind = 'real_user'
      and requester.real_user_id is not null
    order by a.updated_at, a.id
    limit p_row_limit
    for update of a skip locked
  loop
    v_stage := case when v_row.checking_started_at <= p_now_utc - interval '60 minutes' then 2 else 1 end;
    perform private.fn_emit_notification_intent_v1(
      v_row.household_id,
      v_row.requester_user_id,
      v_row.requester_actor_ref_id,
      null,
      v_row.recipient_actor_ref_id,
      'request.checking',
      '最終確認が残っています',
      '「' || coalesce(v_row.shared_title, 'お願い') || '」はまだ確定していません。引き受ける場合は「お願いの返事」と送って、内容を確認し「確定（引受）」を押してください。',
      jsonb_build_object(
        'request_id', v_row.request_id,
        'attempt_id', v_row.attempt_id,
        'state', 'checking',
        'reminder', 'final_confirmation',
        'reminder_stage', v_stage
      ),
      'request:checking-reminder:' || v_row.attempt_id::text || ':' || v_row.attempt_revision::text
        || case when v_stage = 2 then ':2' else '' end,
      'immediate',
      'normal',
      'request:' || v_row.request_id::text,
      coalesce(v_row.reply_due_at, v_row.due_at),
      'request',
      v_row.request_id,
      v_row.attempt_revision
    );
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('reminders_considered', v_count);
end;
$function$;
