-- KMD One database setup — kmd_db_part 10 of 11. Run in order, each once.
-- Files: 20261114044459_class_tests.sql … 20261116033500_fees_copy_structure_catchup.sql

-- ======================================================== migrations/20261114044459_class_tests.sql
/*
 * Class tests (D-609): any test a teacher takes, any day, out of any marks,
 * kept apart from the school's exams.
 *
 * The owner (14 Nov 2026): teachers "randomly take different exams as well
 * ... they need to be uploaded as well to track the student progress. But
 * they are not added to the main ... sometimes they are added, sometimes
 * they are not". So a class test is its own record, never an `assessments`
 * row: results, report cards, the exam office's trackers, the parent helper
 * and every view over `assessments` keep reading exactly the exams they read
 * today, and a class test cannot reach a result by accident.
 *
 * A class test may name ONE school exam it helps fill (`counts_in`, "Count
 * in Test I"). That is a note for the teacher's Test I sheet, which offers to
 * fill her boxes from the counted tests; she checks every number and sends
 * Test I through `save_marks` as always. Nothing here writes `marks`.
 *
 *   1. `class_tests`        one test: class, subject, day, out of, the exam
 *                           it counts in (or none), open or finished.
 *   2. `class_test_marks`   one child's mark in it. NULL value and absent
 *                           false is a box somebody cleared: blank, not 0.
 *   3. `save_class_test_marks(jsonb)`  one save, in one transaction, for the
 *                           sheet the exam papers use (draft, finish, change).
 *
 * Who may save is decided by the app before the call (the test's teacher, a
 * teacher of that class and subject, or the exam office); the function checks
 * the test, the roll, the marks and the counts. Service role only, like the
 * other exam writes. It only adds tables and a function, and no fee
 * table is touched.
 */

begin;

/* ----------------------------------------------------------- the tests */

