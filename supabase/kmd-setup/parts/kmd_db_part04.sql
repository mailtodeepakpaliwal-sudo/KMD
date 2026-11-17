-- KMD One database setup — part 4 of 11. Run the parts in order, each once.
-- Files: 20261004051300_attendance_whole_roster_save.sql … 20261004123341_export_kinds_for_workbooks.sql

-- ======================================================== migrations/20261004051300_attendance_whole_roster_save.sql
-- P6: a register is saved whole, once, with a receipt — and changed only by a
-- correction that says why.
--
-- Before this a register could be submitted with some children marked and the
-- rest simply missing, which every reader then had to interpret; a lost
-- response was recovered by comparing marks in the action; and changing a
-- submitted register rewrote the mark in place behind an approval, leaving no
-- before-and-after. The plan's rule (§12) is the other way round:
--
--   - opening a roster records nothing; "present" is only a preview until a
--     person presses Save;
--   - a save names every child on the roll for that date, or it is refused —
--     a roll that changed underneath the page is shown, not guessed at;
--   - only the server's receipt makes a register recorded, and the receipt
--     says who, when, the totals and the revision;
--   - a correction is a new revision with a reason, by the class's current
--     teacher or by the office, and the old one is kept.
--
-- Everything here is in `vppsone`. Nothing reads or writes fee data.

-- ---------------------------------------------------------------------------
-- The school's rule for a half day
-- ---------------------------------------------------------------------------

create table vppsone.attendance_rules (
  session_label text primary key,
  /** How much of a day a half day counts as in a percentage: 0 to 1. */
  half_day_credit numeric(3, 2) not null default 0.50,
  revision integer not null default 1,
  updated_by uuid references vppsone.staff_profiles (id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint attendance_rules_half_day_credit_range
    check (half_day_credit >= 0 and half_day_credit <= 1)
);

comment on table vppsone.attendance_rules is
  'Per session, how attendance is counted. Absent a row, a half day counts as 0.5 — the default the school can change.';

alter table vppsone.attendance_rules enable row level security;
create policy attendance_rules_select_staff
  on vppsone.attendance_rules for select to authenticated
  using ((select vppsone.is_active_staff()));
grant select on vppsone.attendance_rules to authenticated;
grant all on vppsone.attendance_rules to service_role;

create or replace function vppsone.half_day_credit(p_session text)
returns numeric
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select half_day_credit from vppsone.attendance_rules where session_label = p_session),
    0.50
  );
$$;

-- ---------------------------------------------------------------------------
-- The register carries its revision; every revision is kept
-- ---------------------------------------------------------------------------

alter table vppsone.attendance_registers
  add column revision integer not null default 0,
  add column roster_hash text,
  add column totals jsonb;

comment on column vppsone.attendance_registers.revision is
  '0 until the first save; each save or correction adds one. Only a register at revision 1 or more is recorded.';

create table vppsone.attendance_register_revisions (
  id uuid primary key default gen_random_uuid(),
  -- RESTRICT: a register's history outlives nothing. Registers are never
  -- deleted by the app; a test that removes one removes its history first.
  register_id uuid not null references vppsone.attendance_registers (id) on delete restrict,
  revision integer not null,
  kind text not null,
  /** The browser's submission id. A repeat returns this revision's receipt. */
  command_id uuid not null,
  payload_hash text,
  actor_staff_id uuid references vppsone.staff_profiles (id) on delete restrict,
  /** The class teacher the office stood in for, if it did. No FK: one is enough to embed. */
  on_behalf_of uuid,
  reason text,
  /** The whole register as saved: student id → status. */
  marks jsonb not null,
  /** What this revision changed: [{student_id, from, to}]. */
  changes jsonb not null default '[]'::jsonb,
  /** The roll it was saved against, as md5 of the sorted ids. */
  roster_hash text,
  totals jsonb not null,
  /** The request this correction answered, when it came through the queue. */
  correction_request_id uuid,
  created_at timestamptz not null default now(),
  constraint attendance_register_revisions_kind_known
    check (kind in ('save', 'correction', 'imported')),
  constraint attendance_register_revisions_correction_says_why
    check (kind <> 'correction' or (reason is not null and btrim(reason) <> ''))
);

comment on table vppsone.attendance_register_revisions is
  'Every saved state of every daily register, with who, when, why and what changed. Append-only.';

create unique index attendance_register_revisions_one_per_number
  on vppsone.attendance_register_revisions (register_id, revision);
create unique index attendance_register_revisions_command_unique
  on vppsone.attendance_register_revisions (command_id);

alter table vppsone.attendance_register_revisions enable row level security;
-- Visible exactly when its register is: the subquery is itself under the
-- register's own scoped policy (P1).
create policy attendance_register_revisions_select_scoped
  on vppsone.attendance_register_revisions for select to authenticated
  using (exists (select 1 from vppsone.attendance_registers r where r.id = register_id));
grant select on vppsone.attendance_register_revisions to authenticated;
grant all on vppsone.attendance_register_revisions to service_role;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

create or replace function vppsone.attendance_totals(p_marks jsonb)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select jsonb_build_object(
    'present', count(*) filter (where value = 'present'),
    'absent', count(*) filter (where value = 'absent'),
    'late', count(*) filter (where value = 'late'),
    'half_day', count(*) filter (where value = 'half_day'),
    'leave', count(*) filter (where value = 'leave'),
    'total', count(*)
  )
  from jsonb_each_text(coalesce(p_marks, '{}'::jsonb));
$$;

/**
 * Who was on a class's roll on a date.
 *
 * From the academic enrolment, not today's roll: a child admitted on the 10th
 * is not on the 9th's register, and one who left on the 10th is still on it
 * that day (the leaving date is their last). A row that says "left" with no
 * date cannot be placed and is not counted.
 */
create or replace function vppsone.attendance_roster(p_session text, p_class uuid, p_day date)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select e.student_id
  from vppsone.enrolments e
  where e.session_label = p_session
    and e.class_id = p_class
    and (e.enrolled_on is null or e.enrolled_on <= p_day)
    and (
      (e.status in ('enrolled', 'promoted') and e.left_on is null)
      or (e.left_on is not null and e.left_on >= p_day)
    );
$$;

create or replace function vppsone.attendance_receipt(p_revision uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'ok', true,
    'command_id', rv.command_id,
    'register_id', rv.register_id,
    'class_id', r.class_id,
    'day', r.day,
    'revision', rv.revision,
    'kind', rv.kind,
    'saved_at', rv.created_at,
    'actor_staff_id', rv.actor_staff_id,
    'actor_name', sp.display_name,
    'on_behalf_of', rv.on_behalf_of,
    'totals', rv.totals,
    'changes', jsonb_array_length(rv.changes),
    'replayed', false
  )
  from vppsone.attendance_register_revisions rv
  join vppsone.attendance_registers r on r.id = rv.register_id
  left join vppsone.staff_profiles sp on sp.id = rv.actor_staff_id
  where rv.id = p_revision;
$$;

-- ---------------------------------------------------------------------------
-- The command
-- ---------------------------------------------------------------------------

create or replace function vppsone.save_attendance_register(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_command uuid;
  v_actor uuid;
  v_session text := p->>'session_label';
  v_class uuid;
  v_day date;
  v_kind text := coalesce(p->>'kind', 'save');
  v_expected integer;
  v_reason text := nullif(btrim(coalesce(p->>'reason', '')), '');
  v_hash text := p->>'payload_hash';
  v_fault text := p->>'fault';
  v_request uuid;
  v_previous vppsone.attendance_register_revisions%rowtype;
  v_register vppsone.attendance_registers%rowtype;
  v_actor_name text;
  v_actor_user uuid;
  v_owner boolean;
  v_office boolean;
  v_corrector boolean;
  v_day_kind vppsone.calendar_day_kind;
  v_roster uuid[];
  v_marks jsonb := '{}'::jsonb;
  m jsonb;
  v_status text;
  v_missing uuid[];
  v_extra text[];
  v_current integer;
  v_latest uuid;
  v_old jsonb := '{}'::jsonb;
  v_changes jsonb;
  v_totals jsonb;
  v_roster_hash text;
  v_on_behalf uuid;
  v_revision_id uuid;
  v_now timestamptz := now();
begin
  begin
    v_command := (p->>'command_id')::uuid;
    v_actor := (p->>'actor_staff_id')::uuid;
    v_class := (p->>'class_id')::uuid;
    v_day := (p->>'day')::date;
    v_expected := coalesce((p->>'expected_revision')::integer, 0);
    v_request := nullif(p->>'correction_request_id', '')::uuid;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end;

  if v_command is null or v_actor is null or v_session is null or v_class is null or v_day is null
     or v_hash is null or v_kind not in ('save', 'correction')
     or jsonb_typeof(p->'marks') is distinct from 'array' then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- 1. One command per register at a time.
  perform pg_advisory_xact_lock(
    hashtext('vppsone:attendance:' || v_session || ':' || v_class::text || ':' || v_day::text)
  );

  -- 2. The same submission again gets the same receipt, however long after.
  select * into v_previous from vppsone.attendance_register_revisions where command_id = v_command;
  if found then
    if v_previous.payload_hash = v_hash and v_previous.actor_staff_id = v_actor then
      return vppsone.attendance_receipt(v_previous.id) || jsonb_build_object('replayed', true);
    end if;
    return jsonb_build_object('ok', false, 'reason', 'id_reused');
  end if;

  -- 3. Who is asking, now. The class teacher (or assistant) as of today owns
  -- the register; a former one does not keep it. The office marks on behalf
  -- and corrects; deciding somebody else's request is the office's.
  select display_name, user_id into v_actor_name, v_actor_user
  from vppsone.staff_profiles where id = v_actor and is_active;
  if v_actor_name is null then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  v_owner := exists (
    select 1
    from vppsone.class_teachers ct
    join vppsone.staff_profiles sp on sp.id = ct.staff_profile_id
    join vppsone.role_permissions rp on rp.role = sp.role and rp.permission = 'attendance:mark'
    where ct.staff_profile_id = v_actor
      and ct.class_id = v_class
      and ct.session_label = v_session
      and (ct.effective_from is null or ct.effective_from <= vppsone.school_today())
      and (ct.effective_to is null or ct.effective_to >= vppsone.school_today())
  );
  v_office := exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = v_actor and rp.permission = 'attendance:mark_on_behalf'
  );
  v_corrector := exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = v_actor and rp.permission = 'attendance:correct'
  );

  if (v_kind = 'save' and not (v_owner or v_office))
     or (v_kind = 'correction' and not (v_owner or v_corrector))
     or (v_request is not null and not v_corrector) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  -- 4. A day that happened, on which the school was open.
  if v_day > vppsone.school_today() then
    return jsonb_build_object('ok', false, 'reason', 'future_day');
  end if;
  select kind into v_day_kind from vppsone.academic_calendar_days
  where session_label = v_session and day = v_day;
  if (v_day_kind is not null and v_day_kind in ('holiday', 'vacation'))
     or (v_day_kind is null and extract(dow from v_day) = 0) then
    return jsonb_build_object('ok', false, 'reason', 'school_closed');
  end if;

  -- 5. Every child on that day's roll, exactly once, and nobody else.
  select coalesce(array_agg(s order by s), '{}') into v_roster
  from vppsone.attendance_roster(v_session, v_class, v_day) s;
  if cardinality(v_roster) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'empty_roster');
  end if;

  for m in select value from jsonb_array_elements(p->'marks')
  loop
    v_status := m->>'status';
    if (m->>'student_id') is null
       or v_status is null
       or v_status not in ('present', 'absent', 'late', 'half_day', 'leave')
       or v_marks ? (m->>'student_id') then
      return jsonb_build_object('ok', false, 'reason', 'bad_request');
    end if;
    v_marks := v_marks || jsonb_build_object(m->>'student_id', v_status);
  end loop;

  select coalesce(array_agg(r order by r), '{}') into v_missing
  from unnest(v_roster) r where not (v_marks ? r::text);
  select coalesce(array_agg(k order by k), '{}') into v_extra
  from jsonb_object_keys(v_marks) k
  where not (k = any (select r::text from unnest(v_roster) r));

  if cardinality(v_missing) > 0 or cardinality(v_extra) > 0 then
    return jsonb_build_object('ok', false, 'reason', 'roster_changed', 'missing', to_jsonb(v_missing), 'extra', to_jsonb(v_extra));
  end if;

  -- 6. Nothing has moved since the page was drawn.
  select * into v_register from vppsone.attendance_registers
  where session_label = v_session and class_id = v_class and day = v_day and period is null
  for update;
  v_current := coalesce(v_register.revision, 0);

  if v_current <> v_expected then
    select id into v_latest from vppsone.attendance_register_revisions
    where register_id = v_register.id order by revision desc limit 1;
    return jsonb_build_object(
      'ok', false,
      'reason', 'stale',
      'current_revision', v_current,
      'latest', case when v_latest is null then null else vppsone.attendance_receipt(v_latest) end
    );
  end if;

  if v_kind = 'correction' and v_current = 0 then
    return jsonb_build_object('ok', false, 'reason', 'not_saved_yet');
  end if;
  if v_kind = 'correction' and v_reason is null then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;

  if v_register.id is not null then
    select coalesce(jsonb_object_agg(student_id::text, status::text), '{}'::jsonb) into v_old
    from vppsone.attendance_marks where register_id = v_register.id;
  end if;

  select coalesce(
    jsonb_agg(jsonb_build_object('student_id', k, 'from', v_old->>k, 'to', v_marks->>k) order by k),
    '[]'::jsonb
  ) into v_changes
  from jsonb_object_keys(v_marks) k
  where (v_old->>k) is distinct from (v_marks->>k);

  if v_kind = 'correction' and jsonb_array_length(v_changes) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_change');
  end if;

  v_totals := vppsone.attendance_totals(v_marks);
  v_roster_hash := md5(array_to_string(v_roster, ','));

  -- The office standing in: name the class teacher it stood in for.
  if v_kind = 'save' and not v_owner then
    select ct.staff_profile_id into v_on_behalf
    from vppsone.class_teachers ct
    where ct.class_id = v_class and ct.session_label = v_session and ct.role = 'class_teacher'
      and ct.staff_profile_id <> v_actor
      and (ct.effective_from is null or ct.effective_from <= vppsone.school_today())
      and (ct.effective_to is null or ct.effective_to >= vppsone.school_today())
    limit 1;
  end if;

  -- 7. The register. The morning job may have opened it meanwhile; either way
  -- there is exactly one, and it moves to the next revision.
  if v_register.id is null then
    insert into vppsone.attendance_registers (session_label, class_id, day, period, status, created_by)
    values (v_session, v_class, v_day, null, 'open', v_actor_user)
    on conflict (session_label, class_id, day) where period is null do nothing;
    select * into v_register from vppsone.attendance_registers
    where session_label = v_session and class_id = v_class and day = v_day and period is null
    for update;
    if v_register.revision <> 0 then
      raise exception 'attendance:raced';
    end if;
  end if;

  update vppsone.attendance_registers
  set status = 'submitted',
      taken_by = case when v_kind = 'save' then v_actor else taken_by end,
      on_behalf_of = case when v_kind = 'save' then v_on_behalf else on_behalf_of end,
      submitted_at = coalesce(submitted_at, v_now),
      revision = v_current + 1,
      roster_hash = v_roster_hash,
      totals = v_totals
  where id = v_register.id;

  if v_fault = 'after_register' and vppsone.flag_enabled('fault_injection') then
    raise exception 'attendance:injected_fault:after_register';
  end if;

  delete from vppsone.attendance_marks
  where register_id = v_register.id and not (v_marks ? student_id::text);

  insert into vppsone.attendance_marks (register_id, student_id, status)
  select v_register.id, k::uuid, (v_marks->>k)::vppsone.attendance_status
  from jsonb_object_keys(v_marks) k
  on conflict (register_id, student_id) do update
    set status = excluded.status
    where vppsone.attendance_marks.status is distinct from excluded.status;

  if v_fault = 'after_marks' and vppsone.flag_enabled('fault_injection') then
    raise exception 'attendance:injected_fault:after_marks';
  end if;

  insert into vppsone.attendance_register_revisions (
    register_id, revision, kind, command_id, payload_hash, actor_staff_id, on_behalf_of,
    reason, marks, changes, roster_hash, totals, correction_request_id
  ) values (
    v_register.id, v_current + 1, v_kind, v_command, v_hash, v_actor,
    case when v_kind = 'save' then v_on_behalf else null end,
    v_reason, v_marks, v_changes, v_roster_hash, v_totals, v_request
  )
  returning id into v_revision_id;

  -- 8. A correction that answers a request closes it, in the same breath.
  if v_request is not null then
    update vppsone.attendance_corrections
    set status = 'approved', decided_by = v_actor, decided_at = v_now,
        decision_note = nullif(btrim(coalesce(p->>'decision_note', '')), '')
    where id = v_request and status = 'pending' and register_id = v_register.id
      and requested_by <> v_actor;
    if not found then
      raise exception 'attendance:request_not_pending';
    end if;
  end if;

  if v_fault = 'before_receipt' and vppsone.flag_enabled('fault_injection') then
    raise exception 'attendance:injected_fault:before_receipt';
  end if;

  return vppsone.attendance_receipt(v_revision_id);
