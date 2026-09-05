-- Q72: household terminology is a confirmed, household-scoped vocabulary.
-- It deliberately stores only language -> language mappings: neither
-- assignee nor recurrence/routine rules are fields in this model, so learning
-- a phrase cannot silently alter a family's operating rules.
create table if not exists public.household_terminology (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  phrase text not null check (char_length(btrim(phrase)) between 1 and 80),
  meaning text not null check (char_length(btrim(meaning)) between 1 and 80),
  confirmed_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (household_id, phrase)
);

alter table public.household_terminology enable row level security;
grant select on public.household_terminology to authenticated;
create policy household_terminology_select on public.household_terminology
  for select to authenticated
  using (public.is_household_member(household_id));

-- The PWA replaces the explicitly reviewed vocabulary atomically. It is a
-- server mutation with an operation receipt, rather than an exposed-table write.
create or replace function public.server_tx_replace_household_terminology(
  p_actor_id uuid, p_operation_id uuid, p_terms jsonb
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_household_id uuid;
  v_receipt record;
  v_hash text;
  v_item jsonb;
  v_phrase text;
  v_meaning text;
  v_id uuid;
  v_keep_ids uuid[] := '{}';
  v_phrases text[] := '{}';
begin
  if p_actor_id is null or p_operation_id is null or jsonb_typeof(p_terms) <> 'array'
     or jsonb_array_length(p_terms) > 30 then
    raise exception 'INVALID_INPUT';
  end if;
  v_hash := encode(sha256(convert_to('household-terminology|' || p_terms::text, 'UTF8')), 'hex');
  loop
    insert into private.mutation_receipts(actor_id, operation_id, action_type, request_hash)
      values (p_actor_id, p_operation_id, 'replace-household-terminology', v_hash)
      on conflict (actor_id, operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts
      where actor_id = p_actor_id and operation_id = p_operation_id for update;
    if v_receipt.request_hash <> v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return v_receipt.result_payload;
  end loop;
  select household_id into v_household_id from public.household_members where user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  for v_item in select value from jsonb_array_elements(p_terms) loop
    v_phrase := btrim(coalesce(v_item->>'phrase', ''));
    v_meaning := btrim(coalesce(v_item->>'meaning', ''));
    if char_length(v_phrase) not between 1 and 80 or char_length(v_meaning) not between 1 and 80 then raise exception 'INVALID_INPUT'; end if;
    if lower(v_phrase) = any(v_phrases) then raise exception 'INVALID_INPUT'; end if;
    v_phrases := array_append(v_phrases, lower(v_phrase));
    if nullif(v_item->>'id', '') is not null then
      begin v_id := (v_item->>'id')::uuid; exception when invalid_text_representation then raise exception 'INVALID_INPUT'; end;
      if not exists (select 1 from public.household_terminology where id = v_id and household_id = v_household_id) then raise exception 'INVALID_INPUT'; end if;
      v_keep_ids := array_append(v_keep_ids, v_id);
    end if;
  end loop;
  delete from public.household_terminology where household_id = v_household_id and not (id = any(v_keep_ids));
  for v_item in select value from jsonb_array_elements(p_terms) loop
    v_phrase := btrim(v_item->>'phrase'); v_meaning := btrim(v_item->>'meaning');
    if nullif(v_item->>'id', '') is null then
      insert into public.household_terminology(household_id, phrase, meaning) values (v_household_id, v_phrase, v_meaning);
    else
      update public.household_terminology set phrase = v_phrase, meaning = v_meaning, confirmed_at = now(), updated_at = now()
        where id = (v_item->>'id')::uuid and household_id = v_household_id;
    end if;
  end loop;
  update private.mutation_receipts set result_type = 'household_terminology', result_payload = jsonb_build_object('ok', true)
    where actor_id = p_actor_id and operation_id = p_operation_id;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.server_tx_replace_household_terminology(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.server_tx_replace_household_terminology(uuid, uuid, jsonb) to service_role;
