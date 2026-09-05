-- The supported public complete-task RPC has exactly five arguments. Historical
-- experimentation left an additional overload with trailing defaults, making a
-- legacy five-argument call containing NULL ambiguous in PostgreSQL/PostgREST.
-- Remove only overloads that can be invoked with five arguments; retain the
-- exact five-argument compatibility RPC and any non-ambiguous signatures.

do $$
declare
  r record;
  v_required_args int;
begin
  for r in
    select p.oid,p.pronargs,p.pronargdefaults,pg_get_function_identity_arguments(p.oid) as identity_args
    from pg_proc p
    join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname='server_tx_complete_task'
  loop
    v_required_args := r.pronargs-r.pronargdefaults;
    if r.pronargs<>5 and v_required_args<=5 then
      execute format('drop function public.server_tx_complete_task(%s)',r.identity_args);
    end if;
  end loop;
end;
$$;

-- Fail migration rather than leave a subtly ambiguous public API.
do $$
declare v_count int;
begin
  select count(*) into v_count
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='server_tx_complete_task'
    and p.pronargs-p.pronargdefaults<=5;
  if v_count<>1 then
    raise exception 'COMPLETE_TASK_PUBLIC_ARITY_DRIFT count=%',v_count;
  end if;
end;
$$;