create table vppsone.class_tests (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,

  -- `public.classes.id` / the roster projection's class, with no FK (rule 2, D-5).
  class_id uuid not null,
  class_label text not null,

  subject_id uuid not null references vppsone.subjects (id),
  subject_code text not null,

  title text not null,
  held_on date not null,

  max_marks numeric not null,
  mark_step numeric not null default 1,

  -- The school exam this test helps fill, or none (progress only).
  counts_in uuid references vppsone.assessments (id),

  status text not null default 'open',
  revision integer not null default 0,
  finished_at timestamptz,
  finished_by uuid references vppsone.staff_profiles (id),

  -- Taken off the lists by its teacher. The row stays for good: a mark once
  -- typed is a record of what a child did.
  removed_at timestamptz,
  removed_by uuid references vppsone.staff_profiles (id),

  created_by uuid not null references vppsone.staff_profiles (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint class_tests_title_sane check (char_length(btrim(title)) between 1 and 80),
  constraint class_tests_max_sane check (max_marks > 0 and max_marks <= 500),
  constraint class_tests_step_sane check (mark_step in (0.5, 1)),
  constraint class_tests_status_known check (status in ('open', 'finished')),
  constraint class_tests_finished_together check ((status = 'finished') = (finished_at is not null)),
  constraint class_tests_removed_together check ((removed_at is null) = (removed_by is null))
);

comment on table vppsone.class_tests is
  'A test a teacher takes for her class, any day, out of any marks (D-609). Never a column on a result by itself; counts_in names the school exam whose sheet may be filled from it, with the teacher''s check.';
comment on column vppsone.class_tests.counts_in is
  'The school exam (assessments.id) this test helps fill, e.g. Test I; NULL = progress only.';

create index class_tests_class_subject_idx
  on vppsone.class_tests (session_label, class_id, subject_id, held_on desc)
  where removed_at is null;

create index class_tests_counts_in_idx
  on vppsone.class_tests (counts_in, class_id, subject_id)
  where counts_in is not null and removed_at is null;

create index class_tests_creator_idx
  on vppsone.class_tests (created_by, session_label, held_on desc)
  where removed_at is null;

create trigger class_tests_set_updated_at
  before update on vppsone.class_tests
  for each row execute function vppsone.set_updated_at();

alter table vppsone.class_tests enable row level security;
revoke all on vppsone.class_tests from public, anon, authenticated;
grant all on vppsone.class_tests to service_role;

/* ----------------------------------------------------------- the marks */

create table vppsone.class_test_marks (
  id uuid primary key default gen_random_uuid(),
  class_test_id uuid not null references vppsone.class_tests (id),
  student_id uuid not null,

  value numeric,
  absent boolean not null default false,

  entered_by uuid references vppsone.staff_profiles (id),
  entered_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  -- A row holds a mark, an absence, or neither (a box somebody cleared,
  -- which reads as blank); never a mark and an absence together.
  constraint class_test_marks_one_answer check (not (value is not null and absent)),
  constraint class_test_marks_not_negative check (value is null or value >= 0)
);

comment on table vppsone.class_test_marks is
  'One child''s mark in one class test (D-609). NULL value with absent false is a cleared box: blank, never a zero.';

create unique index class_test_marks_unique
  on vppsone.class_test_marks (class_test_id, student_id);

create index class_test_marks_student_idx
  on vppsone.class_test_marks (student_id);

create trigger class_test_marks_set_updated_at
  before update on vppsone.class_test_marks
  for each row execute function vppsone.set_updated_at();

alter table vppsone.class_test_marks enable row level security;
revoke all on vppsone.class_test_marks from public, anon, authenticated;
grant all on vppsone.class_test_marks to service_role;

/* ------------------------------------------------------------ one save */

/*
 * p: { actor_staff_id, test_id, kind: draft | submit | reopen,
 *      entries: [{ student_id, state: blank | value | absent, value }] }
 *
 * Answers { ok: true, revision, entry_status: open | submitted, saved_at,
 * changed, counts } or { ok: false, reason[, student_id | blank] }, the
 * shapes the marks sheet already reads. A save repeated after a lost answer
 * writes the same values again, so it needs no command ledger: every entry
 * says what the cell IS, never what to add.
 */
create or replace function vppsone.save_class_test_marks(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_actor uuid := nullif(p->>'actor_staff_id', '')::uuid;
  v_test uuid := nullif(p->>'test_id', '')::uuid;
  v_kind text := coalesce(p->>'kind', '');
  t vppsone.class_tests%rowtype;
  v_roster uuid[];
  e jsonb;
  v_student uuid;
  v_state text;
  v_value numeric;
  v_changed integer := 0;
  v_rows integer;
  v_blank uuid[];
  v_entered integer;
  v_absent integer;
begin
  if v_actor is null or v_test is null or v_kind not in ('draft', 'submit', 'reopen') then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  select * into t from vppsone.class_tests where id = v_test for update;
  if not found or t.removed_at is not null then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  if v_kind = 'reopen' then
    if t.status = 'finished' then
      update vppsone.class_tests
        set status = 'open', finished_at = null, finished_by = null, revision = revision + 1
        where id = t.id
        returning * into t;
    end if;
    return jsonb_build_object('ok', true, 'revision', t.revision, 'entry_status', 'open', 'saved_at', now(), 'changed', 0);
  end if;

  -- A finished test is changed only after "Change marks" (reopen); a draft
  -- arriving late from another phone must not edit it behind her back.
  if t.status = 'finished' and v_kind = 'draft' then
    return jsonb_build_object('ok', false, 'reason', 'paper_submitted');
  end if;

  select coalesce(array_agg(r), '{}'::uuid[]) into v_roster
    from vppsone.attendance_roster(t.session_label, t.class_id, t.held_on) r;

  for e in select * from jsonb_array_elements(coalesce(p->'entries', '[]'::jsonb)) loop
    v_student := nullif(e->>'student_id', '')::uuid;
    v_state := coalesce(e->>'state', '');
    v_value := case when e->>'value' is null then null else (e->>'value')::numeric end;
    if v_student is null or not (v_student = any(v_roster)) then
      return jsonb_build_object('ok', false, 'reason', 'not_on_roster', 'student_id', v_student);
    end if;
    if v_state = 'value' then
      if v_value is null or v_value < 0 or v_value > t.max_marks
         or (v_value / t.mark_step) <> trunc(v_value / t.mark_step) then
        return jsonb_build_object('ok', false, 'reason', 'invalid_value', 'student_id', v_student);
      end if;
      insert into vppsone.class_test_marks (class_test_id, student_id, value, absent, entered_by)
        values (t.id, v_student, v_value, false, v_actor)
        on conflict (class_test_id, student_id) do update
          set value = excluded.value, absent = false, entered_by = excluded.entered_by, entered_at = now()
          where vppsone.class_test_marks.value is distinct from excluded.value
             or vppsone.class_test_marks.absent;
      get diagnostics v_rows = row_count;
    elsif v_state = 'absent' then
      insert into vppsone.class_test_marks (class_test_id, student_id, value, absent, entered_by)
        values (t.id, v_student, null, true, v_actor)
        on conflict (class_test_id, student_id) do update
          set value = null, absent = true, entered_by = excluded.entered_by, entered_at = now()
          where not vppsone.class_test_marks.absent;
      get diagnostics v_rows = row_count;
    elsif v_state = 'blank' then
      -- Cleared: the row stays, holding neither a mark nor Absent, which
      -- reads as blank (the exam marks table's rule, P7).
      update vppsone.class_test_marks
        set value = null, absent = false, entered_by = v_actor, entered_at = now()
        where class_test_id = t.id and student_id = v_student
          and (value is not null or absent);
      get diagnostics v_rows = row_count;
    else
      return jsonb_build_object('ok', false, 'reason', 'bad_request');
    end if;
    v_changed := v_changed + v_rows;
  end loop;

  -- Children with no mark and no absence, among the class on the test's day.
  select coalesce(array_agg(r.id), '{}'::uuid[]) into v_blank
    from unnest(v_roster) as r(id)
    where not exists (
      select 1 from vppsone.class_test_marks m
      where m.class_test_id = t.id and m.student_id = r.id
        and (m.value is not null or m.absent)
    );

  if v_kind = 'submit' and cardinality(v_blank) > 0 then
    return jsonb_build_object('ok', false, 'reason', 'incomplete', 'blank', to_jsonb(v_blank));
  end if;

  select count(*) filter (where not m.absent), count(*) filter (where m.absent)
    into v_entered, v_absent
    from vppsone.class_test_marks m
    where m.class_test_id = t.id and m.student_id = any(v_roster)
      and (m.value is not null or m.absent);

  update vppsone.class_tests
    set revision = revision + 1,
        status = case when v_kind = 'submit' then 'finished' else status end,
        finished_at = case when v_kind = 'submit' then now() else finished_at end,
        finished_by = case when v_kind = 'submit' then v_actor else finished_by end
    where id = t.id
    returning * into t;

  return jsonb_build_object(
    'ok', true,
    'revision', t.revision,
    'entry_status', case when t.status = 'finished' then 'submitted' else 'open' end,
    'saved_at', now(),
    'changed', v_changed,
    'counts', jsonb_build_object('entered', v_entered, 'absent', v_absent, 'exempt', 0, 'blank', cardinality(v_blank), 'total', cardinality(v_roster))
  );
end;
$$;

revoke all on function vppsone.save_class_test_marks(jsonb) from public, anon, authenticated;
grant execute on function vppsone.save_class_test_marks(jsonb) to service_role;

commit;

-- ======================================================== migrations/20261114052936_class_tests_decision_number.sql
-- Class tests are D-609. The first apply of 20261114044459 named them D-608,
-- which is the sign-in decision; this sets the two table comments right.
comment on table vppsone.class_tests is
  'A test a teacher takes for her class, any day, out of any marks (D-609). Never a column on a result by itself; counts_in names the school exam whose sheet may be filled from it, with the teacher''s check.';
comment on table vppsone.class_test_marks is
  'One child''s mark in one class test (D-609). NULL value with absent false is a cleared box: blank, never a zero.';

-- ======================================================== migrations/20261114070634_parent_helper_report_cards.sql
-- Veer Patta AI sends a family its child's report card (D-613, exams step 4).
--
-- `parent_helper_child` (20261112041158) gains two things on each released
-- result and two on the child:
--
--  * on a result, its exam `code` and each subject's `code`, so the one-line
--    summary can name the subjects the card calls strongest and to practise;
--  * on a result, `card`: the term's report card as the school ISSUED it, its
--    figures and the exams it carries. Never a preview: a card the office has
--    not issued is not sent, and nothing here reads marks still being entered;
--  * on the child, `released_codes`: every exam released for the child's class, so a card
--    goes only when every exam on it is out (a Term 1 card reissued after a
--    later, unreleased exam is held back);
--  * on the child, `pending_results`: up to two exams the child sat whose results are not
--    out yet, by name and the day the plan gives, so the helper can say when
--    they come. No mark, no subject.
--
-- Everything else is byte-for-byte the function as it was, and it is still
-- for test-year children only. Additive: `create or replace`, the same
-- signature, so the grants stand.

create or replace function vppsone.parent_helper_child(p_student_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with today as (
    select (now() at time zone 'Asia/Kolkata')::date as d
  ),
  kid as (
    select s.id, s.full_name, s.class_id, s.status::text as status,
           c.session_label, c.class_name, c.section, c.stream_name
    from public.students s
    join public.classes c on c.id = s.class_id
    where s.id = p_student_id
      -- Step 1: test-year children only. A real family's fees come from the
      -- Fees app through its own connection, never from this replica.
      and c.session_label ~* '^(TEST|UAT|DEMO)-'
  )
  select case when not exists (select 1 from kid) then null else jsonb_build_object(
    'today', (select d from today),
    'student', (
      select jsonb_build_object(
        'id', k.id, 'full_name', k.full_name, 'class_id', k.class_id, 'status', k.status,
        'session_label', k.session_label, 'class_name', k.class_name, 'section', k.section, 'stream_name', k.stream_name)
      from kid k
    ),
    -- Fees only in `pending`; the late fee is its own column, never added in.
    'installments', coalesce((
      select jsonb_agg(jsonb_build_object(
          'installment_no', b.installment_no, 'due_date', b.due_date, 'pending', b.pending_amount,
          'late_pending', b.late_fee_pending, 'applied', b.applied_amount, 'carry_forward', b.is_carry_forward)
        order by b.due_date, b.installment_no)
      from public.v_workbook_installment_balances b
      join kid k on k.id = b.student_id and b.session_label = k.session_label
    ), '[]'::jsonb),
    -- The five latest receipts. A write-off is not a payment and is left out;
    -- a reversed receipt stays, marked.
    'receipts', coalesce((
      select jsonb_agg(q.r order by q.d desc, q.n desc)
      from (
        select jsonb_build_object(
            'number', r.receipt_number, 'date', r.payment_date, 'amount', r.total_amount,
            'mode', r.payment_mode::text,
            'reversed', r.total_amount > 0 and coalesce(t.reversed_amount, 0) >= r.total_amount) as r,
          r.payment_date as d, r.receipt_number as n
        from public.receipts r
        join kid k on k.id = r.student_id
        left join public.v_receipt_reversal_totals t on t.receipt_id = r.id
        where r.payment_mode::text <> 'discount'
        order by r.payment_date desc, r.receipt_number desc
        limit 5
      ) q
    ), '[]'::jsonb),
    'attendance', (
      select jsonb_build_object(
        'attendance_pct', a.attendance_pct, 'days_counted', a.days_counted,
        'absent_days', a.absent_days, 'late_days', a.late_days)
      from vppsone.v_student_attendance a
      join kid k on k.id = a.student_id and a.session_label = k.session_label
    ),
    -- The daily register's last 30 days, submitted registers only.
    'days', coalesce((
      select jsonb_agg(jsonb_build_object('day', g.day, 'status', m.status::text) order by g.day desc)
      from vppsone.attendance_marks m
      join vppsone.attendance_registers g on g.id = m.register_id
      join kid k on k.id = m.student_id and g.session_label = k.session_label
      where g.status = 'submitted' and g.period is null and g.day >= (select d from today) - 30
    ), '[]'::jsonb),
    -- What the school has finished: results released, the child's class locked.
    'results', coalesce((
      select jsonb_agg(q.e order by q.s desc nulls last)
      from (
        select jsonb_build_object(
            'label', a.label_en, 'label_hi', a.label_hi, 'term', a.term, 'code', a.code,
            'subjects', coalesce((
              select jsonb_agg(jsonb_build_object(
                  'name', coalesce(sub.name_en, s2.subject_code), 'name_hi', sub.name_hi, 'max', s2.max_marks,
                  'code', s2.subject_code,
                  'value', mk.value, 'absent', coalesce(mk.absent, false), 'exempt', coalesce(mk.exempt, false))
                order by s2.sort_order, sub.sort_order)
              from vppsone.assessment_subjects s2
              left join vppsone.subjects sub on sub.id = s2.subject_id
              left join vppsone.marks mk on mk.assessment_subject_id = s2.id and mk.student_id = k.id
              where s2.assessment_id = a.id and s2.class_id = k.class_id
            ), '[]'::jsonb),
            -- The term's report card as the school ISSUED it (D-613): its
            -- figures for the one-line summary, and the exams on it, so a
            -- card is sent only when every exam it carries is released.
            'card', (
              select jsonb_build_object(
                  'revision', r.revision,
                  'percent', r.card->'totals'->'percent',
                  'grade', r.card->'grade',
                  'status', r.card->'status',
                  'passed', r.card->'passed',
                  'rank', r.card->'rank',
                  'rank_of', r.card->'rankOf',
                  'strengths', coalesce(r.card->'insight'->'strengths', '[]'::jsonb),
                  'focus', coalesce(r.card->'insight'->'focus', '[]'::jsonb),
                  'trend', r.card->'insight'->'trend',
                  'growth', r.card->'insight'->'growth',
                  'codes', coalesce((
                    select jsonb_agg(distinct m.value->>'assessmentCode')
                    from jsonb_array_elements(
                      case when jsonb_typeof(r.card->'rows') = 'array' then r.card->'rows' else '[]'::jsonb end
                      || case when jsonb_typeof(r.card->'apart') = 'array' then r.card->'apart' else '[]'::jsonb end) w,
                      jsonb_array_elements(case when jsonb_typeof(w.value->'marks') = 'array' then w.value->'marks' else '[]'::jsonb end) m
                  ), '[]'::jsonb))
              from vppsone.report_card_issues r
              where r.student_id = k.id and r.session_label = k.session_label and r.term = a.term and r.status = 'issued'
              order by r.revision desc
              limit 1
            )) as e,
          a.starts_on as s
        from vppsone.assessments a
        join kid k on k.session_label = a.session_label
        join vppsone.exam_class_locks l on l.assessment_id = a.id and l.class_id = k.class_id
        join vppsone.exam_plans p on p.assessment_id = a.id
        where p.results_published_at is not null
           or (p.results_publish_at is not null and p.results_publish_at <= now())
        order by a.starts_on desc nulls last
        limit 3
      ) q
    ), '[]'::jsonb),
    -- Every exam whose results this child's class has had released (D-613).
    'released_codes', coalesce((
      select jsonb_agg(distinct a.code)
      from vppsone.assessments a
      join kid k on k.session_label = a.session_label
      join vppsone.exam_class_locks l on l.assessment_id = a.id and l.class_id = k.class_id
      join vppsone.exam_plans p on p.assessment_id = a.id
      where p.results_published_at is not null
         or (p.results_publish_at is not null and p.results_publish_at <= now())
    ), '[]'::jsonb),
    -- Exams the child sat whose results are not out for the class yet (D-613):
    -- only their names and the day the plan gives, never a mark.
    'pending_results', coalesce((
      select jsonb_agg(q.e order by q.s desc nulls last)
      from (
        select jsonb_build_object(
            'label', a.label_en, 'label_hi', a.label_hi, 'term', a.term,
            'results_on', p.results_on, 'publish_at', p.results_publish_at) as e,
          a.starts_on as s
        from vppsone.assessments a
        join kid k on k.session_label = a.session_label
        left join vppsone.exam_plans p on p.assessment_id = a.id
        where a.status::text <> 'draft'
          and exists (
            select 1
            from vppsone.assessment_subjects s2
            join vppsone.marks mk on mk.assessment_subject_id = s2.id and mk.student_id = k.id
            where s2.assessment_id = a.id and s2.class_id = k.class_id)
          and not (
            exists (select 1 from vppsone.exam_class_locks l where l.assessment_id = a.id and l.class_id = k.class_id)
            and coalesce(p.results_published_at is not null or (p.results_publish_at is not null and p.results_publish_at <= now()), false))
        order by a.starts_on desc nulls last
        limit 2
      ) q
    ), '[]'::jsonb),
    'class_teacher', (
      select jsonb_build_object('staff_id', sp.id, 'name', sp.display_name, 'is_test', coalesce(sp.is_test_account, false))
      from vppsone.class_teachers ct
      join vppsone.staff_profiles sp on sp.id = ct.staff_profile_id
      join kid k on ct.class_id = k.class_id and ct.session_label = k.session_label
      where ct.role = 'class_teacher' and sp.is_active
        and (ct.effective_from is null or ct.effective_from <= (select d from today))
        and (ct.effective_to is null or ct.effective_to >= (select d from today))
      order by ct.effective_from desc nulls last
      limit 1
    ),
    -- The next 30 days of the child's own session calendar.
    'calendar', coalesce((
      select jsonb_agg(jsonb_build_object(
          'date', e.starts_on, 'until', e.ends_on, 'title', e.title, 'title_hi', e.title_hi, 'kind', e.kind)
        order by e.starts_on)
      from vppsone.calendar_events e
      join kid k on e.session_label = k.session_label
      where e.cancelled_at is null
        and coalesce(e.ends_on, e.starts_on) >= (select d from today)
        and e.starts_on <= (select d from today) + 30
        and (e.class_ids is null or cardinality(e.class_ids) = 0 or k.class_id = any(e.class_ids))
    ), '[]'::jsonb)
  ) end;
$$;

comment on function vppsone.parent_helper_child(uuid) is
  'Veer Patta AI (D-574): one TEST child''s facts in one read. Results only when released and the class locked; the issued report card per term and the exams still to come (D-613).';

-- ======================================================== migrations/20261114082332_parent_report_card_notice.sql
-- "Results are out": the school's approved message to a parent once a
-- child's report card is issued and the exam released, with one quick reply,
-- Get report card (D-614; the owner, 14 Nov 2026: "Yes get it for approval").
--
-- It names the child, the class and the exam. The quick reply carries the
-- child's own id back when tapped (`vpai:report_card:<child>`), and Veer
-- Patta AI answers the tap as a result ask for that child: the issued card
-- as its PDF, only if every exam on it is released (D-613). The tap opens
-- the 24 hours, so the card itself needs no template.
--
-- What this adds: two registry rows, `not_submitted`, Hindi and English,
-- under `report_delivery` (Settings -> WhatsApp, "Report cards"). The hourly
-- template check sends each to Meta once by itself (the hub's
-- `POST /v1/templates`, the quick reply included); nothing is sent to anyone.
--
-- Nothing here sends to a parent: every message still passes
-- `checkWhatsAppSend` (the feature switch, real recipients, which are off and
-- leave only the owner's number, and practice mode).
--
-- Rollback: take out the two rows by key ('vpps_parent_report_card_hi_v1',
-- 'vpps_parent_report_card_en_v1') while they still read `not_submitted`.
-- Once Meta has them, leave them: a row Meta knows is how One reads its status.

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

insert into vppsone.whatsapp_templates (key, provider_name, language_code, feature, body_params, param_names, header, url_button, label_en, label_hi) values
  ('vpps_parent_report_card_hi_v1', 'vpps_parent_report_card_hi_v1', 'hi', 'report_delivery', 3, array['student', 'class', 'exam']::text[], 'none', false, 'Results are out, with Get report card (hi)', 'परीक्षा परिणाम, रिपोर्ट कार्ड भेजें बटन के साथ'),
  ('vpps_parent_report_card_en_v1', 'vpps_parent_report_card_en_v1', 'en', 'report_delivery', 3, array['student', 'class', 'exam']::text[], 'none', false, 'Results are out, with Get report card (en)', 'परीक्षा परिणाम, रिपोर्ट कार्ड भेजें बटन के साथ')
on conflict (key) do nothing;

commit;

-- ======================================================== migrations/20261115034215_parent_chats.sql
-- Chats with parents in One (D-616; the owner, 15 Nov 2026: "build an in-app
-- chat ... organised, with the idea of whom parents are talking and whose
-- parents are talking", "the WhatsApp message just shares the link of the
-- chat, so on one tap the chat section is open").
--
-- Until now a parent's question that Veer Patta AI could not answer reached a
-- teacher as a WhatsApp message on the teacher's own phone, and the teacher
-- answered by swiping on it (D-578). With several parents at once nobody could
-- tell which answer was going to whom. Now each family has one chat per desk
-- in One, and the conversation happens there:
--
--  * the class desk: the child's class teacher (one chat per class teacher);
--  * the accounts desk: fees, read by the accountants;
--  * the admin desk: the principal, complaints, "I want to talk to the admin".
--
-- An admin sees every chat, filtered by teacher, accounts, dues or student,
-- and may take one over. The parent keeps using WhatsApp: a staff reply goes
-- from the school's number through the hub, a photo or file too.
--
-- What this adds, all in `vppsone`, service role only (the app checks the
-- reader's permission and desk before every read and write):
--
--  * `parent_chats`: one row per family per desk (parent's number, desk,
--    class teacher for the class desk, practice or real). Its status says
--    whether the parent is waiting for the school, and `next_nudge_at` when
--    the person it is for gets a WhatsApp nudge with a one-tap link.
--  * `parent_chat_messages`: what was said, both ways, with WhatsApp's ticks.
--    A parent's photo or file is shown from the hub (`media.media_id`); a
--    staff member's from the private bucket below (`media.path`).
--  * `parent_chat_reads`: when each person last read each chat (unread dots,
--    and a nudge is not sent to someone who has already seen it).
--  * `parent_chat_nudges`: each WhatsApp nudge sent to a member of staff.
--  * `go_links`: short codes for one-tap links into One (`/go/<code>`), any
--    page of One, never a sign-in: the person still signs in as themselves.
--  * `parent_chat_settings`: one row; chats on or off, nudges on or off, how
--    long a chat stays "live" after a staff reply (30 minutes).
--  * Functions: open a chat, add a message (and move the chat's state),
--    record a WhatsApp tick, take the chats whose nudge is due, count unread,
--    and open a go link.
--  * Storage bucket `parent-chat-files`, private: what staff send. Uploaded
--    straight from the phone with a signed upload link and fetched by Meta
--    once, through a link signed for an hour.
--  * `chats:reply` for every role that can be a class teacher or works the
--    fee desk, and `chats:all` for the admin (Staff -> Roles can change both).
--  * Four registry rows, `not_submitted`: the staff nudge with an "Open in
--    One" button, and the parent's "the school has sent you a message" note,
--    Hindi and English. The hourly template check sends them to Meta once.
--  * pg_cron job `parent-chats`, every two minutes and only when a nudge is
--    due, calling /api/jobs/parent-chats with the WhatsApp queue's secret.
--
-- Parents' words are kept here, which D-576 kept out of One: a chat is only
-- useful if the next person can read what was said. A parent's message still
-- never changes a child's or the school's record (the owner, 12 Nov 2026):
-- anything it asks for stays a suggestion a person approves. Nothing here
-- sends to anyone: every message still passes `checkWhatsAppSend` (real
-- recipients are off, which leaves only the owner's number).
--
-- Rollback, in this order: unschedule the cron job 'parent-chats'; take the
-- four template rows out while they read `not_submitted`; take the
-- `chats:*` rows out of `role_permissions`; remove the bucket's policy and
-- the bucket once it is empty; then the six functions and the six tables
-- above (messages, reads and nudges before chats).

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

create table vppsone.parent_chats (
  id uuid primary key default gen_random_uuid(),
  parent_e164 text not null check (parent_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  desk text not null check (desk in ('class', 'accounts', 'admin')),
  class_teacher_id uuid references vppsone.staff_profiles(id) on delete set null,
  practice boolean not null default false,
  session_label text not null check (char_length(session_label) between 4 and 40),
  from_name text not null default 'Parent' check (char_length(from_name) between 1 and 120),
  student_ids uuid[] not null default '{}'::uuid[] check (cardinality(student_ids) <= 8),
  student_label text check (student_label is null or char_length(student_label) <= 200),
  language text not null default 'hi' check (language in ('hi', 'hx', 'en')),
  status text not null default 'open' check (status in ('waiting', 'open', 'done')),
  waiting_since timestamptz,
  topic text check (topic is null or topic ~ '^[a-z_]{2,30}$'),
  complaint boolean not null default false,
  wants_admin boolean not null default false,
  taken_by uuid references vppsone.staff_profiles(id) on delete set null,
  taken_at timestamptz,
  live_until timestamptz,
  last_parent_at timestamptz,
  last_staff_at timestamptz,
  last_message_at timestamptz not null default now(),
  last_preview text check (last_preview is null or char_length(last_preview) <= 160),
  last_direction text check (last_direction is null or last_direction in ('in', 'out', 'ai', 'note')),
  nudge_step text check (nudge_step is null or nudge_step in ('first', 'remind', 'pass_up')),
  next_nudge_at timestamptz,
  nudged_at timestamptz,
  reminded_at timestamptz,
  passed_up_at timestamptz,
  done_at timestamptz,
  done_by uuid references vppsone.staff_profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint parent_chats_class_teacher_on_class_desk check (desk = 'class' or class_teacher_id is null),
  constraint parent_chats_waiting_together check ((status = 'waiting') = (waiting_since is not null)),
  constraint parent_chats_nudge_together check ((nudge_step is null) = (next_nudge_at is null))
);

comment on table vppsone.parent_chats is
  'Chats with parents (D-616): one per family per desk (class teacher, accounts, admin), practice or real. Service role only; the app checks the reader''s desk.';

create unique index parent_chats_one_per_desk
  on vppsone.parent_chats (parent_e164, desk, class_teacher_id, practice) nulls not distinct;
create index parent_chats_recent on vppsone.parent_chats (practice, last_message_at desc);
create index parent_chats_waiting on vppsone.parent_chats (waiting_since) where status = 'waiting';
create index parent_chats_class_teacher on vppsone.parent_chats (class_teacher_id) where desk = 'class';
create index parent_chats_nudge_due on vppsone.parent_chats (next_nudge_at) where next_nudge_at is not null;

create table vppsone.parent_chat_messages (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references vppsone.parent_chats(id) on delete cascade,
  direction text not null check (direction in ('in', 'out', 'ai', 'note')),
  kind text not null default 'text' check (kind in (
    'text', 'image', 'document', 'audio', 'video', 'sticker', 'location', 'contacts', 'tap', 'other', 'suggestion', 'event'
  )),
  body text check (body is null or char_length(body) <= 4096),
  media jsonb check (media is null or jsonb_typeof(media) = 'object'),
  meta jsonb check (meta is null or jsonb_typeof(meta) = 'object'),
  wamid text unique check (wamid is null or char_length(wamid) between 8 and 256),
  note_wamid text check (note_wamid is null or char_length(note_wamid) between 8 and 256),
  reply_to_wamid text check (reply_to_wamid is null or char_length(reply_to_wamid) between 8 and 256),
  client_ref uuid unique,
  staff_id uuid references vppsone.staff_profiles(id) on delete set null,
  staff_name text check (staff_name is null or char_length(staff_name) <= 80),
  status text not null default 'received' check (status in ('received', 'sending', 'sent', 'delivered', 'read', 'failed', 'waiting')),
  error text check (error is null or char_length(error) <= 200),
  handoff_id uuid references vppsone.parent_helper_handoffs(id) on delete set null,
  parent_reply_id uuid references vppsone.parent_replies(id) on delete set null,
  at timestamptz not null default now(),
  status_at timestamptz,
  created_at timestamptz not null default now()
);

comment on table vppsone.parent_chat_messages is
  'What was said in a chat with parents (D-616): in = the parent, out = the school, ai = Veer Patta AI, note = an event only staff see. Service role only.';

create index parent_chat_messages_by_chat on vppsone.parent_chat_messages (chat_id, at, id);
create index parent_chat_messages_waiting on vppsone.parent_chat_messages (chat_id) where status = 'waiting';
create index parent_chat_messages_note on vppsone.parent_chat_messages (note_wamid) where note_wamid is not null;
create index parent_chat_messages_handoff on vppsone.parent_chat_messages (handoff_id) where handoff_id is not null;

create table vppsone.parent_chat_reads (
  chat_id uuid not null references vppsone.parent_chats(id) on delete cascade,
  staff_id uuid not null references vppsone.staff_profiles(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (chat_id, staff_id)
);

create table vppsone.parent_chat_nudges (
  id uuid primary key default gen_random_uuid(),
  staff_id uuid references vppsone.staff_profiles(id) on delete set null,
  to_e164 text not null check (to_e164 ~ '^\+[1-9][0-9]{7,14}$'),
  kind text not null check (kind in ('first', 'remind', 'pass_up')),
  chat_ids uuid[] not null default '{}'::uuid[],
  waiting integer not null default 0 check (waiting >= 0),
  via text not null check (via in ('text', 'template', 'none')),
  status text not null check (status in ('sent', 'failed', 'skipped')),
  reason text check (reason is null or char_length(reason) <= 120),
  message_id text check (message_id is null or char_length(message_id) <= 256),
  practice boolean not null default false,
  created_at timestamptz not null default now()
);

create index parent_chat_nudges_to on vppsone.parent_chat_nudges (to_e164, created_at desc);
create index parent_chat_nudges_staff on vppsone.parent_chat_nudges (staff_id, created_at desc);

create table vppsone.go_links (
  code text primary key check (code ~ '^[A-Za-z0-9]{8,16}$'),
  path text not null check (path ~ '^/[^/]' and char_length(path) <= 300 and path !~ '[[:space:]]' and strpos(path, chr(92)) = 0),
  session_label text check (session_label is null or char_length(session_label) between 4 and 40),
  staff_id uuid references vppsone.staff_profiles(id) on delete set null,
  purpose text not null check (purpose ~ '^[a-z_]{2,40}$'),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  uses integer not null default 0 check (uses >= 0),
  last_used_at timestamptz,
  constraint go_links_expire_after_creation check (expires_at > created_at)
);

comment on table vppsone.go_links is
  'One-tap links into One (D-616): https://one.vpps.co.in/go/<code> opens `path` after the person signs in as themselves. Never a sign-in.';

create index go_links_staff on vppsone.go_links (staff_id, created_at desc);

create table vppsone.parent_chat_settings (
  id smallint primary key default 1 check (id = 1),
  enabled boolean not null default true,
  nudges boolean not null default true,
  live_minutes integer not null default 30 check (live_minutes between 5 and 240),
  first_nudge_minutes integer not null default 2 check (first_nudge_minutes between 0 and 60),
  updated_by uuid references vppsone.staff_profiles(id) on delete set null,
  updated_at timestamptz not null default now()
);

insert into vppsone.parent_chat_settings (id) values (1) on conflict (id) do nothing;

alter table vppsone.parent_chats enable row level security;
alter table vppsone.parent_chat_messages enable row level security;
alter table vppsone.parent_chat_reads enable row level security;
alter table vppsone.parent_chat_nudges enable row level security;
alter table vppsone.go_links enable row level security;
alter table vppsone.parent_chat_settings enable row level security;

revoke all on vppsone.parent_chats, vppsone.parent_chat_messages, vppsone.parent_chat_reads,
  vppsone.parent_chat_nudges, vppsone.go_links, vppsone.parent_chat_settings from anon, authenticated;
grant all on vppsone.parent_chats, vppsone.parent_chat_messages, vppsone.parent_chat_reads,
  vppsone.parent_chat_nudges, vppsone.go_links, vppsone.parent_chat_settings to service_role;

-- Find a family's chat at one desk, or start it. A second child, a better name
-- or the parent's language joins the existing chat rather than starting another.
create or replace function vppsone.parent_chat_open(
  p_parent text,
  p_desk text,
  p_class_teacher uuid,
  p_practice boolean,
  p_session text,
  p_from_name text,
  p_student_ids uuid[],
  p_student_label text,
  p_language text
)
returns uuid
language sql
volatile
set search_path = ''
as $$
  insert into vppsone.parent_chats as c (
    parent_e164, desk, class_teacher_id, practice, session_label, from_name, student_ids, student_label, language
  ) values (
    p_parent,
    p_desk,
    case when p_desk = 'class' then p_class_teacher end,
    coalesce(p_practice, false),
    p_session,
    coalesce(nullif(btrim(left(coalesce(p_from_name, ''), 120)), ''), 'Parent'),
    coalesce(p_student_ids[1:8], '{}'::uuid[]),
    nullif(btrim(left(coalesce(p_student_label, ''), 200)), ''),
    coalesce(p_language, 'hi')
  )
  on conflict (parent_e164, desk, class_teacher_id, practice) do update set
    from_name = case when excluded.from_name <> 'Parent' then excluded.from_name else c.from_name end,
    student_ids = (
      select coalesce(array_agg(s.id order by s.first_at), '{}'::uuid[])
        from (
          select u.id, min(u.n) as first_at
            from unnest(c.student_ids || excluded.student_ids) with ordinality as u(id, n)
           group by u.id
           order by min(u.n)
           limit 8
        ) s
    ),
    student_label = coalesce(excluded.student_label, c.student_label),
    language = excluded.language,
    session_label = excluded.session_label,
    updated_at = now()
  returning c.id;
$$;

comment on function vppsone.parent_chat_open(text, text, uuid, boolean, text, text, uuid[], text, text) is
  'Chats with parents (D-616): the family''s chat at one desk, started if it is new. Returns its id.';

-- Add one message and move the chat along with it. The parent writing makes the
-- chat wait for the school (and plans the first nudge); a staff reply ends the
-- wait and keeps the chat live for a while, so the parent''s next words come
-- here rather than to Veer Patta AI. A WhatsApp id or a client reference seen
-- before adds nothing: `duplicate` is true.
create or replace function vppsone.parent_chat_append(p jsonb)
returns jsonb
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_chat uuid := (p->>'chat_id')::uuid;
  v_direction text := p->>'direction';
  v_at timestamptz := coalesce((p->>'at')::timestamptz, now());
  v_body text := nullif(left(coalesce(p->>'body', ''), 4096), '');
  v_preview text;
  v_id uuid;
  v_live integer;
  v_first integer;
begin
  if v_chat is null or v_direction is null then
    raise exception 'parent_chat_append: chat_id and direction are required' using errcode = '22023';
  end if;

  insert into vppsone.parent_chat_messages (
    chat_id, direction, kind, body, media, meta, wamid, note_wamid, reply_to_wamid, client_ref,
    staff_id, staff_name, status, error, handoff_id, parent_reply_id, at, status_at
  ) values (
    v_chat,
    v_direction,
    coalesce(p->>'kind', 'text'),
    v_body,
    case when jsonb_typeof(p->'media') = 'object' then p->'media' end,
    case when jsonb_typeof(p->'meta') = 'object' then p->'meta' end,
    nullif(p->>'wamid', ''),
    nullif(p->>'note_wamid', ''),
    nullif(p->>'reply_to_wamid', ''),
    (p->>'client_ref')::uuid,
    (p->>'staff_id')::uuid,
    nullif(left(coalesce(p->>'staff_name', ''), 80), ''),
    coalesce(p->>'status', case when v_direction = 'in' then 'received' else 'sent' end),
    nullif(left(coalesce(p->>'error', ''), 200), ''),
    (p->>'handoff_id')::uuid,
    (p->>'parent_reply_id')::uuid,
    v_at,
    case when coalesce(p->>'status', '') in ('sent', 'delivered', 'read', 'failed') then v_at end
  )
  on conflict do nothing
  returning id into v_id;

  if v_id is null then
    return jsonb_build_object('id', null, 'duplicate', true);
  end if;

  v_preview := left(coalesce(nullif(p->>'preview', ''), v_body, ''), 160);

  if v_direction = 'in' then
    select s.first_nudge_minutes into v_first from vppsone.parent_chat_settings s where s.id = 1;
    update vppsone.parent_chats c set
      waiting_since = case when c.status = 'waiting' then c.waiting_since else v_at end,
      nudge_step = case when c.status = 'waiting' then c.nudge_step else 'first' end,
      next_nudge_at = case
        when c.status = 'waiting' then c.next_nudge_at
        else coalesce((p->>'nudge_at')::timestamptz, v_at + make_interval(mins => coalesce(v_first, 2)))
      end,
      nudged_at = case when c.status = 'waiting' then c.nudged_at end,
      reminded_at = case when c.status = 'waiting' then c.reminded_at end,
      passed_up_at = case when c.status = 'waiting' then c.passed_up_at end,
      status = 'waiting',
      done_at = null,
      done_by = null,
      last_parent_at = greatest(coalesce(c.last_parent_at, v_at), v_at),
      last_message_at = greatest(c.last_message_at, v_at),
      last_preview = v_preview,
      last_direction = 'in',
      updated_at = now()
    where c.id = v_chat;
  elsif v_direction = 'out' then
    select s.live_minutes into v_live from vppsone.parent_chat_settings s where s.id = 1;
    update vppsone.parent_chats c set
      status = 'open',
      waiting_since = null,
      nudge_step = null,
      next_nudge_at = null,
      done_at = null,
      done_by = null,
      last_staff_at = greatest(coalesce(c.last_staff_at, v_at), v_at),
      live_until = greatest(coalesce(c.live_until, v_at), v_at + make_interval(mins => coalesce(v_live, 30))),
      last_message_at = greatest(c.last_message_at, v_at),
      last_preview = v_preview,
      last_direction = 'out',
      updated_at = now()
    where c.id = v_chat;
  elsif v_direction = 'ai' then
    update vppsone.parent_chats c set
      last_message_at = greatest(c.last_message_at, v_at),
      last_preview = v_preview,
      last_direction = 'ai',
      updated_at = now()
    where c.id = v_chat;
  else
    update vppsone.parent_chats c set updated_at = now() where c.id = v_chat;
  end if;

  return jsonb_build_object('id', v_id, 'duplicate', false);
end;
$$;

comment on function vppsone.parent_chat_append(jsonb) is
  'Chats with parents (D-616): add one message and move its chat (waiting, live, last line). A WhatsApp id or client reference seen before adds nothing.';

-- WhatsApp's ticks on a staff message, forward only: sent, then delivered,
-- then read. A failure can only replace "sending" or "sent".
create or replace function vppsone.parent_chat_status(p_wamid text, p_status text, p_at timestamptz, p_error text)
returns boolean
language sql
volatile
set search_path = ''
as $$
  with ranked as (
    select m.id
      from vppsone.parent_chat_messages m
     where m.wamid = p_wamid
       and m.direction = 'out'
       and (
         (p_status = 'failed' and m.status in ('sending', 'sent'))
         or (p_status <> 'failed'
             and (case m.status when 'sending' then 0 when 'sent' then 1 when 'delivered' then 2 when 'read' then 3 else 9 end)
               < (case p_status when 'sent' then 1 when 'delivered' then 2 when 'read' then 3 else -1 end))
       )
  ), moved as (
    update vppsone.parent_chat_messages m
       set status = p_status,
           status_at = coalesce(p_at, now()),
           error = case when p_status = 'failed' then nullif(left(coalesce(p_error, ''), 200), '') else m.error end
      from ranked r
     where m.id = r.id
    returning m.id
  )
  select exists (select 1 from moved);
$$;

comment on function vppsone.parent_chat_status(text, text, timestamptz, text) is
  'Chats with parents (D-616): a WhatsApp tick on a school message, forward only. True when it moved.';

-- The chats whose nudge is due, each held for ten minutes so two runs never
-- nudge for it twice. The job sets the real next time once it has acted.
create or replace function vppsone.parent_chat_take_due(p_limit integer)
returns setof uuid
language sql
volatile
set search_path = ''
as $$
  update vppsone.parent_chats c
     set next_nudge_at = now() + interval '10 minutes',
         updated_at = now()
   where c.id in (
     select d.id
       from vppsone.parent_chats d
      where d.next_nudge_at is not null
        and d.next_nudge_at <= now()
        and d.status = 'waiting'
      order by d.next_nudge_at
      limit greatest(1, least(coalesce(p_limit, 40), 100))
      for update skip locked
   )
  returning c.id;
$$;

comment on function vppsone.parent_chat_take_due(integer) is
  'Chats with parents (D-616): the waiting chats whose WhatsApp nudge is due, each pushed ten minutes on so another run leaves it alone.';

-- How many of the parent's messages each chat has that this person has not read.
create or replace function vppsone.parent_chat_unread(p_staff uuid, p_chats uuid[])
returns table (chat_id uuid, unread integer)
language sql
stable
set search_path = ''
as $$
  select c.id,
         (select count(*)::integer
            from vppsone.parent_chat_messages m
           where m.chat_id = c.id
             and m.direction = 'in'
             and m.created_at > coalesce(r.read_at, '-infinity'::timestamptz))
    from unnest(coalesce(p_chats, '{}'::uuid[])) as c(id)
    left join vppsone.parent_chat_reads r on r.chat_id = c.id and r.staff_id = p_staff;
$$;

comment on function vppsone.parent_chat_unread(uuid, uuid[]) is
  'Chats with parents (D-616): the parent''s messages each chat has that this person has not read yet.';

-- Open a one-tap link: where it goes, counted. An expired code opens nothing.
create or replace function vppsone.go_link_open(p_code text)
returns table (path text, session_label text, staff_id uuid, purpose text)
language sql
volatile
set search_path = ''
as $$
  update vppsone.go_links g
     set uses = g.uses + 1,
         last_used_at = now()
   where g.code = p_code
     and g.expires_at > now()
  returning g.path, g.session_label, g.staff_id, g.purpose;
$$;

comment on function vppsone.go_link_open(text) is
  'One-tap links (D-616): where an unexpired code goes, with its use counted.';

revoke all on function vppsone.parent_chat_open(text, text, uuid, boolean, text, text, uuid[], text, text) from public, anon, authenticated;
revoke all on function vppsone.parent_chat_append(jsonb) from public, anon, authenticated;
revoke all on function vppsone.parent_chat_status(text, text, timestamptz, text) from public, anon, authenticated;
revoke all on function vppsone.parent_chat_take_due(integer) from public, anon, authenticated;
revoke all on function vppsone.parent_chat_unread(uuid, uuid[]) from public, anon, authenticated;
revoke all on function vppsone.go_link_open(text) from public, anon, authenticated;
grant execute on function vppsone.parent_chat_open(text, text, uuid, boolean, text, text, uuid[], text, text) to service_role;
grant execute on function vppsone.parent_chat_append(jsonb) to service_role;
grant execute on function vppsone.parent_chat_status(text, text, timestamptz, text) to service_role;
grant execute on function vppsone.parent_chat_take_due(integer) to service_role;
grant execute on function vppsone.parent_chat_unread(uuid, uuid[]) to service_role;
grant execute on function vppsone.go_link_open(text) to service_role;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'parent-chat-files', 'parent-chat-files', false, 16777216,
  array[
    'image/jpeg', 'image/png', 'application/pdf',
    'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.ms-excel', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  ]
)
on conflict (id) do nothing;

-- Restrictive so an unrelated, broad permissive storage policy cannot expose
-- this bucket. The service role bypasses RLS, including for signed uploads.
create policy parent_chat_files_server_only on storage.objects as restrictive
for all to anon, authenticated
using (bucket_id <> 'parent-chat-files') with check (bucket_id <> 'parent-chat-files');

insert into vppsone.role_permissions (role, permission) values
  ('admin', 'chats:reply'),
  ('admin', 'chats:all'),
  ('office', 'chats:reply'),
  ('accountant', 'chats:reply'),
  ('fee_collector', 'chats:reply'),
  ('academic_coordinator', 'chats:reply'),
  ('exam_coordinator', 'chats:reply'),
  ('teacher', 'chats:reply')
on conflict (role, permission) do nothing;

insert into vppsone.whatsapp_templates (key, provider_name, language_code, feature, body_params, param_names, header, url_button, label_en, label_hi) values
  ('vpps_staff_open_one_hi_v1', 'vpps_staff_open_one_hi_v1', 'hi', 'parent_helper', 2, array['name', 'waiting']::text[], 'none', true, 'Waiting for you in One, with an Open in One button (hi)', 'One में आपके लिए, One में खोलें बटन के साथ'),
  ('vpps_staff_open_one_en_v1', 'vpps_staff_open_one_en_v1', 'en', 'parent_helper', 2, array['name', 'waiting']::text[], 'none', true, 'Waiting for you in One, with an Open in One button (en)', 'One में आपके लिए, One में खोलें बटन के साथ'),
  ('vpps_parent_school_message_hi_v1', 'vpps_parent_school_message_hi_v1', 'hi', 'parent_helper', 2, array['who', 'child']::text[], 'none', false, 'The school has sent you a message (hi)', 'विद्यालय ने आपको संदेश भेजा है'),
  ('vpps_parent_school_message_en_v1', 'vpps_parent_school_message_en_v1', 'en', 'parent_helper', 2, array['who', 'child']::text[], 'none', false, 'The school has sent you a message (en)', 'विद्यालय ने आपको संदेश भेजा है')
on conflict (key) do nothing;

select cron.schedule(
  'parent-chats',
  '*/2 * * * *',
  $job$
  select net.http_post(
    url := 'https://one.vpps.co.in/api/jobs/parent-chats',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'WHATSAPP_QUEUE_CRON_SECRET')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  )
  where exists (
    select 1 from vppsone.parent_chats c
     where c.next_nudge_at is not null and c.next_nudge_at <= now() and c.status = 'waiting'
  );
  $job$
);

commit;

-- ======================================================== migrations/20261115044716_parent_chats_pass.sql
-- Chats with parents, part two (D-617): passing a chat to the desk it belongs
-- to, and the class teachers a chat can go to.
--
-- Veer Patta AI puts each passed-on message at a desk by its topic, and a
-- topic can be wrong: a fee question in a class teacher's chat, a leave note
-- at the accounts desk. Whoever may answer a chat can pass it on, with a line
-- only staff read ("please check the receipt"). The chat then waits at its new
-- desk and that desk is told at once, as for any new message.
--
-- A family has one chat per desk, so a chat passed to a desk where the family
-- already has one joins it: every message moves across in time order, the
-- wait carries over, and the old chat closes with `merged_into` pointing at
-- the one it joined (a screen or a one-tap link to it opens the joined chat).
-- If that desk is wanted again later, the old row starts afresh.
--
-- What this adds, all in `vppsone`, service role only:
--
--  * `parent_chats.merged_into`: the chat this one joined, when it did.
--  * `parent_chat_open`: unchanged, except that it clears `merged_into` when
--    a message reopens a chat that had joined another.
--  * `parent_chat_class_teachers(chat)`: each child's class teacher today, of
--    the chat's own kind (test accounts for a practice chat, real staff for a
--    real one: the owner's rule, 8 Nov 2026), for the "Pass to" choices.
--    It reads the roster (`public.students`, `public.classes`); it writes
--    nothing there.
--  * `parent_chat_pass(...)`: the move, or the join, in one transaction.
--  * An index on `parent_chat_messages.parent_reply_id`, so Messages can find
--    the chat a parent's message went into.
--
-- Nothing here sends anything. Rollback: restore the previous body of
-- `parent_chat_open` (in 20261115034215), then remove the two new functions,
-- the index and the column.

begin;

set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table vppsone.parent_chats
  add column if not exists merged_into uuid references vppsone.parent_chats(id) on delete set null;

comment on column vppsone.parent_chats.merged_into is
  'Chats with parents (D-617): the chat this one joined when it was passed to a desk where the family already had one. Null otherwise.';

create index if not exists parent_chat_messages_reply
  on vppsone.parent_chat_messages (parent_reply_id) where parent_reply_id is not null;

-- As before (20261115034215), and a chat that had joined another starts afresh.
create or replace function vppsone.parent_chat_open(
  p_parent text,
  p_desk text,
  p_class_teacher uuid,
  p_practice boolean,
  p_session text,
  p_from_name text,
  p_student_ids uuid[],
  p_student_label text,
  p_language text
)
returns uuid
language sql
volatile
set search_path = ''
as $$
  insert into vppsone.parent_chats as c (
    parent_e164, desk, class_teacher_id, practice, session_label, from_name, student_ids, student_label, language
  ) values (
    p_parent,
    p_desk,
    case when p_desk = 'class' then p_class_teacher end,
    coalesce(p_practice, false),
    p_session,
    coalesce(nullif(btrim(left(coalesce(p_from_name, ''), 120)), ''), 'Parent'),
    coalesce(p_student_ids[1:8], '{}'::uuid[]),
    nullif(btrim(left(coalesce(p_student_label, ''), 200)), ''),
    coalesce(p_language, 'hi')
  )
  on conflict (parent_e164, desk, class_teacher_id, practice) do update set
    from_name = case when excluded.from_name <> 'Parent' then excluded.from_name else c.from_name end,
    student_ids = (
      select coalesce(array_agg(s.id order by s.first_at), '{}'::uuid[])
        from (
          select u.id, min(u.n) as first_at
            from unnest(c.student_ids || excluded.student_ids) with ordinality as u(id, n)
           group by u.id
           order by min(u.n)
           limit 8
        ) s
    ),
    student_label = coalesce(excluded.student_label, c.student_label),
    language = excluded.language,
    session_label = excluded.session_label,
    merged_into = null,
    updated_at = now()
  returning c.id;
$$;

-- Each child's class teacher today, of the chat's own kind, in the chat's order.
create or replace function vppsone.parent_chat_class_teachers(p_chat uuid)
returns table (student_id uuid, staff_id uuid, staff_name text)
language sql
stable
set search_path = ''
as $$
  select t.student_id, t.staff_id, t.staff_name
    from (
      select distinct on (s.id)
             s.id as student_id,
             sp.id as staff_id,
             sp.display_name as staff_name,
             u.n as n
        from vppsone.parent_chats pc
        cross join lateral unnest(pc.student_ids) with ordinality as u(id, n)
        join public.students s on s.id = u.id
        join public.classes cl on cl.id = s.class_id
        join vppsone.class_teachers ct
          on ct.class_id = cl.id
         and ct.session_label = cl.session_label
         and ct.role = 'class_teacher'
        join vppsone.staff_profiles sp on sp.id = ct.staff_profile_id and sp.is_active
       where pc.id = p_chat
         and (ct.effective_from is null or ct.effective_from <= vppsone.school_today())
         and (ct.effective_to is null or ct.effective_to >= vppsone.school_today())
         and coalesce(sp.is_test_account, false) = pc.practice
       order by s.id, ct.effective_from desc nulls last
    ) t
   order by t.n;
$$;

comment on function vppsone.parent_chat_class_teachers(uuid) is
  'Chats with parents (D-617): each child''s class teacher today, test accounts for a practice chat and real staff for a real one.';

-- Pass a chat to another desk: move it, or join the family's chat already
-- there. Returns the chat it now lives in; null when there is no such chat or
-- it had already joined another. A line only staff read says who passed it.
create or replace function vppsone.parent_chat_pass(
  p_chat uuid,
  p_desk text,
  p_class_teacher uuid,
  p_wants_admin boolean,
  p_by uuid,
  p_by_name text,
  p_note text
)
returns uuid
language plpgsql
volatile
set search_path = ''
as $$
declare
  v_src vppsone.parent_chats%rowtype;
  v_dst vppsone.parent_chats%rowtype;
  v_teacher uuid := case when p_desk = 'class' then p_class_teacher end;
  v_wants boolean := p_desk = 'admin' and coalesce(p_wants_admin, false);
  v_now timestamptz := clock_timestamp();
  v_status text;
  v_into uuid;
begin
  if p_desk is null or p_desk not in ('class', 'accounts', 'admin') then
    raise exception 'parent_chat_pass: unknown desk' using errcode = '22023';
  end if;
  if p_desk = 'class' and v_teacher is null then
    raise exception 'parent_chat_pass: the class desk needs its teacher' using errcode = '22023';
  end if;

  select * into v_src from vppsone.parent_chats where id = p_chat for update;
  if not found or v_src.merged_into is not null then
    return null;
  end if;

  -- Already at that desk: only a wish for the principal can be added.
  if v_src.desk = p_desk and v_src.class_teacher_id is not distinct from v_teacher then
    if v_wants and not v_src.wants_admin then
      update vppsone.parent_chats c set wants_admin = true, updated_at = now() where c.id = v_src.id;
    end if;
    return v_src.id;
  end if;

  select * into v_dst
    from vppsone.parent_chats d
   where d.parent_e164 = v_src.parent_e164
     and d.desk = p_desk
     and d.class_teacher_id is not distinct from v_teacher
     and d.practice = v_src.practice
     and d.id <> v_src.id
   for update;

  if not found then
    -- The chat moves. A waiting chat is the new desk's to answer, now.
    update vppsone.parent_chats c set
      desk = p_desk,
      class_teacher_id = v_teacher,
      wants_admin = v_wants or (p_desk = 'admin' and c.wants_admin),
      taken_by = null,
      taken_at = null,
      passed_up_at = null,
      nudged_at = null,
      reminded_at = null,
      nudge_step = case when c.status = 'waiting' then 'first' end,
      next_nudge_at = case when c.status = 'waiting' then v_now end,
      updated_at = now()
    where c.id = v_src.id;
    v_into := v_src.id;
  else
    -- The family already has a chat at that desk: every message joins it.
    update vppsone.parent_chat_messages m set chat_id = v_dst.id where m.chat_id = v_src.id;

    v_status := case
      when v_src.status = 'waiting' or v_dst.status = 'waiting' then 'waiting'
      when v_src.status = 'done' and v_dst.status = 'done' then 'done'
      else 'open'
    end;

    update vppsone.parent_chats d set
      student_ids = (
        select coalesce(array_agg(s.id order by s.first_at), '{}'::uuid[])
          from (
            select u.id, min(u.n) as first_at
              from unnest(d.student_ids || v_src.student_ids) with ordinality as u(id, n)
             group by u.id
             order by min(u.n)
             limit 8
          ) s
      ),
      student_label = coalesce(d.student_label, v_src.student_label),
      topic = coalesce(v_src.topic, d.topic),
      complaint = d.complaint or v_src.complaint,
      wants_admin = p_desk = 'admin' and (d.wants_admin or v_src.wants_admin or v_wants),
      status = v_status,
      waiting_since = case when v_status = 'waiting' then least(
        case when d.status = 'waiting' then d.waiting_since end,
        case when v_src.status = 'waiting' then v_src.waiting_since end
      ) end,
      nudge_step = case when v_status = 'waiting' then 'first' end,
      next_nudge_at = case when v_status = 'waiting' then v_now end,
      nudged_at = null,
      reminded_at = null,
      passed_up_at = null,
      live_until = greatest(d.live_until, v_src.live_until),
      last_parent_at = greatest(d.last_parent_at, v_src.last_parent_at),
      last_staff_at = greatest(d.last_staff_at, v_src.last_staff_at),
      last_message_at = greatest(d.last_message_at, v_src.last_message_at),
      last_preview = case when v_src.last_message_at > d.last_message_at then v_src.last_preview else d.last_preview end,
      last_direction = case when v_src.last_message_at > d.last_message_at then v_src.last_direction else d.last_direction end,
      done_at = case when v_status = 'done' then d.done_at end,
      done_by = case when v_status = 'done' then d.done_by end,
      updated_at = now()
    where d.id = v_dst.id;

    update vppsone.parent_chats c set
      status = 'done',
      waiting_since = null,
      nudge_step = null,
      next_nudge_at = null,
      live_until = null,
      taken_by = null,
      taken_at = null,
      done_at = now(),
      done_by = p_by,
      merged_into = v_dst.id,
      updated_at = now()
    where c.id = v_src.id;
    v_into := v_dst.id;
  end if;

  insert into vppsone.parent_chat_messages (chat_id, direction, kind, body, meta, staff_id, staff_name, status, at)
  values (
    v_into,
    'note',
    'event',
    nullif(btrim(left(coalesce(p_note, ''), 500)), ''),
    jsonb_build_object(
      'event', 'passed',
      'from', v_src.desk,
      'to', p_desk,
      'from_teacher', v_src.class_teacher_id,
      'to_teacher', v_teacher,
      'joined', v_into <> v_src.id
    ),
    p_by,
    nullif(left(coalesce(p_by_name, ''), 80), ''),
    'received',
    v_now
  );

  return v_into;
end;
$$;

comment on function vppsone.parent_chat_pass(uuid, text, uuid, boolean, uuid, text, text) is
  'Chats with parents (D-617): pass a chat to another desk, moving it or joining the family''s chat there. Returns where it now lives.';

revoke all on function vppsone.parent_chat_class_teachers(uuid) from public, anon, authenticated;
revoke all on function vppsone.parent_chat_pass(uuid, text, uuid, boolean, uuid, text, text) from public, anon, authenticated;
grant execute on function vppsone.parent_chat_class_teachers(uuid) to service_role;
grant execute on function vppsone.parent_chat_pass(uuid, text, uuid, boolean, uuid, text, text) to service_role;

commit;

-- ======================================================== migrations/20261115060835_needs_you.sql
/*
 * Needs you, for everyone (D-630..D-635).
 *
 * The owner (15 Nov 2026) asked for a Needs you that teachers, accountants,
 * the exam office and the admin all have: what is waiting, what is done, in
 * an order the AI helps arrange, with reminders. The jobs themselves are NOT
 * stored here. Each list is built, every time it is opened, from the records
 * the person's Today screen already reads (registers, covers, marks, tasks,
 * notices, the counter, the books), so a job is never "done" here while its
 * own screen says otherwise. This keeps only what those records do not know:
 *
 *   1. `needs_reminders`  a person's own to-do ("kal subah 9 baje ... phone
 *                         karna") and "remind me later" on a job of theirs.
 *   2. `needs_seen`       the jobs a person's list held each day, so a job
 *                         that has left the list can show under "Done today",
 *                         and the menu can count what is waiting without
 *                         building the whole list again.
 *   3. `needs_plans`      the order the AI suggested for a day's list, kept
 *                         so the AI is asked once per change, not per visit.
 *   4. `needs_sync(...)`  one call that records a fresh list and returns
 *                         what has left it today.
 *
 * Nothing here changes a register, a mark, a fee or a message: a job is done
 * on its own screen, and this only notices that it has gone. The AI is shown
 * kinds and numbers, never a name or a title (D-633). Service role only, like
 * every One write; the app checks the person first. Additive: three new
 * tables and one function, and no fee table is touched.
 */

begin;

/* -------------------------------------------- own to-dos and reminders */

create table vppsone.needs_reminders (
  id uuid primary key default gen_random_uuid(),
  staff_profile_id uuid not null references vppsone.staff_profiles (id),
  session_label text not null,

  -- 'own': the person's own to-do, in their own words.
  -- 'snooze': "remind me later" on a job from their list, named by its key.
  kind text not null,
  item_key text,
  title text,
  -- The words the time was read from ("kal subah 9 baje"), said back to them.
  heard text,
  remind_at timestamptz,

  done_at timestamptz,
  cancelled_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint needs_reminders_kind_known check (kind in ('own', 'snooze')),
  constraint needs_reminders_session_sane check (char_length(session_label) between 4 and 40),
  constraint needs_reminders_own_has_title check (kind <> 'own' or char_length(btrim(coalesce(title, ''))) between 1 and 200),
  constraint needs_reminders_snooze_has_job check (kind <> 'snooze' or (item_key is not null and remind_at is not null)),
  constraint needs_reminders_key_sane check (item_key is null or char_length(item_key) between 1 and 160),
  constraint needs_reminders_heard_sane check (heard is null or char_length(heard) <= 200)
);

comment on table vppsone.needs_reminders is
  'Needs you (D-632): a person''s own to-do, or "remind me later" on a job of theirs. The job itself lives on its own screen; this only holds the person''s words and the time to bring it back.';

create index needs_reminders_open_idx
  on vppsone.needs_reminders (staff_profile_id, session_label, remind_at)
  where done_at is null and cancelled_at is null;

create trigger needs_reminders_set_updated_at
  before update on vppsone.needs_reminders
  for each row execute function vppsone.set_updated_at();

alter table vppsone.needs_reminders enable row level security;
revoke all on vppsone.needs_reminders from public, anon, authenticated;
grant all on vppsone.needs_reminders to service_role;

/* ------------------------------------------ what each day's list held */

create table vppsone.needs_seen (
  staff_profile_id uuid not null references vppsone.staff_profiles (id),
  session_label text not null,
  day date not null,
  item_key text not null,
  kind text not null,
  lane text not null,
  -- The job's name as the list said it, {"en": ..., "hi": ...}, for Done today.
  title jsonb not null,
  -- A job put off with "remind me later": when it comes back, so the menu's
  -- count includes it from then.
  wake_at timestamptz,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  -- Set when a complete read of the person's list no longer holds the job.
  done_at timestamptz,

  constraint needs_seen_pkey primary key (staff_profile_id, session_label, day, item_key),
  constraint needs_seen_session_sane check (char_length(session_label) between 4 and 40),
  constraint needs_seen_key_sane check (char_length(item_key) between 1 and 160),
  constraint needs_seen_kind_sane check (char_length(kind) between 1 and 40),
  constraint needs_seen_lane_known check (lane in ('now', 'today', 'later', 'waiting')),
  constraint needs_seen_title_object check (jsonb_typeof(title) = 'object')
);

comment on table vppsone.needs_seen is
  'Needs you (D-631): the jobs a person''s list held on a day. A job that a complete read no longer finds is marked done; it is never a record that the work itself was done, which only its own screen knows.';

alter table vppsone.needs_seen enable row level security;
revoke all on vppsone.needs_seen from public, anon, authenticated;
grant all on vppsone.needs_seen to service_role;

/* ------------------------------------------- the AI's order for a day */

create table vppsone.needs_plans (
  id uuid primary key default gen_random_uuid(),
  staff_profile_id uuid not null references vppsone.staff_profiles (id),
  session_label text not null,
  day date not null,
  -- The jobs the order was made for (`needSignature`), so a changed list asks again.
  signature text not null,
  -- The jobs' keys, first to last. Empty when the AI gave no usable answer.
  item_order jsonb not null,
  -- key -> one word from NEED_REASONS ("late", "starts_soon", ...).
  reasons jsonb not null default '{}'::jsonb,
  -- 'ai': the AI's order. 'none': it was asked and gave nothing usable, kept
  -- so a failing AI is not asked again on every visit.
  source text not null,
  created_at timestamptz not null default now(),

  constraint needs_plans_session_sane check (char_length(session_label) between 4 and 40),
  constraint needs_plans_signature_sane check (char_length(signature) between 1 and 200),
  constraint needs_plans_order_array check (case when jsonb_typeof(item_order) = 'array' then jsonb_array_length(item_order) <= 60 else false end),
  constraint needs_plans_reasons_object check (jsonb_typeof(reasons) = 'object'),
  constraint needs_plans_source_known check (source in ('ai', 'none'))
);

comment on table vppsone.needs_plans is
  'Needs you (D-633): the order the AI suggested for a person''s list on a day, with a one-word reason per job. It was shown only job kinds and numbers. A suggestion: the app keeps a job that starts within 15 minutes first whatever it says.';

create index needs_plans_latest_idx
  on vppsone.needs_plans (staff_profile_id, session_label, day, created_at desc);

alter table vppsone.needs_plans enable row level security;
revoke all on vppsone.needs_plans from public, anon, authenticated;
grant all on vppsone.needs_plans to service_role;

/* --------------------------------------------------- one list, recorded */

/*
 * Record the jobs a person's list holds now, and return what has left it
 * today. `p_open` is the list: [{key, kind, lane, title: {en, hi}, wake_at}].
 * Only a COMPLETE read (`p_complete`, every source answered) may mark a job
 * done: a list missing a source because its read failed would otherwise
 * tick off every job in it.
 */
create function vppsone.needs_sync(
  p_staff uuid,
  p_session text,
  p_day date,
  p_open jsonb,
  p_complete boolean
)
returns table (seen_key text, seen_kind text, seen_lane text, seen_title jsonb, seen_done_at timestamptz)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_staff is null or p_session is null or p_day is null then
    raise exception 'needs_sync: a person, a session and a day are required' using errcode = '22023';
  end if;
  if p_open is null or jsonb_typeof(p_open) <> 'array' then
    raise exception 'needs_sync: the list must be an array' using errcode = '22023';
  end if;
  if jsonb_array_length(p_open) > 200 then
    raise exception 'needs_sync: a list holds at most 200 jobs' using errcode = '22023';
  end if;

  insert into vppsone.needs_seen as s (staff_profile_id, session_label, day, item_key, kind, lane, title, wake_at)
  select distinct on (e.value ->> 'key')
         p_staff, p_session, p_day,
         e.value ->> 'key', e.value ->> 'kind', e.value ->> 'lane', e.value -> 'title',
         nullif(e.value ->> 'wake_at', '')::timestamptz
    from jsonb_array_elements(p_open) as e
   where jsonb_typeof(e.value) = 'object'
     and char_length(coalesce(e.value ->> 'key', '')) between 1 and 160
     and char_length(coalesce(e.value ->> 'kind', '')) between 1 and 40
     and coalesce(e.value ->> 'lane', '') in ('now', 'today', 'later', 'waiting')
     and jsonb_typeof(e.value -> 'title') = 'object'
   order by e.value ->> 'key'
  on conflict on constraint needs_seen_pkey do update
     set kind = excluded.kind,
         lane = excluded.lane,
         title = excluded.title,
         wake_at = excluded.wake_at,
         last_seen_at = now(),
         done_at = null;

  if p_complete then
    update vppsone.needs_seen as s
       set done_at = now()
     where s.staff_profile_id = p_staff
       and s.session_label = p_session
       and s.day = p_day
       and s.done_at is null
       and not exists (
             select 1
               from jsonb_array_elements(p_open) as e
              where jsonb_typeof(e.value) = 'object'
                and e.value ->> 'key' = s.item_key
           );
  end if;

  return query
    select s.item_key, s.kind, s.lane, s.title, s.done_at
      from vppsone.needs_seen as s
     where s.staff_profile_id = p_staff
       and s.session_label = p_session
       and s.day = p_day
       and s.done_at is not null
     order by s.done_at desc, s.item_key
     limit 50;
end;
$$;

comment on function vppsone.needs_sync(uuid, text, date, jsonb, boolean) is
  'Needs you (D-631): records the jobs a person''s list holds now and returns what has left it today. Marks a job done only on a complete read.';

revoke all on function vppsone.needs_sync(uuid, text, date, jsonb, boolean) from public, anon, authenticated;
grant execute on function vppsone.needs_sync(uuid, text, date, jsonb, boolean) to service_role;

commit;

-- ======================================================== migrations/20261115064931_parent_chats_role_permissions.sql
-- D-616: who answers parents in Chats, kept where every permission addition
-- is kept (`*_role_permissions.sql`). The promotion seed
-- (scripts/migrate/lib/quarantine-rules.mjs#rolePermissionSeed) and
-- tests/scoped-reads.test.ts read the role -> permission map from those files.
--
-- 20261115034215_parent_chats.sql already wrote these rows on One, so on One
-- this changes nothing (on conflict do nothing). Rows only; additive.
--
-- chats:reply  "Chat with parents": the class teacher answers their own
--              class's parents, the fee desk the accounts chats, the office
--              the office's.
-- chats:all    "See every chat": every desk, filtered, and taking a chat over.
-- The admin rows are what lets Staff -> Roles offer these to other roles.
insert into vppsone.role_permissions (role, permission) values
  ('admin', 'chats:reply'),
  ('admin', 'chats:all'),
  ('office', 'chats:reply'),
  ('accountant', 'chats:reply'),
  ('fee_collector', 'chats:reply'),
  ('academic_coordinator', 'chats:reply'),
  ('exam_coordinator', 'chats:reply'),
  ('teacher', 'chats:reply')
on conflict (role, permission) do nothing;

-- ======================================================== fee-migrations/20261116033500_fees_copy_structure_catchup.sql
-- ============================================================================
-- VPPS One fee-migration (One-only): catch One's fee tables up with the
-- columns and tables the fees app added between 31 Oct and 9 Nov 2026, so a
-- straight copy of the fees app's data fits (D-644, 16 Nov 2026).
--
-- Why this differs from the fees app: the fees app shipped these with its
-- household-communications work (households, split tenders, queued campaign
-- dispatch). That work also added ~140 functions, 175 triggers and fourteen
-- more household_* tables, which drive sending on the fees app's own number.
-- None of that is copied here. One needs only the SHAPE that holds the data,
-- so that the D-644 copy (vppsone.fees_copy_run) can bring every row across
-- unchanged:
--
--   * payment_mode 'split' (a receipt paid partly in cash, partly by UPI…),
--     and receipt_tenders, its lines;
--   * household_communication_preferences: the office's per-family contact
--     choices (cadence, no-contact, language, which numbers);
--   * whatsapp_run_households and the queued-dispatch columns on
--     whatsapp_campaign_runs;
--   * the household / quote columns on online_payment_intents/_orders,
--     whatsapp_reminder_sends and school_notice_sends, and the family-merge
--     columns on student_family_groups.
--
-- Left out on purpose:
--   * foreign keys to the fourteen household_* tables One does not have
--     (household_event_id, household_notice_claim_id,
--     household_recipient_claim_id stay plain uuid columns);
--   * the two deferred constraint triggers (receipt_tenders_balance,
--     receipts_split_has_tenders) and the fees app's audit / bridge triggers:
--     One posts no split receipt while fee writes are off, and copied rows
--     already passed them on the fees app;
--   * students_suggestion_*_idx: they index private.suggestion_phone(), which
--     belongs to the household suggestions feature One does not have.
--
-- Fees-app unique indexes that are LOOSER than One's older ones
-- (…_one_a_day_role, …_receipt_kind_role_idx, …_transactional_day_idx,
-- …_event_student_role) are created alongside One's here; retiring One's
-- older, stricter rules is a separate step.
--
-- Access: RLS on, as on the fees app. anon gets nothing; authenticated reads
-- receipt_tenders through the fees app's own policy and nothing else; writes
-- are for the owner and service_role only. receipt_tenders holds money, so it
-- carries the D-345 fee-writes guard like the other sixteen money tables.
--
-- Rollback: every object here is new or nullable/defaulted; nothing existing
-- changes meaning.
-- ============================================================================

alter type public.payment_mode add value if not exists 'split';

/* ------------------------------------------------- columns on old tables */

alter table public.online_payment_intents
  add column if not exists approved_student_ids uuid[],
  add column if not exists child_quote_snapshot jsonb,
  add column if not exists household_access_fingerprint text,
  add column if not exists household_key text;

alter table public.online_payment_orders
  add column if not exists approved_student_ids uuid[],
  add column if not exists child_quote_snapshot jsonb,
  add column if not exists household_access_fingerprint text,
  add column if not exists household_key text;

alter table public.school_notice_sends
  add column if not exists destination_role text not null default 'primary',
  add column if not exists household_key text,
  add column if not exists household_notice_claim_id uuid;

alter table public.school_notice_sends
  add constraint school_notice_sends_destination_role_check
  check (destination_role = any (array['primary', 'secondary']) or destination_role ~ '^contact:[0-9a-f]{64}$');

create unique index if not exists school_notice_sends_one_a_day_role
  on public.school_notice_sends (session_label, student_id, notice_kind, sent_on, destination_role);

alter table public.student_family_groups
  add column if not exists merged_into_family_group_id uuid,
  add column if not exists retired_at timestamptz;

alter table public.student_family_groups
  add constraint student_family_groups_merged_into_family_group_id_fkey
  foreign key (merged_into_family_group_id) references public.student_family_groups(id) on delete restrict;

alter table public.whatsapp_campaign_runs
  add column if not exists dispatch_job jsonb,
  add column if not exists dispatch_note text,
  add column if not exists dispatch_state text not null default 'finished',
  add column if not exists worker_heartbeat_at timestamptz,
  add column if not exists worker_id text,
  add column if not exists worker_lease_until timestamptz,
  add column if not exists worker_starts integer not null default 0;

alter table public.whatsapp_campaign_runs
  add constraint whatsapp_campaign_runs_dispatch_state_check
  check (dispatch_state = any (array['queued', 'sending', 'finished', 'stopped']));

create index if not exists whatsapp_campaign_runs_open_dispatch_idx
  on public.whatsapp_campaign_runs (worker_lease_until)
  where dispatch_state = any (array['queued', 'sending']);

alter table public.whatsapp_reminder_sends
  add column if not exists child_quote_snapshot jsonb,
  add column if not exists household_access_fingerprint text,
  add column if not exists household_event_id uuid,
  add column if not exists household_key text,
  add column if not exists household_notice_claim_id uuid,
  add column if not exists household_recipient_claim_id uuid;

create unique index if not exists whatsapp_reminder_sends_event_student_role
  on public.whatsapp_reminder_sends (household_event_id, student_id, destination_role)
  where household_event_id is not null;

create unique index if not exists whatsapp_reminder_sends_receipt_kind_role_idx
  on public.whatsapp_reminder_sends (receipt_id, notice_kind, destination_role)
  where receipt_id is not null;

create unique index if not exists whatsapp_reminder_sends_transactional_day_idx
  on public.whatsapp_reminder_sends (student_id, session_label, sent_on, campaign_name, destination_role, notice_kind)
  where receipt_id is null and notice_kind <> 'reminder';

/* ------------------------------------------------------------ new tables */

create table if not exists public.household_communication_preferences (
  id uuid not null default gen_random_uuid(),
  household_key text not null,
  session_label text not null,
  no_contact boolean not null default false,
  cadence text not null default 'every_run',
  snoozed_until date,
  profile text,
  language text,
  primary_destination text,
  secondary_destination text,
  secondary_mode text not null default 'off',
  transactional_notices_enabled boolean not null default true,
  needs_review boolean not null default true,
  review_reasons text[] not null default array['settings_not_initialized'],
  version bigint not null default 1,
  member_student_ids uuid[] not null,
  migration_evidence jsonb not null default '{}'::jsonb,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint household_communication_preferences_pkey primary key (id),
  constraint household_communication_prefere_household_key_session_label_key unique (household_key, session_label),
  constraint household_communication_preferences_cadence_check
    check (cadence = any (array['every_run', 'weekly', 'fortnightly', 'monthly', 'never'])),
  constraint household_communication_preferences_check
    check (secondary_destination is null or primary_destination is distinct from secondary_destination),
  constraint household_communication_preferences_check1
    check (secondary_mode <> 'copy' or secondary_destination is not null),
  constraint household_communication_preferences_check2
    check (needs_review or cardinality(review_reasons) = 0),
  constraint household_communication_preferences_household_key_check
    check (household_key ~ '^(family|student):[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
  constraint household_communication_preferences_language_check
    check (language = any (array['hi', 'en'])),
  constraint household_communication_preferences_member_student_ids_check
    check (cardinality(member_student_ids) > 0),
  constraint household_communication_preferences_primary_destination_check
    check (primary_destination ~ '^\+91[6-9][0-9]{9}$'),
  constraint household_communication_preferences_profile_check
    check (profile = any (array['on_time', 'standard', 'chronic', 'hardship', 'quiet'])),
  constraint household_communication_preferences_secondary_destination_check
    check (secondary_destination ~ '^\+91[6-9][0-9]{9}$'),
  constraint household_communication_preferences_secondary_mode_check
    check (secondary_mode = any (array['off', 'copy'])),
  constraint household_communication_preferences_session_label_check
    check (session_label ~ '^(TEST-|UAT-|DEMO-)?[0-9]{4}-[0-9]{2}$'),
  constraint household_communication_preferences_version_check
    check (version > 0),
  constraint household_communication_preferences_created_by_fkey
    foreign key (created_by) references auth.users(id) on delete set null,
  constraint household_communication_preferences_updated_by_fkey
    foreign key (updated_by) references auth.users(id) on delete set null
);

create table if not exists public.receipt_tenders (
  id uuid not null default gen_random_uuid(),
  receipt_id uuid not null,
  student_id uuid not null,
  line_no smallint not null,
  payment_mode public.payment_mode not null,
  amount integer not null,
  reference_number text,
  created_by uuid,
  created_at timestamptz not null default now(),
  constraint receipt_tenders_pkey primary key (id),
  constraint receipt_tenders_amount_check check (amount > 0),
  constraint receipt_tenders_line_no_check check (line_no >= 1 and line_no <= 4),
  constraint receipt_tenders_mode_check
    check (payment_mode::text = any (array['cash', 'upi', 'bank_transfer', 'cheque'])),
  constraint receipt_tenders_line_unique unique (receipt_id, line_no),
  constraint receipt_tenders_mode_unique unique (receipt_id, payment_mode),
  constraint receipt_tenders_receipt_fk
    foreign key (receipt_id, student_id) references public.receipts(id, student_id) on delete restrict,
  constraint receipt_tenders_created_by_fkey
    foreign key (created_by) references auth.users(id) on delete set null
);

create index if not exists idx_receipt_tenders_created_by on public.receipt_tenders (created_by);
create index if not exists idx_receipt_tenders_receipt_student on public.receipt_tenders (receipt_id, student_id);
create index if not exists idx_receipt_tenders_student on public.receipt_tenders (student_id);

create table if not exists public.whatsapp_run_households (
  run_id uuid not null,
  "position" integer not null,
  household_key text not null,
  item jsonb,
  state text not null default 'pending',
  attempts integer not null default 0,
  claimed_by text,
  claimed_at timestamptz,
  outcome jsonb,
  finished_at timestamptz,
  constraint whatsapp_run_households_pkey primary key (run_id, "position"),
  constraint whatsapp_run_households_run_id_household_key_key unique (run_id, household_key),
  constraint whatsapp_run_households_position_check check ("position" >= 0),
  constraint whatsapp_run_households_state_check
    check (state = any (array['pending', 'sending', 'done', 'stopped'])),
  constraint whatsapp_run_households_run_id_fkey
    foreign key (run_id) references public.whatsapp_campaign_runs(id) on delete cascade
);

/* ---------------------------------------------------------------- access */

alter table public.household_communication_preferences enable row level security;
alter table public.receipt_tenders enable row level security;
alter table public.whatsapp_run_households enable row level security;

revoke all on table public.household_communication_preferences from anon, authenticated;
revoke all on table public.receipt_tenders from anon, authenticated;
revoke all on table public.whatsapp_run_households from anon, authenticated;

grant select on table public.receipt_tenders to authenticated;
grant all on table public.household_communication_preferences to service_role;
grant all on table public.receipt_tenders to service_role;
grant all on table public.whatsapp_run_households to service_role;

create policy "authenticated can read receipt tenders"
  on public.receipt_tenders
  for select
  to authenticated
  using ((select public.has_any_permission(array['payments:view', 'ledger:view', 'receipts:view', 'dashboard:view', 'finance:view'])));

-- The D-345 switch and the test-account fence, as on the other money tables
-- (20261030230200 / 20261031000200).
create trigger fee_writes_row_guard
  before insert or update or delete on public.receipt_tenders
  for each row execute function vppsone.fee_money_row_guard();

create trigger fee_writes_truncate_guard
  before truncate on public.receipt_tenders
  for each statement execute function vppsone.fee_money_truncate_guard();
