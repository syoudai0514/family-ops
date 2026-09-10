-- F2 regression for the real LINE Today remediation.
-- The rejected clock-prefix workaround must stay gone. Same-title routine work
-- is disambiguated by daypart grouping, handovers carry direction/ack context,
-- and tomorrow output names the actual preparation/change instead of an opaque
-- impact count.
\set ON_ERROR_STOP on

begin;
set local role service_role;

do $$
declare
  v_plain text;
  v_urgent text;
  v_handover text;
  v_rendered text;
begin
  v_plain := private.fn_daily_brief_lines_v1(
    jsonb_build_array(
      jsonb_build_object('title', '同名タスク', 'due_at', '2026-09-09T22:00:00+00:00'),
      jsonb_build_object('title', '同名タスク', 'due_at', '2026-09-10T11:45:00+00:00')
    )
  );
  if position('07:00' in v_plain) > 0 or position('20:45' in v_plain) > 0 then
    raise exception 'FAIL f2-line-today-daypart: per-item clock clutter returned: %', v_plain;
  end if;

  v_urgent := private.fn_daily_brief_urgent_lines_v2(
    jsonb_build_array(
      jsonb_build_object('kind', 'request_reply_needed', 'title', 'お迎えのお願い', 'state', 'pending'),
      jsonb_build_object('kind', 'assignment_needed', 'title', '同名タスク', 'routine_phase', 'morning'),
      jsonb_build_object('kind', 'assignment_needed', 'title', '朝だけ', 'routine_phase', 'morning'),
      jsonb_build_object('kind', 'assignment_needed', 'title', '同名タスク', 'routine_phase', 'evening')
    )
  );
  if position('・お迎えのお願い（返事待ち）' in v_urgent) = 0
     or position('担当未定（朝）' in v_urgent) = 0
     or position('担当未定（夜）' in v_urgent) = 0
     or position('07:00' in v_urgent) > 0
     or position('20:45' in v_urgent) > 0 then
    raise exception 'FAIL f2-line-today-daypart: urgent/daypart context missing: %', v_urgent;
  end if;
  if position('担当未定（朝）' in v_urgent) > position('担当未定（夜）' in v_urgent) then
    raise exception 'FAIL f2-line-today-daypart: daypart order drifted: %', v_urgent;
  end if;

  v_handover := private.fn_daily_brief_handover_lines_v1(
    jsonb_build_array(
      jsonb_build_object(
        'author_role', 'papa',
        'audience_label', '家族',
        'info_kind', 'handover',
        'ack_policy', 'none',
        'shared_text', '水筒は玄関です'
      ),
      jsonb_build_object(
        'author_role', 'mama',
        'audience_label', '家族',
        'info_kind', 'share',
        'ack_policy', 'required',
        'shared_text', '提出物を確認してください'
      )
    )
  );
  if position('パパ → 家族全員｜引き継ぎ' in v_handover) = 0
     or position('状態: 共有中・確認不要' in v_handover) = 0
     or position('ママ → 家族全員｜共有' in v_handover) = 0
     or position('状態: あなたの確認待ち' in v_handover) = 0
     or position('必要: 下の「共有を確認」→「確認した」' in v_handover) = 0
     or position('内容: 水筒は玄関です' in v_handover) = 0
     or position('内容: 提出物を確認してください' in v_handover) = 0 then
    raise exception 'FAIL f2-line-today-handover: actor/audience/state/action context missing: %', v_handover;
  end if;

  v_rendered := private.fn_render_daily_brief_text_v3(
    jsonb_build_object(
      'urgent_actions', '[]'::jsonb,
      'exceptions', '[]'::jsonb,
      'carryovers', '[]'::jsonb,
      'active_infos', '[]'::jsonb,
      'already_handled', '[]'::jsonb,
      'waiting_checks', '[]'::jsonb,
      'schedule', '[]'::jsonb,
      'own_task_groups', jsonb_build_object(
        'morning', '[]'::jsonb,
        'daytime', '[]'::jsonb,
        'evening', '[]'::jsonb,
        'optional', '[]'::jsonb
      ),
      'partner_summary', jsonb_build_object(
        'open_assigned', 0,
        'waiting', 0,
        'completed_today', 0,
        'critical_items', '[]'::jsonb
      ),
      'tomorrow_impact', jsonb_build_object(
        'tasks', jsonb_build_array(jsonb_build_object('title', '明日の園バッグ準備')),
        'schedule', '[]'::jsonb,
        'carryovers', '[]'::jsonb,
        'impact_count', 1
      ),
      'reconciliation', jsonb_build_object('remaining_count', 0),
      'morning_summary', jsonb_build_object('completed_count', 0, 'total_count', 0),
      'shopping', '[]'::jsonb
    ),
    'evening'
  );
  if position('明日の準備・変更' in v_rendered) = 0
     or position('明日の園バッグ準備' in v_rendered) = 0
     or position('明日に影響' in v_rendered) > 0 then
    raise exception 'FAIL f2-line-today-tomorrow: concrete tomorrow detail missing: %', v_rendered;
  end if;
end;
$$;

rollback;
select 'f2_line_today_actionable_ux: PASS' as result;
