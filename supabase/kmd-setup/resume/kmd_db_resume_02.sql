-- KMD One database setup — kmd_db_resume_ 2 of 5. Run in order, each once.
-- Files: 20261103031956_school_office_certificate_kinds.sql … 20261107045020_ai_report_export_kind.sql

-- ======================================================== migrations/20261103031956_school_office_certificate_kinds.sql
-- School Office, second pass: several school document kinds, each with its own
-- approved template, series and reprint-first rule; a verification code frozen
-- into every new issue; and a minimal public check. No financial mutation.
begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

-- Kinds the school issues itself. A TC is a document kind here; changing a
-- student's status to left stays with the existing leaving workflow.
alter table vppsone.school_certificate_templates
  add column kind text not null default 'study' check (kind in ('study','character','dob','tc'));
alter table vppsone.school_certificate_templates
  add constraint school_certificate_template_kind_matches check (coalesce(template->>'kind','study')=kind);
drop index vppsone.school_certificate_template_active;
create unique index school_certificate_template_active_kind on vppsone.school_certificate_templates(kind) where active;

alter table vppsone.school_certificate_issues
  add column kind text not null default 'study' check (kind in ('study','character','dob','tc')),
  add column verify_code text generated always as (snapshot->>'verifyCode') stored;
alter table vppsone.school_certificate_issues
  add constraint school_certificate_issue_kind_matches check (coalesce(snapshot->>'kind','study')=kind),
  add constraint school_certificate_verify_code_shape check (verify_code is null or verify_code ~ '^[a-f0-9]{16}$');
create unique index school_certificate_verify_code on vppsone.school_certificate_issues(verify_code) where verify_code is not null;
create index school_certificate_student_kind on vppsone.school_certificate_issues(student_id,session_label,kind,issued_at desc);
create index school_certificate_tray on vppsone.school_certificate_issues(session_label,issued_at desc) where status='prepared' and artifact_state='ready';

create or replace function vppsone.school_certificate_immutable()
returns trigger language plpgsql set search_path='' as $$
begin
 if tg_op='DELETE' then raise exception 'certificate:immutable'; end if;
 if new.snapshot is distinct from old.snapshot or new.serial<>old.serial or new.student_id<>old.student_id
   or new.session_label<>old.session_label or new.enrolment_id<>old.enrolment_id or new.template_version<>old.template_version
   or new.issued_at<>old.issued_at or new.issued_by<>old.issued_by or new.supersedes is distinct from old.supersedes
   or new.reason is distinct from old.reason or new.kind<>old.kind then raise exception 'certificate:immutable'; end if;
 if old.artifact_state='ready' and (new.artifact_state<>old.artifact_state or new.storage_path is distinct from old.storage_path
    or new.artifact_sha256 is distinct from old.artifact_sha256 or new.artifact_bytes is distinct from old.artifact_bytes) then
   raise exception 'certificate:artifact_immutable'; end if;
 if new.status<>old.status and not (old.status='prepared' and new.status in('issued','superseded','cancelled')
   or old.status='issued' and new.status in('superseded','cancelled')) then raise exception 'certificate:invalid_transition'; end if;
 return new;
end;
$$;

-- Default wording for the three new kinds, active from the start so the office
-- can use them; every later edit is a new version under the existing manage rule.
insert into vppsone.school_certificate_templates(version,kind,active,approved_via,template)
select v.version, v.kind, true, 'default wording, School Office second pass 2026-11-03', v.template||jsonb_build_object('version',v.version,'kind',v.kind)
from (values
 ((select coalesce(max(version),0)+1 from vppsone.school_certificate_templates),'character',jsonb_build_object(
   'active',true,'titleEn','Character Certificate','titleHi','चरित्र प्रमाण पत्र',
   'bodyEn','This is to certify that {studentName}, {sonDaughter} of {fatherName}, admission/SR number {admissionNo}, has been a student of this school in Class {classLabel} during academic session {sessionLabel}. To the best of my knowledge {heShe} bears {conduct} moral character. I wish {himHer} every success in life.',
   'bodyHi','प्रमाणित किया जाता है कि {studentName}, {putraPutri} श्री {fatherName}, प्रवेश/एसआर संख्या {admissionNo}, शैक्षणिक सत्र {sessionLabel} में इस विद्यालय की कक्षा {classLabel} के विद्यार्थी रहे हैं। मेरी जानकारी के अनुसार इनका चरित्र {conduct} है। इनके उज्ज्वल भविष्य के लिए शुभकामनाएँ।',
   'historicalBodyEn','This is to certify that {studentName}, {sonDaughter} of {fatherName}, admission/SR number {admissionNo}, was a student of this school in Class {classLabel} during academic session {sessionLabel}. To the best of my knowledge {heShe} bears {conduct} moral character. I wish {himHer} every success in life.',
   'historicalBodyHi','प्रमाणित किया जाता है कि {studentName}, {putraPutri} श्री {fatherName}, प्रवेश/एसआर संख्या {admissionNo}, शैक्षणिक सत्र {sessionLabel} में इस विद्यालय की कक्षा {classLabel} के विद्यार्थी रहे हैं। मेरी जानकारी के अनुसार इनका चरित्र {conduct} है। इनके उज्ज्वल भविष्य के लिए शुभकामनाएँ।',
   'requiredFields',jsonb_build_array('studentName','fatherName','admissionNo','classLabel','sessionLabel'),
   'detailRows',jsonb_build_array(),'language','en','prefix','VPPS/CC','signaturePolicy','manual')),
 ((select coalesce(max(version),0)+2 from vppsone.school_certificate_templates),'dob',jsonb_build_object(
   'active',true,'titleEn','Date of Birth Certificate','titleHi','जन्म तिथि प्रमाण पत्र',
   'bodyEn','This is to certify that, as recorded in the Scholar''s Register of this school, the date of birth of {studentName}, {sonDaughter} of {fatherName}, admission/SR number {admissionNo}, is {dateOfBirth} ({dateOfBirthWords}).',
   'bodyHi','प्रमाणित किया जाता है कि इस विद्यालय की छात्र पंजिका (एसआर) के अनुसार {studentName}, {putraPutri} श्री {fatherName}, प्रवेश/एसआर संख्या {admissionNo}, की जन्म तिथि {dateOfBirth} ({dateOfBirthWords}) है।',
   'historicalBodyEn','This is to certify that, as recorded in the Scholar''s Register of this school, the date of birth of {studentName}, {sonDaughter} of {fatherName}, admission/SR number {admissionNo}, is {dateOfBirth} ({dateOfBirthWords}).',
   'historicalBodyHi','प्रमाणित किया जाता है कि इस विद्यालय की छात्र पंजिका (एसआर) के अनुसार {studentName}, {putraPutri} श्री {fatherName}, प्रवेश/एसआर संख्या {admissionNo}, की जन्म तिथि {dateOfBirth} ({dateOfBirthWords}) है।',
   'requiredFields',jsonb_build_array('studentName','fatherName','admissionNo','dateOfBirth'),
   'detailRows',jsonb_build_array(),'language','en','prefix','VPPS/DOB','signaturePolicy','manual')),
 ((select coalesce(max(version),0)+3 from vppsone.school_certificate_templates),'tc',jsonb_build_object(
   'active',true,'titleEn','Transfer Certificate','titleHi','स्थानांतरण प्रमाण पत्र',
   'bodyEn','Certified that the particulars given below are as recorded in the Scholar''s Register of {schoolName}.',
   'bodyHi','प्रमाणित किया जाता है कि नीचे दिया गया विवरण {schoolName} की छात्र पंजिका के अनुसार है।',
   'historicalBodyEn','Certified that the particulars given below are as recorded in the Scholar''s Register of {schoolName}.',
   'historicalBodyHi','प्रमाणित किया जाता है कि नीचे दिया गया विवरण {schoolName} की छात्र पंजिका के अनुसार है।',
   'requiredFields',jsonb_build_array('studentName','fatherName','admissionNo','dateOfBirth','classLabel','leftOn'),
   'detailRows',jsonb_build_array('studentName','fatherName','motherName','dateOfBirth','dateOfBirthWords','admissionNo','admittedOn','classLabel','sessionLabel','lastResult','leftOn','reasonForLeaving','conduct','remarks'),
   'language','en','prefix','VPPS/TC','signaturePolicy','manual'))
) as v(version,kind,template);

-- Facts for one kind. Optional personal facts are returned only when that
-- kind's active template mentions them anywhere (body, detail rows or required).
create function vppsone.school_certificate_facts_v2(p_actor uuid,p_student uuid,p_session text,p_kind text,p_confined boolean default false)
returns jsonb language plpgsql stable set search_path='' as $$
declare e vppsone.enrolments; s jsonb; c jsonb; t jsonb; current_record boolean; verified boolean; mentioned text;
begin
 if not vppsone.school_office_actor_allowed(p_actor,'certificates:issue',p_session,p_confined) then raise exception 'certificate:forbidden'; end if;
 if p_kind not in ('study','character','dob','tc') then raise exception 'certificate:invalid_kind'; end if;
 if not vppsone.is_test_session(p_session) and not exists(select 1 from vppsone.fees_bridge_state where id and enabled and live_read_ready and last_error_code is null and last_checked_at>=clock_timestamp()-interval '5 minutes') then raise exception 'certificate:source_unavailable'; end if;
 select * into e from vppsone.enrolments where student_id=p_student and session_label=p_session order by created_at desc limit 1;
 select to_jsonb(x) into s from vppsone.fees_identity_students x where x.id=p_student limit 1;
 select to_jsonb(x) into c from vppsone.fees_identity_classes x where x.id=e.class_id and x.session_label=p_session;
 select template into t from vppsone.school_certificate_templates where active and kind=p_kind;
 current_record:=coalesce(e.status::text='enrolled' and e.left_on is null and s->>'status'='active' and (s->>'class_id')::uuid=e.class_id,false);
 verified:=e.id is not null and s is not null and c is not null and (current_record or (e.enrolled_on is not null and e.left_on is not null and e.left_on>=e.enrolled_on));
 mentioned:=coalesce(t::text,'');
 return jsonb_build_object('studentId',p_student,'enrolmentId',coalesce(e.id,'00000000-0000-0000-0000-000000000000'::uuid),
   'classId',coalesce(e.class_id,'00000000-0000-0000-0000-000000000000'::uuid),'studentName',coalesce(s->>'full_name',''),
   'admissionNo',coalesce(s->>'admission_no',''),'classLabel',concat_ws(' ',c->>'class_name',nullif(c->>'section','')),
   'sessionLabel',p_session,'status',case when current_record then 'current' else 'historical' end,
   'enrolledOn',e.enrolled_on,'leftOn',e.left_on,
   'admittedOn',case when position('admittedOn' in mentioned)>0 then s->>'joined_on' end,
   'dateOfBirth',case when position('dateOfBirth' in mentioned)>0 then s->>'date_of_birth' end,
   'fatherName',case when position('fatherName' in mentioned)>0 then s->>'father_name' end,
   'motherName',case when position('motherName' in mentioned)>0 then s->>'mother_name' end,
   'gender',case when position('{sonDaughter}' in mentioned)+position('{heShe}' in mentioned)+position('{himHer}' in mentioned)+position('{hisHer}' in mentioned)+position('{putraPutri}' in mentioned)>0 then s->>'gender' end,
   'identityVerified',verified,'sourceCurrent',s is not null and c is not null,
   'sourceRevision',case when vppsone.is_test_session(p_session) then coalesce(s->>'updated_at','test') else coalesce((select last_revision::text from vppsone.fees_bridge_state where id),'unknown') end,
   'checkedAt',clock_timestamp());
