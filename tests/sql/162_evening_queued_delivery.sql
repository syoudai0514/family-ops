\set ON_ERROR_STOP on
begin;
do $$
declare actor uuid:=gen_random_uuid(); hh uuid; day date:=(now() at time zone 'Asia/Tokyo')::date;
  note uuid; outbox uuid; rows jsonb; row jsonb; brief jsonb;
begin
  update private.notification_outbox set status='dead',lease_owner=null,lease_token=null,lease_until=null where status in ('queued','sending');
  insert into auth.users(id) values(actor);
  hh:=(public.server_tx_create_household(actor,gen_random_uuid(),'evening queue test','A')->>'household_id')::uuid;
  update public.notification_preferences set quiet_mode='normal' where household_id=hh;
  brief:=jsonb_build_object('local_date',day,'display_recipient_user_id',actor,'own_task_groups',jsonb_build_object(
    'morning',jsonb_build_array(jsonb_build_object('title','朝の作業')),
    'daytime',jsonb_build_array(jsonb_build_object('title','昼の作業')),
    'evening',jsonb_build_array(jsonb_build_object('title','夜の作業')),
    'optional','[]'::jsonb));
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(hh,actor,'daily_brief.v2','夜のおうちノート','以前の朝の残り',jsonb_build_object('brief',brief),'queued-evening-test') returning id into note;
  insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key,priority,business_expires_at)
    values(hh,actor,'line','daily_brief.v2',jsonb_build_object('items',jsonb_build_array(
      jsonb_build_object('type','daily_brief.v2','title','夜のおうちノート','body','以前の朝の残り','user_notification_id',note),
      jsonb_build_object('type','request.received','title','お願い','body','大切な連絡'))),
      'queued-evening-outbox','normal',now()+interval '1 hour') returning id into outbox;
  rows:=public.server_tx_claim_notification_outbox_batch('evening-test',20,60);
  select value into row from jsonb_array_elements(rows) where value->>'id'=outbox::text;
  if row is null or row::text like '%朝の残り%' or row::text like '%朝の作業%' or row::text like '%昼の作業%'
    or row::text not like '%夜の作業%' or row::text not like '%大切な連絡%'
    then raise exception 'queued evening was not updated safely: %',row; end if;
end $$;
rollback;
select 'evening_queued_delivery: PASS' as result;
