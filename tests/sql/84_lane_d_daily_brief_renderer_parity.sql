-- Lane D CF-02 / CF-04: text transports must surface the same material
-- DailyBrief exception/waiting/completion semantics as PWA Today.
\set ON_ERROR_STOP on

begin;
set local role service_role;

do $$
declare
  v_brief jsonb := jsonb_build_object(
    'urgent_actions', jsonb_build_array(jsonb_build_object('shared_title', '担当を決める')),
    'exceptions', jsonb_build_array(jsonb_build_object('message', '保育園が短縮')),
    'carryovers', jsonb_build_array(jsonb_build_object('title', '昨日の提出物')),
    'waiting_checks', jsonb_build_array(jsonb_build_object('waiting_note', '園から返事待ち')),
    'active_infos', jsonb_build_array(jsonb_build_object('shared_text', '水筒を玄関へ')),
    'already_handled', jsonb_build_array(jsonb_build_object('title', '朝の連絡帳')),
    'own_task_groups', jsonb_build_object(
      'morning', jsonb_build_array(jsonb_build_object('title', '朝の薬')),
      'daytime', jsonb_build_array(jsonb_build_object('title', '買い出し')),
      'evening', jsonb_build_array(jsonb_build_object('title', '洗濯')),
      'optional', '[]'::jsonb
    ),
    'schedule', jsonb_build_array(jsonb_build_object('title', '保育園面談')),
    'partner_summary', jsonb_build_object('critical_items', '[]'::jsonb),
    'tomorrow_impact', jsonb_build_object('impact_count', 1),
    'shopping', '[]'::jsonb,
    'reconciliation', jsonb_build_object('remaining_count', 0),
    'morning_summary', jsonb_build_object('completed_count', 3, 'total_count', 4)
  );
  v_day text;
  v_evening text;
begin
  v_day := private.fn_render_daily_brief_text_v3(v_brief, 'daytime');
  if position('担当を決める' in v_day) = 0
     or position('まず確認' in v_day) = 0
     or position('いつもと違うこと' in v_day) = 0
     or position('保育園が短縮' in v_day) = 0
     or position('昨日の提出物' in v_day) = 0
     or position('引き継ぎ・共有' in v_day) = 0
     or position('もう済んでいる' in v_day) = 0
     or position('今やること' in v_day) = 0
     or position('園から返事待ち' in v_day) = 0 then
    raise exception 'FAIL lane-d-renderer-day: material DailyBrief semantics missing: %', v_day;
  end if;

  if position('まず確認' in v_day) > position('いつもと違うこと' in v_day)
     or position('いつもと違うこと' in v_day) > position('引き継ぎ・共有' in v_day)
     or position('引き継ぎ・共有' in v_day) > position('もう済んでいる' in v_day)
     or position('もう済んでいる' in v_day) > position('今やること' in v_day) then
    raise exception 'FAIL lane-d-renderer-order: approved priority order drifted: %', v_day;
  end if;

  v_evening := private.fn_render_daily_brief_text_v3(v_brief, 'evening');
  if position('園から返事待ち' in v_evening) = 0
     or position('朝 3/4 完了' in v_evening) = 0
     or position('明日に影響' in v_evening) = 0 then
    raise exception 'FAIL lane-d-renderer-evening: waiting/morning-summary/tomorrow missing: %', v_evening;
  end if;
  if position('引き継ぎ・共有' in v_evening) > position('もう済んでいる' in v_evening)
     or position('もう済んでいる' in v_evening) > position('まだ残っていること' in v_evening) then
    raise exception 'FAIL lane-d-renderer-evening-order: completed/handover must precede ordinary remaining work: %', v_evening;
  end if;
end;
$$;

rollback;
select 'lane_d_daily_brief_renderer_parity: PASS' as result;
