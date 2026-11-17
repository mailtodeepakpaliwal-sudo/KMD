-- Re-add the background jobs that call the app over the web.
-- 1) Replace YOUR-KMD-APP-ADDRESS (e.g. one.kmdpublicschool.in).
-- 2) Add the Vault secret WHATSAPP_QUEUE_CRON_SECRET (same value as CRON_SECRET in the app).
-- 3) Run in the SQL Editor.
select cron.schedule('parent-chats', '*/2 * * * *', $job$
  select net.http_post(
    url := 'https://YOUR-KMD-APP-ADDRESS/api/jobs/parent-chats',
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
  $job$);
select cron.schedule('parent-files', '17 * * * *', $job$
  select net.http_post(
    url := 'https://YOUR-KMD-APP-ADDRESS/api/jobs/parent-files',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'WHATSAPP_QUEUE_CRON_SECRET')
    ),
    body := '{"part": "files"}'::jsonb,
    timeout_milliseconds := 290000
  )
  where exists (
    select 1 from vppsone.runtime_flags f
     where f.key = 'whatsapp_features'
       and f.enabled is true
       and f.value -> 'parent_helper' = 'true'::jsonb
  );
  $job$);
select cron.schedule('parent-helper', '*/5 * * * *', $job$
  select net.http_post(
    url := 'https://YOUR-KMD-APP-ADDRESS/api/jobs/parent-helper',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'WHATSAPP_QUEUE_CRON_SECRET')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  )
  where exists (
    select 1 from vppsone.parent_helper_handoffs h
     where h.next_action_at is not null and h.next_action_at <= now()
       and h.answered_at is null and h.closed_at is null
  );
  $job$);
select cron.schedule('whatsapp-chat-archive', '40 21 * * *', $job$
  select net.http_post(
    url := 'https://YOUR-KMD-APP-ADDRESS/api/jobs/parent-files',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'WHATSAPP_QUEUE_CRON_SECRET')
    ),
    body := '{"part": "archive"}'::jsonb,
    timeout_milliseconds := 290000
  );
  $job$);
select cron.schedule('whatsapp-queue', '*/5 * * * *', $job$
  select net.http_post(
    url := 'https://YOUR-KMD-APP-ADDRESS/api/jobs/whatsapp-queue',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'WHATSAPP_QUEUE_CRON_SECRET')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  )
  where exists (
    select 1 from vppsone.whatsapp_messages m
     where m.status in ('queued', 'retry_wait') and m.next_attempt_at <= now()
  )
  or exists (
    select 1 from vppsone.whatsapp_messages m
     where m.provider = 'hub' and m.status in ('accepted', 'sent') and m.provider_message_id is not null
       and vppsone.whatsapp_poll_is_due(m)
  );
  $job$);
select cron.schedule('whatsapp-templates', '17 * * * *', $job$
  select net.http_post(
    url := 'https://YOUR-KMD-APP-ADDRESS/api/jobs/whatsapp-templates',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || (select s.decrypted_secret from vault.decrypted_secrets s where s.name = 'WHATSAPP_QUEUE_CRON_SECRET')
    ),
    body := '{}'::jsonb,
    timeout_milliseconds := 55000
  );
  $job$);
