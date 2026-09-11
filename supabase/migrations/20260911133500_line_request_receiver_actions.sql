-- F2 physical two-account LINE remediation.
-- Preserve the canonical request payload when user_notifications enters the
-- LINE outbox, and accept the canonical dotted request.received type in the
-- enrichment trigger. Without this, send-notifications only sees title/body
-- and cannot render recipient "やる / 難しい" actions.

create or replace function private.fn_enqueue_line_notification()
returns trigger
language plpgsql
set search_path=''
as $$
declare
  v_pref_column text;
  v_enabled boolean;
  v_has_link boolean;
  v_existing_id uuid;
  v_item jsonb;
  v_is_canonical boolean;
  v_priority text;
begin
  if coalesce(new.urgency,'immediate') in ('digest','in_app_only') then
    return new;
  end if;

  v_pref_column := private.fn_line_preference_column_for_type(new.type);
  if v_pref_column is null then
    return new;
  end if;

  execute format(
    'select %I from public.notification_preferences where household_id = $1 and user_id = $2',
    v_pref_column
  )
  into v_enabled
  using new.household_id,new.recipient_user_id;

  if coalesce(v_enabled,false) is not true then
    return new;
  end if;

  select exists (
    select 1
    from private.line_user_links
    where user_id=new.recipient_user_id and status='active'
  )
  into v_has_link;

  if not v_has_link then
    return new;
  end if;

  -- Keep the domain payload at the transport boundary. Request action cards
  -- require request_id/attempt/revisions/request_kind; dropping these turns an
  -- actionable request into an inert text notification.
  v_item := jsonb_build_object(
    'user_notification_id',new.id,
    'type',new.type,
    'notification_kind',new.notification_kind,
    'title',new.title,
    'body',new.body,
    'payload',coalesce(new.payload,'{}'::jsonb),
    'dedup_key',new.dedup_key,
    'aggregate_type',new.aggregate_type,
    'aggregate_id',new.aggregate_id,
    'aggregate_revision',new.aggregate_revision
  );

  v_is_canonical :=
    new.notification_kind is not null
    or new.type like 'request.%'
    or new.type='task.completed_neutral';

  v_priority := case
    when new.safety_class='safety_critical' then 'critical'
    else 'normal'
  end;

  if v_is_canonical then
    insert into private.notification_outbox (
      household_id,
      recipient_user_id,
      channel,
      type,
      payload,
      dedup_key,
      priority,
      business_expires_at,
      test_context_id
    )
    values (
      new.household_id,
      new.recipient_user_id,
      'line',
      new.type,
      jsonb_build_object('items',jsonb_build_array(v_item)),
      'canonical:'||new.dedup_key,
      v_priority,
      coalesce(new.business_expires_at,now()+interval '24 hours'),
      null
    )
    on conflict (recipient_user_id,channel,dedup_key) do nothing;
    return new;
  end if;

  select id
  into v_existing_id
  from private.notification_outbox
  where household_id=new.household_id
    and recipient_user_id=new.recipient_user_id
    and channel='line'
    and status='queued'
  order by created_at desc
  limit 1
  for update;

  if found then
    update private.notification_outbox
    set payload=jsonb_set(
      payload,
      '{items}',
      coalesce(payload->'items','[]'::jsonb)||jsonb_build_array(v_item)
    )
    where id=v_existing_id;
    return new;
  end if;

  insert into private.notification_outbox (
    household_id,
    recipient_user_id,
    channel,
    type,
    payload,
    dedup_key,
    priority,
    business_expires_at,
    test_context_id
  )
  values (
    new.household_id,
    new.recipient_user_id,
    'line',
    new.type,
    jsonb_build_object('items',jsonb_build_array(v_item)),
    'bundle:'||new.dedup_key,
    'normal',
    now()+interval '24 hours',
    null
  );

  return new;
end;
$$;

