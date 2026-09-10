-- F2 real-use UX follow-up: a handover/share row must answer three questions
-- directly in LINE: who shared it, who can see it, and what the current user
-- needs to do. The underlying audience model remains household/self; this is a
-- rendering correction only.

create or replace function private.fn_daily_brief_handover_lines_v1(p_items jsonb)
returns text
language sql
immutable
security invoker
set search_path = ''
as $$
  select string_agg(
    '・'
    || case item->>'author_role'
      when 'papa' then 'パパ'
      when 'mama' then 'ママ'
      else coalesce(nullif(item->>'author_label', ''), '家族')
    end
    || ' → ' || case coalesce(nullif(item->>'audience_label', ''), '家族')
      when '家族' then '家族全員'
      else coalesce(nullif(item->>'audience_label', ''), '家族全員')
    end
    || '｜' || case item->>'info_kind' when 'share' then '共有' else '引き継ぎ' end
    || E'\n  状態: ' || case
      when coalesce(item->>'ack_policy', 'none') = 'required' then 'あなたの確認待ち'
      else '共有中・確認不要'
    end
    || case
      when coalesce(item->>'ack_policy', 'none') = 'required'
        then E'\n  必要: 下の「共有を確認」→「確認した」'
      else ''
    end
    || E'\n  内容: '
    || replace(coalesce(nullif(item->>'shared_text', ''), '内容なし'), E'\n', E'\n        '),
    E'\n' order by ord
  )
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
    with ordinality as entries(item, ord)
$$;

revoke all on function private.fn_daily_brief_handover_lines_v1(jsonb)
  from public, anon, authenticated;
grant execute on function private.fn_daily_brief_handover_lines_v1(jsonb)
  to service_role;
