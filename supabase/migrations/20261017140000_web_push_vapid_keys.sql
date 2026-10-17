-- The VAPID key pair for PWA push lives here unless WEB_PUSH_VAPID_* secrets are set.
-- The deploy token cannot write Edge Function secrets, so the first push request makes
-- the pair and every later request reads the same one. Only service_role can read it.
create table private.web_push_vapid_keys (
  id boolean primary key default true check (id),
  public_key text not null check (length(public_key) between 40 and 200),
  private_key text not null check (length(private_key) between 20 and 200),
  created_at timestamptz not null default now()
);
grant all on private.web_push_vapid_keys to service_role;

-- Returns the stored pair, storing the offered one first if none exists yet. Two
-- workers racing both get the pair that won.
create or replace function public.server_tx_web_push_vapid_keys(p_public_key text, p_private_key text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare v private.web_push_vapid_keys%rowtype;
begin
  if p_public_key is not null and p_private_key is not null then
    insert into private.web_push_vapid_keys(public_key,private_key) values(p_public_key,p_private_key)
    on conflict(id) do nothing;
  end if;
  select * into v from private.web_push_vapid_keys where id;
  if not found then return null; end if;
  return jsonb_build_object('public_key',v.public_key,'private_key',v.private_key);
end $$;
revoke all on function public.server_tx_web_push_vapid_keys(text,text) from public,anon,authenticated;
grant execute on function public.server_tx_web_push_vapid_keys(text,text) to service_role;
