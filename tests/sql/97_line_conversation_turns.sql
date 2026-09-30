-- LINE conversation turns: written by the inbox, read back oldest-first for the AI router.
\set ON_ERROR_STOP on

begin;
set role service_role;

do $$
declare
  u1 uuid:=gen_random_uuid();
  u2 uuid:=gen_random_uuid();
  outsider uuid:=gen_random_uuid();
  hh uuid;
  turns jsonb;
  n int;
begin
  insert into auth.users(id) values(u1),(u2),(outsider);
  hh:=(public.server_tx_create_household(u1,gen_random_uuid(),'turns','Owner')->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role,family_role) values(hh,u2,'adult','mama');

  perform public.server_tx_log_line_turn(u1,'user','買うものは？');
  perform public.server_tx_log_line_turn(u1,'assistant','買い物リストを確認したいのですね。どなたが…');
  perform public.server_tx_log_line_turn(u1,'user','おれ');
  perform public.server_tx_log_line_turn(u2,'user','ママの発言');

  turns:=public.server_read_line_turns(u1);
  if jsonb_array_length(turns)<>3 then raise exception 'expected 3 turns for papa, got %', turns; end if;
  if turns->0->>'text'<>'買うものは？' or turns->2->>'text'<>'おれ' or turns->1->>'role'<>'assistant' then
    raise exception 'turns must come back oldest first with roles: %', turns;
  end if;
  -- One person never sees the other's conversation.
  if jsonb_array_length(public.server_read_line_turns(u2))<>1 then raise exception 'turns leaked between people'; end if;

  -- Limit and window.
  if jsonb_array_length(public.server_read_line_turns(u1,2))<>2
     or public.server_read_line_turns(u1,2)->0->>'text'<>'買い物リストを確認したいのですね。どなたが…' then
    raise exception 'limit must keep the most recent turns';
  end if;
  update private.line_conversation_turns set created_at=now()-interval '5 hours' where actor_id=u1 and text='買うものは？';
  if jsonb_array_length(public.server_read_line_turns(u1))<>2 then raise exception 'turns older than the window must not be returned'; end if;

  -- Retention: an old row is removed when the next turn is written.
  update private.line_conversation_turns set created_at=now()-interval '4 days' where actor_id=u1 and text='買うものは？';
  perform public.server_tx_log_line_turn(u1,'user','次の発言');
  if exists(select 1 from private.line_conversation_turns where actor_id=u1 and text='買うものは？') then
    raise exception 'turns older than 3 days must be deleted on write';
  end if;

  -- At most 60 turns are kept per person.
  for n in 1..70 loop
    perform public.server_tx_log_line_turn(u2,'user','発言'||n);
  end loop;
  if (select count(*) from private.line_conversation_turns where actor_id=u2)<>60 then
    raise exception 'expected 60 kept, got %', (select count(*) from private.line_conversation_turns where actor_id=u2);
  end if;
  if not exists(select 1 from private.line_conversation_turns where actor_id=u2 and text='発言70') then
    raise exception 'the newest turn must be kept';
  end if;

  -- Validation.
  begin perform public.server_tx_log_line_turn(u1,'bot','x'); raise exception 'bad role accepted';
  exception when others then if sqlerrm<>'INVALID_INPUT' then raise; end if; end;
  begin perform public.server_tx_log_line_turn(u1,'user','   '); raise exception 'blank text accepted';
  exception when others then if sqlerrm<>'INVALID_INPUT' then raise; end if; end;
  begin perform public.server_tx_log_line_turn(outsider,'user','x'); raise exception 'non-member accepted';
  exception when others then if sqlerrm<>'NOT_HOUSEHOLD_MEMBER' then raise; end if; end;
end $$;

rollback;
