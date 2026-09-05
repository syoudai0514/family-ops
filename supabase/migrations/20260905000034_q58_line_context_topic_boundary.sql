-- Appendix A Q58 exact context boundary.
-- A new calendar day never resets LINE context by itself. Explicit topic-switch
-- language always does. A long gap may reset only when the current text is a
-- clearly distinct fixed product entry topic; ambiguous free prose stays linked.
-- The worker is sender-serialized, so its currently-processing webhook is the
-- authoritative current text for this read-only context decision.
create or replace function public.server_tx_get_line_conversation_pending(
  p_actor_id uuid,
  p_line_user_id text
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_row record;
  v_current_text text;
  v_current_norm text;
  v_gap interval;
  v_explicit_switch boolean := false;
  v_clear_distinct_topic boolean := false;
begin
  if p_actor_id is null or coalesce(p_line_user_id,'')='' then raise exception 'INVALID_INPUT'; end if;

  select w.payload #>> '{message,text}' into v_current_text
  from private.webhook_inbox w
  where w.provider='line' and w.source_external_user_id=p_line_user_id
    and w.status='processing' and w.payload->>'type'='message'
    and w.payload #>> '{message,type}'='text'
  order by w.last_started_at desc nulls last,w.received_at desc,w.id desc
  limit 1;
  v_current_norm:=regexp_replace(normalize(coalesce(v_current_text,''),NFKC),'[[:space:]]+','','g');

  v_explicit_switch := v_current_norm ~ '^(別の話(だけど|なんだけど|で)?|話(は|を)?変(える|わる)(けど|んだけど)?|話題変(える|わる)(けど|んだけど)?|別件(だけど|で)?|ところで)[、,。.!！]?';
  if v_explicit_switch then return null; end if;

  update private.pending_actions pa set status='expired'
  from private.line_user_links link
  where pa.actor_id=p_actor_id and pa.source='line' and pa.status='draft'
    and pa.expires_at<=now() and link.user_id=pa.actor_id
    and link.household_id=pa.household_id and link.line_user_id=p_line_user_id
    and link.status='active';

  select pa.id,pa.household_id,pa.actor_id,pa.action_type,pa.normalized_payload,
         pa.status,pa.expires_at,pa.updated_at
  into v_row
  from private.pending_actions pa
  join private.line_user_links link on link.user_id=pa.actor_id
    and link.household_id=pa.household_id and link.line_user_id=p_line_user_id
    and link.status='active'
  where pa.actor_id=p_actor_id and pa.source='line'
  order by pa.updated_at desc,pa.created_at desc
  limit 1;
  if not found then return null; end if;

  v_gap:=now()-v_row.updated_at;
  if v_gap>=interval '12 hours' then
    -- Conservative fixed-topic judgment only. The date boundary or elapsed time
    -- alone is never enough, and referential wording remains continuation.
    if v_current_norm !~ '^(それ|これ|さっき|昨日の|前の)'
       and position(regexp_replace(normalize(coalesce(v_row.normalized_payload->>'title',''),NFKC),'[[:space:]]+','','g') in v_current_norm)=0 then
      v_clear_distinct_topic :=
        v_current_norm ~ '^(入力|今日の入力|朝の入力|夜の入力|追加|追加したい|登録|共有|引き継ぎ|共有したい|その他|管理|設定)$'
        or v_current_norm ~ '^(メニュー|何ができる|何できる|できること|使い方|ヘルプ)'
        or v_current_norm ~ '^(今日|明日|今週)(の予定|どうなってる|なにある)'
        or v_current_norm ~ '^(予定|単発予定|タスク|お願い|依頼|買い物|買うもの)(を)?(追加|登録|送りたい|したい|送って|する)';
    end if;
  end if;
  if v_clear_distinct_topic then return null; end if;

  return jsonb_build_object(
    'id',v_row.id,'household_id',v_row.household_id,'actor_id',v_row.actor_id,
    'action_type',v_row.action_type,'normalized_payload',v_row.normalized_payload,
    'status',v_row.status,'expires_at',v_row.expires_at,'updated_at',v_row.updated_at
  );
end;
$$;
revoke all on function public.server_tx_get_line_conversation_pending(uuid,text) from public,anon,authenticated;
grant execute on function public.server_tx_get_line_conversation_pending(uuid,text) to service_role;