end;
$$;
revoke all on function vppsone.school_certificate_facts_v2(uuid,uuid,text,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_facts_v2(uuid,uuid,text,text,boolean) to service_role;

create function vppsone.school_certificate_current_v2(p_actor uuid,p_student uuid,p_session text,p_kind text,p_command uuid,p_request_hash text,p_confined boolean default false,p_issue uuid default null)
returns jsonb language plpgsql set search_path='' as $$
declare prior vppsone.school_certificate_commands; issue vppsone.school_certificate_issues;
begin
 if not vppsone.school_office_actor_allowed(p_actor,'certificates:issue',p_session,p_confined) then raise exception 'certificate:forbidden'; end if;
 if p_request_hash !~ '^[a-f0-9]{64}$' then raise exception 'certificate:invalid_command'; end if;
 perform pg_advisory_xact_lock(hashtextextended('school-certificate-command:'||p_command::text,0));
 select * into prior from vppsone.school_certificate_commands where command_id=p_command;
 if found then
   if prior.actor_id<>p_actor or prior.request_hash<>p_request_hash then raise exception 'certificate:command_reused'; end if;
   select * into issue from vppsone.school_certificate_issues where id=prior.issue_id;
   if issue.student_id<>p_student or issue.session_label<>p_session or issue.kind<>p_kind then raise exception 'certificate:command_reused'; end if;
   return to_jsonb(issue);
 end if;
 perform pg_advisory_xact_lock(hashtextextended('school-certificate-student:'||p_student::text||':'||p_session,0));
 select * into issue from vppsone.school_certificate_issues where student_id=p_student and session_label=p_session and kind=p_kind
   and status in('prepared','issued') and (p_issue is null or id=p_issue) order by issued_at desc limit 1;
 if not found then
   if p_issue is not null then raise exception 'certificate:stale_issue'; end if;
   return null;
 end if;
 insert into vppsone.school_certificate_commands(command_id,actor_id,request_hash,issue_id) values(p_command,p_actor,p_request_hash,issue.id);
 return to_jsonb(issue);
end;
$$;
revoke all on function vppsone.school_certificate_current_v2(uuid,uuid,text,text,uuid,text,boolean,uuid) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_current_v2(uuid,uuid,text,text,uuid,text,boolean,uuid) to service_role;

create function vppsone.school_certificate_reserve_v2(p_actor uuid,p_student uuid,p_session text,p_kind text,p_command uuid,p_request_hash text,
 p_expected_facts jsonb,p_school jsonb,p_expected_template integer,p_purpose text default null,p_extras jsonb default '{}'::jsonb,
 p_new boolean default false,p_supersedes uuid default null,p_reason text default null,p_confined boolean default false)
returns jsonb language plpgsql set search_path='' as $$
declare prior vppsone.school_certificate_commands; issue vppsone.school_certificate_issues; t vppsone.school_certificate_templates;
 facts jsonb; serial_number bigint; serial_text text; instant timestamptz:=clock_timestamp(); field text; extra record; code text;
begin
 if not vppsone.school_office_actor_allowed(p_actor,'certificates:issue',p_session,p_confined) then raise exception 'certificate:forbidden'; end if;
 if p_kind not in ('study','character','dob','tc') then raise exception 'certificate:invalid_kind'; end if;
 if p_request_hash !~ '^[a-f0-9]{64}$' then raise exception 'certificate:invalid_command'; end if;
 if p_purpose is not null and (length(btrim(p_purpose))<2 or length(p_purpose)>80 or p_purpose ~ '[{}<>]') then raise exception 'certificate:invalid_purpose'; end if;
 if jsonb_typeof(coalesce(p_extras,'{}'::jsonb))<>'object' then raise exception 'certificate:invalid_extras'; end if;
 for extra in select key, value from jsonb_each(coalesce(p_extras,'{}'::jsonb)) loop
   if extra.key not in ('reasonForLeaving','conduct','lastResult','remarks') or jsonb_typeof(extra.value)<>'string'
     or length(extra.value#>>'{}')>200 or (extra.value#>>'{}') ~ '[{}<>]' then raise exception 'certificate:invalid_extras'; end if;
 end loop;
 perform pg_advisory_xact_lock(hashtextextended('school-certificate-command:'||p_command::text,0));
 select * into prior from vppsone.school_certificate_commands where command_id=p_command;
 if found then
   if prior.actor_id<>p_actor or prior.request_hash<>p_request_hash then raise exception 'certificate:command_reused'; end if;
   select * into issue from vppsone.school_certificate_issues where id=prior.issue_id;
   return jsonb_build_object('issue',to_jsonb(issue),'existing',true);
 end if;
 perform pg_advisory_xact_lock(hashtextextended('school-certificate-student:'||p_student::text||':'||p_session,0));
 if not p_new and p_supersedes is null then
   select * into issue from vppsone.school_certificate_issues where student_id=p_student and session_label=p_session and kind=p_kind
     and status in('prepared','issued') order by issued_at desc limit 1;
   if found then
     insert into vppsone.school_certificate_commands(command_id,actor_id,request_hash,issue_id) values(p_command,p_actor,p_request_hash,issue.id);
     return jsonb_build_object('issue',to_jsonb(issue),'existing',true);
   end if;
 end if;
 select * into t from vppsone.school_certificate_templates where active and kind=p_kind for share;
 if not found then raise exception 'certificate:template_inactive'; end if;
 if t.version<>p_expected_template then raise exception 'certificate:template_changed'; end if;
 facts:=vppsone.school_certificate_facts_v2(p_actor,p_student,p_session,p_kind,p_confined);
 if facts->>'identityVerified'<>'true' or facts->>'sourceCurrent'<>'true' then raise exception 'certificate:identity_unverified'; end if;
 if (facts-'checkedAt') is distinct from (p_expected_facts-'checkedAt') then raise exception 'certificate:source_changed'; end if;
 if p_kind='tc' and facts->>'status'<>'historical' then raise exception 'certificate:not_left'; end if;
 for field in select jsonb_array_elements_text(t.template->'requiredFields') loop
   if nullif(btrim(facts->>field),'') is null then raise exception 'certificate:missing_field:%',field; end if;
 end loop;
 if p_supersedes is not null then
   if not vppsone.school_office_actor_allowed(p_actor,'certificates:manage',p_session,p_confined) or length(btrim(coalesce(p_reason,'')))<3 then raise exception 'certificate:correction_forbidden'; end if;
   select * into issue from vppsone.school_certificate_issues where id=p_supersedes and student_id=p_student and session_label=p_session and kind=p_kind for update;
   if not found or issue.status not in('prepared','issued') then raise exception 'certificate:stale_issue'; end if;
 end if;
 if p_school->>'name' is null or length(p_school->>'name')<2 then raise exception 'certificate:school_missing'; end if;
 insert into vppsone.school_certificate_series(prefix,session_label,is_test,last_number)
   values(t.template->>'prefix',p_session,vppsone.is_test_session(p_session),1)
   on conflict(prefix,session_label,is_test) do update set last_number=vppsone.school_certificate_series.last_number+1
   returning last_number into serial_number;
 serial_text:=case when vppsone.is_test_session(p_session) then 'TEST/' else '' end||(t.template->>'prefix');
 serial_text:=serial_text||'/'||p_session||'/'||lpad(serial_number::text,greatest(4,length(serial_number::text)),'0');
 code:=substr(md5(gen_random_uuid()::text||clock_timestamp()::text),1,16);
 insert into vppsone.school_certificate_issues(student_id,session_label,enrolment_id,template_version,serial,snapshot,issued_by,issued_at,supersedes,reason,kind)
   values(p_student,p_session,(facts->>'enrolmentId')::uuid,t.version,serial_text,
    jsonb_build_object('serial',serial_text,'issuedAt',instant,'issuedOn',(instant at time zone 'Asia/Kolkata')::date,
      'isTest',vppsone.is_test_session(p_session),'school',p_school,'facts',facts,'template',t.template,
      'kind',p_kind,'purpose',nullif(btrim(coalesce(p_purpose,'')),''),'extras',coalesce(p_extras,'{}'::jsonb),'verifyCode',code),
    p_actor,instant,p_supersedes,p_reason,p_kind)
   returning * into issue;
 insert into vppsone.school_certificate_commands(command_id,actor_id,request_hash,issue_id) values(p_command,p_actor,p_request_hash,issue.id);
 insert into vppsone.school_certificate_events(issue_id,actor_id,kind) values(issue.id,p_actor,'prepared');
 return jsonb_build_object('issue',to_jsonb(issue),'existing',false);
end;
$$;
revoke all on function vppsone.school_certificate_reserve_v2(uuid,uuid,text,text,uuid,text,jsonb,jsonb,integer,text,jsonb,boolean,uuid,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_reserve_v2(uuid,uuid,text,text,uuid,text,jsonb,jsonb,integer,text,jsonb,boolean,uuid,text,boolean) to service_role;

create function vppsone.school_certificate_save_template_v2(p_actor uuid,p_kind text,p_template jsonb,p_expected_version integer,p_confined boolean default false)
returns integer language plpgsql set search_path='' as $$
declare current_version integer; new_version integer;
begin
 if not vppsone.school_office_actor_allowed(p_actor,'certificates:manage',null,p_confined) then raise exception 'certificate:forbidden'; end if;
 if p_kind not in ('study','character','dob','tc') then raise exception 'certificate:invalid_kind'; end if;
 perform pg_advisory_xact_lock(hashtextextended('school-certificate-template',0));
 select coalesce(max(version),0) into current_version from vppsone.school_certificate_templates where kind=p_kind;
 if current_version<>p_expected_version then raise exception 'certificate:template_changed'; end if;
 if p_template->>'signaturePolicy'<>'manual' or p_template->>'prefix' !~ '^[A-Z0-9][A-Z0-9/-]{0,39}$' then raise exception 'certificate:invalid_template'; end if;
 if exists(select 1 from vppsone.school_certificate_templates where kind<>p_kind and template->>'prefix'=p_template->>'prefix') then raise exception 'certificate:prefix_in_use'; end if;
 select coalesce(max(version),0)+1 into new_version from vppsone.school_certificate_templates;
 update vppsone.school_certificate_templates set active=false where active and kind=p_kind;
 insert into vppsone.school_certificate_templates(version,kind,active,template,approved_by,approved_via)
 values(new_version,p_kind,coalesce((p_template->>'active')::boolean,false),p_template||jsonb_build_object('version',new_version,'kind',p_kind),p_actor,'authorized template configuration');
 return new_version;
end;
$$;
revoke all on function vppsone.school_certificate_save_template_v2(uuid,text,jsonb,integer,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_save_template_v2(uuid,text,jsonb,integer,boolean) to service_role;

-- The v1 entry points keep working for a deployment that has not caught up:
-- they now mean the study kind only, so they cannot read another kind's template.
create or replace function vppsone.school_certificate_facts(p_actor uuid,p_student uuid,p_session text,p_confined boolean default false)
returns jsonb language sql stable set search_path='' as $$
 select vppsone.school_certificate_facts_v2(p_actor,p_student,p_session,'study',p_confined);
$$;
create or replace function vppsone.school_certificate_current(p_actor uuid,p_student uuid,p_session text,p_command uuid,p_request_hash text,p_confined boolean default false,p_issue uuid default null)
returns jsonb language sql set search_path='' as $$
 select vppsone.school_certificate_current_v2(p_actor,p_student,p_session,'study',p_command,p_request_hash,p_confined,p_issue);
$$;
create or replace function vppsone.school_certificate_reserve(p_actor uuid,p_student uuid,p_session text,p_command uuid,p_request_hash text,
 p_expected_facts jsonb,p_school jsonb,p_expected_template integer,p_new boolean default false,p_supersedes uuid default null,p_reason text default null,p_confined boolean default false)
returns jsonb language sql set search_path='' as $$
 select vppsone.school_certificate_reserve_v2(p_actor,p_student,p_session,'study',p_command,p_request_hash,p_expected_facts,p_school,p_expected_template,null,'{}'::jsonb,p_new,p_supersedes,p_reason,p_confined);
$$;
create or replace function vppsone.school_certificate_save_template(p_actor uuid,p_template jsonb,p_expected_version integer,p_confined boolean default false)
returns integer language sql set search_path='' as $$
 select vppsone.school_certificate_save_template_v2(p_actor,'study',p_template,p_expected_version,p_confined);
$$;

revoke all on function vppsone.school_certificate_facts(uuid,uuid,text,boolean) from public,anon,authenticated;
revoke all on function vppsone.school_certificate_current(uuid,uuid,text,uuid,text,boolean,uuid) from public,anon,authenticated;
revoke all on function vppsone.school_certificate_reserve(uuid,uuid,text,uuid,text,jsonb,jsonb,integer,boolean,uuid,text,boolean) from public,anon,authenticated;
revoke all on function vppsone.school_certificate_save_template(uuid,jsonb,integer,boolean) from public,anon,authenticated;

-- Class batches: the enrolled roster an issuer may prepare documents for.
-- Names, SR numbers and classes only; the issue command rereads every fact.
create function vppsone.school_certificate_roster(p_actor uuid,p_session text,p_confined boolean default false)
returns jsonb language plpgsql stable set search_path='' as $$
begin
 if not vppsone.school_office_actor_allowed(p_actor,'certificates:issue',p_session,p_confined) then raise exception 'certificate:forbidden'; end if;
 if not vppsone.is_test_session(p_session) and not exists(select 1 from vppsone.fees_bridge_state where id and enabled and live_read_ready and last_error_code is null and last_checked_at>=clock_timestamp()-interval '5 minutes') then raise exception 'certificate:source_unavailable'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('studentId',s.id,'studentName',s.full_name,'admissionNo',s.admission_no,'classId',c.id,
     'classLabel',concat_ws(' ',c.class_name,nullif(c.section,''))) order by c.class_name,c.section,s.full_name)
   from vppsone.enrolments e
   join vppsone.fees_identity_students s on s.id=e.student_id
   join vppsone.fees_identity_classes c on c.id=e.class_id and c.session_label=p_session
   where e.session_label=p_session and e.status::text='enrolled' and e.left_on is null),'[]'::jsonb);
end;
$$;
revoke all on function vppsone.school_certificate_roster(uuid,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_roster(uuid,text,boolean) to service_role;

-- The attention card follows study certificates; it reads the study template,
-- not whichever kind was saved last.
create or replace function vppsone.school_office_attention(p_actor uuid,p_session text,p_confined boolean default false)
returns jsonb language plpgsql stable set search_path='' as $$
declare certificates boolean; government boolean; t jsonb; candidates jsonb:='[]'; artifacts jsonb:='[]'; batches jsonb:='[]'; unavailable boolean:=false;
begin
 certificates:=vppsone.school_office_actor_allowed(p_actor,'certificates:view',p_session,p_confined);
 government:=vppsone.school_office_actor_allowed(p_actor,'government:view',p_session,p_confined);
 if p_session is null or p_session !~ '^(TEST-)?[0-9]{4}-[0-9]{2}$' or not(certificates or government) then raise exception 'office:forbidden'; end if;
 if certificates then
  select template||jsonb_build_object('active',active) into t from vppsone.school_certificate_templates where kind='study' order by version desc limit 1;
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into artifacts from (
   select id,student_id,student_name,session_label,artifact_state from vppsone.school_certificate_issues
   where session_label=p_session and status in('prepared','issued') and artifact_state in('preparing','failed')
   order by issued_at desc,id desc limit 4
  ) x;
  if exists(select 1 from vppsone.school_certificate_attention where session_label=p_session) then
   if not vppsone.is_test_session(p_session) and not exists(select 1 from vppsone.fees_bridge_state where id and enabled
    and live_read_ready and last_error_code is null and last_checked_at>=clock_timestamp()-interval '5 minutes') then
    unavailable:=true;
   else
    begin
     with logged as materialized (
      select student_id,blocker_codes,last_seen_at from vppsone.school_certificate_attention where session_label=p_session
      order by last_seen_at desc,student_id limit 1000
     ), records as (
      select l.*,e.id enrolment_id,e.class_id,e.enrolled_on,e.left_on,s.id source_id,s.full_name,s.admission_no,
       s.date_of_birth,s.father_name,s.mother_name,c.id source_class_id,concat_ws(' ',c.class_name,nullif(c.section,'')) class_label,
       coalesce(e.status::text='enrolled' and e.left_on is null and s.status::text='active' and s.class_id=e.class_id,false) current_record
      from logged l
      left join lateral(select * from vppsone.enrolments e where e.student_id=l.student_id and e.session_label=p_session order by e.created_at desc,e.id desc limit 1) e on true
      left join vppsone.fees_identity_students s on s.id=l.student_id and exists(
       select 1 from vppsone.fees_identity_classes scope where scope.id=s.class_id
        and vppsone.is_test_session(scope.session_label)=vppsone.is_test_session(p_session))
      left join vppsone.fees_identity_classes c on c.id=e.class_id and c.session_label=p_session
     ), facts as (
      select r.*,
       coalesce((t->'requiredFields')::text,'')||' '||
        case when t->>'language' in('en','both') then coalesce(t->>(case when current_record then 'bodyEn' else 'historicalBodyEn' end),'') else '' end||' '||
        case when t->>'language' in('hi','both') then coalesce(t->>(case when current_record then 'bodyHi' else 'historicalBodyHi' end),'') else '' end optional_text
      from records r
     ), snapshots as (
      select student_id,blocker_codes,last_seen_at,optional_text,
       jsonb_build_object('studentId',student_id,'enrolmentId',coalesce(enrolment_id,'00000000-0000-0000-0000-000000000000'::uuid),
       'classId',coalesce(class_id,'00000000-0000-0000-0000-000000000000'::uuid),'studentName',coalesce(full_name,''),'admissionNo',coalesce(admission_no,''),
       'classLabel',class_label,'sessionLabel',p_session,'status',case when current_record then 'current' else 'historical' end,
       'enrolledOn',enrolled_on,'leftOn',left_on,'dateOfBirth',case when position('dateOfBirth' in optional_text)>0 then date_of_birth end,
       'fatherName',case when position('fatherName' in optional_text)>0 then father_name end,'motherName',case when position('motherName' in optional_text)>0 then mother_name end,
       'identityVerified',enrolment_id is not null and source_id is not null and source_class_id is not null
        and (current_record or (enrolled_on is not null and left_on is not null and left_on>=enrolled_on)),
       'sourceCurrent',source_id is not null and source_class_id is not null,'sourceRevision','attention-current','checkedAt',clock_timestamp()) facts
      from facts
     )
     select coalesce(jsonb_agg(jsonb_build_object('student_id',student_id,'blocker_codes',blocker_codes,'facts',facts)),'[]'::jsonb)
     into candidates from (
      -- Skip resolved logs before limiting the response, so old corrected
      -- records cannot crowd an unresolved student out of the card.
      select * from snapshots f where f.facts->>'sourceCurrent'='false' or exists(
       select 1 from unnest(f.blocker_codes) code where
        (code='identity:identity_unverified' and f.facts->>'identityVerified'='false')
        or (code='template:template_inactive' and t->>'active'='false')
        or (split_part(code,':',2)='missing_field'
         and ((t->'requiredFields') ? split_part(code,':',1) or position('{'||split_part(code,':',1)||'}' in f.optional_text)>0)
         and nullif(btrim(f.facts->>split_part(code,':',1)),'') is null)
      ) order by last_seen_at desc,student_id limit 8
     ) current_candidates;
    exception when others then unavailable:=true; candidates:='[]'; end;
   end if;
  end if;
 end if;
 if government then
  -- State filtering deliberately happens AFTER newest-per-parent selection.
  -- An older conflicted preview cannot survive a newer applied import.
  with latest_imports as materialized (
   select distinct on(coalesce(parent_batch_id,id)) id,parent_batch_id,direction,state,created_at,session_label,payload
   from vppsone.school_return_batches where session_label=p_session and direction='import'
   order by coalesce(parent_batch_id,id),created_at desc,id desc
  ), actionable as (
   select id,parent_batch_id,direction,state,created_at,session_label,
    exists(select 1 from jsonb_array_elements(coalesce(payload->'preview','[]'::jsonb)) r where r->>'state' in('conflict','unmatched')) has_conflicts
   from latest_imports where state in('preparing','staged')
   union all
   select id,parent_batch_id,direction,state,created_at,session_label,false from vppsone.school_return_batches
   where session_label=p_session and direction='export' and state='preparing'
  )
  select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) into batches from (
   select * from actionable where state='preparing' or has_conflicts order by created_at desc,id desc limit 8
  ) x;
 end if;
 return jsonb_build_object('template',t,'certificate_candidates',candidates,'certificate_artifacts',artifacts,
  'return_batches',batches,'certificate_unavailable',unavailable);
end;
$$;

-- Public check behind the QR: status, number, kind, date and the name for the
-- server to mask. No class, parentage, DOB or anything else from the profile.
-- TEST issues answer as unknown so a test document cannot be vouched for.
create function vppsone.school_certificate_verify(p_code text)
returns jsonb language sql stable security definer set search_path='' as $$
 select case when p_code !~ '^[a-f0-9]{16}$' then null else (
   select jsonb_build_object('status',i.status,'serial',i.serial,'kind',i.kind,'issuedOn',i.snapshot->>'issuedOn',
     'studentName',i.student_name,'school',i.snapshot->'school'->>'name','supersededBy',
     (select n.serial from vppsone.school_certificate_issues n where n.supersedes=i.id and n.status in('prepared','issued') limit 1))
   from vppsone.school_certificate_issues i where i.verify_code=p_code and i.artifact_state='ready' and not coalesce((i.snapshot->>'isTest')::boolean,false)) end;
$$;
revoke all on function vppsone.school_certificate_verify(text) from public,anon,authenticated;
grant execute on function vppsone.school_certificate_verify(text) to service_role;

notify pgrst,'reload schema';
commit;

-- ======================================================== migrations/20261103032018_returns_copilot_rows.sql
-- Manual entry assistant ("Portal Copilot") row marks for prepared reference sheets.
-- A mark is a person's own record that they typed a row into the official portal
-- (or found a mismatch there). It is human submission evidence only: never
-- portal acceptance, never a change to any student, fee or source record.
begin;
set local lock_timeout='5s';
set local statement_timeout='60s';

create table vppsone.school_return_copilot_rows (
 batch_id uuid not null references vppsone.school_return_batches(id),
 row_key uuid not null,
 state text not null check(state in('entered','mismatch')),
 note text check(note is null or length(btrim(note)) between 1 and 500),
 actor_id uuid not null references vppsone.staff_profiles(id),
 updated_at timestamptz not null default now(),
 primary key(batch_id,row_key),
 check(state<>'mismatch' or note is not null)
);
alter table vppsone.school_return_copilot_rows enable row level security;
-- Visible exactly when the batch is (its own policy checks permission, scope and session).
create policy school_return_copilot_rows_read on vppsone.school_return_copilot_rows for select to authenticated
 using(exists(select 1 from vppsone.school_return_batches b where b.id=batch_id));
revoke all on vppsone.school_return_copilot_rows from public,anon,authenticated;
grant select on vppsone.school_return_copilot_rows to authenticated;
grant all on vppsone.school_return_copilot_rows to service_role;

-- Called by the server only, after its permission, view-as and session checks.
-- Rechecks the actor, the TEST fence and that the row belongs to this prepared
-- manual reference batch. Idempotent: the same mark twice is one row.
create function vppsone.school_return_copilot_mark(p_actor uuid,p_batch uuid,p_row uuid,p_state text,p_note text default null,p_confined boolean default false)
returns jsonb language plpgsql set search_path='' as $$
declare b vppsone.school_return_batches; result vppsone.school_return_copilot_rows; clean_note text:=nullif(btrim(coalesce(p_note,'')),'');
begin
 select * into b from vppsone.school_return_batches where id=p_batch;
 if not found or not vppsone.school_office_actor_allowed(p_actor,'government:export',b.session_label,p_confined) then raise exception 'office:forbidden'; end if;
 if b.direction<>'export' or b.adapter->>'mode'<>'manual_reference' or b.file_path is null
  or b.state not in('exported','submitted','partially_accepted','rejected') then raise exception 'office:not_manual_entry'; end if;
 if p_state not in('entered','mismatch') or (p_state='mismatch' and clean_note is null) or length(coalesce(clean_note,''))>500 then raise exception 'office:invalid_mark'; end if;
 if not exists(select 1 from jsonb_array_elements(b.payload->'rows') r where r->>'studentId'=p_row::text) then raise exception 'office:row_not_in_batch'; end if;
 insert into vppsone.school_return_copilot_rows(batch_id,row_key,state,note,actor_id)
 values(p_batch,p_row,p_state,case when p_state='mismatch' then clean_note end,p_actor)
 on conflict(batch_id,row_key) do update set state=excluded.state,note=excluded.note,actor_id=excluded.actor_id,updated_at=now()
 returning * into result;
 return to_jsonb(result);
end;
$$;
revoke all on function vppsone.school_return_copilot_mark(uuid,uuid,uuid,text,text,boolean) from public,anon,authenticated;
grant execute on function vppsone.school_return_copilot_mark(uuid,uuid,uuid,text,text,boolean) to service_role;

notify pgrst,'reload schema';
commit;

-- ======================================================== migrations/20261103192446_teacher_leave_request_id.sql
-- VPPS One — a retried leave request files once (MCP feasibility §10).
--
-- `requestLeaveVx` inserted `teacher_leave` rows with no idempotency key, so
-- a send whose answer was lost — a dropped connection, a phone that slept —
-- and was tapped again filed the same leave twice, and each row queued its
-- own office notice through `teacher_leave_staff_notices`.
--
-- The leave sheet now generates one id per submission and keeps it across
-- retries of that same submission. The server stores it here and, when the
-- id is already filed for that person, returns the original rows instead of
-- inserting (src/vx/screens/teach/actions.ts).
--
-- One submission is one row per run of school days, so the key is the id
-- *and* the run's first day: the runs of one request never share a
-- `from_day`. The person is in the key too, so an id is only ever matched
-- against that person's own requests.
--
-- Additive and backfill-safe: the column is nullable and nothing is
-- backfilled. Existing rows, and rows written by the office's own leave
-- screens, keep NULL, which the partial index leaves out.
--
-- Rollback:
--   drop index if exists vppsone.teacher_leave_request_once;
--   alter table vppsone.teacher_leave drop column if exists client_request_id;

begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table vppsone.teacher_leave
  add column if not exists client_request_id uuid;

comment on column vppsone.teacher_leave.client_request_id is
  'The leave sheet''s id for one submission, kept across its retries. A repeat with the same id returns the rows already filed instead of filing again. NULL for rows from before it and from other screens.';

create unique index if not exists teacher_leave_request_once
  on vppsone.teacher_leave (staff_profile_id, client_request_id, from_day)
  where client_request_id is not null;

-- The app writes the column through PostgREST, which must see it at once.
notify pgrst, 'reload schema';

commit;

-- ======================================================== migrations/20261104022925_ai_connection_mcp.sql
-- The AI connection, first slice (M0/M1): One's own small OAuth 2.1
-- authorization server for the MCP endpoint, and its metadata-only call log
-- (docs/plans/2026-11-03-mcp-feasibility.md §5.2 option B, §5.3, §6.3; the
-- guarantees and their tests are in docs/plans/2026-11-03-mcp-m1-security-contract.md).
--
--  * ai_oauth_clients — public clients from dynamic registration (RFC 7591).
--    Redirect URIs were checked against an allowlist in code before insert.
--  * ai_connections   — one grant: which staff member, which auth user, which
--    client and provider, 90 days at most (owner decision D8), revoked with a
--    reason and by whom.
--  * ai_oauth_codes   — single-use authorization codes, 60 seconds, bound to
--    the client, redirect URI, PKCE challenge, resource and connection.
--  * ai_tokens        — access (15 minutes) and refresh (rotated, never past
--    the connection's expiry) tokens.
--  * ai_tool_calls    — one row per tool call: staff, connection, provider,
--    tool, outcome, row count, duration. Never arguments, names or free text
--    (the assist_log rule). Kept 180 days (D8), purged by `ai_purge`.
--
-- Codes and tokens are opaque random values; only their SHA-256 (hex) is
-- stored, so a copy of these tables opens nothing. Single use is decided here,
-- not in the app: each redemption locks its row (`select … for update`), so of
-- two concurrent redemptions exactly one finds it unused, and the other is
-- treated as reuse — the whole connection and every token from it is revoked
-- (RFC 6749 §4.1.2, OAuth 2.1 refresh rotation).
--
-- Service role only, like vppsone.assist_log: RLS on with no policy, every
-- grant to anon and authenticated revoked, functions executable by
-- service_role alone. Nothing here touches fee data.
--
-- The kill switch is a new runtime_flags key, `ai_connection`, added OFF:
-- absent or unreadable is off in the app as well.
--
-- Rollback:
--   drop function vppsone.ai_purge(integer), vppsone.ai_connection_list(uuid, integer),
--     vppsone.ai_staff_for_user(uuid), vppsone.ai_call_counts(uuid),
--     vppsone.ai_revoke_token(text, text), vppsone.ai_revoke_staff_connections(uuid, text, uuid),
--     vppsone.ai_resolve_access(text), vppsone.ai_rotate_refresh(text, text, text, text, text, integer),
--     vppsone.ai_exchange_code(text, text, text, text, text, text, text, integer),
--     vppsone.ai_create_grant(uuid, uuid, text, text, text[], text, text, text, text, integer, integer),
--     vppsone.ai_revoke_connection(uuid, text, uuid),
--     vppsone.ai_register_client(text, text, text[], text, text, integer, integer, integer);
--   drop table vppsone.ai_tool_calls, vppsone.ai_tokens, vppsone.ai_oauth_codes,
--     vppsone.ai_connections, vppsone.ai_oauth_clients;
--   delete from vppsone.runtime_flags where key = 'ai_connection';
--   re-add runtime_flags_key_known without it (20261031125856).

/* ------------------------------------------------------------ the switch */

alter table vppsone.runtime_flags drop constraint if exists runtime_flags_key_known;
alter table vppsone.runtime_flags add constraint runtime_flags_key_known check (
  key in (
    'cover_command',
    'staff_notice_dispatch',
    'fault_injection',
    'parent_dispatch',
    'parent_dispatch_categories',
    'absent_notice_owner',
    'parent_dispatch_test_only',
    'staff_notice_kinds_enabled',
    'staff_whatsapp_month_cap',
    'staff_notice_student_names',
    'aisensy_month_plan_cap',
    'ai_connection'
  )
);
insert into vppsone.runtime_flags (key, enabled, value, note)
values (
  'ai_connection', false, null,
  'AI connection (Claude / ChatGPT through MCP) for eligible staff. Off = every tool call is refused; connections and the call log are kept.'
)
on conflict (key) do nothing;

/* --------------------------------------------------------------- tables */

create table vppsone.ai_oauth_clients (
  client_id text primary key check (client_id ~ '^[A-Za-z0-9_-]{22,64}$'),
  -- Display only, never trusted: the consent card names the provider from
  -- the redirect host, not from this.
  client_name text check (client_name is null or char_length(client_name) <= 80),
  redirect_uris text[] not null check (cardinality(redirect_uris) between 1 and 5),
  -- Which deployment registered it: production and every Preview share this
  -- database, so they count registrations separately.
  environment text not null check (environment in ('production', 'preview')),
  -- SHA-256 of the platform-set client IP (x-real-ip), never the address
  -- itself; nulled by the purge after a day. Only for the per-source limit.
  source_hash text check (source_hash is null or source_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now()
);

comment on table vppsone.ai_oauth_clients is
  'AI connection: public OAuth clients from dynamic registration. Every redirect URI matched an allowlist in code (src/modules/mcp/domain/redirects.ts).';

create index ai_oauth_clients_created on vppsone.ai_oauth_clients (environment, created_at);
create index ai_oauth_clients_source on vppsone.ai_oauth_clients (environment, source_hash, created_at);

create table vppsone.ai_connections (
  id uuid primary key default gen_random_uuid(),
  staff_profile_id uuid not null references vppsone.staff_profiles (id) on delete cascade,
  auth_user_id uuid not null references auth.users (id) on delete cascade,
  client_id text not null references vppsone.ai_oauth_clients (client_id) on delete restrict,
  provider text not null check (provider in ('claude', 'chatgpt', 'local')),
  scopes text[] not null check (cardinality(scopes) between 1 and 4),
  created_at timestamptz not null default now(),
  -- Null until the code is redeemed: consent alone makes a pending grant that
  -- holds no token, replaces nothing and is never shown as allowed.
  activated_at timestamptz,
  expires_at timestamptz not null,
  revoked_at timestamptz,
  revoked_by uuid references vppsone.staff_profiles (id) on delete set null,
  revoke_reason text check (revoke_reason is null or revoke_reason ~ '^[a-z_]{2,40}$'),
  constraint ai_connections_revoked_shape check ((revoked_at is null) = (revoke_reason is null)),
  -- Re-consent every 90 days (D8): no grant outlives that, whatever the app asks.
  constraint ai_connections_lifetime check (expires_at > created_at and expires_at <= created_at + interval '90 days')
);

comment on table vppsone.ai_connections is
  'AI connection grants: one staff member, one client, at most 90 days. Revoked rows are kept as evidence.';

create index ai_connections_staff on vppsone.ai_connections (staff_profile_id, created_at desc);
create index ai_connections_client on vppsone.ai_connections (client_id);

create table vppsone.ai_oauth_codes (
  code_hash text primary key check (code_hash ~ '^[0-9a-f]{64}$'),
  connection_id uuid not null references vppsone.ai_connections (id) on delete cascade,
  client_id text not null,
  redirect_uri text not null check (char_length(redirect_uri) <= 512),
  -- S256 only: base64url of a SHA-256, 43 characters.
  code_challenge text not null check (code_challenge ~ '^[A-Za-z0-9_-]{43}$'),
  resource text not null check (char_length(resource) <= 512),
  scopes text[] not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_at timestamptz,
  constraint ai_oauth_codes_short check (expires_at <= created_at + interval '5 minutes')
);

create index ai_oauth_codes_connection on vppsone.ai_oauth_codes (connection_id);
create index ai_oauth_codes_expires on vppsone.ai_oauth_codes (expires_at);

create table vppsone.ai_tokens (
  id uuid primary key default gen_random_uuid(),
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  kind text not null check (kind in ('access', 'refresh')),
  connection_id uuid not null references vppsone.ai_connections (id) on delete cascade,
  resource text not null check (char_length(resource) <= 512),
  scopes text[] not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  -- Refresh only: set once, when the token is rotated. A second presentation
  -- of a used refresh token is replay.
  used_at timestamptz,
  replaced_by uuid references vppsone.ai_tokens (id) on delete set null,
  revoked_at timestamptz,
  constraint ai_tokens_rotation_refresh_only check (kind = 'refresh' or (used_at is null and replaced_by is null))
);

create index ai_tokens_connection on vppsone.ai_tokens (connection_id);
create index ai_tokens_expires on vppsone.ai_tokens (expires_at);

create table vppsone.ai_tool_calls (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  staff_profile_id uuid references vppsone.staff_profiles (id) on delete set null,
  connection_id uuid references vppsone.ai_connections (id) on delete set null,
  provider text not null check (provider in ('claude', 'chatgpt', 'local')),
  -- A registry name, or 'unknown' for a name the registry does not have —
  -- never the text a client sent.
  tool text not null check (tool ~ '^[a-z][a-z0-9_]{1,40}$'),
  outcome text not null check (outcome ~ '^(ok|refused:[a-z_]{2,40}|error:[a-z_]{2,40})$'),
  row_count integer check (row_count is null or row_count >= 0),
  duration_ms integer not null check (duration_ms >= 0)
);

comment on table vppsone.ai_tool_calls is
  'One row per AI connection tool call: who, which connection and provider, which tool, outcome, row count, duration. Never arguments, names or free text. 180 days.';

create index ai_tool_calls_staff_created on vppsone.ai_tool_calls (staff_profile_id, created_at desc);
create index ai_tool_calls_connection_created on vppsone.ai_tool_calls (connection_id, created_at desc);
create index ai_tool_calls_created on vppsone.ai_tool_calls (created_at);

alter table vppsone.ai_oauth_clients enable row level security;
alter table vppsone.ai_connections enable row level security;
alter table vppsone.ai_oauth_codes enable row level security;
alter table vppsone.ai_tokens enable row level security;
alter table vppsone.ai_tool_calls enable row level security;

revoke all on vppsone.ai_oauth_clients, vppsone.ai_connections, vppsone.ai_oauth_codes,
  vppsone.ai_tokens, vppsone.ai_tool_calls from public, anon, authenticated;
grant all on vppsone.ai_oauth_clients, vppsone.ai_connections, vppsone.ai_oauth_codes,
  vppsone.ai_tokens, vppsone.ai_tool_calls to service_role;

/* ------------------------------------------------------------ functions */

-- Register a public client, under one lock per environment so the counts
-- hold however many registrations arrive at once:
--  * the same source asking for the same redirect set within
--    p_reuse_seconds gets the client it already has (a provider re-registering
--    on every fresh connection does not use up the allowance);
--  * otherwise at most p_max_per_source new clients an hour per source
--    (hashed client IP), under a ceiling of p_max_per_hour per environment,
--    so one unauthenticated script cannot block everybody's onboarding and a
--    Preview cannot use up production's.
create function vppsone.ai_register_client(
  p_client_id text,
  p_client_name text,
  p_redirect_uris text[],
  p_source_hash text,
  p_environment text,
  p_max_per_source integer,
  p_max_per_hour integer,
  p_reuse_seconds integer
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_existing vppsone.ai_oauth_clients%rowtype;
  v_source integer;
  v_recent integer;
begin
  perform pg_advisory_xact_lock(hashtext('vppsone:ai-register:' || p_environment));

  select * into v_existing
  from vppsone.ai_oauth_clients
  where environment = p_environment
    and source_hash = p_source_hash
    and redirect_uris = p_redirect_uris
    and created_at > now() - make_interval(secs => p_reuse_seconds)
  order by created_at desc
  limit 1;
  if found then
    return jsonb_build_object(
      'ok', true, 'reused', true, 'client_id', v_existing.client_id,
      'client_name', v_existing.client_name, 'created_at', v_existing.created_at
    );
  end if;

  select count(*) filter (where source_hash = p_source_hash), count(*)
  into v_source, v_recent
  from vppsone.ai_oauth_clients
  where environment = p_environment and created_at > now() - interval '1 hour';
  if v_source >= p_max_per_source or v_recent >= p_max_per_hour then
    return jsonb_build_object('ok', false, 'reason', 'rate_limited');
  end if;

  insert into vppsone.ai_oauth_clients (client_id, client_name, redirect_uris, environment, source_hash)
  values (p_client_id, nullif(btrim(p_client_name), ''), p_redirect_uris, p_environment, p_source_hash)
  returning * into v_existing;
  return jsonb_build_object(
    'ok', true, 'reused', false, 'client_id', v_existing.client_id,
    'client_name', v_existing.client_name, 'created_at', v_existing.created_at
  );
end;
$$;

-- End a connection and every token issued from it. Idempotent: the tokens
-- are revoked even when the connection already was.
create function vppsone.ai_revoke_connection(
  p_connection_id uuid,
  p_reason text,
  p_by uuid default null
)
returns boolean
language plpgsql
set search_path = ''
as $$
declare
  v_done boolean;
begin
  update vppsone.ai_connections
  set revoked_at = now(), revoke_reason = p_reason, revoked_by = p_by
  where id = p_connection_id and revoked_at is null;
  v_done := found;
  update vppsone.ai_tokens
  set revoked_at = now()
  where connection_id = p_connection_id and revoked_at is null;
  return v_done;
end;
$$;

-- The consent, in one transaction: a PENDING connection (no token, nothing
-- replaced, `activated_at` null) for 90 days at most, and its single-use
-- code for 60 seconds. Only redeeming the code activates it (ai_exchange_code).
-- The staff row must be active and belong to the signed-in auth user, and the
-- redirect URI must be one the client registered; eligibility (admins first,
-- D7) is checked by the app before this is called.
create function vppsone.ai_create_grant(
  p_staff_profile_id uuid,
  p_auth_user_id uuid,
  p_client_id text,
  p_provider text,
  p_scopes text[],
  p_code_hash text,
  p_redirect_uri text,
  p_code_challenge text,
  p_resource text,
  p_code_ttl_seconds integer,
  p_grant_days integer
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_staff vppsone.staff_profiles%rowtype;
  v_client vppsone.ai_oauth_clients%rowtype;
  v_conn uuid;
begin
  if p_code_ttl_seconds not between 1 and 300 or p_grant_days not between 1 and 90 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;

  select * into v_staff from vppsone.staff_profiles where id = p_staff_profile_id;
  if not found or not v_staff.is_active or v_staff.user_id is distinct from p_auth_user_id then
    return jsonb_build_object('ok', false, 'reason', 'staff');
  end if;

  select * into v_client from vppsone.ai_oauth_clients where client_id = p_client_id;
  if not found or not (p_redirect_uri = any (v_client.redirect_uris)) then
    return jsonb_build_object('ok', false, 'reason', 'client');
  end if;

  insert into vppsone.ai_connections (staff_profile_id, auth_user_id, client_id, provider, scopes, expires_at)
  values (p_staff_profile_id, p_auth_user_id, p_client_id, p_provider, p_scopes, now() + make_interval(days => p_grant_days))
  returning id into v_conn;

  insert into vppsone.ai_oauth_codes (code_hash, connection_id, client_id, redirect_uri, code_challenge, resource, scopes, expires_at)
  values (p_code_hash, v_conn, p_client_id, p_redirect_uri, p_code_challenge, p_resource, p_scopes,
          now() + make_interval(secs => p_code_ttl_seconds));

  return jsonb_build_object('ok', true, 'connection_id', v_conn);
end;
$$;

-- Redeem a code for the first access and refresh tokens. The row is locked,
-- so a concurrent second redemption waits and then finds it used: that is
-- reuse, and the connection with every token from it is revoked. A code
-- presented with the wrong client, redirect URI, PKCE verifier or resource is
-- consumed and its connection revoked; an expired one is consumed and its
-- connection, which never had a token, ended.
--
-- A good code activates its connection. Under an advisory lock per staff
-- member and provider, every other unrevoked connection of theirs to that
-- provider — live or still pending — ends as 'replaced', and the connection
-- is re-read after the lock: two approvals redeemed at once leave exactly one
-- live, and a connection revoked while this waited is not activated.
create function vppsone.ai_exchange_code(
  p_code_hash text,
  p_verifier_challenge text,
  p_client_id text,
  p_redirect_uri text,
  p_resource text,
  p_access_hash text,
  p_refresh_hash text,
  p_access_ttl_seconds integer
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_code vppsone.ai_oauth_codes%rowtype;
  v_conn vppsone.ai_connections%rowtype;
  v_access_expires timestamptz;
begin
  select * into v_code from vppsone.ai_oauth_codes where code_hash = p_code_hash for update;
  if not found then
    return jsonb_build_object('status', 'invalid');
  end if;

  if v_code.used_at is not null then
    perform vppsone.ai_revoke_connection(v_code.connection_id, 'code_reuse', null);
    return jsonb_build_object('status', 'replayed');
  end if;

  update vppsone.ai_oauth_codes set used_at = now() where code_hash = p_code_hash;

  if v_code.expires_at <= now() then
    perform vppsone.ai_revoke_connection(v_code.connection_id, 'code_expired', null);
    return jsonb_build_object('status', 'invalid');
  end if;

  if v_code.client_id is distinct from p_client_id
     or v_code.redirect_uri is distinct from p_redirect_uri
     or v_code.code_challenge is distinct from p_verifier_challenge
     or v_code.resource is distinct from p_resource then
    perform vppsone.ai_revoke_connection(v_code.connection_id, 'code_mismatch', null);
    return jsonb_build_object('status', 'invalid');
  end if;

  select * into v_conn from vppsone.ai_connections where id = v_code.connection_id;
  perform pg_advisory_xact_lock(hashtext('vppsone:ai-connection:' || v_conn.staff_profile_id::text || ':' || v_conn.provider));
  select * into v_conn from vppsone.ai_connections where id = v_code.connection_id;
  if v_conn.revoked_at is not null or v_conn.expires_at <= now() then
    return jsonb_build_object('status', 'invalid');
  end if;

  perform vppsone.ai_revoke_connection(c.id, 'replaced', v_conn.staff_profile_id)
  from vppsone.ai_connections c
  where c.staff_profile_id = v_conn.staff_profile_id
    and c.provider = v_conn.provider
    and c.id <> v_conn.id
    and c.revoked_at is null;
  update vppsone.ai_connections set activated_at = now() where id = v_conn.id;

  v_access_expires := least(now() + make_interval(secs => p_access_ttl_seconds), v_conn.expires_at);
  insert into vppsone.ai_tokens (token_hash, kind, connection_id, resource, scopes, expires_at)
  values
    (p_access_hash, 'access', v_conn.id, v_code.resource, v_code.scopes, v_access_expires),
    (p_refresh_hash, 'refresh', v_conn.id, v_code.resource, v_code.scopes, v_conn.expires_at);

  return jsonb_build_object(
    'status', 'ok',
    'connection_id', v_conn.id,
    'scopes', to_jsonb(v_code.scopes),
    'access_expires_at', v_access_expires,
    'refresh_expires_at', v_conn.expires_at
  );
end;
$$;

-- Rotate a refresh token: the presented one is marked used and a new pair
-- issued, the refresh never past the connection's expiry. A used refresh
-- token presented again is replay: the connection and every token from it is
-- revoked. The same row lock as codes makes two concurrent rotations one
-- rotation and one replay.
create function vppsone.ai_rotate_refresh(
  p_refresh_hash text,
  p_client_id text,
  p_resource text,
  p_new_access_hash text,
  p_new_refresh_hash text,
  p_access_ttl_seconds integer
)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_old vppsone.ai_tokens%rowtype;
  v_conn vppsone.ai_connections%rowtype;
  v_new uuid;
  v_access_expires timestamptz;
begin
  select * into v_old from vppsone.ai_tokens
  where token_hash = p_refresh_hash and kind = 'refresh'
  for update;
  if not found then
    return jsonb_build_object('status', 'invalid');
  end if;

  select * into v_conn from vppsone.ai_connections where id = v_old.connection_id;
  if v_conn.client_id is distinct from p_client_id then
    return jsonb_build_object('status', 'invalid');
  end if;

  if v_old.used_at is not null then
    perform vppsone.ai_revoke_connection(v_old.connection_id, 'refresh_reuse', null);
    return jsonb_build_object('status', 'replayed');
  end if;

  if v_old.revoked_at is not null or v_old.expires_at <= now()
     or v_conn.revoked_at is not null or v_conn.expires_at <= now()
     or v_old.resource is distinct from p_resource then
    return jsonb_build_object('status', 'invalid');
  end if;

  v_access_expires := least(now() + make_interval(secs => p_access_ttl_seconds), v_conn.expires_at);

  insert into vppsone.ai_tokens (token_hash, kind, connection_id, resource, scopes, expires_at)
  values (p_new_refresh_hash, 'refresh', v_conn.id, v_old.resource, v_old.scopes, v_conn.expires_at)
  returning id into v_new;

  insert into vppsone.ai_tokens (token_hash, kind, connection_id, resource, scopes, expires_at)
  values (p_new_access_hash, 'access', v_conn.id, v_old.resource, v_old.scopes, v_access_expires);

  update vppsone.ai_tokens set used_at = now(), replaced_by = v_new where id = v_old.id;

  return jsonb_build_object(
    'status', 'ok',
    'connection_id', v_conn.id,
    'scopes', to_jsonb(v_old.scopes),
    'access_expires_at', v_access_expires,
    'refresh_expires_at', v_conn.expires_at
  );
end;
$$;

-- Step 1 and 2 of every call (§5.3): the token by its hash, with its
-- connection. Null when no such token. The app decides kind, expiry,
-- audience and revocation from the row, on every call.
create function vppsone.ai_resolve_access(p_token_hash text)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'kind', t.kind,
    'resource', t.resource,
    'scopes', to_jsonb(t.scopes),
    'expires_at', t.expires_at,
    'revoked_at', t.revoked_at,
    'connection', jsonb_build_object(
      'id', c.id,
      'staff_profile_id', c.staff_profile_id,
      'auth_user_id', c.auth_user_id,
      'client_id', c.client_id,
      'provider', c.provider,
      'scopes', to_jsonb(c.scopes),
      'expires_at', c.expires_at,
      'revoked_at', c.revoked_at
    )
  )
  from vppsone.ai_tokens t
  join vppsone.ai_connections c on c.id = t.connection_id
  where t.token_hash = p_token_hash
$$;

-- RFC 7009. Only the client the token was issued to can revoke it; anything
-- else is answered the same way and changes nothing. A refresh token ends the
-- whole grant; an access token only itself.
create function vppsone.ai_revoke_token(p_token_hash text, p_client_id text)
returns void
language plpgsql
set search_path = ''
as $$
declare
  v_token vppsone.ai_tokens%rowtype;
  v_client text;
begin
  select * into v_token from vppsone.ai_tokens where token_hash = p_token_hash;
  if not found then
    return;
  end if;
  select client_id into v_client from vppsone.ai_connections where id = v_token.connection_id;
  if v_client is distinct from p_client_id then
    return;
  end if;
  if v_token.kind = 'refresh' then
    perform vppsone.ai_revoke_connection(v_token.connection_id, 'revoked_by_client', null);
  else
    update vppsone.ai_tokens set revoked_at = coalesce(revoked_at, now()) where id = v_token.id;
  end if;
end;
$$;

-- Every live connection of one staff member: Disconnect on their card, an
-- admin disabling them, or the call pipeline finding them inactive.
create function vppsone.ai_revoke_staff_connections(
  p_staff_profile_id uuid,
  p_reason text,
  p_by uuid default null
)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_id uuid;
  v_n integer := 0;
begin
  for v_id in
    select id from vppsone.ai_connections
    where staff_profile_id = p_staff_profile_id and revoked_at is null
  loop
    if vppsone.ai_revoke_connection(v_id, p_reason, p_by) then
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end;
$$;

-- Per-staff limits (§5.5), checked before anything else a call does: calls
-- in the last hour and the last 24 hours, counted from the log, refused ones
-- included. A call already refused for the limit does not count again, so a
-- client that keeps knocking is not locked out for longer; `limited_hour`
-- lets the app write at most one such refusal an hour, so a token cannot
-- flood the log either.
create function vppsone.ai_call_counts(p_staff_profile_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'hour', count(*) filter (where created_at > now() - interval '1 hour' and outcome <> 'refused:rate_limited'),
    'day', count(*) filter (where outcome <> 'refused:rate_limited'),
    'limited_hour', count(*) filter (where created_at > now() - interval '1 hour' and outcome = 'refused:rate_limited')
  )
  from vppsone.ai_tool_calls
  where staff_profile_id = p_staff_profile_id
    and created_at > now() - interval '24 hours'
$$;

-- Step 4 of every call: the staff profile for a verified auth user, and its
-- role's permissions as the matrix holds them now — the service-role twin of
-- what `readCurrentStaff` reads with the cookie (`my_permissions()` keys on
-- auth.uid(), which a token-authenticated call does not have).
create function vppsone.ai_staff_for_user(p_user_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'id', s.id,
    'display_name', s.display_name,
    'short_name', s.short_name,
    'role', s.role,
    'is_teaching', s.is_teaching,
    'is_active', s.is_active,
    'preferred_language', s.preferred_language,
    'is_test_account', s.is_test_account,
    'permissions', coalesce(
      (select jsonb_agg(rp.permission order by rp.permission)
       from vppsone.role_permissions rp where rp.role = s.role),
      '[]'::jsonb
    )
  )
  from vppsone.staff_profiles s
  where s.user_id = p_user_id
$$;

-- The connections list (admin page) and one person's card: activated
-- connections only — a pending grant whose code was never redeemed holds no
-- token and is never shown as allowed. Last used and the 30-day count come
-- from the log; no argument or result is stored anywhere.
create function vppsone.ai_connection_list(p_staff_profile_id uuid default null, p_limit integer default 200)
returns table (
  id uuid,
  staff_profile_id uuid,
  staff_name text,
  provider text,
  created_at timestamptz,
  activated_at timestamptz,
  expires_at timestamptz,
  revoked_at timestamptz,
  revoke_reason text,
  last_used_at timestamptz,
  calls_30d integer
)
language sql
stable
set search_path = ''
as $$
  select
    c.id,
    c.staff_profile_id,
    s.display_name,
    c.provider,
    c.created_at,
    c.activated_at,
    c.expires_at,
    c.revoked_at,
    c.revoke_reason,
    (select max(l.created_at) from vppsone.ai_tool_calls l where l.connection_id = c.id),
    (select count(*)::integer from vppsone.ai_tool_calls l
      where l.connection_id = c.id and l.created_at > now() - interval '30 days')
  from vppsone.ai_connections c
  join vppsone.staff_profiles s on s.id = c.staff_profile_id
  where c.activated_at is not null
    and (p_staff_profile_id is null or c.staff_profile_id = p_staff_profile_id)
  order by c.created_at desc
  limit least(greatest(coalesce(p_limit, 200), 1), 500)
$$;

-- The scheduled clean-up (job `ai-connection-purge`): call rows older than
-- the retention (180 days, D8); codes a day past expiry; tokens a day past
-- expiry or revocation (a used refresh token lives until its connection
-- expires, so replay is still recognised while the grant could be used);
-- connections ended longer ago than the retention or never activated;
-- registered clients nobody connected with within a day; and hashed source
-- addresses older than a day.
create function vppsone.ai_purge(p_keep_days integer default 180)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_calls integer;
  v_codes integer;
  v_tokens integer;
  v_connections integer;
  v_clients integer;
begin
  if p_keep_days is null or p_keep_days < 30 then
    raise exception 'ai_purge keeps at least 30 days';
  end if;

  delete from vppsone.ai_tool_calls where created_at < now() - make_interval(days => p_keep_days);
  get diagnostics v_calls = row_count;

  delete from vppsone.ai_oauth_codes where expires_at < now() - interval '1 day';
  get diagnostics v_codes = row_count;

  delete from vppsone.ai_tokens
  where expires_at < now() - interval '1 day'
     or (revoked_at is not null and revoked_at < now() - interval '1 day');
  get diagnostics v_tokens = row_count;

  -- Ended long ago, or consented to and never redeemed (pending past a day).
  delete from vppsone.ai_connections
  where coalesce(revoked_at, expires_at) < now() - make_interval(days => p_keep_days)
     or (activated_at is null and created_at < now() - interval '1 day');
  get diagnostics v_connections = row_count;

  delete from vppsone.ai_oauth_clients c
  where c.created_at < now() - interval '1 day'
    and not exists (select 1 from vppsone.ai_connections x where x.client_id = c.client_id);
  get diagnostics v_clients = row_count;

  -- The per-source limit looks back an hour; the hashed address need not
  -- outlive a day on the clients that stay.
  update vppsone.ai_oauth_clients set source_hash = null
  where source_hash is not null and created_at < now() - interval '1 day';

  return jsonb_build_object(
    'calls', v_calls,
    'codes', v_codes,
    'tokens', v_tokens,
    'connections', v_connections,
    'clients', v_clients
  );
end;
$$;

revoke all on function vppsone.ai_register_client(text, text, text[], text, text, integer, integer, integer) from public, anon, authenticated;
revoke all on function vppsone.ai_revoke_connection(uuid, text, uuid) from public, anon, authenticated;
revoke all on function vppsone.ai_create_grant(uuid, uuid, text, text, text[], text, text, text, text, integer, integer) from public, anon, authenticated;
revoke all on function vppsone.ai_exchange_code(text, text, text, text, text, text, text, integer) from public, anon, authenticated;
revoke all on function vppsone.ai_rotate_refresh(text, text, text, text, text, integer) from public, anon, authenticated;
revoke all on function vppsone.ai_resolve_access(text) from public, anon, authenticated;
revoke all on function vppsone.ai_revoke_token(text, text) from public, anon, authenticated;
revoke all on function vppsone.ai_revoke_staff_connections(uuid, text, uuid) from public, anon, authenticated;
revoke all on function vppsone.ai_call_counts(uuid) from public, anon, authenticated;
revoke all on function vppsone.ai_staff_for_user(uuid) from public, anon, authenticated;
revoke all on function vppsone.ai_connection_list(uuid, integer) from public, anon, authenticated;
revoke all on function vppsone.ai_purge(integer) from public, anon, authenticated;

grant execute on function vppsone.ai_register_client(text, text, text[], text, text, integer, integer, integer) to service_role;
grant execute on function vppsone.ai_revoke_connection(uuid, text, uuid) to service_role;
grant execute on function vppsone.ai_create_grant(uuid, uuid, text, text, text[], text, text, text, text, integer, integer) to service_role;
grant execute on function vppsone.ai_exchange_code(text, text, text, text, text, text, text, integer) to service_role;
grant execute on function vppsone.ai_rotate_refresh(text, text, text, text, text, integer) to service_role;
grant execute on function vppsone.ai_resolve_access(text) to service_role;
grant execute on function vppsone.ai_revoke_token(text, text) to service_role;
grant execute on function vppsone.ai_revoke_staff_connections(uuid, text, uuid) to service_role;
grant execute on function vppsone.ai_call_counts(uuid) to service_role;
grant execute on function vppsone.ai_staff_for_user(uuid) to service_role;
grant execute on function vppsone.ai_connection_list(uuid, integer) to service_role;
grant execute on function vppsone.ai_purge(integer) to service_role;

-- ======================================================== migrations/20261104054116_built_in_ai_jobs.sql
-- Built-in Gemini pilot. Only VPPS One's server can use this ledger or bucket.
-- No browser role can list, read or change objects; the server mints individual
-- upload tokens only after authenticating and authorising the operation.
create table vppsone.ai_jobs (
  id uuid primary key default gen_random_uuid(),
  staff_profile_id uuid not null references vppsone.staff_profiles (id),
  action text not null check (action ~ '^[a-z][a-z0-9-]{1,39}$'),
  session_label text not null check (session_label = 'TEST-2026-27'),
  target_id uuid not null,
  target_revision integer not null check (target_revision >= 0),
  roster_stamp text,
  input_paths text[] not null check (cardinality(input_paths) between 1 and 4),
  model text not null,
  model_version text,
  input_tokens integer not null default 0 check (input_tokens >= 0),
  output_tokens integer not null default 0 check (output_tokens >= 0),
  thinking_tokens integer not null default 0 check (thinking_tokens >= 0),
  estimated_cost_inr numeric(12,6) not null default 0 check (estimated_cost_inr >= 0),
  attempts jsonb not null default '[]',
  raw_output jsonb,
  reviewed_data jsonb,
  final_applied_data jsonb,
  status text not null default 'draft' check (status in ('draft','applied','discarded','failed')),
  error text,
  created_at timestamptz not null default now(),
  parse_started_at timestamptz,
  parsed_at timestamptz,
  applied_at timestamptz,
  purged_at timestamptz
);
alter table vppsone.ai_jobs enable row level security;
revoke all on vppsone.ai_jobs from public, anon, authenticated;
grant select, insert, update on vppsone.ai_jobs to service_role;
create index ai_jobs_staff_created_idx on vppsone.ai_jobs (staff_profile_id, created_at);
create index ai_jobs_retention_idx on vppsone.ai_jobs (created_at) where purged_at is null;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('ai-inputs', 'ai-inputs', false, 2097152, array['image/jpeg','audio/webm','audio/mp4']);

-- Restrictive so an unrelated, broad permissive storage policy cannot expose
-- this bucket. The service role bypasses RLS, including for signed uploads.
create policy ai_inputs_server_only on storage.objects as restrictive
for all to anon, authenticated
using (bucket_id <> 'ai-inputs') with check (bucket_id <> 'ai-inputs');

-- Serialize reservations per person. In particular, 51 parallel requests
-- cannot all observe the same count and then get usable upload tokens.
create function vppsone.reserve_ai_job(
  p_staff uuid, p_action text, p_target uuid, p_revision integer,
  p_pages integer, p_model text
) returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  v_id uuid := gen_random_uuid();
  v_now timestamptz := clock_timestamp();
  v_day timestamptz := date_trunc('day', v_now at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
begin
  if p_pages is null or p_pages not between 1 and 4 then
    raise exception 'invalid page count';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('builtin-ai:' || p_staff::text, 0));
  if (select count(*) from vppsone.ai_jobs where staff_profile_id = p_staff and created_at >= v_day) >= 50 then
    return null;
  end if;
  insert into vppsone.ai_jobs (id, staff_profile_id, action, session_label, target_id, target_revision, input_paths, model, created_at)
  values (v_id, p_staff, p_action, 'TEST-2026-27', p_target, p_revision,
    array(select v_id::text || '/' || i::text || '.jpg' from generate_series(1, p_pages) i), p_model, v_now);
  return v_id;
end;
$$;
revoke all on function vppsone.reserve_ai_job(uuid, text, uuid, integer, integer, text) from public, anon, authenticated;
grant execute on function vppsone.reserve_ai_job(uuid, text, uuid, integer, integer, text) to service_role;

-- ======================================================== migrations/20261104054119_ai_cover_photo.sql
-- AI photo writes are fenced to TEST. Use the existing cover command to
-- publish, record history, and queue notices. The ordinary outbox claim
-- already locks each notice and excludes pending rows before next_attempt_at.
create function vppsone.apply_ai_cover_photo(
  p_job uuid, p_actor uuid, p_day date, p_timetable_day text,
  p_version uuid, p_bells integer, p_assignments jsonb, p_review jsonb
) returns jsonb
language plpgsql volatile security invoker set search_path = ''
as $$
declare
  v_session constant text := 'TEST-2026-27';
  j vppsone.ai_jobs%rowtype;
  s vppsone.timetable_slots%rowtype;
  r record;
  v_existing jsonb;
  v_desired jsonb := '[]';
  v_previous_absences jsonb;
  v_absences jsonb;
  v_applied jsonb := '[]';
  v_keys text[] := '{}';
  v_row jsonb;
  v_written text;
  v_date_parts text[];
  v_starts timestamptz;
  v_first_start timestamptz;
  v_undo_until timestamptz;
  v_receipt jsonb;
  v_result jsonb;
begin
  if p_day is null or p_version is null or p_timetable_day is null or p_bells is null
     or length(btrim(p_timetable_day)) < 3
     or not starts_with(lower(to_char(p_day, 'FMDay')), lower(btrim(p_timetable_day)))
     or jsonb_typeof(p_assignments) is distinct from 'array'
     or jsonb_array_length(p_assignments) not between 1 and 60 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;
  if not exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = p_actor and sp.is_active and rp.permission = 'substitutions:manage'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  select * into j from vppsone.ai_jobs
  where id = p_job and staff_profile_id = p_actor and session_label = v_session
    and action = 'substitution-photo' and purged_at is null
    and target_id = ('00000000-0000-4000-8000-0000' || to_char(p_day, 'YYYYMMDD'))::uuid
  for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if j.status = 'applied' then
    return jsonb_build_object('ok', true, 'result', j.final_applied_data);
  end if;
  if j.status <> 'draft' or j.parsed_at is null or j.raw_output is null
     or j.roster_stamp is distinct from p_version::text || ':' || p_bells::text then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;

  perform pg_advisory_xact_lock(hashtext('vppsone:cover:' || v_session || ':' || p_day::text));
  if coalesce((select revision from vppsone.cover_days where session_label = v_session and day = p_day), 0)
       <> j.target_revision
     or not exists (select 1 from vppsone.timetable_versions
                    where id = p_version and session_label = v_session and status = 'published') then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;

  -- The ordinary absence table's unique key omits session_label. Prevent a
  -- concurrent insertion for the same staff/day from letting the upsert
  -- replace an absence belonging to another session.
  lock table vppsone.teacher_absences in share row exclusive mode;

  select coalesce(jsonb_agg(to_jsonb(d)), '[]') into v_existing
  from vppsone.cover_duties d
  where d.session_label = v_session and d.day = p_day and d.status in ('assigned', 'needs_help');

  for r in
    select * from jsonb_to_recordset(p_assignments)
      as x(index integer, "absentId" uuid, "coveringId" uuid, "classId" uuid, period smallint, "needKey" text)
  loop
    if r."absentId" is null or r."coveringId" is null or r."absentId" = r."coveringId"
       or r."classId" is null or r.period is null or r.period not between 0 and 7
       or r.index is null or r.index not between 0 and 59 or r."needKey" is null
       or r."needKey" = any(v_keys) or v_applied @> jsonb_build_array(r.index) then
      return jsonb_build_object('ok', false, 'reason', 'bad_request');
    end if;

    v_row := j.raw_output->'rows'->r.index;
    v_written := btrim(translate(v_row->>'sourceDate', '०१२३४५६७८९０１２３４５６７８９', '01234567890123456789'));
    v_date_parts := regexp_match(v_written, '^([0-9]{1,2})[[:space:]]*([./-])[[:space:]]*([0-9]{1,2})[[:space:]]*\2[[:space:]]*([0-9]{4})$');
    if v_row->'unclear' is distinct from 'false'::jsonb or (
      v_written is distinct from p_day::text and
      (v_date_parts[4] || '-' || lpad(v_date_parts[3], 2, '0') || '-' || lpad(v_date_parts[1], 2, '0')) is distinct from p_day::text
    ) then
      return jsonb_build_object('ok', false, 'reason', 'source_date');
    end if;

    select (p_day + (period->>'starts')::time) at time zone 'Asia/Kolkata'
    into v_starts
    from vppsone.bell_schedules b, jsonb_array_elements(b.periods) period
    where b.session_label = v_session and b.is_current and b.revision = p_bells
      and (period->>'index')::smallint = r.period;
    if v_starts is null or v_starts <= clock_timestamp() + interval '2 minutes' then
      return jsonb_build_object('ok', false, 'reason', 'closed');
    end if;
    v_first_start := least(v_first_start, v_starts);

    select * into s from vppsone.timetable_slots ts
    where ts.version_id = p_version and ts.day = p_timetable_day and ts.period = r.period
      and ts.class_id = r."classId" and ts.staff_profile_id = r."absentId"
      and not ts.parallel and not ts.shared;
    if not found or r."needKey" <>
       (s.day || '|P' || s.period || '|ordinary|' || s.subject_code || '|' || s.class_id || '|' || s.staff_profile_id || '#lesson')
       or (select count(*) from vppsone.timetable_slots ts
           where ts.version_id = p_version and ts.day = p_timetable_day and ts.period = r.period
             and (ts.class_id = r."classId" or ts.staff_profile_id = r."absentId")) <> 1
       or (select count(*) from vppsone.staff_profiles sp
           where sp.id in (r."absentId", r."coveringId") and sp.is_active and sp.is_teaching) <> 2
       or not exists (select 1 from vppsone.timetable_slots ts
                      where ts.version_id = p_version and ts.staff_profile_id = r."coveringId")
       or exists (select 1 from vppsone.cover_policies cp
                  where cp.session_label = v_session and cp.staff_profile_id = r."coveringId"
                    and not (r.period = any(cp.allowed_periods)))
       or exists (select 1 from vppsone.teacher_leave l
                  where l.session_label = v_session and l.staff_profile_id = r."coveringId" and l.status = 'approved'
                    and p_day between l.from_day and l.to_day
                    and (l.span = 'full' or (l.span = 'first_half' and r.period <= 3)
                                         or (l.span = 'second_half' and r.period > 3)))
       or exists (select 1 from vppsone.teacher_absences a
                  where a.staff_profile_id = r."absentId" and a.day = p_day and a.session_label <> v_session)
       or exists (select 1 from vppsone.cover_duties d
                  where d.session_label = v_session and d.day = p_day and d.need_key = r."needKey"
                    and (d.status = 'assigned' or (d.covering_staff_id = r."coveringId" and d.cannot_cover_at is not null)))
    then
      return jsonb_build_object('ok', false, 'reason', 'conflict');
    end if;

    v_desired := v_desired || jsonb_build_object(
      'need_key', r."needKey", 'period', r.period, 'event_kind', 'ordinary',
      'class_ids', jsonb_build_array(s.class_id), 'class_labels', jsonb_build_array(s.class_label),
      'subject_code', s.subject_code, 'absent_staff_ids', jsonb_build_array(r."absentId"),
      'status', 'assigned', 'covering_staff_id', r."coveringId", 'source', 'manual', 'pinned', true
    );
    v_applied := v_applied || to_jsonb(r.index);
    v_keys := array_append(v_keys, r."needKey");
  end loop;

  -- Only append or fill the photographed duties. Keep every other duty,
  -- including unresolved duties and the coordinator's existing choices.
  v_desired := v_desired || coalesce(
    (select jsonb_agg(value) from jsonb_array_elements(v_existing) where not (value->>'need_key' = any(v_keys))),
    '[]'
  );
  with changes as (
    select (entry->>'absentId')::uuid as staff_id, array_agg(distinct (entry->>'period')::smallint) as periods
    from jsonb_array_elements(p_assignments) entry
    group by (entry->>'absentId')::uuid
  ), additions as (
    select c.staff_id, c.periods, a.periods as previous
    from changes c left join vppsone.teacher_absences a
      on a.staff_profile_id = c.staff_id and a.day = p_day and a.session_label = v_session
    where a.periods is null or not c.periods <@ a.periods
  )
  select coalesce(jsonb_agg(jsonb_build_object('staff_profile_id', staff_id, 'periods', previous)), '[]'),
         coalesce(jsonb_agg(jsonb_build_object('staff_profile_id', staff_id, 'periods', previous || periods)), '[]')
  into v_previous_absences, v_absences
  from additions;

  v_receipt := vppsone.commit_cover_command(jsonb_build_object(
    'command_id', p_job, 'kind', 'substitution_photo', 'actor_staff_id', p_actor, 'session_label', v_session,
    'day', p_day, 'timetable_day', p_timetable_day, 'payload_hash', 'substitution-photo:' || p_job,
    'expected', jsonb_build_object('day_revision', j.target_revision, 'timetable_version_id', p_version, 'bells_revision', p_bells),
    'absences', v_absences, 'duties', v_desired
  ));
  if not (v_receipt->>'ok')::boolean then return v_receipt; end if;
  v_undo_until := clock_timestamp() + interval '2 minutes';
  if v_first_start <= v_undo_until
     or (select count(*) from vppsone.staff_notices where command_id = p_job and status = 'pending')
          <> jsonb_array_length(v_applied) then
    raise exception 'substitution photo was not fully applied';
  end if;
  update vppsone.staff_notices set next_attempt_at = v_undo_until
  where command_id = p_job and status = 'pending';

  v_result := jsonb_build_object('jobId', p_job, 'review', p_review, 'applied', v_applied, 'undoUntil', v_undo_until);
  update vppsone.ai_jobs set
    status = 'applied', applied_at = v_undo_until - interval '2 minutes', final_applied_data = v_result,
    reviewed_data = jsonb_build_object(
      'duties', v_existing, 'absences', v_previous_absences, 'dayRevision', v_receipt->'day_revision',
      'version', p_version, 'bells', p_bells, 'timetableDay', p_timetable_day
    )
  where id = p_job;
  return jsonb_build_object('ok', true, 'result', v_result);
end;
$$;

create function vppsone.undo_ai_cover_photo(p_job uuid, p_actor uuid, p_day date)
returns jsonb
language plpgsql volatile security invoker set search_path = ''
as $$
declare
  v_session constant text := 'TEST-2026-27';
  j vppsone.ai_jobs%rowtype;
  v_undo_until timestamptz;
  v_notice_count integer;
  v_receipt jsonb;
  v_result jsonb;
begin
  if not exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = p_actor and sp.is_active and rp.permission = 'substitutions:manage'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  select * into j from vppsone.ai_jobs
  where id = p_job and staff_profile_id = p_actor and session_label = v_session
    and action = 'substitution-photo' and status = 'applied' and purged_at is null
    and target_id = ('00000000-0000-4000-8000-0000' || to_char(p_day, 'YYYYMMDD'))::uuid
  for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  if j.final_applied_data->>'undone' = 'true' then
    return jsonb_build_object('ok', true, 'result', j.final_applied_data);
  end if;
  v_undo_until := (j.final_applied_data->>'undoUntil')::timestamptz;
  if v_undo_until is null or clock_timestamp() >= v_undo_until then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;

  perform pg_advisory_xact_lock(hashtext('vppsone:cover:' || v_session || ':' || p_day::text));
  lock table vppsone.teacher_absences in share row exclusive mode;
  if exists (
    select 1 from vppsone.teacher_absences a
    join jsonb_array_elements(j.reviewed_data->'absences') prior on a.staff_profile_id = (prior->>'staff_profile_id')::uuid
    where a.day = p_day and a.session_label <> v_session
  ) then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;

  -- Teacher replies lock their duty before writing a notice. Use that same
  -- order here so any reply which already happened stays in the history and
  -- any reply to the withdrawn duty is refused after Undo commits.
  perform 1 from vppsone.cover_duties d where d.command_id = p_job order by d.id for update;

  -- Take the same notice locks the dispatcher claims, before the real-clock
  -- check. Once locked, the dispatcher skips these rows until Undo commits.
  perform 1 from vppsone.staff_notices n where n.command_id = p_job order by n.id for update;
  select count(*) into v_notice_count from vppsone.staff_notices
  where command_id = p_job and kind = 'cover_assigned';
  if clock_timestamp() >= v_undo_until then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;
  if v_notice_count <> jsonb_array_length(j.final_applied_data->'applied') or exists (
    select 1 from vppsone.staff_notices n
    join vppsone.cover_duties d on d.id = n.duty_id
    where n.command_id = p_job
      and (n.status <> 'pending' or n.attempts <> 0 or n.next_attempt_at is distinct from v_undo_until
           or d.status <> 'assigned')
  ) then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;

  v_receipt := vppsone.commit_cover_command(jsonb_build_object(
    'command_id', gen_random_uuid(), 'kind', 'substitution_photo_undo', 'actor_staff_id', p_actor,
    'session_label', v_session, 'day', p_day, 'timetable_day', j.reviewed_data->'timetableDay',
    'payload_hash', 'substitution-photo-undo:' || p_job,
    'expected', jsonb_build_object(
      'day_revision', j.reviewed_data->'dayRevision',
      'timetable_version_id', j.reviewed_data->'version', 'bells_revision', j.reviewed_data->'bells'
    ),
    'absences', j.reviewed_data->'absences', 'duties', j.reviewed_data->'duties'
  ));
  if not (v_receipt->>'ok')::boolean then return v_receipt; end if;
  if exists (select 1 from vppsone.staff_notices where command_id = p_job and status <> 'cancelled') then
    raise exception 'substitution photo notices were not withdrawn';
  end if;
  v_result := j.final_applied_data || jsonb_build_object('undone', true);
  update vppsone.ai_jobs set final_applied_data = v_result where id = p_job;
  return jsonb_build_object('ok', true, 'result', v_result);
end;
$$;

revoke all on function vppsone.apply_ai_cover_photo(uuid, uuid, date, text, uuid, integer, jsonb, jsonb) from public, anon, authenticated;
revoke all on function vppsone.undo_ai_cover_photo(uuid, uuid, date) from public, anon, authenticated;
grant execute on function vppsone.apply_ai_cover_photo(uuid, uuid, date, text, uuid, integer, jsonb, jsonb) to service_role;
grant execute on function vppsone.undo_ai_cover_photo(uuid, uuid, date) to service_role;

-- A teacher can respond on the web before a WhatsApp notice is due, and
-- another coordinator can change a duty. Their related escalation or
-- replacement notice must honor the original hold, too.
create function vppsone.inherit_ai_cover_photo_hold()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_hold timestamptz;
begin
  if new.session_label <> 'TEST-2026-27' or new.duty_id is null then return new; end if;
  with recursive chain as (
    select id, supersedes, command_id from vppsone.cover_duties where id = new.duty_id
    union
    select d.id, d.supersedes, d.command_id from vppsone.cover_duties d join chain c on c.supersedes = d.id
  )
  select max((j.final_applied_data->>'undoUntil')::timestamptz) into v_hold
  from chain c join vppsone.ai_jobs j on c.command_id = j.id
  where j.action = 'substitution-photo' and j.status = 'applied';

  if v_hold > clock_timestamp() then new.next_attempt_at := greatest(new.next_attempt_at, v_hold); end if;
  return new;
end;
$$;
revoke all on function vppsone.inherit_ai_cover_photo_hold() from public, anon, authenticated;
create trigger staff_notices_inherit_ai_cover_photo_hold
before insert on vppsone.staff_notices for each row execute function vppsone.inherit_ai_cover_photo_hold();

-- ======================================================== migrations/20261104054126_builtin_ai_provider_usage.sql
-- Built-in AI stays in TEST-2026-27. The new setting controls reservations
-- across photo and voice actions, and the report returns no input or transcript.
alter table vppsone.ai_jobs add column provider text;
alter table vppsone.ai_jobs add column edited boolean;

create table vppsone.builtin_ai_settings (
  id integer primary key check (id = 1),
  daily_limit integer not null default 50 check (daily_limit between 0 and 200),
  updated_at timestamptz not null default now(),
  updated_by uuid references vppsone.staff_profiles(id)
);
insert into vppsone.builtin_ai_settings (id) values (1);
alter table vppsone.builtin_ai_settings enable row level security;
revoke all on vppsone.builtin_ai_settings from public, anon, authenticated;
grant select, update on vppsone.builtin_ai_settings to service_role;

update storage.buckets
set allowed_mime_types = array['image/jpeg','audio/webm','audio/mp4','audio/wav','audio/m4a']
where id = 'ai-inputs' and public is false;

drop function vppsone.reserve_ai_job(uuid, text, uuid, integer, integer, text);
create function vppsone.reserve_ai_job(
  p_staff uuid, p_action text, p_target uuid, p_revision integer,
  p_pages integer, p_model text, p_audio_extension text default null
) returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  v_id uuid := gen_random_uuid();
  v_now timestamptz := clock_timestamp();
  v_day timestamptz := date_trunc('day', v_now at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
  v_limit integer;
  v_extension text := coalesce(p_audio_extension, 'jpg');
begin
  if p_action not in ('marks-photo','substitution-photo','voice')
     or p_pages is null or p_pages not between 1 and 4
     or (p_action = 'voice' and (p_pages <> 1 or v_extension not in ('webm','m4a','wav')))
     or (p_action <> 'voice' and p_audio_extension is not null)
     or p_action is null then
    raise exception 'invalid AI input';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('builtin-ai:' || p_staff::text, 0));
  select daily_limit into v_limit from vppsone.builtin_ai_settings where id = 1;
  if v_limit is null or (select count(*) from vppsone.ai_jobs where staff_profile_id = p_staff and created_at >= v_day) >= v_limit then
    return null;
  end if;
  insert into vppsone.ai_jobs (id, staff_profile_id, action, session_label, target_id, target_revision, input_paths, model, created_at)
  values (v_id, p_staff, p_action, 'TEST-2026-27', p_target, p_revision,
    array(select v_id::text || '/' || i::text || '.' || v_extension from generate_series(1, p_pages) i), p_model, v_now);
  return v_id;
end;
$$;
revoke all on function vppsone.reserve_ai_job(uuid, text, uuid, integer, integer, text, text) from public, anon, authenticated;
grant execute on function vppsone.reserve_ai_job(uuid, text, uuid, integer, integer, text, text) to service_role;

create function vppsone.builtin_ai_usage() returns jsonb
language sql stable security invoker set search_path = '' as $$
with current_month as (
  select date_trunc('month', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata' as start_at
), jobs as materialized (
  select * from vppsone.ai_jobs where created_at >= (select start_at from current_month)
), handled as (
  select provider, count(*) as handled from jobs
  where parsed_at is not null and provider is not null group by provider
), attempts as (
  select a->>'provider' as provider, count(*) as attempts,
    sum(case when jsonb_typeof(a->'costInr') = 'number' then (a->>'costInr')::numeric else 0 end) as cost
  from jobs cross join lateral jsonb_array_elements(
    case when jsonb_typeof(jobs.attempts) = 'array' then jobs.attempts else '[]'::jsonb end
  ) a where a->>'provider' is not null group by a->>'provider'
), providers as (
  select provider, coalesce(handled.handled,0) as handled, coalesce(attempts.attempts,0) as attempts,
         coalesce(attempts.cost,0) as cost
  from handled full join attempts using (provider)
), failures as (
  select created_at, action, provider, error from jobs where status = 'failed'
  order by created_at desc limit 12
)
select jsonb_build_object(
  'actions', (select count(*) from jobs),
  'handled', (select count(*) from jobs where parsed_at is not null),
  'applied', (select count(*) from jobs where status = 'applied'),
  'edited', (select count(*) from jobs where status = 'applied' and edited),
  'costInr', (select coalesce(sum(estimated_cost_inr),0) from jobs),
  'providers', (select coalesce(jsonb_agg(to_jsonb(p) order by provider),'[]'::jsonb) from providers p),
  'failures', (select coalesce(jsonb_agg(to_jsonb(f) order by created_at desc),'[]'::jsonb) from failures f),
  'dailyLimit', (select daily_limit from vppsone.builtin_ai_settings where id = 1)
);
$$;
revoke all on function vppsone.builtin_ai_usage() from public, anon, authenticated;
grant execute on function vppsone.builtin_ai_usage() to service_role;

-- ======================================================== migrations/20261104055339_builtin_ai_live.sql
-- Built-in AI goes live for staff (owner direction, 4 November 2026).
--
-- The pilot fenced every AI job, cover-photo apply and Undo to TEST-2026-27.
-- A job now belongs to the session the member of staff is working in, which
-- the app resolves with the ordinary session rule. The fence that stays is the
-- one every other write keeps (D-340): a test account works only in a TEST
-- session. Cover-photo apply and Undo take their session from the job row,
-- never from the caller, and still go through commit_cover_command.

alter table vppsone.ai_jobs drop constraint ai_jobs_session_label_check;
alter table vppsone.ai_jobs add constraint ai_jobs_session_label_check
  check (session_label ~ '^([A-Z]{2,5}-)?[0-9]{4}-[0-9]{2}$');

drop function vppsone.reserve_ai_job(uuid, text, uuid, integer, integer, text, text);
create function vppsone.reserve_ai_job(
  p_staff uuid, p_action text, p_session text, p_target uuid, p_revision integer,
  p_pages integer, p_model text, p_audio_extension text default null
) returns uuid language plpgsql security invoker set search_path = '' as $$
declare
  v_id uuid := gen_random_uuid();
  v_now timestamptz := clock_timestamp();
  v_day timestamptz := date_trunc('day', v_now at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
  v_limit integer;
  v_extension text := coalesce(p_audio_extension, 'jpg');
  v_test boolean;
begin
  if p_action not in ('marks-photo','substitution-photo','voice')
     or p_pages is null or p_pages not between 1 and 4
     or (p_action = 'voice' and (p_pages <> 1 or v_extension not in ('webm','m4a','wav')))
     or (p_action <> 'voice' and p_audio_extension is not null)
     or p_action is null
     or p_session is null or p_session !~ '^([A-Z]{2,5}-)?[0-9]{4}-[0-9]{2}$' then
    raise exception 'invalid AI input';
  end if;
  select is_test_account into v_test from vppsone.staff_profiles where id = p_staff and is_active;
  if not found then
    raise exception 'invalid AI input';
  end if;
  -- A test account works only in a TEST session (D-340). Which real session a
  -- member of staff may open is the app's session rule (resolveSessionLabel).
  if v_test and p_session !~ '^(TEST|UAT|DEMO)-[0-9]{4}-[0-9]{2}$' then
    raise exception 'AI session not allowed';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('builtin-ai:' || p_staff::text, 0));
  select daily_limit into v_limit from vppsone.builtin_ai_settings where id = 1;
  if v_limit is null or (select count(*) from vppsone.ai_jobs where staff_profile_id = p_staff and created_at >= v_day) >= v_limit then
    return null;
  end if;
  insert into vppsone.ai_jobs (id, staff_profile_id, action, session_label, target_id, target_revision, input_paths, model, created_at)
  values (v_id, p_staff, p_action, p_session, p_target, p_revision,
    array(select v_id::text || '/' || i::text || '.' || v_extension from generate_series(1, p_pages) i), p_model, v_now);
  return v_id;
end;
$$;
revoke all on function vppsone.reserve_ai_job(uuid, text, text, uuid, integer, integer, text, text) from public, anon, authenticated;
grant execute on function vppsone.reserve_ai_job(uuid, text, text, uuid, integer, integer, text, text) to service_role;

create or replace function vppsone.apply_ai_cover_photo(
  p_job uuid, p_actor uuid, p_day date, p_timetable_day text,
  p_version uuid, p_bells integer, p_assignments jsonb, p_review jsonb
) returns jsonb
language plpgsql volatile security invoker set search_path = ''
as $$
declare
  v_session text;
  j vppsone.ai_jobs%rowtype;
  s vppsone.timetable_slots%rowtype;
  r record;
  v_existing jsonb;
  v_desired jsonb := '[]';
  v_previous_absences jsonb;
  v_absences jsonb;
  v_applied jsonb := '[]';
  v_keys text[] := '{}';
  v_row jsonb;
  v_written text;
  v_date_parts text[];
  v_starts timestamptz;
  v_first_start timestamptz;
  v_undo_until timestamptz;
  v_receipt jsonb;
  v_result jsonb;
begin
  if p_day is null or p_version is null or p_timetable_day is null or p_bells is null
     or length(btrim(p_timetable_day)) < 3
     or not starts_with(lower(to_char(p_day, 'FMDay')), lower(btrim(p_timetable_day)))
     or jsonb_typeof(p_assignments) is distinct from 'array'
     or jsonb_array_length(p_assignments) not between 1 and 60 then
    return jsonb_build_object('ok', false, 'reason', 'bad_request');
  end if;
  if not exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = p_actor and sp.is_active and rp.permission = 'substitutions:manage'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  select * into j from vppsone.ai_jobs
  where id = p_job and staff_profile_id = p_actor
    and action = 'substitution-photo' and purged_at is null
    and target_id = ('00000000-0000-4000-8000-0000' || to_char(p_day, 'YYYYMMDD'))::uuid
  for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  v_session := j.session_label;
  -- A test account acts only in a TEST session (D-340), whatever the caller says.
  if exists (select 1 from vppsone.staff_profiles where id = p_actor and is_test_account)
     and v_session !~ '^(TEST|UAT|DEMO)-[0-9]{4}-[0-9]{2}$' then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;
  if j.status = 'applied' then
    return jsonb_build_object('ok', true, 'result', j.final_applied_data);
  end if;
  if j.status <> 'draft' or j.parsed_at is null or j.raw_output is null
     or j.roster_stamp is distinct from p_version::text || ':' || p_bells::text then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;

  perform pg_advisory_xact_lock(hashtext('vppsone:cover:' || v_session || ':' || p_day::text));
  if coalesce((select revision from vppsone.cover_days where session_label = v_session and day = p_day), 0)
       <> j.target_revision
     or not exists (select 1 from vppsone.timetable_versions
                    where id = p_version and session_label = v_session and status = 'published') then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;

  -- The ordinary absence table's unique key omits session_label. Prevent a
  -- concurrent insertion for the same staff/day from letting the upsert
  -- replace an absence belonging to another session.
  lock table vppsone.teacher_absences in share row exclusive mode;

  select coalesce(jsonb_agg(to_jsonb(d)), '[]') into v_existing
  from vppsone.cover_duties d
  where d.session_label = v_session and d.day = p_day and d.status in ('assigned', 'needs_help');

  for r in
    select * from jsonb_to_recordset(p_assignments)
      as x(index integer, "absentId" uuid, "coveringId" uuid, "classId" uuid, period smallint, "needKey" text)
  loop
    if r."absentId" is null or r."coveringId" is null or r."absentId" = r."coveringId"
       or r."classId" is null or r.period is null or r.period not between 0 and 7
       or r.index is null or r.index not between 0 and 59 or r."needKey" is null
       or r."needKey" = any(v_keys) or v_applied @> jsonb_build_array(r.index) then
      return jsonb_build_object('ok', false, 'reason', 'bad_request');
    end if;

    v_row := j.raw_output->'rows'->r.index;
    v_written := btrim(translate(v_row->>'sourceDate', '०१२३४५६७८९０１２３４５６７８９', '01234567890123456789'));
    v_date_parts := regexp_match(v_written, '^([0-9]{1,2})[[:space:]]*([./-])[[:space:]]*([0-9]{1,2})[[:space:]]*\2[[:space:]]*([0-9]{4})$');
    if v_row->'unclear' is distinct from 'false'::jsonb or (
      v_written is distinct from p_day::text and
      (v_date_parts[4] || '-' || lpad(v_date_parts[3], 2, '0') || '-' || lpad(v_date_parts[1], 2, '0')) is distinct from p_day::text
    ) then
      return jsonb_build_object('ok', false, 'reason', 'source_date');
    end if;

    select (p_day + (period->>'starts')::time) at time zone 'Asia/Kolkata'
    into v_starts
    from vppsone.bell_schedules b, jsonb_array_elements(b.periods) period
    where b.session_label = v_session and b.is_current and b.revision = p_bells
      and (period->>'index')::smallint = r.period;
    if v_starts is null or v_starts <= clock_timestamp() + interval '2 minutes' then
      return jsonb_build_object('ok', false, 'reason', 'closed');
    end if;
    v_first_start := least(v_first_start, v_starts);

    select * into s from vppsone.timetable_slots ts
    where ts.version_id = p_version and ts.day = p_timetable_day and ts.period = r.period
      and ts.class_id = r."classId" and ts.staff_profile_id = r."absentId"
      and not ts.parallel and not ts.shared;
    if not found or r."needKey" <>
       (s.day || '|P' || s.period || '|ordinary|' || s.subject_code || '|' || s.class_id || '|' || s.staff_profile_id || '#lesson')
       or (select count(*) from vppsone.timetable_slots ts
           where ts.version_id = p_version and ts.day = p_timetable_day and ts.period = r.period
             and (ts.class_id = r."classId" or ts.staff_profile_id = r."absentId")) <> 1
       or (select count(*) from vppsone.staff_profiles sp
           where sp.id in (r."absentId", r."coveringId") and sp.is_active and sp.is_teaching) <> 2
       or not exists (select 1 from vppsone.timetable_slots ts
                      where ts.version_id = p_version and ts.staff_profile_id = r."coveringId")
       or exists (select 1 from vppsone.cover_policies cp
                  where cp.session_label = v_session and cp.staff_profile_id = r."coveringId"
                    and not (r.period = any(cp.allowed_periods)))
       or exists (select 1 from vppsone.teacher_leave l
                  where l.session_label = v_session and l.staff_profile_id = r."coveringId" and l.status = 'approved'
                    and p_day between l.from_day and l.to_day
                    and (l.span = 'full' or (l.span = 'first_half' and r.period <= 3)
                                         or (l.span = 'second_half' and r.period > 3)))
       or exists (select 1 from vppsone.teacher_absences a
                  where a.staff_profile_id = r."absentId" and a.day = p_day and a.session_label <> v_session)
       or exists (select 1 from vppsone.cover_duties d
                  where d.session_label = v_session and d.day = p_day and d.need_key = r."needKey"
                    and (d.status = 'assigned' or (d.covering_staff_id = r."coveringId" and d.cannot_cover_at is not null)))
    then
      return jsonb_build_object('ok', false, 'reason', 'conflict');
    end if;

    v_desired := v_desired || jsonb_build_object(
      'need_key', r."needKey", 'period', r.period, 'event_kind', 'ordinary',
      'class_ids', jsonb_build_array(s.class_id), 'class_labels', jsonb_build_array(s.class_label),
      'subject_code', s.subject_code, 'absent_staff_ids', jsonb_build_array(r."absentId"),
      'status', 'assigned', 'covering_staff_id', r."coveringId", 'source', 'manual', 'pinned', true
    );
    v_applied := v_applied || to_jsonb(r.index);
    v_keys := array_append(v_keys, r."needKey");
  end loop;

  -- Only append or fill the photographed duties. Keep every other duty,
  -- including unresolved duties and the coordinator's existing choices.
  v_desired := v_desired || coalesce(
    (select jsonb_agg(value) from jsonb_array_elements(v_existing) where not (value->>'need_key' = any(v_keys))),
    '[]'
  );
  with changes as (
    select (entry->>'absentId')::uuid as staff_id, array_agg(distinct (entry->>'period')::smallint) as periods
    from jsonb_array_elements(p_assignments) entry
    group by (entry->>'absentId')::uuid
  ), additions as (
    select c.staff_id, c.periods, a.periods as previous
    from changes c left join vppsone.teacher_absences a
      on a.staff_profile_id = c.staff_id and a.day = p_day and a.session_label = v_session
    where a.periods is null or not c.periods <@ a.periods
  )
  select coalesce(jsonb_agg(jsonb_build_object('staff_profile_id', staff_id, 'periods', previous)), '[]'),
         coalesce(jsonb_agg(jsonb_build_object('staff_profile_id', staff_id, 'periods', previous || periods)), '[]')
  into v_previous_absences, v_absences
  from additions;

  v_receipt := vppsone.commit_cover_command(jsonb_build_object(
    'command_id', p_job, 'kind', 'substitution_photo', 'actor_staff_id', p_actor, 'session_label', v_session,
    'day', p_day, 'timetable_day', p_timetable_day, 'payload_hash', 'substitution-photo:' || p_job,
    'expected', jsonb_build_object('day_revision', j.target_revision, 'timetable_version_id', p_version, 'bells_revision', p_bells),
    'absences', v_absences, 'duties', v_desired
  ));
  if not (v_receipt->>'ok')::boolean then return v_receipt; end if;
  v_undo_until := clock_timestamp() + interval '2 minutes';
  if v_first_start <= v_undo_until
     or (select count(*) from vppsone.staff_notices where command_id = p_job and status = 'pending')
          <> jsonb_array_length(v_applied) then
    raise exception 'substitution photo was not fully applied';
  end if;
  update vppsone.staff_notices set next_attempt_at = v_undo_until
  where command_id = p_job and status = 'pending';

  v_result := jsonb_build_object('jobId', p_job, 'review', p_review, 'applied', v_applied, 'undoUntil', v_undo_until);
  update vppsone.ai_jobs set
    status = 'applied', applied_at = v_undo_until - interval '2 minutes', final_applied_data = v_result,
    reviewed_data = jsonb_build_object(
      'duties', v_existing, 'absences', v_previous_absences, 'dayRevision', v_receipt->'day_revision',
      'version', p_version, 'bells', p_bells, 'timetableDay', p_timetable_day
    )
  where id = p_job;
  return jsonb_build_object('ok', true, 'result', v_result);
end;
$$;

create or replace function vppsone.undo_ai_cover_photo(p_job uuid, p_actor uuid, p_day date)
returns jsonb
language plpgsql volatile security invoker set search_path = ''
as $$
declare
  v_session text;
  j vppsone.ai_jobs%rowtype;
  v_undo_until timestamptz;
  v_notice_count integer;
  v_receipt jsonb;
  v_result jsonb;
begin
  if not exists (
    select 1 from vppsone.staff_profiles sp
    join vppsone.role_permissions rp on rp.role = sp.role
    where sp.id = p_actor and sp.is_active and rp.permission = 'substitutions:manage'
  ) then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;

  select * into j from vppsone.ai_jobs
  where id = p_job and staff_profile_id = p_actor
    and action = 'substitution-photo' and status = 'applied' and purged_at is null
    and target_id = ('00000000-0000-4000-8000-0000' || to_char(p_day, 'YYYYMMDD'))::uuid
  for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'not_found'); end if;
  v_session := j.session_label;
  -- A test account acts only in a TEST session (D-340), whatever the caller says.
  if exists (select 1 from vppsone.staff_profiles where id = p_actor and is_test_account)
     and v_session !~ '^(TEST|UAT|DEMO)-[0-9]{4}-[0-9]{2}$' then
    return jsonb_build_object('ok', false, 'reason', 'not_permitted');
  end if;
  if j.final_applied_data->>'undone' = 'true' then
    return jsonb_build_object('ok', true, 'result', j.final_applied_data);
  end if;
  v_undo_until := (j.final_applied_data->>'undoUntil')::timestamptz;
  if v_undo_until is null or clock_timestamp() >= v_undo_until then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;

  perform pg_advisory_xact_lock(hashtext('vppsone:cover:' || v_session || ':' || p_day::text));
  lock table vppsone.teacher_absences in share row exclusive mode;
  if exists (
    select 1 from vppsone.teacher_absences a
    join jsonb_array_elements(j.reviewed_data->'absences') prior on a.staff_profile_id = (prior->>'staff_profile_id')::uuid
    where a.day = p_day and a.session_label <> v_session
  ) then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;

  -- Teacher replies lock their duty before writing a notice. Use that same
  -- order here so any reply which already happened stays in the history and
  -- any reply to the withdrawn duty is refused after Undo commits.
  perform 1 from vppsone.cover_duties d where d.command_id = p_job order by d.id for update;

  -- Take the same notice locks the dispatcher claims, before the real-clock
  -- check. Once locked, the dispatcher skips these rows until Undo commits.
  perform 1 from vppsone.staff_notices n where n.command_id = p_job order by n.id for update;
  select count(*) into v_notice_count from vppsone.staff_notices
  where command_id = p_job and kind = 'cover_assigned';
  if clock_timestamp() >= v_undo_until then
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;
  if v_notice_count <> jsonb_array_length(j.final_applied_data->'applied') or exists (
    select 1 from vppsone.staff_notices n
    join vppsone.cover_duties d on d.id = n.duty_id
    where n.command_id = p_job
      and (n.status <> 'pending' or n.attempts <> 0 or n.next_attempt_at is distinct from v_undo_until
           or d.status <> 'assigned')
  ) then
    return jsonb_build_object('ok', false, 'reason', 'stale');
  end if;

  v_receipt := vppsone.commit_cover_command(jsonb_build_object(
    'command_id', gen_random_uuid(), 'kind', 'substitution_photo_undo', 'actor_staff_id', p_actor,
    'session_label', v_session, 'day', p_day, 'timetable_day', j.reviewed_data->'timetableDay',
    'payload_hash', 'substitution-photo-undo:' || p_job,
    'expected', jsonb_build_object(
      'day_revision', j.reviewed_data->'dayRevision',
      'timetable_version_id', j.reviewed_data->'version', 'bells_revision', j.reviewed_data->'bells'
    ),
    'absences', j.reviewed_data->'absences', 'duties', j.reviewed_data->'duties'
  ));
  if not (v_receipt->>'ok')::boolean then return v_receipt; end if;
  if exists (select 1 from vppsone.staff_notices where command_id = p_job and status <> 'cancelled') then
    raise exception 'substitution photo notices were not withdrawn';
  end if;
  v_result := j.final_applied_data || jsonb_build_object('undone', true);
  update vppsone.ai_jobs set final_applied_data = v_result where id = p_job;
  return jsonb_build_object('ok', true, 'result', v_result);
end;
$$;

-- Create or replace keeps the grants; restated for the reader.
revoke all on function vppsone.apply_ai_cover_photo(uuid, uuid, date, text, uuid, integer, jsonb, jsonb) from public, anon, authenticated;
revoke all on function vppsone.undo_ai_cover_photo(uuid, uuid, date) from public, anon, authenticated;
grant execute on function vppsone.apply_ai_cover_photo(uuid, uuid, date, text, uuid, integer, jsonb, jsonb) to service_role;
grant execute on function vppsone.undo_ai_cover_photo(uuid, uuid, date) to service_role;

-- A notice for any duty that descends from an applied AI cover photo honours
-- its Undo hold, in every session.
create or replace function vppsone.inherit_ai_cover_photo_hold()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  v_hold timestamptz;
begin
  if new.duty_id is null then return new; end if;
  with recursive chain as (
    select id, supersedes, command_id from vppsone.cover_duties where id = new.duty_id
    union
    select d.id, d.supersedes, d.command_id from vppsone.cover_duties d join chain c on c.supersedes = d.id
  )
  select max((j.final_applied_data->>'undoUntil')::timestamptz) into v_hold
  from chain c join vppsone.ai_jobs j on c.command_id = j.id
  where j.action = 'substitution-photo' and j.status = 'applied';

  if v_hold > clock_timestamp() then new.next_attempt_at := greatest(new.next_attempt_at, v_hold); end if;
  return new;
end;
$$;
revoke all on function vppsone.inherit_ai_cover_photo_hold() from public, anon, authenticated;

-- ======================================================== migrations/20261104083132_builtin_ai_key_status.sql
-- Built-in AI: which key answered, and what each key last did (4 November 2026).
--
-- ai_jobs.key_type records how the answering key is paid for: the free AI
-- Studio tier, Google billing, or prepaid API credits (lib/ai/router.ts).
-- builtin_ai_provider_status keeps one row per key: working, out of quota
-- (with the time a free-tier daily quota resets, midnight Pacific), or
-- failing, with a fixed failure category and HTTP status only. Every server
-- instance reads it, so one exhausted free key is skipped everywhere.
-- builtin_ai_settings.last_smoke holds the admin key check's results.
-- Server only: RLS on, no browser grants.

alter table vppsone.ai_jobs add column key_type text check (key_type in ('free', 'paid', 'credits'));

create table vppsone.builtin_ai_provider_status (
  provider text primary key check (provider in ('gemini-free', 'gemini-paid', 'anthropic', 'openai')),
  state text not null check (state in ('ok', 'quota', 'failing')),
  problem text check (problem ~ '^[a-z_]{1,32}$'),
  http_status integer check (http_status between 100 and 599),
  model text check (char_length(model) <= 80),
  blocked_until timestamptz,
  checked_at timestamptz not null default now()
);
alter table vppsone.builtin_ai_provider_status enable row level security;
revoke all on vppsone.builtin_ai_provider_status from public, anon, authenticated;
grant select, insert, update on vppsone.builtin_ai_provider_status to service_role;

alter table vppsone.builtin_ai_settings add column last_smoke jsonb;
alter table vppsone.builtin_ai_settings add column last_smoke_at timestamptz;

-- ======================================================== migrations/20261105063256_assist_drafts_cover_reports.sql
-- AI that shows up without being asked (D-418) and the cover period's report
-- back to the absent teacher (D-419).
--
-- assist_drafts: drafts the app prepares for one member of staff before they
-- ask: the plan for a cover duty, a class's week of notes. A draft is a
-- suggestion only; it never becomes school data until the person uses it on
-- the ordinary screen. One row per (person, kind, thing it is about), so a
-- rerun replaces rather than piles up. Expired rows are purged with the log.
--
-- cover_reports: one line from the teacher who covered a period ("settled",
-- "work done", "a problem") with an optional sentence, for the teacher who was
-- away. One report per duty; the covering teacher may change it.
--
-- Both private, like assist_log: RLS on with no policies and nothing granted to
-- anon or authenticated. The app reaches them only through the service role,
-- after its own permission and ownership checks.

create table vppsone.assist_drafts (
  id uuid primary key default gen_random_uuid(),
  staff_profile_id uuid not null references vppsone.staff_profiles (id) on delete cascade,
  kind text not null check (kind in ('cover_plan', 'class_digest')),
  ref text not null check (char_length(ref) between 1 and 120),
  session_label text not null check (session_label ~ '^([A-Z]{2,5}-)?[0-9]{4}-[0-9]{2}$'),
  title_en text not null check (char_length(title_en) between 1 and 160),
  title_hi text not null check (char_length(title_hi) between 1 and 160),
  href text check (href is null or (href ~ '^/[A-Za-z0-9/_?=&.%-]*$' and char_length(href) <= 300)),
  payload jsonb not null,
  log_id uuid,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  decision text check (decision in ('kept', 'edited', 'discarded')),
  decided_at timestamptz,
  constraint assist_drafts_decided check ((decision is null) = (decided_at is null)),
  constraint assist_drafts_one unique (staff_profile_id, kind, ref)
);

create index assist_drafts_waiting on vppsone.assist_drafts (staff_profile_id, expires_at) where decision is null;

create table vppsone.cover_reports (
  duty_id uuid primary key references vppsone.cover_duties (id) on delete cascade,
  session_label text not null check (session_label ~ '^([A-Z]{2,5}-)?[0-9]{4}-[0-9]{2}$'),
  written_by uuid not null references vppsone.staff_profiles (id) on delete cascade,
  outcome text not null check (outcome in ('settled', 'work_done', 'problem')),
  body text check (body is null or char_length(body) between 1 and 600),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  seen_by uuid[] not null default '{}'
);

create index cover_reports_recent on vppsone.cover_reports (session_label, created_at desc);

alter table vppsone.assist_drafts enable row level security;
alter table vppsone.cover_reports enable row level security;

revoke all on vppsone.assist_drafts, vppsone.cover_reports from anon, authenticated;
grant all on vppsone.assist_drafts, vppsone.cover_reports to service_role;

-- ======================================================== migrations/20261106122604_notes_client_request_id.sql
-- VPPS One — a note saved twice files once (20-teacher school day, 6 Nov 2026).
--
-- `createNoteAction` inserted `notes` rows with no idempotency key. On a slow
-- day a save took 30-90 s; a teacher who left the screen while it said "Still
-- saving" came back to her draft ("not saved yet"), saved it again, and the
-- child got two identical notes, each with its own follow-up to the class
-- teacher. Six of ten teacher seats hit it in the smoke run.
--
-- The composer now gives every draft one id, keeps it in the stored draft and
-- sends it with every save of that draft. The server stores it here and, when
-- the id is already filed for that writer, returns the original note instead
-- of inserting (src/vx/screens/notes/actions.ts). Same shape as
-- `teacher_leave_request_once` (20261103192446).
--
-- Additive: the column is nullable and nothing is backfilled; the partial
-- index leaves out every existing row and every note written elsewhere.
--
-- Rollback:
--   drop index if exists vppsone.notes_request_once;
--   alter table vppsone.notes drop column if exists client_request_id;

begin;
set local lock_timeout = '5s';
set local statement_timeout = '60s';

alter table vppsone.notes
  add column if not exists client_request_id uuid;

comment on column vppsone.notes.client_request_id is
  'The composer''s id for one draft, kept across its retries. A repeat save with the same id returns the note already filed instead of a second one. NULL for notes from before it and from other screens.';

create unique index if not exists notes_request_once
  on vppsone.notes (written_by, client_request_id)
  where client_request_id is not null;

notify pgrst, 'reload schema';

commit;

-- ======================================================== migrations/20261106143831_parent_message_switches.sql
-- Admin on/off switches for every message VPPS One queues for parents (owner,
-- 6 Nov 2026: "let admin make the switch on off of all the decisions that
-- needs to send to parent").
--
-- One row per kind of vppsone.parent_message_queue. `enabled` decides whether
-- the app queues that kind at all; `starts_on` is the register's parent switch
-- default for the first save of the day (D-320), read only for absent_alert.
-- Nothing here sends: the queue is still sent by a person from Messages → To
-- send. Seeded to today's behaviour, so applying this changes nothing until an
-- admin flips a switch.
--
-- Rollback: drop table vppsone.parent_message_switches;

create table if not exists vppsone.parent_message_switches (
  kind text primary key,
  enabled boolean not null default true,
  starts_on boolean not null default true,
  updated_by uuid references vppsone.staff_profiles (id) on delete set null,
  updated_at timestamptz not null default now(),
  constraint parent_message_switches_kind_known check (kind in ('absent_alert', 'birthday', 'note', 'support_plan'))
);
comment on table vppsone.parent_message_switches is
  'Admin switches: which kinds of parent_message_queue the app may queue, and whether the register''s parent switch starts on. Written by Settings → Messages to parents.';

insert into vppsone.parent_message_switches (kind, enabled, starts_on) values
  ('absent_alert', true, true),
  ('birthday', true, true),
  ('note', true, true),
  ('support_plan', true, true)
on conflict (kind) do nothing;

alter table vppsone.parent_message_switches enable row level security;
-- Read and written on the service role, after the caller's permission check.
grant select, insert, update on vppsone.parent_message_switches to service_role;

-- ======================================================== migrations/20261106162701_fees_bridge_nightly_only.sql
-- The Fees roster is copied into One once a night, not every minute
-- (owner's decision, 6 Nov 2026, D-457: "a night sync is enough").
--
-- 1. Remove the every-minute `fees-bridge-sync` pg_cron job. It was paused by
--    hand during the 6 Nov outage (it ran each minute for up to 120 s and
--    overlapped itself). Unscheduling it, rather than leaving it inactive,
--    means no later script or person can switch it back on by mistake.
--    `fees-bridge-nightly-verify` (20:30 UTC = 02:00 IST, `?verify=1`) stays:
--    it forces a full snapshot, applies it and acknowledges the events, so it
--    is a complete sync on its own. `fees-bridge-cron-history` stays.
-- 2. A roster checked last night is current until the next night. Four
--    readers refused anything older than five minutes; they now allow 26 hours
--    (a day plus slack), the same figure as BRIDGE_FRESH_FOR_MS in
--    src/platform/fees-bridge/state.ts. The functions are patched in place by
--    exact text, and the migration fails unless each holds the old check
--    exactly once, so a function that has changed shape is never half-edited.
--    Money figures are not affected: canonical financial lookup is still a
--    direct request to Fees.
begin;

do $$
declare j bigint;
begin
  for j in select jobid from cron.job where jobname = 'fees-bridge-sync' loop
    perform cron.unschedule(j);
  end loop;
end;
$$;

do $$
declare
  f text;
  d text;
  old_check constant text := 'last_checked_at>=clock_timestamp()-interval ''5 minutes''';
  new_check constant text := 'last_checked_at>=clock_timestamp()-interval ''26 hours''';
begin
  foreach f in array array[
    'vppsone.school_certificate_facts_v2(uuid,uuid,text,text,boolean)',
    'vppsone.school_certificate_roster(uuid,text,boolean)',
    'vppsone.school_office_attention(uuid,text,boolean)',
    'vppsone.school_office_roster(uuid,text,text,boolean)'
  ] loop
    d := pg_get_functiondef(f::regprocedure);
    if (length(d) - length(replace(d, old_check, ''))) / length(old_check) <> 1 then
      raise exception 'fees_bridge_nightly_only: % does not hold the five-minute check exactly once', f;
    end if;
    execute replace(d, old_check, new_check);
  end loop;
end;
$$;

commit;

-- ======================================================== migrations/20261106192629_bolo_typed_requests.sql
-- Bolo can be typed as well as spoken (teacher day, 6 Nov 2026: "You can't
-- type to Bolo"). A typed request is one UTF-8 text file in the same private
-- bucket, on the same voice job, quota, review and 90-day purge as a recording.
-- The server writes it; no browser uploads text.
begin;

update storage.buckets
set allowed_mime_types = array['image/jpeg','audio/webm','audio/mp4','audio/wav','audio/m4a','text/plain']
where id = 'ai-inputs' and public is false;

create or replace function vppsone.reserve_ai_job(
  p_staff uuid, p_action text, p_session text, p_target uuid, p_revision integer,
  p_pages integer, p_model text, p_audio_extension text default null
) returns uuid language plpgsql set search_path = '' as $$
declare
  v_id uuid := gen_random_uuid();
  v_now timestamptz := clock_timestamp();
  v_day timestamptz := date_trunc('day', v_now at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
  v_limit integer;
  v_extension text := coalesce(p_audio_extension, 'jpg');
  v_test boolean;
begin
  if p_action not in ('marks-photo','substitution-photo','voice')
     or p_pages is null or p_pages not between 1 and 4
     or (p_action = 'voice' and (p_pages <> 1 or v_extension not in ('webm','m4a','wav','txt')))
     or (p_action <> 'voice' and p_audio_extension is not null)
     or p_action is null
     or p_session is null or p_session !~ '^([A-Z]{2,5}-)?[0-9]{4}-[0-9]{2}$' then
    raise exception 'invalid AI input';
  end if;
  select is_test_account into v_test from vppsone.staff_profiles where id = p_staff and is_active;
  if not found then
    raise exception 'invalid AI input';
  end if;
  -- A test account works only in a TEST session (D-340). Which real session a
  -- member of staff may open is the app's session rule (resolveSessionLabel).
  if v_test and p_session !~ '^(TEST|UAT|DEMO)-[0-9]{4}-[0-9]{2}$' then
    raise exception 'AI session not allowed';
  end if;
  perform pg_advisory_xact_lock(hashtextextended('builtin-ai:' || p_staff::text, 0));
  select daily_limit into v_limit from vppsone.builtin_ai_settings where id = 1;
  if v_limit is null or (select count(*) from vppsone.ai_jobs where staff_profile_id = p_staff and created_at >= v_day) >= v_limit then
    return null;
  end if;
  insert into vppsone.ai_jobs (id, staff_profile_id, action, session_label, target_id, target_revision, input_paths, model, created_at)
  values (v_id, p_staff, p_action, p_session, p_target, p_revision,
    array(select v_id::text || '/' || i::text || '.' || v_extension from generate_series(1, p_pages) i), p_model, v_now);
  return v_id;
end;
$$;
revoke all on function vppsone.reserve_ai_job(uuid, text, text, uuid, integer, integer, text, text) from public, anon, authenticated;
grant execute on function vppsone.reserve_ai_job(uuid, text, text, uuid, integer, integer, text, text) to service_role;

commit;

-- ======================================================== migrations/20261107042312_fees_reports_role_permissions.sql
-- D-476: Reports gets its own switch, fees:reports ("See fee reports" on
-- Staff -> Roles), so the admin decides who opens the fee reports apart from
-- who reads the other fee screens. On for the roles that had Reports before
-- and whose Fees role carries reports:view; off for the office (owner,
-- 7 Nov 2026: the two Viewers do not get reports). Rows only; additive.
-- The admin row comes first because set_role_permissions only offers a
-- permission the admin role already holds.
insert into vppsone.role_permissions (role, permission) values
  ('admin', 'fees:reports'),
  ('accountant', 'fees:reports'),
  ('fee_collector', 'fees:reports')
on conflict do nothing;

-- ======================================================== migrations/20261107045006_ai_report_role_permissions.sql
-- D-484, D-485: the AI report (reports:ai, "Download the AI report" on Staff -> Roles):
-- one file of everything One and Fees hold for a session, student photographs
-- included, for staff to give to an AI assistant. The admin's alone by default
-- (owner, 7 Nov 2026); the admin can grant it to another role in the matrix,
-- and what the file carries is still narrowed to what that reader may see.
-- Rows only; additive. The admin row is the only one: set_role_permissions
-- offers a permission to other roles only once the admin role holds it.
insert into vppsone.role_permissions (role, permission) values
  ('admin', 'reports:ai')
on conflict do nothing;

-- ======================================================== migrations/20261107045020_ai_report_export_kind.sql
-- D-485: every AI report download is logged in academic_exports like the
-- other bulk exports (who took which session, when, how many rows), so the
-- admin can see who took a file that holds the whole school's records.
alter type vppsone.export_kind add value if not exists 'ai_report';