end;
$$;

revoke all on function vppsone.half_day_credit(text) from public;
revoke all on function vppsone.attendance_totals(jsonb) from public;
revoke all on function vppsone.attendance_roster(text, uuid, date) from public;
revoke all on function vppsone.attendance_receipt(uuid) from public;
revoke all on function vppsone.save_attendance_register(jsonb) from public;
grant execute on function vppsone.half_day_credit(text) to authenticated, service_role;
grant execute on function vppsone.attendance_totals(jsonb) to service_role;
grant execute on function vppsone.attendance_roster(text, uuid, date) to service_role;
grant execute on function vppsone.attendance_receipt(uuid) to service_role;
grant execute on function vppsone.save_attendance_register(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- What was already submitted becomes revision 1, kept as it was
-- ---------------------------------------------------------------------------

with snapshot as (
  select r.id,
         coalesce(jsonb_object_agg(m.student_id::text, m.status::text) filter (where m.id is not null), '{}'::jsonb) as marks
  from vppsone.attendance_registers r
  left join vppsone.attendance_marks m on m.register_id = r.id
  where r.status = 'submitted'
  group by r.id
)
update vppsone.attendance_registers r
set revision = 1, totals = vppsone.attendance_totals(s.marks)
from snapshot s
where s.id = r.id;

insert into vppsone.attendance_register_revisions (
  register_id, revision, kind, command_id, actor_staff_id, on_behalf_of, marks, totals, created_at
)
select r.id, 1, 'imported', gen_random_uuid(), r.taken_by, r.on_behalf_of,
       coalesce(jsonb_object_agg(m.student_id::text, m.status::text) filter (where m.id is not null), '{}'::jsonb),
       r.totals,
       coalesce(r.submitted_at, r.updated_at)
from vppsone.attendance_registers r
left join vppsone.attendance_marks m on m.register_id = r.id
where r.status = 'submitted'
group by r.id;

-- ======================================================== migrations/20261004051407_attendance_reminder_notices.sql
-- P6: the attendance reminder goes through the staff outbox.
--
-- It used to be a drafted message at 11 a.m. for whoever was class teacher,
-- with no way to take it back. The plan (§12) asks for three things the P4
-- outbox already does for cover: remind only the person responsible now,
-- after the first period ends; let a save made just before dispatch suppress
-- it; and never treat "the provider did not answer" as "not sent". So a
-- reminder becomes one more kind of staff notice, re-checked at the moment it
-- is claimed: a register saved in the meantime, or a teacher no longer
-- responsible for the class, and it is suppressed rather than sent.
--
-- A reminder is about a class and a day, not a duty, so the duty columns
-- become optional for it and a class takes their place.

alter table vppsone.staff_notices
  alter column duty_id drop not null,
  alter column duty_revision drop not null,
  alter column period drop not null,
  add column class_id uuid,
  add column class_label text;

alter table vppsone.staff_notices drop constraint staff_notices_kind_known;
alter table vppsone.staff_notices add constraint staff_notices_kind_known check (
  kind in ('cover_assigned', 'cover_changed', 'cover_cancelled', 'cover_escalation', 'attendance_reminder')
);
alter table vppsone.staff_notices add constraint staff_notices_names_its_subject check (
  (kind <> 'attendance_reminder' and duty_id is not null and duty_revision is not null and period is not null)
  or (kind = 'attendance_reminder' and duty_id is null and class_id is not null)
);

comment on column vppsone.staff_notices.class_id is
  'For an attendance reminder: the class whose register is outstanding (`public.classes.id`, no FK, D-5).';

create or replace function vppsone.claim_staff_notice(
  p_worker text,
  p_lease_seconds integer,
  p_transport text,
  p_notice_id uuid default null
)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  n vppsone.staff_notices%rowtype;
  d vppsone.cover_duties%rowtype;
  s vppsone.staff_profiles%rowtype;
  v_destination text;
  v_attempt uuid;
  v_why text;
begin
  if not vppsone.flag_enabled('staff_notice_dispatch') then
    return jsonb_build_object('claimed', false, 'reason', 'disabled');
  end if;

  for n in
    select * from vppsone.staff_notices
    where (p_notice_id is null or id = p_notice_id)
      and (
        status = 'pending'
        or (status = 'failed' and next_attempt_at is not null and next_attempt_at <= now())
      )
    order by not_after, created_at
    limit 20
    for update skip locked
  loop
    d := null;
    if n.duty_id is not null then
      select * into d from vppsone.cover_duties where id = n.duty_id;
    end if;
    select * into s from vppsone.staff_profiles where id = n.staff_profile_id;
    v_destination := vppsone.staff_destination(n.staff_profile_id);
    v_why := null;

    if now() >= n.not_after then
      v_why := 'too_late';
    elsif not s.is_active then
      v_why := 'inactive';
    elsif n.kind in ('cover_assigned', 'cover_changed')
      and (d.status <> 'assigned' or d.covering_staff_id is distinct from n.staff_profile_id) then
      v_why := 'duty_changed';
    elsif n.kind = 'cover_cancelled' and d.status in ('assigned', 'needs_help')
      and d.covering_staff_id = n.staff_profile_id then
      v_why := 'duty_restored';
    elsif n.kind = 'cover_escalation' and (d.status <> 'assigned' or d.cannot_cover_at is null) then
      v_why := 'resolved';
    elsif n.kind = 'attendance_reminder' and exists (
      select 1 from vppsone.attendance_registers r
      where r.session_label = n.session_label and r.class_id = n.class_id
        and r.day = n.day and r.period is null and r.revision >= 1
    ) then
      -- Saved since it was queued: nothing to remind anybody of.
      v_why := 'already_saved';
    elsif n.kind = 'attendance_reminder' and not exists (
      select 1 from vppsone.class_teachers ct
      where ct.staff_profile_id = n.staff_profile_id and ct.class_id = n.class_id
        and ct.session_label = n.session_label
        and (ct.effective_from is null or ct.effective_from <= n.day)
        and (ct.effective_to is null or ct.effective_to >= n.day)
    ) then
      v_why := 'not_responsible';
    elsif v_destination is null or length(v_destination) < 10 then
      v_why := 'no_phone';
    end if;

    if v_why is not null then
      update vppsone.staff_notices set status = 'suppressed', status_reason = v_why where id = n.id;
      continue;
    end if;

    insert into vppsone.staff_notice_attempts (
      notice_id, attempt_no, lease_owner, lease_expires_at, destination, contact_version, transport
    ) values (
      n.id, n.attempts + 1, p_worker, now() + make_interval(secs => p_lease_seconds),
      right(v_destination, 10),
      md5(coalesce(s.whatsapp_phone, '') || '|' || coalesce(s.phone, '') || '|' || s.updated_at::text),
      p_transport
    )
    returning id into v_attempt;

    update vppsone.staff_notices
    set status = 'dispatching', attempts = attempts + 1, next_attempt_at = null
    where id = n.id;

    return jsonb_build_object(
      'claimed', true,
      'attempt_id', v_attempt,
      'notice', jsonb_build_object(
        'id', n.id, 'kind', n.kind, 'day', n.day, 'period', n.period,
        'attempt_no', n.attempts + 1, 'not_after', n.not_after, 'session_label', n.session_label
      ),
      'duty', case when n.duty_id is null then null else jsonb_build_object(
        'id', d.id, 'class_labels', d.class_labels, 'subject_code', d.subject_code,
        'period', d.period, 'day', d.day, 'revision', d.revision, 'status', d.status
      ) end,
      'register', case when n.kind = 'attendance_reminder' then jsonb_build_object(
        'class_id', n.class_id, 'class_label', n.class_label, 'day', n.day
      ) else null end,
      'staff', jsonb_build_object(
        'id', s.id, 'display_name', s.display_name, 'language', s.preferred_language
      ),
      'destination', right(v_destination, 10)
    );
  end loop;

  return jsonb_build_object('claimed', false, 'reason', 'empty');
end;
$$;

revoke all on function vppsone.claim_staff_notice(text, integer, text, uuid) from public;
grant execute on function vppsone.claim_staff_notice(text, integer, text, uuid) to service_role;

-- ======================================================== migrations/20261004060553_attendance_imports_old_saves.sql
-- P6 follow-up: a register submitted without a revision is kept, not overwritten.
--
-- Until this release is deployed, the previous build still saves registers the
-- old way: status 'submitted', revision 0, no history row. None exist on dev
-- now (checked before writing this), but one could be made in the minutes
-- between this migration and the deploy. The save command now imports such a
-- register as revision 1 — exactly as the P6 migration imported the rest —
-- before it compares revisions, so the next save is refused as stale and the
-- page shows what was recorded. Any that exist when this runs are imported
-- here.

create or replace function vppsone.import_unrevisioned_register(p_register uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  r vppsone.attendance_registers%rowtype;
  v_marks jsonb;
begin
  select * into r from vppsone.attendance_registers where id = p_register for update;
  if not found or r.status <> 'submitted' or r.revision <> 0 then
    return;
  end if;

  select coalesce(jsonb_object_agg(student_id::text, status::text), '{}'::jsonb) into v_marks
  from vppsone.attendance_marks where register_id = p_register;

  update vppsone.attendance_registers
  set revision = 1, totals = vppsone.attendance_totals(v_marks)
  where id = p_register;

  insert into vppsone.attendance_register_revisions (
    register_id, revision, kind, command_id, actor_staff_id, on_behalf_of, marks, totals, created_at
  ) values (
    p_register, 1, 'imported', gen_random_uuid(), r.taken_by, r.on_behalf_of,
    v_marks, vppsone.attendance_totals(v_marks), coalesce(r.submitted_at, r.updated_at)
  );
end;
$$;

revoke all on function vppsone.import_unrevisioned_register(uuid) from public;
grant execute on function vppsone.import_unrevisioned_register(uuid) to service_role;

create or replace function vppsone.save_attendance_register(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_command uuid;
  v_actor uuid;
  v_session text := p->>'session_label';
  v_class uuid;
  v_day date;
  v_kind text := coalesce(p->>'kind', 'save');
  v_expected integer;
  v_reason text := nullif(btrim(coalesce(p->>'reason', '')), '');
  v_hash text := p->>'payload_hash';
  v_fault text := p->>'fault';
  v_request uuid;
  v_previous vppsone.attendance_register_revisions%rowtype;
  v_register vppsone.attendance_registers%rowtype;
  v_actor_name text;
  v_actor_user uuid;
  v_owner boolean;
  v_office boolean;
  v_corrector boolean;
  v_day_kind vppsone.calendar_day_kind;
  v_roster uuid[];
  v_marks jsonb := '{}'::jsonb;
  m jsonb;
  v_status text;
  v_missing uuid[];
  v_extra text[];
  v_current integer;
  v_latest uuid;
  v_old jsonb := '{}'::jsonb;
  v_changes jsonb;
  v_totals jsonb;
  v_roster_hash text;
  v_on_behalf uuid;
  v_revision_id uuid;
  v_now timestamptz := now();
begin
  begin
    v_command := (p->>'command_id')::uuid;
    v_actor := (p->>'actor_staff_id')::uuid;
    v_class := (p->>'class_id')::uuid;
    v_day := (p->>'day')::date;
    v_expected := coalesce((p->>'expected_revision')::integer, 0);
    v_request := nullif(p->>'correction_request_id', '')::uuid;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end;

  if v_command is null or v_actor is null or v_session is null or v_class is null or v_day is null
     or v_hash is null or v_kind not in ('save', 'correction')
     or jsonb_typeof(p->'marks') is distinct from 'array' then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- 1. One command per register at a time.
  perform pg_advisory_xact_lock(
    hashtext('vppsone:attendance:' || v_session || ':' || v_class::text || ':' || v_day::text)
  );

  -- 2. The same submission again gets the same receipt, however long after.
  select * into v_previous from vppsone.attendance_register_revisions where command_id = v_command;
  if found then
    if v_previous.payload_hash = v_hash and v_previous.actor_staff_id = v_actor then
      return vppsone.attendance_receipt(v_previous.id) || jsonb_build_object('replayed', true);
    end if;
    return jsonb_build_object('ok', false, 'reason', 'id_reused');
  end if;

  -- 3. Who is asking, now. The class teacher (or assistant) as of today owns
  -- the register; a former one does not keep it. The office marks on behalf
  -- and corrects; deciding somebody else's request is the office's.
  select display_name, user_id into v_actor_name, v_actor_user
  from vppsone.staff_profiles where id = v_actor and is_active;
  if v_actor_name is null then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  v_owner := exists (
    select 1
    from vppsone.class_teachers ct
    join vppsone.staff_profiles sp on sp.id = ct.staff_profile_id
    join vppsone.role_permissions rp on rp.role = sp.role and rp.permission = 'attendance:mark'
    where ct.staff_profile_id = v_actor
      and ct.class_id = v_class
      and ct.session_label = v_session
      and (ct.effective_from is null or ct.effective_from <= vppsone.school_today())
      and (ct.effective_to is null or ct.effective_to >= vppsone.school_today())
  );
  v_office := exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = v_actor and rp.permission = 'attendance:mark_on_behalf'
  );
  v_corrector := exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = v_actor and rp.permission = 'attendance:correct'
  );

  if (v_kind = 'save' and not (v_owner or v_office))
     or (v_kind = 'correction' and not (v_owner or v_corrector))
     or (v_request is not null and not v_corrector) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  -- 4. A day that happened, on which the school was open.
  if v_day > vppsone.school_today() then
    return jsonb_build_object('ok', false, 'reason', 'future_day');
  end if;
  select kind into v_day_kind from vppsone.academic_calendar_days
  where session_label = v_session and day = v_day;
  if (v_day_kind is not null and v_day_kind in ('holiday', 'vacation'))
     or (v_day_kind is null and extract(dow from v_day) = 0) then
    return jsonb_build_object('ok', false, 'reason', 'school_closed');
  end if;

  -- 5. Every child on that day's roll, exactly once, and nobody else.
  select coalesce(array_agg(s order by s), '{}') into v_roster
  from vppsone.attendance_roster(v_session, v_class, v_day) s;
  if cardinality(v_roster) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'empty_roster');
  end if;

  for m in select value from jsonb_array_elements(p->'marks')
  loop
    v_status := m->>'status';
    if (m->>'student_id') is null
       or v_status is null
       or v_status not in ('present', 'absent', 'late', 'half_day', 'leave')
       or v_marks ? (m->>'student_id') then
      return jsonb_build_object('ok', false, 'reason', 'bad_request');
    end if;
    v_marks := v_marks || jsonb_build_object(m->>'student_id', v_status);
  end loop;

  select coalesce(array_agg(r order by r), '{}') into v_missing
  from unnest(v_roster) r where not (v_marks ? r::text);
  select coalesce(array_agg(k order by k), '{}') into v_extra
  from jsonb_object_keys(v_marks) k
  where not (k = any (select r::text from unnest(v_roster) r));

  if cardinality(v_missing) > 0 or cardinality(v_extra) > 0 then
    return jsonb_build_object('ok', false, 'reason', 'roster_changed', 'missing', to_jsonb(v_missing), 'extra', to_jsonb(v_extra));
  end if;

  -- 6. Nothing has moved since the page was drawn.
  select * into v_register from vppsone.attendance_registers
  where session_label = v_session and class_id = v_class and day = v_day and period is null
  for update;

  -- A register submitted before revisions were kept — by an older build,
  -- while this one was deploying — is history too. Keep it as revision 1
  -- before anything else, so this save is told it is stale rather than
  -- writing over a register somebody already handed in.
  if v_register.id is not null and v_register.status = 'submitted' and v_register.revision = 0 then
    perform vppsone.import_unrevisioned_register(v_register.id);
    select * into v_register from vppsone.attendance_registers where id = v_register.id;
  end if;

  v_current := coalesce(v_register.revision, 0);

  if v_current <> v_expected then
    select id into v_latest from vppsone.attendance_register_revisions
    where register_id = v_register.id order by revision desc limit 1;
    return jsonb_build_object(
      'ok', false,
      'reason', 'stale',
      'current_revision', v_current,
      'latest', case when v_latest is null then null else vppsone.attendance_receipt(v_latest) end
    );
  end if;

  if v_kind = 'correction' and v_current = 0 then
    return jsonb_build_object('ok', false, 'reason', 'not_saved_yet');
  end if;
  if v_kind = 'correction' and v_reason is null then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;

  if v_register.id is not null then
    select coalesce(jsonb_object_agg(student_id::text, status::text), '{}'::jsonb) into v_old
    from vppsone.attendance_marks where register_id = v_register.id;
  end if;

  select coalesce(
    jsonb_agg(jsonb_build_object('student_id', k, 'from', v_old->>k, 'to', v_marks->>k) order by k),
    '[]'::jsonb
  ) into v_changes
  from jsonb_object_keys(v_marks) k
  where (v_old->>k) is distinct from (v_marks->>k);

  if v_kind = 'correction' and jsonb_array_length(v_changes) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'no_change');
  end if;

  v_totals := vppsone.attendance_totals(v_marks);
  v_roster_hash := md5(array_to_string(v_roster, ','));

  -- The office standing in: name the class teacher it stood in for.
  if v_kind = 'save' and not v_owner then
    select ct.staff_profile_id into v_on_behalf
    from vppsone.class_teachers ct
    where ct.class_id = v_class and ct.session_label = v_session and ct.role = 'class_teacher'
      and ct.staff_profile_id <> v_actor
      and (ct.effective_from is null or ct.effective_from <= vppsone.school_today())
      and (ct.effective_to is null or ct.effective_to >= vppsone.school_today())
    limit 1;
  end if;

  -- 7. The register. The morning job may have opened it meanwhile; either way
  -- there is exactly one, and it moves to the next revision.
  if v_register.id is null then
    insert into vppsone.attendance_registers (session_label, class_id, day, period, status, created_by)
    values (v_session, v_class, v_day, null, 'open', v_actor_user)
    on conflict (session_label, class_id, day) where period is null do nothing;
    select * into v_register from vppsone.attendance_registers
    where session_label = v_session and class_id = v_class and day = v_day and period is null
    for update;
    if v_register.revision <> 0 then
      raise exception 'attendance:raced';
    end if;
  end if;

  update vppsone.attendance_registers
  set status = 'submitted',
      taken_by = case when v_kind = 'save' then v_actor else taken_by end,
      on_behalf_of = case when v_kind = 'save' then v_on_behalf else on_behalf_of end,
      submitted_at = coalesce(submitted_at, v_now),
      revision = v_current + 1,
      roster_hash = v_roster_hash,
      totals = v_totals
  where id = v_register.id;

  if v_fault = 'after_register' and vppsone.flag_enabled('fault_injection') then
    raise exception 'attendance:injected_fault:after_register';
  end if;

  delete from vppsone.attendance_marks
  where register_id = v_register.id and not (v_marks ? student_id::text);

  insert into vppsone.attendance_marks (register_id, student_id, status)
  select v_register.id, k::uuid, (v_marks->>k)::vppsone.attendance_status
  from jsonb_object_keys(v_marks) k
  on conflict (register_id, student_id) do update
    set status = excluded.status
    where vppsone.attendance_marks.status is distinct from excluded.status;

  if v_fault = 'after_marks' and vppsone.flag_enabled('fault_injection') then
    raise exception 'attendance:injected_fault:after_marks';
  end if;

  insert into vppsone.attendance_register_revisions (
    register_id, revision, kind, command_id, payload_hash, actor_staff_id, on_behalf_of,
    reason, marks, changes, roster_hash, totals, correction_request_id
  ) values (
    v_register.id, v_current + 1, v_kind, v_command, v_hash, v_actor,
    case when v_kind = 'save' then v_on_behalf else null end,
    v_reason, v_marks, v_changes, v_roster_hash, v_totals, v_request
  )
  returning id into v_revision_id;

  -- 8. A correction that answers a request closes it, in the same breath.
  if v_request is not null then
    update vppsone.attendance_corrections
    set status = 'approved', decided_by = v_actor, decided_at = v_now,
        decision_note = nullif(btrim(coalesce(p->>'decision_note', '')), '')
    where id = v_request and status = 'pending' and register_id = v_register.id
      and requested_by <> v_actor;
    if not found then
      raise exception 'attendance:request_not_pending';
    end if;
  end if;

  if v_fault = 'before_receipt' and vppsone.flag_enabled('fault_injection') then
    raise exception 'attendance:injected_fault:before_receipt';
  end if;

  return vppsone.attendance_receipt(v_revision_id);
