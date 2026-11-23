\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
  actor uuid:=gen_random_uuid(); partner uuid:=gen_random_uuid(); h uuid; token text;
  day date:=(now() at time zone 'Asia/Tokyo')::date; tomorrow date:=day+1;
  evening_id uuid; other_id uuid; mkey text; mixed uuid; morning uuid; sending uuid; retrying uuid; prepared uuid; other_user uuid;
  subscription uuid; push uuid; inserted uuid;
begin
  insert into auth.users(id) values(actor),(partner);
  h:=(public.server_tx_create_household(actor,gen_random_uuid(),'Quiet','パパ')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(actor,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(partner,gen_random_uuid(),token,'ママ');
  update public.notification_preferences set quiet_mode='normal' where household_id=h;
  mkey:='morning-nudge:'||day::text||':'||actor::text;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
  values(h,actor,'daily_brief.v2','夜のおうちノート','night',jsonb_build_object('brief',jsonb_build_object('local_date',day)),'quiet-test-evening') returning id into evening_id;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
  values(h,actor,'request_received','お願い','request','{}','quiet-test-request') returning id into other_id;
  insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key)
  values(h,actor,'line','daily_brief.v2',jsonb_build_object('items',jsonb_build_array(
    jsonb_build_object('type','daily_brief.v2','title','夜のおうちノート','user_notification_id',evening_id),
    jsonb_build_object('type','request_received','title','お願い','user_notification_id',other_id))),'quiet-test-mixed') returning id into mixed;
  insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key)
  values(h,actor,'line','morning_nudge',jsonb_build_object('items',jsonb_build_array(jsonb_build_object('title','朝の残り'))),mkey) returning id into morning;
  insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key,status,attempts,lease_owner,lease_token,lease_until)
  values(h,actor,'line','daily_brief.v2',jsonb_build_object('items',jsonb_build_array(jsonb_build_object('type','daily_brief.v2','title','夜のおうちノート','user_notification_id',evening_id))),
    'quiet-test-inflight','sending',1,'test',gen_random_uuid(),now()+interval '1 minute') returning id into sending;
  insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key,status,attempts)
  values(h,actor,'line','daily_brief.v2',jsonb_build_object('items',jsonb_build_array(jsonb_build_object('type','daily_brief.v2','title','夜のおうちノート','user_notification_id',evening_id))),
    'quiet-test-retry','queued',1) returning id into retrying;
  insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key,provider_retry_key)
  values(h,actor,'line','daily_brief.v2',jsonb_build_object('items',jsonb_build_array(jsonb_build_object('type','daily_brief.v2','title','夜のおうちノート','user_notification_id',evening_id))),
    'quiet-test-prepared',gen_random_uuid()) returning id into prepared;
  insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key)
  values(h,partner,'line','daily_brief.v2',jsonb_build_object('items',jsonb_build_array(jsonb_build_object('type','daily_brief.v2','title','夜のおうちノート'))),'quiet-test-partner') returning id into other_user;
  insert into private.web_push_subscriptions(household_id,user_id,endpoint,p256dh,auth)
  values(h,actor,'https://push.example/quiet',repeat('x',20),repeat('y',8)) returning id into subscription;
  insert into private.web_push_outbox(subscription_id,household_id,recipient_user_id,title,body,tag,dedup_key,expires_at)
  values(subscription,h,actor,'朝の残り','body','morning-nudge',mkey,now()+interval '1 hour') returning id into push;

  perform public.server_tx_line_quiet_today_v1(actor,day);
  perform public.server_tx_line_quiet_today_v1(actor,day);
  if (select status from private.notification_outbox where id=morning)<>'dead' then raise exception 'queued morning nudge not paused'; end if;
  if (select status from private.web_push_outbox where id=push)<>'dead' then raise exception 'queued web push not paused'; end if;
  if (select status from private.notification_outbox where id=mixed)<>'queued'
    or (select jsonb_array_length(payload->'items') from private.notification_outbox where id=mixed)<>1
    or (select type from private.notification_outbox where id=mixed)<>'request_received'
    or (select payload->'items'->0->>'title' from private.notification_outbox where id=mixed)<>'お願い' then
      raise exception 'bundled request was lost or evening not removed'; end if;
  if (select status from private.notification_outbox where id=sending)<>'sending' then raise exception 'in-flight delivery altered'; end if;
  if (select status from private.notification_outbox where id=retrying)<>'queued' then raise exception 'retry-key delivery altered'; end if;
  if (select status from private.notification_outbox where id=prepared)<>'queued' then raise exception 'prepared retry key altered'; end if;
  if (select status from private.notification_outbox where id=other_user)<>'queued' then raise exception 'partner delivery altered'; end if;

  inserted:=null;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
  values(h,actor,'morning_nudge','朝の残り','body',jsonb_build_object('date',day),'quiet-test-future-morning') returning id into inserted;
  if inserted is not null then raise exception 'new same-day nudge inserted'; end if;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
  values(h,actor,'daily_brief.v2','夜のおうちノート','body',jsonb_build_object('brief',jsonb_build_object('local_date',day)),'quiet-test-future-evening') returning id into inserted;
  if inserted is not null then raise exception 'new same-day evening note inserted'; end if;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
  values(h,actor,'daily_brief.v2','夜のおうちノート','body',jsonb_build_object('brief',jsonb_build_object('local_date',tomorrow)),'quiet-test-tomorrow') returning id into inserted;
  if inserted is null then raise exception 'tomorrow suppressed'; end if;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
  values(h,partner,'morning_nudge','朝の残り','body',jsonb_build_object('date',day),'quiet-test-partner-nudge') returning id into inserted;
  if inserted is null then raise exception 'partner nudge suppressed'; end if;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
  values(h,actor,'request_received','お願い','body','{}','quiet-test-new-request') returning id into inserted;
  if inserted is null then raise exception 'request suppressed'; end if;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key,safety_class)
  values(h,actor,'daily_brief.v2','夜のおうちノート','safety',jsonb_build_object('brief',jsonb_build_object('local_date',day)),
    'quiet-test-safety','safety_critical') returning id into inserted;
  if inserted is null then raise exception 'safety notification suppressed'; end if;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
  values(h,actor,'morning_nudge','朝の残り','body','{"date":"2026-02-30"}','quiet-test-invalid-date') returning id into inserted;
  if inserted is null then raise exception 'invalid date should not disrupt an insert'; end if;
  begin
    perform public.server_tx_line_quiet_today_v1(actor,tomorrow);
    raise exception 'future button accepted';
  exception when others then if sqlerrm<>'INVALID_INPUT' then raise; end if; end;
  if has_function_privilege('authenticated','public.server_tx_line_quiet_today_v1(uuid,date)','execute') then raise exception 'public rpc access'; end if;
end $$;
rollback;
select 'line_quiet_today: PASS' as result;
