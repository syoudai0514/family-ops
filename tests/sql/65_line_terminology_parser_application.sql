-- Q72 literal runtime evidence: confirmed household vocabulary is applied to
-- the claimed LINE message BEFORE the existing parser sees it.  Stored raw
-- webhook payload stays unchanged, mappings are household-scoped and
-- deletion immediately removes parser behavior.  Fixed product commands may
-- not be shadowed by a household alias.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('65000000-0000-0000-0000-000000000001'),
  ('65000000-0000-0000-0000-000000000002');

set role service_role;
do $$
declare
  v_hh_a jsonb;
  v_hh_b jsonb;
  v_hh_a_id uuid;
  v_hh_b_id uuid;
  v_claim jsonb;
  v_item jsonb;
  v_raw text;
  v_parser text;
begin
  v_hh_a := public.server_tx_create_household(
    '65000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Term Parser A', 'Owner A'
  );
  v_hh_b := public.server_tx_create_household(
    '65000000-0000-0000-0000-000000000002', gen_random_uuid(), 'Term Parser B', 'Owner B'
  );
  v_hh_a_id := (v_hh_a->>'household_id')::uuid;
  v_hh_b_id := (v_hh_b->>'household_id')::uuid;

  insert into private.line_user_links(household_id,user_id,line_user_id,status)
  values
    (v_hh_a_id,'65000000-0000-0000-0000-000000000001','U-term-parser-a','active'),
    (v_hh_b_id,'65000000-0000-0000-0000-000000000002','U-term-parser-b','active');

  perform public.server_tx_replace_household_terminology(
    '65000000-0000-0000-0000-000000000001', gen_random_uuid(),
    jsonb_build_array(
      jsonb_build_object('phrase','送り','meaning','保育園の送り'),
      jsonb_build_object('phrase','保育園','meaning','園')
    )
  );
  perform public.server_tx_replace_household_terminology(
    '65000000-0000-0000-0000-000000000002', gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('phrase','送り','meaning','学童の送り'))
  );

  perform public.server_tx_ingest_line_webhook_event(
    'term-parser-a-1','U-term-parser-a',
    '{"type":"message","timestamp":1000,"message":{"type":"text","text":"送り 明日"}}'::jsonb
  );
  perform public.server_tx_ingest_line_webhook_event(
    'term-parser-b-1','U-term-parser-b',
    '{"type":"message","timestamp":1000,"message":{"type":"text","text":"送り 明日"}}'::jsonb
  );

  v_claim := public.server_tx_claim_webhook_inbox_batch('term-parser-worker',100,60);
  select value into v_item from jsonb_array_elements(v_claim)
    where value->>'provider_event_id'='term-parser-a-1';
  if v_item is null then raise exception 'FAIL terminology-parser: household A event was not claimed'; end if;
  v_parser := v_item#>>'{payload,message,text}';
  if v_parser <> '保育園の送り 明日' then
    raise exception 'FAIL terminology-parser: expected single-pass household A parser text, got %', v_parser;
  end if;
  select payload#>>'{message,text}' into v_raw from private.webhook_inbox
    where provider_event_id='term-parser-a-1';
  if v_raw <> '送り 明日' then
    raise exception 'FAIL terminology-parser: durable raw webhook payload was mutated';
  end if;
  perform public.server_tx_complete_webhook_inbox_item(
    (v_item->>'id')::uuid,(v_item->>'lease_token')::uuid
  );

  select value into v_item from jsonb_array_elements(v_claim)
    where value->>'provider_event_id'='term-parser-b-1';
  if v_item#>>'{payload,message,text}' <> '学童の送り 明日' then
    raise exception 'FAIL terminology-parser: household B vocabulary leaked/was not isolated';
  end if;
  perform public.server_tx_complete_webhook_inbox_item(
    (v_item->>'id')::uuid,(v_item->>'lease_token')::uuid
  );

  -- Remove A's vocabulary. The next claimed message must return to literal
  -- input without requiring a deploy or cache invalidation.
  perform public.server_tx_replace_household_terminology(
    '65000000-0000-0000-0000-000000000001', gen_random_uuid(), '[]'::jsonb
  );
  perform public.server_tx_ingest_line_webhook_event(
    'term-parser-a-2','U-term-parser-a',
    '{"type":"message","timestamp":2000,"message":{"type":"text","text":"送り 明日"}}'::jsonb
  );
  v_claim := public.server_tx_claim_webhook_inbox_batch('term-parser-worker-2',100,60);
  select value into v_item from jsonb_array_elements(v_claim)
    where value->>'provider_event_id'='term-parser-a-2';
  if v_item#>>'{payload,message,text}' <> '送り 明日' then
    raise exception 'FAIL terminology-parser: deleted term still affects parser input';
  end if;
  perform public.server_tx_complete_webhook_inbox_item(
    (v_item->>'id')::uuid,(v_item->>'lease_token')::uuid
  );

  -- Product grammar wins over household vocabulary for the literal LINE menu.
  perform public.server_tx_replace_household_terminology(
    '65000000-0000-0000-0000-000000000001', gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('phrase','追加','meaning','別の意味'))
  );
  perform public.server_tx_ingest_line_webhook_event(
    'term-parser-a-3','U-term-parser-a',
    '{"type":"message","timestamp":3000,"message":{"type":"text","text":"追加"}}'::jsonb
  );
  v_claim := public.server_tx_claim_webhook_inbox_batch('term-parser-worker-3',100,60);
  select value into v_item from jsonb_array_elements(v_claim)
    where value->>'provider_event_id'='term-parser-a-3';
  if v_item#>>'{payload,message,text}' <> '追加' then
    raise exception 'FAIL terminology-parser: household term shadowed fixed LINE command';
  end if;
end;
$$;

reset role;
select 'line_terminology_parser_application: PASS' as result;