end;
$$;

select vppsone.import_unrevisioned_register(id)
from vppsone.attendance_registers
where status = 'submitted' and revision = 0;

-- ======================================================== migrations/20261004062800_marks_draft_submit.sql
-- P7: marks are saved by one command per paper — drafted, then submitted, then
-- only corrected with a reason — and blank, zero, absent and exempt stay four
-- different things.
--
-- Before this a column saved cell by cell: a failure half-way left half a
-- column written. "Exempt" did not exist, so a child excused from a paper was
-- either a blank (and the paper never finished) or an absence (and a nought
-- on a report). Nothing said a teacher had finished: a column with every cell
-- filled looked the same as a column she was still checking. And any teacher
-- with a class could type marks for every subject in it.
--
-- The plan (§13): open only the assigned class and subject; keep blank, zero,
-- absent and exempt distinct; take the maximum and the precision from the
-- scheme; a draft returns a draft receipt; submitting completes the teacher's
-- task under the completeness rule and approves nothing; a missing entry is
-- visible and never a zero.

-- ---------------------------------------------------------------------------
-- The cell: exempt is its own state
-- ---------------------------------------------------------------------------

alter table vppsone.marks
  add column exempt boolean not null default false,
  add constraint marks_exempt_has_no_value check (not exempt or (value is null and not absent));

comment on column vppsone.marks.exempt is
  'Excused from this paper: not sat, not a nought, and out of both halves of any total.';

alter table vppsone.marks_change_log
  add column from_exempt boolean,
  add column to_exempt boolean,
  add column command_id uuid;

-- ---------------------------------------------------------------------------
-- The paper: its scheme, and whether its marks are in
-- ---------------------------------------------------------------------------

alter table vppsone.assessment_subjects
  add column mark_step numeric(4, 2) not null default 0.5,
  add column allow_exempt boolean not null default true,
  add column entry_status text not null default 'open',
  add column entry_revision integer not null default 0,
  add column submitted_by uuid references vppsone.staff_profiles (id) on delete restrict,
  add column submitted_at timestamptz,
  add constraint assessment_subjects_mark_step_known check (mark_step in (0.25, 0.5, 1)),
  add constraint assessment_subjects_entry_status_known check (entry_status in ('open', 'submitted')),
  add constraint assessment_subjects_submitted_together
    check ((entry_status = 'submitted') = (submitted_at is not null));

comment on column vppsone.assessment_subjects.mark_step is
  'The smallest part of a mark this paper gives: 1, 0.5 or 0.25.';
comment on column vppsone.assessment_subjects.entry_status is
  'open while the teacher drafts; submitted once every child has a mark, an absence or an exemption. Submitting approves nothing.';