create or replace function private.fn_enrich_line_outbox_request_payload()
returns trigger
language plpgsql
set search_path=''
as $$
declare
  v_rich jsonb;
  v_due_label text;
begin
  if new.type not in ('request.received','request_received')
     or coalesce(new.payload->>'request_id','')='' then
    return new;
  end if;

  -- The worker now builds assignment-change Flex from the canonical payload.
  -- Keep the existing server-side rich-message path for general requests too.
  if new.payload->>'request_kind'='general'
     and coalesce(new.payload->>'accept_pending_action_id','')<>''
     and coalesce(new.payload->>'decline_pending_action_id','')<>'' then
    v_due_label := case
      when new.payload->>'due_at' is null then null
      else to_char(
        (new.payload->>'due_at')::timestamptz at time zone 'Asia/Tokyo',
        'MM/DD HH24:MI'
      )
    end;

    v_rich := jsonb_build_object(
      'type','flex',
      'altText','お願い: '||new.title,
      'contents',jsonb_build_object(
        'type','bubble',
        'body',jsonb_build_object(
          'type','box',
          'layout','vertical',
          'spacing','md',
          'contents',jsonb_strip_nulls(jsonb_build_array(
            jsonb_build_object(
              'type','text','text','お願いが届いています',
              'weight','bold','size','sm','color','#166B5D'
            ),
            jsonb_build_object(
              'type','text','text',new.title,
              'weight','bold','size','xl','wrap',true
            ),
            case
              when v_due_label is null then null
              else jsonb_build_object(
                'type','text','text',v_due_label,
                'size','sm','color','#555555'
              )
            end,
            jsonb_build_object(
              'type','text',
              'text',coalesce(new.body,'お願いできますか？'),
              'wrap',true,'color','#555555'
            ),
            jsonb_build_object(
              'type','text',
              'text','引き受けるまでタスクにはなりません。',
              'size','xs','wrap',true,'color','#777777'
            )
          ))
        ),
        'footer',jsonb_build_object(
          'type','box',
          'layout','vertical',
          'spacing','sm',
          'contents',jsonb_build_array(
            jsonb_build_object(
              'type','button','style','primary',
              'action',jsonb_build_object(
                'type','postback',
                'label','引き受ける',
                'data','action=confirm_pending&pending_action_id='||(new.payload->>'accept_pending_action_id'),
                'displayText','引き受ける'
              )
            ),
            jsonb_build_object(
              'type','button','style','secondary',
              'action',jsonb_build_object(
                'type','postback',
                'label','今回は難しい',
                'data','action=confirm_pending&pending_action_id='||(new.payload->>'decline_pending_action_id'),
                'displayText','今回は難しい'
              )
            )
          )
        )
      )
    );
  end if;

  update private.notification_outbox o
  set payload = case
    when v_rich is null then
      jsonb_set(
        o.payload,
        '{items}',
        coalesce((
          select jsonb_agg(
            case
              when item->>'user_notification_id'=new.id::text
                then item||jsonb_build_object('payload',new.payload)
              else item
            end
          )
          from jsonb_array_elements(coalesce(o.payload->'items','[]'::jsonb)) item
        ),'[]'::jsonb),
        true
      )
    else
      jsonb_set(
        jsonb_set(
          o.payload,
          '{items}',
          coalesce((
            select jsonb_agg(
              case
                when item->>'user_notification_id'=new.id::text
                  then item||jsonb_build_object('payload',new.payload)
                else item
              end
            )
            from jsonb_array_elements(coalesce(o.payload->'items','[]'::jsonb)) item
          ),'[]'::jsonb),
          true
        ),
        '{rich_message}',
        v_rich,
        true
      )
  end
  where o.household_id=new.household_id
    and o.recipient_user_id=new.recipient_user_id
    and o.status='queued'
    and o.payload @> jsonb_build_object(
      'items',
      jsonb_build_array(jsonb_build_object('user_notification_id',new.id))
    );

  return new;
end;
$$;