-- ---------------------------------------------------------------------------
-- Every command, and its receipt
-- ---------------------------------------------------------------------------

create table vppsone.marks_commands (
  /** The submission id the browser minted once. */
  id uuid primary key,
  assessment_subject_id uuid not null references vppsone.assessment_subjects (id) on delete cascade,
  actor_staff_id uuid not null references vppsone.staff_profiles (id) on delete restrict,
  kind text not null,
  payload_hash text not null,
  receipt jsonb not null,
  created_at timestamptz not null default now(),
  constraint marks_commands_kind_known check (kind in ('draft', 'submit', 'correction', 'reopen'))
);

comment on table vppsone.marks_commands is
  'Every committed marks command and the receipt it returned. A repeated id with the same payload gets the receipt back.';

create index marks_commands_by_paper_idx on vppsone.marks_commands (assessment_subject_id, created_at desc);

alter table vppsone.marks_commands enable row level security;
grant all on vppsone.marks_commands to service_role;

-- ---------------------------------------------------------------------------
-- Who sat a paper
-- ---------------------------------------------------------------------------

/**
 * The children on a paper's class roll at some point during its exam: enrolled
 * by the time it ended, and not gone before it began. Without dates, today's
 * roll. A child who joined after the exam is not asked for a mark; one who
 * left during it still is.
 */
create or replace function vppsone.paper_roster(p_paper uuid)
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select e.student_id
  from vppsone.assessment_subjects s
  join vppsone.assessments a on a.id = s.assessment_id
  join vppsone.enrolments e on e.class_id = s.class_id and e.session_label = a.session_label
  where s.id = p_paper
    and (e.enrolled_on is null or e.enrolled_on <= coalesce(a.ends_on, a.starts_on, vppsone.school_today()))
    and (
      (e.status in ('enrolled', 'promoted') and e.left_on is null)
      or (e.left_on is not null and e.left_on >= coalesce(a.starts_on, a.ends_on, vppsone.school_today()))
    );
$$;

-- ---------------------------------------------------------------------------
-- The command
-- ---------------------------------------------------------------------------

create or replace function vppsone.save_marks(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_command uuid;
  v_actor uuid;
  v_paper uuid;
  v_kind text := coalesce(p->>'kind', 'draft');
  v_expected integer;
  v_reason text := nullif(btrim(coalesce(p->>'reason', '')), '');
  v_hash text := p->>'payload_hash';
  v_fault text := p->>'fault';
  v_previous vppsone.marks_commands%rowtype;
  s vppsone.assessment_subjects%rowtype;
  a vppsone.assessments%rowtype;
  v_actor_name text;
  v_manager boolean;
  v_assigned boolean;
  v_roster uuid[];
  e jsonb;
  v_student uuid;
  v_state text;
  v_value numeric;
  v_seen uuid[] := '{}';
  v_old record;
  v_existed boolean;
  v_old_state text;
  v_changes integer := 0;
  v_blank uuid[];
  v_counts jsonb;
  v_receipt jsonb;
  v_now timestamptz := now();
begin
  begin
    v_command := (p->>'command_id')::uuid;
    v_actor := (p->>'actor_staff_id')::uuid;
    v_paper := (p->>'paper_id')::uuid;
    v_expected := coalesce((p->>'expected_revision')::integer, 0);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end;

  if v_command is null or v_actor is null or v_paper is null or v_hash is null
     or v_kind not in ('draft', 'submit', 'correction', 'reopen') then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  -- 1. One command per paper at a time.
  select * into s from vppsone.assessment_subjects where id = v_paper for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'not_found');
  end if;

  -- 2. The same submission again gets the same receipt.
  select * into v_previous from vppsone.marks_commands where id = v_command;
  if found then
    if v_previous.payload_hash = v_hash and v_previous.actor_staff_id = v_actor then
      return v_previous.receipt || jsonb_build_object('replayed', true);
    end if;
    return jsonb_build_object('ok', false, 'reason', 'id_reused');
  end if;

  select * into a from vppsone.assessments where id = s.assessment_id;

  -- 3. Who is asking: the teacher who teaches this subject to this class, or
  -- whoever runs the exams. A class teacher is not thereby every subject's.
  select display_name into v_actor_name from vppsone.staff_profiles where id = v_actor and is_active;
  if v_actor_name is null then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;
  v_manager := exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = v_actor and rp.permission = 'assessments:manage'
  );
  v_assigned := exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role and rp.permission = 'marks:write'
    join vppsone.teaching_assignments ta
      on ta.staff_profile_id = sp.id and ta.session_label = a.session_label
     and ta.class_id = s.class_id and ta.subject_id = s.subject_id
    where sp.id = v_actor
  );
  if (v_kind = 'reopen' and not v_manager) or (v_kind <> 'reopen' and not (v_manager or v_assigned)) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  -- 4. An exam that is taking marks.
  if a.status <> 'open' then
    return jsonb_build_object('ok', false, 'reason', 'exam_not_open');
  end if;

  -- 5. Nothing has moved since the page was drawn.
  if s.entry_revision <> v_expected then
    return jsonb_build_object(
      'ok', false, 'reason', 'stale',
      'current_revision', s.entry_revision, 'entry_status', s.entry_status
    );
  end if;

  -- 6. What each kind may do from where the paper is.
  if v_kind = 'reopen' then
    if s.entry_status <> 'submitted' then
      return jsonb_build_object('ok', false, 'reason', 'not_submitted');
    end if;
    update vppsone.assessment_subjects
    set entry_status = 'open', entry_revision = entry_revision + 1, submitted_by = null, submitted_at = null
    where id = v_paper;
  else
    if v_kind in ('draft', 'submit') and s.entry_status = 'submitted' then
      return jsonb_build_object('ok', false, 'reason', 'already_submitted');
    end if;
    if v_kind = 'correction' and s.entry_status <> 'submitted' then
      return jsonb_build_object('ok', false, 'reason', 'not_submitted');
    end if;
    if v_kind = 'correction' and v_reason is null then
      return jsonb_build_object('ok', false, 'reason', 'reason_required');
    end if;

    select coalesce(array_agg(r), '{}') into v_roster from vppsone.paper_roster(v_paper) r;

    -- 7. Every cell, against the scheme. A refusal leaves the column as it was.
    for e in select value from jsonb_array_elements(coalesce(p->'entries', '[]'::jsonb))
    loop
      begin
        v_student := (e->>'student_id')::uuid;
      exception when others then
        raise exception 'marks:bad_request';
      end;
      if v_student is null or v_student = any (v_seen) then
        raise exception 'marks:bad_request';
      end if;
      v_seen := v_seen || v_student;
      if not (v_student = any (v_roster)) then
        raise exception 'marks:not_on_roll:%', v_student;
      end if;

      v_state := e->>'state';
      v_value := null;
      if v_state = 'value' then
        begin
          v_value := (e->>'value')::numeric;
        exception when others then
          raise exception 'marks:invalid_value:%', v_student;
        end;
        if v_value is null or v_value < 0 or v_value > s.max_marks or mod(v_value, s.mark_step) <> 0 then
          raise exception 'marks:invalid_value:%', v_student;
        end if;
      elsif v_state = 'exempt' then
        if not s.allow_exempt then
          raise exception 'marks:exempt_not_allowed:%', v_student;
        end if;
      elsif v_state is null or v_state not in ('blank', 'absent') then
        raise exception 'marks:bad_request';
      end if;

      select value, absent, exempt into v_old
      from vppsone.marks where assessment_subject_id = v_paper and student_id = v_student;
      v_existed := found;
      v_old_state := case
        when not v_existed then 'blank'
        when v_old.exempt then 'exempt'
        when v_old.absent then 'absent'
        when v_old.value is not null then 'value'
        else 'blank'
      end;

      if v_old_state = v_state and (v_state <> 'value' or (v_existed and v_old.value = v_value)) then
        continue;
      end if;

      if v_kind = 'correction' and v_state = 'blank' then
        raise exception 'marks:cannot_blank:%', v_student;
      end if;

      insert into vppsone.marks (assessment_subject_id, student_id, value, absent, exempt, entered_by, entered_at)
      values (v_paper, v_student, v_value, v_state = 'absent', v_state = 'exempt', v_actor, v_now)
      on conflict (assessment_subject_id, student_id) do update
        set value = excluded.value, absent = excluded.absent, exempt = excluded.exempt,
            entered_by = excluded.entered_by, entered_at = excluded.entered_at;

      insert into vppsone.marks_change_log (
        assessment_subject_id, student_id, from_value, to_value, from_absent, to_absent,
        from_exempt, to_exempt, reason, changed_by, command_id
      ) values (
        v_paper, v_student,
        case when v_existed then v_old.value end, v_value,
        case when v_existed then v_old.absent end, v_state = 'absent',
        case when v_existed then v_old.exempt end, v_state = 'exempt',
        v_reason, v_actor, v_command
      );
      v_changes := v_changes + 1;
    end loop;

    if v_fault = 'after_marks' and vppsone.flag_enabled('fault_injection') then
      raise exception 'marks:injected_fault:after_marks';
    end if;

    -- 8. Submitting is the teacher saying she is done: every child on the
    -- roll has a mark, an absence or an exemption. A blank is never a zero.
    select coalesce(array_agg(r), '{}') into v_blank
    from unnest(v_roster) r
    where not exists (
      select 1 from vppsone.marks m
      where m.assessment_subject_id = v_paper and m.student_id = r
        and (m.value is not null or m.absent or m.exempt)
    );

    if v_kind in ('submit', 'correction') and cardinality(v_blank) > 0 then
      raise exception 'marks:incomplete:%', array_to_string(v_blank, ',');
    end if;
    if v_kind in ('draft', 'correction') and v_changes = 0 then
      raise exception 'marks:no_change';
    end if;

    update vppsone.assessment_subjects
    set entry_revision = entry_revision + 1,
        entry_status = case when v_kind = 'submit' then 'submitted' else entry_status end,
        submitted_by = case when v_kind = 'submit' then v_actor else submitted_by end,
        submitted_at = case when v_kind = 'submit' then v_now else submitted_at end
    where id = v_paper;
  end if;

  -- 9. The receipt.
  select coalesce(array_agg(r), '{}') into v_roster from vppsone.paper_roster(v_paper) r;
  select jsonb_build_object(
    'entered', count(*) filter (where m.value is not null),
    'absent', count(*) filter (where m.absent),
    'exempt', count(*) filter (where m.exempt),
    'blank', cardinality(v_roster) - count(*) filter (where m.value is not null or m.absent or m.exempt),
    'total', cardinality(v_roster)
  ) into v_counts
  from vppsone.marks m
  where m.assessment_subject_id = v_paper and m.student_id = any (v_roster);

  select * into s from vppsone.assessment_subjects where id = v_paper;
  v_receipt := jsonb_build_object(
    'ok', true,
    'command_id', v_command,
    'paper_id', v_paper,
    'kind', v_kind,
    'revision', s.entry_revision,
    'entry_status', s.entry_status,
    'saved_at', v_now,
    'actor_name', v_actor_name,
    'changed', v_changes,
    'counts', v_counts,
    'replayed', false
  );

  if v_fault = 'before_receipt' and vppsone.flag_enabled('fault_injection') then
    raise exception 'marks:injected_fault:before_receipt';
  end if;

  insert into vppsone.marks_commands (id, assessment_subject_id, actor_staff_id, kind, payload_hash, receipt)
  values (v_command, v_paper, v_actor, v_kind, v_hash, v_receipt);

  return v_receipt;
end;
$$;

revoke all on function vppsone.paper_roster(uuid) from public;
revoke all on function vppsone.save_marks(jsonb) from public;
grant execute on function vppsone.paper_roster(uuid) to service_role;
grant execute on function vppsone.save_marks(jsonb) to service_role;

-- ======================================================== migrations/20261004081924_report_schemes_and_issues.sql
-- P8: a report card is issued once, against an approved scheme, from papers
-- their teachers have submitted — and a correction is a new revision that
-- keeps the old one.
--
-- Before this, issuing upserted one row per child and term: a reissue
-- silently replaced what a family had been handed, the grade bands were a
-- constant nobody at the school had confirmed, a card could be issued while
-- papers were still being marked, and nothing recorded which marks, which
-- attendance or which rules it was made from.
--
-- The plan (§13): calculate from a pinned scheme; show absent, exempt and
-- incomplete as what they are, never a silent number; round at an agreed
-- boundary; count attendance over the reporting period and say how many days
-- were not recorded; freeze the approved revision with its sources, approver
-- and reason; a later correction prepares an amended report rather than
-- replacing the old one.

-- ---------------------------------------------------------------------------
-- The scheme: the school's rules for one term's cards
-- ---------------------------------------------------------------------------

create table vppsone.report_schemes (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  term text not null,
  revision integer not null,
  status text not null default 'draft',
  /** [{from, label, hi, en}], highest first. A percentage at or above `from` takes the band. */
  grade_bands jsonb not null,
  /** Decimal places the percentage is rounded to — half up — before it is graded. */
  percent_decimals smallint not null default 1,
  /** The overall percentage a card calls a pass, or null when the school does not print one. */
  pass_percent numeric(5, 2),
  attendance_from date,
  attendance_to date,
  header_en text,
  header_hi text,
  /** [{en, hi}] — the signature lines printed at the foot of the card. */
  signatories jsonb not null default '[]'::jsonb,
  approved_by uuid references vppsone.staff_profiles (id) on delete restrict,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint report_schemes_status_known check (status in ('draft', 'approved')),
  constraint report_schemes_approved_together check ((status = 'approved') = (approved_at is not null)),
  constraint report_schemes_decimals_sane check (percent_decimals between 0 and 2),
  constraint report_schemes_pass_sane check (pass_percent is null or (pass_percent >= 0 and pass_percent <= 100)),
  constraint report_schemes_period_ordered check (
    attendance_from is null or attendance_to is null or attendance_to >= attendance_from
  )
);

comment on table vppsone.report_schemes is
  'How one term''s report cards are worked out and what they print. A card is issued only against an approved revision, and keeps which one.';

create unique index report_schemes_revision_unique on vppsone.report_schemes (session_label, term, revision);
-- At most one revision being edited at a time.
create unique index report_schemes_one_draft on vppsone.report_schemes (session_label, term) where status = 'draft';

create trigger report_schemes_set_updated_at
  before update on vppsone.report_schemes
  for each row execute function vppsone.set_updated_at();

-- An approved scheme is a record: cards were issued from it. The one
-- exception is a synthetic term the verifier made (`QA-…`), which it removes
-- when it is done; a real term never starts so.
create or replace function vppsone.report_schemes_stay_approved()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.status = 'approved' and not (tg_op = 'DELETE' and old.term like 'QA-%') then
    raise exception 'report_scheme:approved_is_final';
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create trigger report_schemes_stay_approved
  before update or delete on vppsone.report_schemes
  for each row execute function vppsone.report_schemes_stay_approved();

alter table vppsone.report_schemes enable row level security;
create policy report_schemes_select_staff
  on vppsone.report_schemes for select to authenticated
  using ((select vppsone.staff_can('reports:view')));
grant select on vppsone.report_schemes to authenticated;
grant all on vppsone.report_schemes to service_role;

-- ---------------------------------------------------------------------------
-- The issued card, every revision of it
-- ---------------------------------------------------------------------------

create table vppsone.report_card_issues (
  id uuid primary key default gen_random_uuid(),
  session_label text not null,
  term text not null,
  student_id uuid not null,
  revision integer not null,
  status text not null default 'issued',
  /** The card as printed: every number, grade and label, kept as it was. */
  card jsonb not null,
  /** Null only for a card issued before schemes existed. */
  scheme_id uuid references vppsone.report_schemes (id) on delete restrict,
  /** What it was made from: each paper's entry revision, the attendance period and what was not recorded. */
  sources jsonb not null default '{}'::jsonb,
  kind text not null default 'issue',
  reason text,
  issued_by uuid references vppsone.staff_profiles (id) on delete restrict,
  issued_at timestamptz not null default now(),
  supersedes uuid references vppsone.report_card_issues (id),
  command_id uuid not null,
  payload_hash text,
  constraint report_card_issues_status_known check (status in ('issued', 'superseded')),
  constraint report_card_issues_kind_known check (kind in ('issue', 'reissue', 'imported')),
  constraint report_card_issues_reissue_says_why check (kind <> 'reissue' or (reason is not null and btrim(reason) <> ''))
);

comment on table vppsone.report_card_issues is
  'Every report card handed out, every revision of it. A reissue supersedes the old revision and says why; nothing is overwritten.';

create unique index report_card_issues_revision_unique
  on vppsone.report_card_issues (session_label, term, student_id, revision);
create unique index report_card_issues_one_current
  on vppsone.report_card_issues (session_label, term, student_id) where status = 'issued';
create unique index report_card_issues_command_unique on vppsone.report_card_issues (command_id);

-- Only one change is ever made to an issued row: it is superseded. Nothing
-- is deleted — except a synthetic term the verifier made (`QA-…`).
create or replace function vppsone.report_card_issues_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if old.term like 'QA-%' then
      return old;
    end if;
    raise exception 'report_card:issued_is_final';
  end if;
  if new.card is distinct from old.card or new.sources is distinct from old.sources
     or new.revision is distinct from old.revision or new.student_id is distinct from old.student_id
     or new.issued_by is distinct from old.issued_by or new.issued_at is distinct from old.issued_at
     or not (old.status = 'issued' and new.status = 'superseded') then
    raise exception 'report_card:issued_is_final';
  end if;
  return new;
end;
$$;

create trigger report_card_issues_append_only
  before update or delete on vppsone.report_card_issues
  for each row execute function vppsone.report_card_issues_append_only();

alter table vppsone.report_card_issues enable row level security;
-- The same scope as the old table (P1): reports:view, and a child the reader
-- may see.
create policy report_card_issues_select_scoped
  on vppsone.report_card_issues for select to authenticated
  using (
    (select vppsone.staff_can('reports:view'))
    and (
      (select vppsone.reads_every_class())
      or exists (
        select 1 from vppsone.enrolments e
        where e.student_id = report_card_issues.student_id
          and e.session_label = report_card_issues.session_label
          and (e.class_id::text || '|' || e.session_label) = any (coalesce((select vppsone.my_class_keys()), '{}'::text[]))
      )
    )
  );
grant select on vppsone.report_card_issues to authenticated;
grant all on vppsone.report_card_issues to service_role;

-- ---------------------------------------------------------------------------
-- The command
-- ---------------------------------------------------------------------------

create or replace function vppsone.issue_report_card(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_command uuid;
  v_actor uuid;
  v_session text := p->>'session_label';
  v_term text := p->>'term';
  v_student uuid;
  v_scheme uuid;
  v_expected integer;
  v_reason text := nullif(btrim(coalesce(p->>'reason', '')), '');
  v_hash text := p->>'payload_hash';
  v_card jsonb := p->'card';
  v_sources jsonb := coalesce(p->'sources', '{}'::jsonb);
  v_fault text := p->>'fault';
  v_previous vppsone.report_card_issues%rowtype;
  v_current vppsone.report_card_issues%rowtype;
  v_actor_name text;
  v_scheme_row vppsone.report_schemes%rowtype;
  v_latest_scheme uuid;
  v_class uuid;
  v_unsubmitted text[];
  v_moved text[];
  v_revision integer;
  v_id uuid;
begin
  begin
    v_command := (p->>'command_id')::uuid;
    v_actor := (p->>'actor_staff_id')::uuid;
    v_student := (p->>'student_id')::uuid;
    v_scheme := (p->>'scheme_id')::uuid;
    v_expected := coalesce((p->>'expected_revision')::integer, 0);
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end;
  if v_command is null or v_actor is null or v_student is null or v_scheme is null
     or v_session is null or v_term is null or v_hash is null or jsonb_typeof(v_card) is distinct from 'object' then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  perform pg_advisory_xact_lock(hashtext('vppsone:report:' || v_session || ':' || v_term || ':' || v_student::text));

  select * into v_previous from vppsone.report_card_issues where command_id = v_command;
  if found then
    if v_previous.payload_hash = v_hash and v_previous.issued_by = v_actor then
      return jsonb_build_object(
        'ok', true, 'issue_id', v_previous.id, 'revision', v_previous.revision,
        'issued_at', v_previous.issued_at, 'kind', v_previous.kind, 'replayed', true
      );
    end if;
    return jsonb_build_object('ok', false, 'reason', 'id_reused');
  end if;

  -- 1. Releasing a card is the exam office's.
  select display_name into v_actor_name from vppsone.staff_profiles where id = v_actor and is_active;
  if v_actor_name is null or not exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = v_actor and rp.permission = 'assessments:manage'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  -- 2. The approved scheme for this term — the latest one.
  select * into v_scheme_row from vppsone.report_schemes where id = v_scheme;
  select id into v_latest_scheme from vppsone.report_schemes
  where session_label = v_session and term = v_term and status = 'approved'
  order by revision desc limit 1;
  if v_scheme_row.id is null or v_scheme_row.status <> 'approved'
     or v_scheme_row.session_label <> v_session or v_scheme_row.term <> v_term then
    return jsonb_build_object('ok', false, 'reason', 'no_approved_scheme');
  end if;
  if v_latest_scheme is distinct from v_scheme then
    return jsonb_build_object('ok', false, 'reason', 'scheme_changed');
  end if;

  -- 3. Every paper the child's class sat this term has been submitted by its
  -- teacher, and none has moved since the card was worked out.
  select class_id into v_class from vppsone.enrolments
  where student_id = v_student and session_label = v_session;
  if v_class is null then
    return jsonb_build_object('ok', false, 'reason', 'not_enrolled');
  end if;

  select coalesce(array_agg(s.subject_code order by s.subject_code), '{}') into v_unsubmitted
  from vppsone.assessment_subjects s
  join vppsone.assessments a on a.id = s.assessment_id
  where s.class_id = v_class and a.session_label = v_session and a.term = v_term
    and a.status <> 'draft' and s.entry_status <> 'submitted';
  if cardinality(v_unsubmitted) > 0 then
    return jsonb_build_object('ok', false, 'reason', 'papers_not_submitted', 'papers', to_jsonb(v_unsubmitted));
  end if;

  if coalesce((v_card->'totals'->>'missing')::integer, 0) > 0 then
    return jsonb_build_object('ok', false, 'reason', 'incomplete');
  end if;

  select coalesce(array_agg(s.subject_code order by s.subject_code), '{}') into v_moved
  from jsonb_array_elements(coalesce(v_sources->'papers', '[]'::jsonb)) src
  join vppsone.assessment_subjects s on s.id = (src->>'id')::uuid
  where s.entry_revision <> (src->>'entry_revision')::integer;
  if cardinality(v_moved) > 0 then
    return jsonb_build_object('ok', false, 'reason', 'marks_moved', 'papers', to_jsonb(v_moved));
  end if;

  -- 4. The revision the page showed.
  select * into v_current from vppsone.report_card_issues
  where session_label = v_session and term = v_term and student_id = v_student and status = 'issued'
  for update;
  if coalesce(v_current.revision, 0) <> v_expected then
    return jsonb_build_object('ok', false, 'reason', 'stale', 'current_revision', coalesce(v_current.revision, 0));
  end if;
  if v_current.id is not null and v_reason is null then
    return jsonb_build_object('ok', false, 'reason', 'reason_required');
  end if;

  -- 5. Supersede, then issue. The old revision stays, and says what replaced it.
  v_revision := coalesce(v_current.revision, 0) + 1;
  if v_current.id is not null then
    update vppsone.report_card_issues set status = 'superseded' where id = v_current.id;
  end if;

  if v_fault = 'after_supersede' and vppsone.flag_enabled('fault_injection') then
    raise exception 'report_card:injected_fault:after_supersede';
  end if;

  insert into vppsone.report_card_issues (
    session_label, term, student_id, revision, status, card, scheme_id, sources, kind, reason,
    issued_by, supersedes, command_id, payload_hash
  ) values (
    v_session, v_term, v_student, v_revision, 'issued', v_card, v_scheme, v_sources,
    case when v_current.id is null then 'issue' else 'reissue' end, v_reason,
    v_actor, v_current.id, v_command, v_hash
  )
  returning id into v_id;

  return jsonb_build_object(
    'ok', true, 'issue_id', v_id, 'revision', v_revision, 'issued_at', now(),
    'kind', case when v_current.id is null then 'issue' else 'reissue' end,
    'actor_name', v_actor_name, 'replayed', false
  );
end;
$$;

revoke all on function vppsone.issue_report_card(jsonb) from public;
grant execute on function vppsone.issue_report_card(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- What was already issued becomes revision 1, kept as it was
-- ---------------------------------------------------------------------------

insert into vppsone.report_card_issues (
  session_label, term, student_id, revision, status, card, kind, issued_by, issued_at, command_id
)
select session_label, term, student_id, 1, 'issued', payload, 'imported', generated_by, generated_at, gen_random_uuid()
from vppsone.report_cards;

comment on table vppsone.report_cards is
  'Superseded by report_card_issues (P8), which keeps every revision. Kept, not dropped: its rows were imported as revision 1.';

-- ======================================================== migrations/20261004084641_parent_message_policy.sql
-- P9: a message to a parent is approved by a person, against what is true at
-- the moment it goes — and an approval cannot go stale silently.
--
-- D-10 already held the line that matters most: the app never hands a
-- parent-facing message to a provider; a person opens it in their own
-- WhatsApp and presses send. What it did not hold: a message queued on Monday
-- could be sent on Thursday to a number the family had since changed, about a
-- request that had since been corrected, with nothing on the screen to say so;
-- and a wrong number had no way to be marked so it stopped being used.
--
-- The plan (§14): approval on by default; a bounded automatic exception names
-- its category, recipients, content, trigger, correction behaviour and policy
-- version; snapshot what was approved and recheck it at the moment it is sent;
-- a suspect route suppresses future sends, keeps the record and tells an
-- administrator; and never coalesce away a real send.

-- ---------------------------------------------------------------------------
-- The policy, per category
-- ---------------------------------------------------------------------------

create table vppsone.parent_message_policies (
  category text primary key,
  label_hi text not null,
  label_en text not null,
  /** On by default. Off only with every field of the exception filled in. */
  approval_required boolean not null default true,
  auto_recipients text,
  auto_trigger text,
  auto_content text,
  auto_correction text,
  /** Moves on every change; a message approved under an older version is stale. */
  policy_version integer not null default 1,
  updated_by uuid references vppsone.staff_profiles (id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint parent_message_policies_exception_named check (
    approval_required
    or (
      nullif(btrim(auto_recipients), '') is not null
      and nullif(btrim(auto_trigger), '') is not null
      and nullif(btrim(auto_content), '') is not null
      and nullif(btrim(auto_correction), '') is not null
    )
  )
);

comment on table vppsone.parent_message_policies is
  'Whether a person must approve each parent message of a category (the default), or the bounded automatic exception the school named instead. Staff-cover automation authorises nothing here.';

insert into vppsone.parent_message_policies (category, label_hi, label_en) values
  ('collection_request', 'जानकारी/दस्तावेज़ माँगना', 'Asking for details or documents'),
  ('report_delivery', 'रिपोर्ट भेजना', 'Sending a report card'),
  ('absence_notice', 'अनुपस्थिति की सूचना', 'Absence notice'),
  ('general', 'अन्य', 'Anything else');

alter table vppsone.parent_message_policies enable row level security;
create policy parent_message_policies_select_staff
  on vppsone.parent_message_policies for select to authenticated
  using ((select vppsone.is_active_staff()));
grant select on vppsone.parent_message_policies to authenticated;
grant all on vppsone.parent_message_policies to service_role;

-- ---------------------------------------------------------------------------
-- What was approved, and whether it still holds
-- ---------------------------------------------------------------------------

alter table vppsone.message_sends
  add column category text not null default 'general',
  -- No foreign key: message_sends already points at staff_profiles twice, and
  -- a third would be one more relationship every embed has to name.
  add column approved_by uuid,
  add column approved_at timestamptz,
  /** {destination, contact, record, content, policy_version} as they were when queued. */
  add column snapshot jsonb,
  add column stale_at timestamptz,
  add column stale_reason text;

comment on column vppsone.message_sends.snapshot is
  'For a parent message: the destination, the guardian contact on record, the record it is about, a hash of the text and the policy version, as they were when it was queued. Rechecked when it is approved and when it is marked sent.';

-- ---------------------------------------------------------------------------
-- A route somebody has reported as wrong
-- ---------------------------------------------------------------------------

create table vppsone.parent_route_flags (
  id uuid primary key default gen_random_uuid(),
  phone text not null,
  student_id uuid,
  reason text not null,
  flagged_by uuid references vppsone.staff_profiles (id) on delete restrict,
  flagged_at timestamptz not null default now(),
  cleared_by uuid,
  cleared_at timestamptz,
  clear_note text,
  constraint parent_route_flags_reason_says check (btrim(reason) <> ''),
  constraint parent_route_flags_cleared_together check ((cleared_at is null) = (cleared_by is null))
);

comment on table vppsone.parent_route_flags is
  'A parent number somebody said is wrong. While a flag is open nothing is sent to it; clearing one is an administrator''s, with a note. Kept, never deleted.';

create index parent_route_flags_open_idx on vppsone.parent_route_flags (phone) where cleared_at is null;

alter table vppsone.parent_route_flags enable row level security;
create policy parent_route_flags_select_collection
  on vppsone.parent_route_flags for select to authenticated
  using ((select vppsone.staff_can('collection:view')));
grant select on vppsone.parent_route_flags to authenticated;
grant all on vppsone.parent_route_flags to service_role;

-- The switch already exists: `runtime_flags.parent_dispatch`, off. The app
-- hands a parent message to a provider only when it is on *and* the
-- message's category names an automatic exception *and* nothing about the
-- message has gone stale — the rule lives in `mayDispatch()`.

-- ======================================================== migrations/20261004100729_record_writer_and_history.sql
-- P10a: a child's collected values have one writer, every write is kept, and
-- who wins is decided in the database.
--
-- Plan §11: "Collected updates — accepted native overlay with field
-- provenance", and P10's "accepted precedence; one writer per entity".
--
-- Before this, accepting an answer was two statements from the app: mark the
-- submissions accepted, then upsert `student_records` for every row it had
-- *read* — so two people deciding at once could both write, an older answer
-- could overwrite a newer decision without anybody choosing to, and the
-- value a record held before was simply gone.
--
-- Now:
--
--   * `vppsone.write_student_value()` is the one function that writes a
--     value. It applies precedence (a person's value is never replaced by an
--     import; an import may correct only what it wrote itself) and appends
--     to `student_record_history`, whatever the outcome.
--   * `vppsone.accept_submissions()` is the one command that decides
--     answers: atomic, idempotent per command id, re-checking authority, and
--     refusing — not silently doing — the two dangerous cases: an answer
--     with a newer one waiting behind it, and an answer about a value that
--     has moved since the teacher was shown it.

-- ---------------------------------------------------------------------------
-- Where a held value came from, more precisely than teacher/office/import
-- ---------------------------------------------------------------------------

alter table vppsone.student_records
  -- Which import: 'sampark', 'psp'… Null for a person's value. An import may
  -- correct what the same import wrote, and nothing else.
  add column source_detail text,
  -- What, exactly: 'submission:<id>', 'sampark:<batch>:<row>'.
  add column source_ref text;

-- ---------------------------------------------------------------------------
-- Every write, kept
-- ---------------------------------------------------------------------------

create table vppsone.student_record_history (
  id bigint generated always as identity primary key,
  -- No foreign keys to the child or the field: the history outlives both,
  -- and the fee app's students are never referenced (rule 2, D-5).
  student_id uuid not null,
  field_id uuid not null,
  session_label text not null,
  outcome text not null,
  reason text,
  old_value text,
  new_value text,
  old_source vppsone.record_source,
  old_source_detail text,
  source vppsone.record_source not null,
  source_detail text,
  source_ref text,
  submission_id uuid,
  command_id uuid not null,
  actor_staff_id uuid,
  recorded_at timestamptz not null default now(),
  constraint student_record_history_outcome check (outcome in ('written', 'blocked')),
  constraint student_record_history_blocked_says_why check (outcome <> 'blocked' or reason is not null)
);

comment on table vppsone.student_record_history is
  'Every write to student_records and every value precedence refused, with where it came from. Append-only.';

create index student_record_history_student_idx
  on vppsone.student_record_history (student_id, field_id, recorded_at desc);

create or replace function vppsone.student_record_history_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'student_record_history is append-only' using errcode = '42501';
end;
$$;

create trigger student_record_history_append_only
  before update or delete on vppsone.student_record_history
  for each row execute function vppsone.student_record_history_append_only();

alter table vppsone.student_record_history enable row level security;
create policy student_record_history_select_scoped
  on vppsone.student_record_history for select to authenticated
  using (
    (select vppsone.staff_can_any(array['collection:view', 'students:view']))
    and (
      (select vppsone.reads_every_class())
      or exists (
        select 1 from vppsone.enrolments e
        where e.student_id = student_record_history.student_id
          and e.session_label = student_record_history.session_label
      )
    )
  );
grant select on vppsone.student_record_history to authenticated;
grant select, insert on vppsone.student_record_history to service_role;

-- What the record held before anybody kept a history: one row each, so every
-- value has somewhere it came from.
insert into vppsone.student_record_history (
  student_id, field_id, session_label, outcome, reason, new_value,
  source, source_detail, source_ref, submission_id, command_id, actor_staff_id, recorded_at
)
select
  r.student_id, r.field_id, r.session_label, 'written', 'held_before_history', r.value,
  r.source, r.source_detail, coalesce(r.source_ref, 'submission:' || r.source_submission_id::text),
  r.source_submission_id, '00000000-0000-0000-0000-00000000a10a'::uuid, r.recorded_by, r.updated_at
from vppsone.student_records r;

-- ---------------------------------------------------------------------------
-- Commands, for replay
-- ---------------------------------------------------------------------------

create table vppsone.record_commands (
  command_id uuid primary key,
  kind text not null,
  actor_staff_id uuid not null,
  payload_hash text not null,
  receipt jsonb not null,
  created_at timestamptz not null default now(),
  constraint record_commands_kind check (kind in ('accept', 'reject', 'import'))
);

comment on table vppsone.record_commands is
  'One row per decision or import command: a repeated submission of the same id returns this receipt instead of acting twice.';

alter table vppsone.record_commands enable row level security;
grant all on vppsone.record_commands to service_role;

-- ---------------------------------------------------------------------------
-- The one writer
-- ---------------------------------------------------------------------------

create or replace function vppsone.write_student_value(
  p_student uuid,
  p_field uuid,
  p_session text,
  p_value text,
  p_source vppsone.record_source,
  p_source_detail text,
  p_source_ref text,
  p_submission uuid,
  p_command uuid,
  p_actor uuid
)
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_held vppsone.student_records%rowtype;
  v_human boolean := p_source in ('teacher', 'office');
  v_reason text;
begin
  select * into v_held from vppsone.student_records
  where student_id = p_student and field_id = p_field
  for update;

  if not found then
    insert into vppsone.student_records (
      session_label, student_id, field_id, value, source, source_detail, source_ref,
      source_submission_id, recorded_by
    ) values (
      p_session, p_student, p_field, p_value, p_source, p_source_detail, p_source_ref,
      p_submission, p_actor
    );
    insert into vppsone.student_record_history (
      student_id, field_id, session_label, outcome, new_value, source, source_detail,
      source_ref, submission_id, command_id, actor_staff_id
    ) values (
      p_student, p_field, p_session, 'written', p_value, p_source, p_source_detail,
      p_source_ref, p_submission, p_command, p_actor
    );
    return 'written';
  end if;

  -- Precedence. A person's value is never replaced by an import. An import
  -- may correct what the same import wrote, and nothing else. A person
  -- replaces anything — whether they may replace a *newer* decision is the
  -- calling command's question, asked before this.
  if not v_human then
    if v_held.source in ('teacher', 'office') then
      v_reason := 'human_value';
    elsif v_held.source is distinct from p_source
       or v_held.source_detail is distinct from p_source_detail then
      v_reason := 'other_source';
    end if;
  end if;

  if v_reason is not null then
    if v_held.value is distinct from p_value then
      insert into vppsone.student_record_history (
        student_id, field_id, session_label, outcome, reason, old_value, new_value,
        old_source, old_source_detail, source, source_detail, source_ref, submission_id,
        command_id, actor_staff_id
      ) values (
        p_student, p_field, p_session, 'blocked', v_reason, v_held.value, p_value,
        v_held.source, v_held.source_detail, p_source, p_source_detail, p_source_ref,
        p_submission, p_command, p_actor
      );
    end if;
    return 'blocked:' || v_reason;
  end if;

  -- The same value from the same kind of source is nothing to write. The same
  -- value confirmed by a person over an import's is: it is now a person's,
  -- and the next import may not replace it.
  if v_held.value is not distinct from p_value
     and (not v_human or v_held.source in ('teacher', 'office')) then
    return 'unchanged';
  end if;

  update vppsone.student_records set
    session_label = p_session,
    value = p_value,
    source = p_source,
    source_detail = p_source_detail,
    source_ref = p_source_ref,
    source_submission_id = p_submission,
    recorded_by = p_actor
  where id = v_held.id;

  insert into vppsone.student_record_history (
    student_id, field_id, session_label, outcome, reason, old_value, new_value,
    old_source, old_source_detail, source, source_detail, source_ref, submission_id,
    command_id, actor_staff_id
  ) values (
    p_student, p_field, p_session, 'written',
    case when v_held.value is not distinct from p_value then 'confirmed_by_person' end,
    v_held.value, p_value, v_held.source, v_held.source_detail, p_source, p_source_detail,
    p_source_ref, p_submission, p_command, p_actor
  );
  return 'written';
end;
$$;

comment on function vppsone.write_student_value is
  'The only writer of student_records. Applies precedence and appends to student_record_history. Called by accept_submissions and the import command, never by the app directly.';

revoke all on function vppsone.write_student_value(uuid, uuid, text, text, vppsone.record_source, text, text, uuid, uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Deciding answers
-- ---------------------------------------------------------------------------

create or replace function vppsone.accept_submissions(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_command uuid;
  v_actor uuid;
  v_session text := p->>'session_label';
  v_decision text := p->>'decision';
  v_note text := nullif(btrim(coalesce(p->>'note', '')), '');
  v_replace boolean := coalesce((p->>'replace_newer')::boolean, false);
  v_hash text := p->>'payload_hash';
  v_fault text := p->>'fault';
  v_ids uuid[];
  v_previous vppsone.record_commands%rowtype;
  v_row record;
  v_value text;
  v_held text;
  v_outcome text;
  v_decided integer := 0;
  v_recorded integer := 0;
  v_confirmed integer := 0;
  v_already integer := 0;
  v_refused jsonb := '[]'::jsonb;
  v_receipt jsonb;
begin
  begin
    v_command := (p->>'command_id')::uuid;
    v_actor := (p->>'actor_staff_id')::uuid;
    select coalesce(array_agg(value::uuid), '{}') into v_ids
    from jsonb_array_elements_text(coalesce(p->'submission_ids', '[]'::jsonb));
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end;
  if v_command is null or v_actor is null or v_session is null or v_hash is null
     or v_decision not in ('accept', 'reject') or cardinality(v_ids) = 0 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  perform pg_advisory_xact_lock(hashtext('vppsone:record-command:' || v_command::text));

  select * into v_previous from vppsone.record_commands where command_id = v_command;
  if found then
    if v_previous.payload_hash = v_hash and v_previous.actor_staff_id = v_actor then
      return v_previous.receipt || jsonb_build_object('replayed', true);
    end if;
    return jsonb_build_object('ok', false, 'reason', 'id_reused');
  end if;

  -- Deciding answers is the office's: collection:manage, re-read now.
  if not exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = v_actor and sp.is_active and rp.permission = 'collection:manage'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  for v_row in
    select s.*
    from vppsone.collection_submissions s
    where s.id = any(v_ids)
    order by s.submitted_at, s.id
    for update
  loop
    -- Somebody else decided it first. Theirs stands; nothing is written twice.
    if v_row.status <> 'pending' then
      v_already := v_already + 1;
      continue;
    end if;

    if v_decision = 'reject' then
      update vppsone.collection_submissions
      set status = 'rejected', decided_by = v_actor, decided_at = now(), decision_note = v_note
      where id = v_row.id;
      v_decided := v_decided + 1;
      continue;
    end if;

    -- A newer answer for the same child and field is waiting: accepting this
    -- one would put an older answer on the record. Refused, not guessed.
    if exists (
      select 1 from vppsone.collection_submissions n
      where n.student_id = v_row.student_id and n.field_id = v_row.field_id
        and n.id <> v_row.id and n.status = 'pending'
        and (n.submitted_at, n.id) > (v_row.submitted_at, v_row.id)
    ) then
      v_refused := v_refused || jsonb_build_object('submission_id', v_row.id, 'reason', 'superseded');
      continue;
    end if;

    v_value := nullif(btrim(coalesce(v_row.value, '')), '');

    -- Blank means "no change": accepted as a confirmation, nothing written.
    if v_value is null then
      update vppsone.collection_submissions
      set status = 'accepted', decided_by = v_actor, decided_at = now(), decision_note = v_note
      where id = v_row.id;
      v_decided := v_decided + 1;
      v_confirmed := v_confirmed + 1;
      continue;
    end if;

    -- The record moved after she was shown it, to something other than her
    -- answer: accepting would quietly revert whoever moved it. Only a person
    -- who has seen both, and says so, replaces it (S-07).
    select nullif(btrim(coalesce(r.value, '')), '') into v_held
    from vppsone.student_records r
    where r.student_id = v_row.student_id and r.field_id = v_row.field_id;
    if v_held is not null
       and v_held is distinct from nullif(btrim(coalesce(v_row.previous_value, '')), '')
       and v_held is distinct from v_value
       and not v_replace then
      v_refused := v_refused || jsonb_build_object('submission_id', v_row.id, 'reason', 'record_moved');
      continue;
    end if;

    v_outcome := vppsone.write_student_value(
      v_row.student_id, v_row.field_id, v_session, v_value, 'teacher', null,
      'submission:' || v_row.id::text, v_row.id, v_command, v_actor
    );

    update vppsone.collection_submissions
    set status = 'accepted', decided_by = v_actor, decided_at = now(), decision_note = v_note
    where id = v_row.id;
    v_decided := v_decided + 1;
    if v_outcome = 'written' then
      v_recorded := v_recorded + 1;
    else
      v_confirmed := v_confirmed + 1;
    end if;

    if v_fault = 'after_first_write' and vppsone.flag_enabled('fault_injection') then
      raise exception 'fault injected after the first write';
    end if;
  end loop;

  v_receipt := jsonb_build_object(
    'ok', true,
    'command_id', v_command,
    'decision', v_decision,
    'decided', v_decided,
    'recorded', v_recorded,
    'confirmed', v_confirmed,
    'already_decided', v_already,
    'refused', v_refused
  );

  insert into vppsone.record_commands (command_id, kind, actor_staff_id, payload_hash, receipt)
  values (v_command, v_decision, v_actor, v_hash, v_receipt);

  return v_receipt;
end;
$$;

comment on function vppsone.accept_submissions is
  'Accept or reject collected answers in one transaction: authority re-checked, a newer waiting answer or a moved record refused unless replace_newer, every write through write_student_value. Idempotent per command_id.';

revoke all on function vppsone.accept_submissions(jsonb) from public, anon, authenticated;
grant execute on function vppsone.accept_submissions(jsonb) to service_role;

-- ======================================================== migrations/20261004101241_record_history_qa_cleanup.sql
-- P10a follow-up: the one exception to an append-only history, said here.
--
-- The tests and `verify:records` drive the real decision command against a
-- synthetic field whose key starts `qa_`, and must be able to remove what
-- they made — the same exception P8 made for `QA-` report terms (D-227).
-- Every other history row stays undeletable and nothing is ever updated.

create or replace function vppsone.student_record_history_append_only()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and exists (
    select 1 from vppsone.collection_fields f
    where f.id = old.field_id and f.key like 'qa\_%'
  ) then
    return old;
  end if;
  raise exception 'student_record_history is append-only' using errcode = '42501';
end;
$$;

grant delete on vppsone.student_record_history to service_role;

-- ======================================================== migrations/20261004113510_sampark_import.sql
-- P10b: SamPark's records come in through the one writer, and a row nobody
-- can identify waits for a person.
--
-- Plan §11, identity reconciliation: "resolve as a multimap: matched,
-- ambiguous and unmatched. Never join pupils by name or shared phone alone.
-- Preserve … source field precedence." P10: "ambiguity queue, accepted
-- precedence and legacy links".
--
-- The office exports SamPark's Students workbook and uploads it. The app
-- reads it, resolves each row by ids alone (`domain/sampark-import.ts`) and
-- stages the file here: one batch, one row per spreadsheet row, with what the
-- row says, the values it carries (already validated) and how its identity
-- resolved. Nothing is written to a child's record by staging.
--
-- Applying is a command. For each matched row it records the mapping in
-- `external_student_ids` — which is what makes SamPark's own links to a
-- child resolve (S-10) — and offers each value to `write_student_value()` as
-- an import from SamPark, where precedence keeps anything a person recorded.
-- An ambiguous or unmatched row is the queue: an office member picks the
-- child, or dismisses the row with a reason, and only then is it applied.

create table vppsone.sampark_import_batches (
  id uuid primary key default gen_random_uuid(),
  file_name text not null,
  file_sha256 text not null,
  -- Which dataset the children were matched in (S-10): a mapping made on dev
  -- says nothing about a child on live.
  source_environment text not null,
  session_label text not null,
  row_count integer not null,
  mapped_fields text[] not null default '{}',
  ignored_headers text[] not null default '{}',
  uploaded_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  uploaded_at timestamptz not null default now(),
  -- The same file twice is the same batch: uploading again resumes it.
  constraint sampark_import_batches_one_per_file unique (source_environment, file_sha256)
);

comment on table vppsone.sampark_import_batches is
  'One uploaded SamPark Students workbook. Re-uploading the same file resumes the same batch.';

create table vppsone.sampark_import_rows (
  batch_id uuid not null references vppsone.sampark_import_batches (id) on delete cascade,
  row_no integer not null,
  external_id text,
  -- What the row says about who it is: {sr, admission, name, class}. Shown to
  -- the person resolving it; never used to decide it.
  presented jsonb not null default '{}',
  -- field key → value, already validated and normalised.
  field_values jsonb not null default '{}',
  -- Cells that did not validate: [{field, value, message}]. Not written.
  problems jsonb not null default '[]',
  resolution text not null,
  why text,
  matched_on text,
  student_id uuid,
  candidates uuid[] not null default '{}',
  applied_at timestamptz,
  outcome jsonb,
  decided_by uuid,
  decided_at timestamptz,
  decision_note text,
  primary key (batch_id, row_no),
  constraint sampark_import_rows_resolution check (resolution in ('matched', 'ambiguous', 'unmatched', 'resolved', 'dismissed')),
  constraint sampark_import_rows_child_when_known check (
    (resolution in ('matched', 'resolved')) = (student_id is not null)
  ),
  constraint sampark_import_rows_dismissal_says_why check (
    resolution <> 'dismissed' or nullif(btrim(decision_note), '') is not null
  )
);

comment on table vppsone.sampark_import_rows is
  'Each row of an uploaded SamPark workbook: who it resolved to (by ids only), its values, and whether it has been applied. Ambiguous and unmatched rows are the identity queue.';

create index sampark_import_rows_queue_idx
  on vppsone.sampark_import_rows (batch_id) where resolution in ('ambiguous', 'unmatched');

alter table vppsone.sampark_import_batches enable row level security;
alter table vppsone.sampark_import_rows enable row level security;
create policy sampark_import_batches_select_office
  on vppsone.sampark_import_batches for select to authenticated
  using ((select vppsone.staff_can('collection:manage')));
create policy sampark_import_rows_select_office
  on vppsone.sampark_import_rows for select to authenticated
  using ((select vppsone.staff_can('collection:manage')));
grant select on vppsone.sampark_import_batches, vppsone.sampark_import_rows to authenticated;
grant all on vppsone.sampark_import_batches, vppsone.sampark_import_rows to service_role;

alter table vppsone.record_commands drop constraint record_commands_kind;
alter table vppsone.record_commands add constraint record_commands_kind
  check (kind in ('accept', 'reject', 'import', 'resolve'));

-- ---------------------------------------------------------------------------
-- Applying one row
-- ---------------------------------------------------------------------------

create or replace function vppsone.apply_sampark_row(p_batch uuid, p_row integer, p_command uuid, p_actor uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_row vppsone.sampark_import_rows%rowtype;
  v_batch vppsone.sampark_import_batches%rowtype;
  v_mapped uuid;
  v_other text;
  v_field uuid;
  v_key text;
  v_value text;
  v_outcome text;
  v_written integer := 0;
  v_unchanged integer := 0;
  v_kept_person integer := 0;
  v_kept_other integer := 0;
  v_no_field integer := 0;
  v_result jsonb;
begin
  select * into v_row from vppsone.sampark_import_rows
  where batch_id = p_batch and row_no = p_row
  for update;
  if not found then
    return jsonb_build_object('applied', false, 'reason', 'no_such_row');
  end if;
  if v_row.applied_at is not null then
    return coalesce(v_row.outcome, '{}'::jsonb) || jsonb_build_object('applied', false, 'reason', 'already_applied');
  end if;
  if v_row.resolution not in ('matched', 'resolved') then
    return jsonb_build_object('applied', false, 'reason', 'not_resolved');
  end if;
  select * into v_batch from vppsone.sampark_import_batches where id = p_batch;

  -- The child is still on the fee record (read only; rule 2).
  if not exists (select 1 from public.students s where s.id = v_row.student_id) then
    update vppsone.sampark_import_rows
    set resolution = 'unmatched', why = 'no_such_child', student_id = null, matched_on = null
    where batch_id = p_batch and row_no = p_row;
    return jsonb_build_object('applied', false, 'reason', 'no_such_child');
  end if;

  -- The mapping, which must agree with every earlier one in both directions.
  -- A disagreement goes back to the queue with both children named.
  if v_row.external_id is not null then
    select student_id into v_mapped from vppsone.external_student_ids
    where app_id = 'sampark' and external_id = v_row.external_id;
    if v_mapped is not null and v_mapped <> v_row.student_id then
      update vppsone.sampark_import_rows
      set resolution = 'ambiguous', why = 'ids_disagree', candidates = array[v_mapped, v_row.student_id],
          student_id = null, matched_on = null
      where batch_id = p_batch and row_no = p_row;
      return jsonb_build_object('applied', false, 'reason', 'mapping_conflict');
    end if;

    select external_id into v_other from vppsone.external_student_ids
    where app_id = 'sampark' and source_environment = v_batch.source_environment
      and student_id = v_row.student_id;
    if v_other is not null and v_other <> v_row.external_id then
      update vppsone.sampark_import_rows
      set resolution = 'ambiguous', why = 'child_mapped_elsewhere', candidates = array[v_row.student_id],
          student_id = null, matched_on = null
      where batch_id = p_batch and row_no = p_row;
      return jsonb_build_object('applied', false, 'reason', 'child_mapped_elsewhere');
    end if;

    if v_mapped is null then
      insert into vppsone.external_student_ids (
        app_id, external_id, student_id, source_environment, matched_on, note, created_by
      ) values (
        'sampark', v_row.external_id, v_row.student_id, v_batch.source_environment,
        coalesce(v_row.matched_on, 'hand'),
        'SamPark import ' || p_batch::text || ', row ' || p_row::text,
        (select user_id from vppsone.staff_profiles where id = p_actor)
      );
    end if;
  end if;

  -- Every value through the one writer, as an import from SamPark.
  for v_key, v_value in select key, value from jsonb_each_text(v_row.field_values) loop
    if nullif(btrim(coalesce(v_value, '')), '') is null then
      continue;
    end if;
    select id into v_field from vppsone.collection_fields where key = v_key and is_active;
    if v_field is null then
      v_no_field := v_no_field + 1;
      continue;
    end if;
    v_outcome := vppsone.write_student_value(
      v_row.student_id, v_field, v_batch.session_label, v_value, 'import', 'sampark',
      'sampark:' || p_batch::text || ':' || p_row::text, null, p_command, p_actor
    );
    if v_outcome = 'written' then
      v_written := v_written + 1;
    elsif v_outcome = 'unchanged' then
      v_unchanged := v_unchanged + 1;
    elsif v_outcome = 'blocked:human_value' then
      v_kept_person := v_kept_person + 1;
    else
      v_kept_other := v_kept_other + 1;
    end if;
    v_field := null;
  end loop;

  v_result := jsonb_build_object(
    'applied', true,
    'written', v_written,
    'unchanged', v_unchanged,
    'kept_person', v_kept_person,
    'kept_other_import', v_kept_other,
    'no_field', v_no_field
  );
  update vppsone.sampark_import_rows
  set applied_at = now(), outcome = v_result
  where batch_id = p_batch and row_no = p_row;
  return v_result;
end;
$$;

revoke all on function vppsone.apply_sampark_row(uuid, integer, uuid, uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Applying every matched row of a batch
-- ---------------------------------------------------------------------------

create or replace function vppsone.apply_sampark_import(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_command uuid;
  v_actor uuid;
  v_batch uuid;
  v_hash text := p->>'payload_hash';
  v_fault text := p->>'fault';
  v_previous vppsone.record_commands%rowtype;
  v_row record;
  v_result jsonb;
  v_rows integer := 0;
  v_written integer := 0;
  v_unchanged integer := 0;
  v_kept_person integer := 0;
  v_kept_other integer := 0;
  v_conflicts integer := 0;
  v_receipt jsonb;
begin
  begin
    v_command := (p->>'command_id')::uuid;
    v_actor := (p->>'actor_staff_id')::uuid;
    v_batch := (p->>'batch_id')::uuid;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end;
  if v_command is null or v_actor is null or v_batch is null or v_hash is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  perform pg_advisory_xact_lock(hashtext('vppsone:record-command:' || v_command::text));
  select * into v_previous from vppsone.record_commands where command_id = v_command;
  if found then
    if v_previous.payload_hash = v_hash and v_previous.actor_staff_id = v_actor then
      return v_previous.receipt || jsonb_build_object('replayed', true);
    end if;
    return jsonb_build_object('ok', false, 'reason', 'id_reused');
  end if;

  if not exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = v_actor and sp.is_active and rp.permission = 'collection:manage'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;
  if not exists (select 1 from vppsone.sampark_import_batches where id = v_batch) then
    return jsonb_build_object('ok', false, 'reason', 'no_such_batch');
  end if;

  -- One application of a batch at a time.
  perform pg_advisory_xact_lock(hashtext('vppsone:sampark-batch:' || v_batch::text));

  for v_row in
    select row_no from vppsone.sampark_import_rows
    where batch_id = v_batch and resolution in ('matched', 'resolved') and applied_at is null
    order by row_no
  loop
    v_result := vppsone.apply_sampark_row(v_batch, v_row.row_no, v_command, v_actor);
    if (v_result->>'applied')::boolean then
      v_rows := v_rows + 1;
      v_written := v_written + (v_result->>'written')::integer;
      v_unchanged := v_unchanged + (v_result->>'unchanged')::integer;
      v_kept_person := v_kept_person + (v_result->>'kept_person')::integer;
      v_kept_other := v_kept_other + (v_result->>'kept_other_import')::integer;
    elsif v_result->>'reason' in ('mapping_conflict', 'child_mapped_elsewhere', 'no_such_child') then
      v_conflicts := v_conflicts + 1;
    end if;

    if v_fault = 'after_first_row' and vppsone.flag_enabled('fault_injection') then
      raise exception 'fault injected after the first row';
    end if;
  end loop;

  v_receipt := jsonb_build_object(
    'ok', true,
    'command_id', v_command,
    'rows_applied', v_rows,
    'written', v_written,
    'unchanged', v_unchanged,
    'kept_person', v_kept_person,
    'kept_other_import', v_kept_other,
    'sent_back_to_queue', v_conflicts
  );
  insert into vppsone.record_commands (command_id, kind, actor_staff_id, payload_hash, receipt)
  values (v_command, 'import', v_actor, v_hash, v_receipt);
  return v_receipt;
end;
$$;

revoke all on function vppsone.apply_sampark_import(jsonb) from public, anon, authenticated;
grant execute on function vppsone.apply_sampark_import(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- The queue: a person picks the child, or says why nobody
-- ---------------------------------------------------------------------------

create or replace function vppsone.resolve_sampark_row(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_command uuid;
  v_actor uuid;
  v_batch uuid;
  v_row_no integer;
  v_student uuid;
  v_dismiss boolean := coalesce((p->>'dismiss')::boolean, false);
  v_note text := nullif(btrim(coalesce(p->>'note', '')), '');
  v_hash text := p->>'payload_hash';
  v_previous vppsone.record_commands%rowtype;
  v_row vppsone.sampark_import_rows%rowtype;
  v_result jsonb;
  v_receipt jsonb;
begin
  begin
    v_command := (p->>'command_id')::uuid;
    v_actor := (p->>'actor_staff_id')::uuid;
    v_batch := (p->>'batch_id')::uuid;
    v_row_no := (p->>'row_no')::integer;
    v_student := nullif(p->>'student_id', '')::uuid;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end;
  if v_command is null or v_actor is null or v_batch is null or v_row_no is null or v_hash is null
     or (v_dismiss and v_student is not null) or (not v_dismiss and v_student is null) then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  perform pg_advisory_xact_lock(hashtext('vppsone:record-command:' || v_command::text));
  select * into v_previous from vppsone.record_commands where command_id = v_command;
  if found then
    if v_previous.payload_hash = v_hash and v_previous.actor_staff_id = v_actor then
      return v_previous.receipt || jsonb_build_object('replayed', true);
    end if;
    return jsonb_build_object('ok', false, 'reason', 'id_reused');
  end if;

  if not exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = v_actor and sp.is_active and rp.permission = 'collection:manage'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  perform pg_advisory_xact_lock(hashtext('vppsone:sampark-batch:' || v_batch::text));
  select * into v_row from vppsone.sampark_import_rows
  where batch_id = v_batch and row_no = v_row_no
  for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no_such_row');
  end if;
  -- Only a row in the queue is decided here; one somebody else decided stands.
  if v_row.resolution not in ('ambiguous', 'unmatched') then
    return jsonb_build_object('ok', false, 'reason', 'already_decided', 'resolution', v_row.resolution);
  end if;

  if v_dismiss then
    if v_note is null then
      return jsonb_build_object('ok', false, 'reason', 'reason_required');
    end if;
    update vppsone.sampark_import_rows
    set resolution = 'dismissed', decided_by = v_actor, decided_at = now(), decision_note = v_note
    where batch_id = v_batch and row_no = v_row_no;
    v_receipt := jsonb_build_object('ok', true, 'command_id', v_command, 'resolution', 'dismissed');
  else
    if not exists (select 1 from public.students s where s.id = v_student) then
      return jsonb_build_object('ok', false, 'reason', 'no_such_child');
    end if;
    update vppsone.sampark_import_rows
    set resolution = 'resolved', student_id = v_student, matched_on = 'hand',
        decided_by = v_actor, decided_at = now(), decision_note = v_note
    where batch_id = v_batch and row_no = v_row_no;
    v_result := vppsone.apply_sampark_row(v_batch, v_row_no, v_command, v_actor);
    v_receipt := jsonb_build_object('ok', true, 'command_id', v_command, 'resolution', 'resolved') || v_result;
  end if;

  insert into vppsone.record_commands (command_id, kind, actor_staff_id, payload_hash, receipt)
  values (v_command, 'resolve', v_actor, v_hash, v_receipt);
  return v_receipt;
end;
$$;

revoke all on function vppsone.resolve_sampark_row(jsonb) from public, anon, authenticated;
grant execute on function vppsone.resolve_sampark_row(jsonb) to service_role;

-- ======================================================== migrations/20261004121311_student_photos.sql
-- P10c: a child's photograph, placed by the office — by camera, one at a
-- time, or a whole folder matched by filename — and never silently replaced.
--
-- SamPark parity S-11: camera/file selection, retake/replace, owner mapping,
-- progress, a missing-photo view and office batch placement by filename.
-- The photograph is VPPS One's own record. The fee app's
-- `public.students.photo_path` is not read or written here (rule 2).
--
-- Bytes live in a private bucket and are served through short-lived signed
-- URLs minted after a permission check, like documents. Database backups do
-- not include Storage objects (plan §18), which is why the archive manifest
-- (P11) checksums these separately.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('vppsone-photos', 'vppsone-photos', false, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create table vppsone.student_photos (
  id uuid primary key default gen_random_uuid(),
  -- `public.students.id`, with no foreign key (rule 2, D-5).
  student_id uuid not null,
  session_label text not null,
  storage_path text not null unique,
  content_type text not null,
  byte_size integer not null,
  sha256 text not null,
  width integer,
  height integer,
  -- 'camera' (taken on this device), 'file' (chosen one at a time),
  -- 'folder' (placed from a batch by filename, or by a person from the tray).
  source text not null,
  -- The filename it arrived as, for a folder; kept because a wrong placement
  -- is found by asking where a photograph came from.
  source_ref text,
  command_id uuid not null unique,
  uploaded_by uuid not null references vppsone.staff_profiles (id) on delete restrict,
  uploaded_at timestamptz not null default now(),
  -- A replaced photograph is kept and says what replaced it.
  replaced_by uuid references vppsone.student_photos (id) deferrable initially deferred,
  replaced_at timestamptz,
  constraint student_photos_size check (byte_size between 1 and 2097152),
  constraint student_photos_type check (content_type in ('image/jpeg', 'image/png', 'image/webp')),
  constraint student_photos_source check (source in ('camera', 'file', 'folder')),
  constraint student_photos_replaced_together check ((replaced_by is null) = (replaced_at is null))
);

comment on table vppsone.student_photos is
  'Photographs of children, VPPS One''s own. One current per child; a replaced one is kept with what replaced it. Bytes are in the private vppsone-photos bucket.';

create unique index student_photos_one_current
  on vppsone.student_photos (student_id) where replaced_at is null;

alter table vppsone.student_photos enable row level security;
create policy student_photos_select_scoped
  on vppsone.student_photos for select to authenticated
  using (
    (select vppsone.staff_can_any(array['collection:view', 'students:view']))
    and (
      (select vppsone.reads_every_class())
      or exists (
        select 1 from vppsone.enrolments e
        where e.student_id = student_photos.student_id
          and e.session_label = student_photos.session_label
      )
    )
  );
grant select on vppsone.student_photos to authenticated;
grant all on vppsone.student_photos to service_role;

alter table vppsone.record_commands drop constraint record_commands_kind;
alter table vppsone.record_commands add constraint record_commands_kind
  check (kind in ('accept', 'reject', 'import', 'resolve', 'photo'));

-- ---------------------------------------------------------------------------
-- Placing a photograph
-- ---------------------------------------------------------------------------

create or replace function vppsone.place_student_photo(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_command uuid;
  v_actor uuid;
  v_student uuid;
  v_expected uuid;
  v_hash text := p->>'payload_hash';
  v_previous vppsone.record_commands%rowtype;
  v_current vppsone.student_photos%rowtype;
  v_id uuid;
  v_receipt jsonb;
begin
  begin
    v_command := (p->>'command_id')::uuid;
    v_actor := (p->>'actor_staff_id')::uuid;
    v_student := (p->>'student_id')::uuid;
    v_expected := nullif(p->>'expected_current', '')::uuid;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end;
  if v_command is null or v_actor is null or v_student is null or v_hash is null
     or p->>'storage_path' is null or p->>'sha256' is null or p->>'session_label' is null then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  perform pg_advisory_xact_lock(hashtext('vppsone:record-command:' || v_command::text));
  select * into v_previous from vppsone.record_commands where command_id = v_command;
  if found then
    if v_previous.payload_hash = v_hash and v_previous.actor_staff_id = v_actor then
      return v_previous.receipt || jsonb_build_object('replayed', true);
    end if;
    return jsonb_build_object('ok', false, 'reason', 'id_reused');
  end if;

  if not exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = v_actor and sp.is_active and rp.permission = 'collection:manage'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;
  if not exists (select 1 from public.students s where s.id = v_student) then
    return jsonb_build_object('ok', false, 'reason', 'no_such_child');
  end if;

  -- One child's photographs at a time.
  perform pg_advisory_xact_lock(hashtext('vppsone:photo:' || v_student::text));
  select * into v_current from vppsone.student_photos
  where student_id = v_student and replaced_at is null;

  -- The screen said which photograph it was replacing (or none). If that has
  -- moved — somebody else placed one meanwhile — this one is not put on top
  -- of theirs unseen.
  if v_current.id is distinct from v_expected then
    return jsonb_build_object('ok', false, 'reason', 'stale', 'current', v_current.id);
  end if;

  -- The old photograph is marked replaced first — a unique index is checked
  -- row by row, so two current for a moment is not allowed even inside one
  -- transaction — pointing at the new one by an id minted here; the pointer
  -- is checked at commit. Nobody ever sees a child with two current or none.
  v_id := gen_random_uuid();
  if v_current.id is not null then
    update vppsone.student_photos set replaced_by = v_id, replaced_at = now()
    where id = v_current.id;
  end if;

  insert into vppsone.student_photos (
    id, student_id, session_label, storage_path, content_type, byte_size, sha256, width, height,
    source, source_ref, command_id, uploaded_by
  ) values (
    v_id, v_student, p->>'session_label', p->>'storage_path', p->>'content_type', (p->>'byte_size')::integer,
    p->>'sha256', nullif(p->>'width', '')::integer, nullif(p->>'height', '')::integer,
    p->>'source', nullif(p->>'source_ref', ''), v_command, v_actor
  );

  v_receipt := jsonb_build_object(
    'ok', true, 'command_id', v_command, 'photo_id', v_id, 'replaced', v_current.id
  );
  insert into vppsone.record_commands (command_id, kind, actor_staff_id, payload_hash, receipt)
  values (v_command, 'photo', v_actor, v_hash, v_receipt);
  return v_receipt;
end;
$$;

revoke all on function vppsone.place_student_photo(jsonb) from public, anon, authenticated;
grant execute on function vppsone.place_student_photo(jsonb) to service_role;

-- ======================================================== migrations/20261004123341_export_kinds_for_workbooks.sql
-- P10d: the student and round workbooks are logged where every other export
-- is — who took what, and when (`academic_exports`).

alter type vppsone.export_kind add value if not exists 'students';
alter type vppsone.export_kind add value if not exists 'round';
