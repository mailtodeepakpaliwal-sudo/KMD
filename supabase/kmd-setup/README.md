# KMD One — database setup (Supabase project `uvvusynovvhtacauvrzc`)

The original app ran next to a separate "School Fees" app, and its fee
tables came from that app's own database, which was never part of this code.
This folder rebuilds that missing fee base from scratch for KMD Public School
and then replays all of One's own migrations on top, so a brand-new Supabase
project gets the complete database.

Tested end to end on a local Postgres with Supabase stand-ins: every part
applies in order, and a full money test passes (posting with receipt numbers
`KMD<date>-0001`, a repeated request returning the same receipt, late fees,
waivers, an EMI plan, a reversal, both dashboards, permissions for admin,
viewer and an anonymous visitor).

## Run it (about 10 minutes)

Part 1 (extensions) is **already applied** to the project.

1. Open https://supabase.com/dashboard/project/uvvusynovvhtacauvrzc/sql/new
2. Open `parts/kmd_db_part02.sql` in a text editor, select all, copy, paste
   into the SQL Editor, press **Run**. Wait for "Success".
3. Repeat for `part03` … `part11`, **in order, each exactly once**, using a
   fresh query tab each time.
4. If a part shows an error, stop and send the message: don't run the next
   part.

## Make yourself the admin

1. Dashboard → Authentication → Users → **Add user** → your email and a
   password (tick "Auto confirm").
2. SQL Editor, with your email in place of the example:

```sql
insert into vppsone.staff_profiles (user_id, display_name, short_name, role, is_active)
select u.id, 'Principal', 'Principal', 'admin', true
from auth.users u where lower(u.email) = lower('principal@example.com')
on conflict (user_id) do update set role = 'admin', is_active = true;
```

3. Dashboard → Authentication → Sign In / Providers → turn **off**
   "Allow new users to sign up" (staff logins are created by an admin in the
   app's Staff screen).

## App settings (Vercel or `.env.local`)

`NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` are
already filled in `.env.example`. Copy `SUPABASE_SERVICE_ROLE_KEY` from
Dashboard → Project Settings → API keys (secret — never share or commit it).

## After the app is online

`reschedule-jobs.sql` brings back the six background jobs (WhatsApp queue,
templates, parent chats and files) that call the app over the web. They were
removed because they pointed at the old school's address. Replace
`YOUR-KMD-APP-ADDRESS` with your app's address, add the Vault secret
`WHATSAPP_QUEUE_CRON_SECRET` (Dashboard → Vault), then run it.

## What is in this folder

| Path | What |
|---|---|
| `base/` | the rebuilt fee base: tables, keys, permission helpers, the ledger calculation and views, every fee function the app calls, write rules |
| `override/` | three migrations changed for a fresh database (a Postgres 17 fix; the old owner's QA run; the receipt floor patch) |
| `skip.txt` | ten migrations not used: they copied the old school's live Fees database every night |
| `post/` | finishing step: helper name "KMD AI", old-address jobs removed, fee writes on |
| `parts/` | everything above plus all migrations, packed for the SQL Editor |
| `local/` | the local test bed and the money / permission tests |
| `tools/` | the scripts that build and replay the parts |

## Known limits of the rebuilt fee base

- Late fee rule: a flat late fee per installment once its due date passes
  with the base charge not settled by then. Matches the app's own
  calculation; check it fits KMD's policy before the first late date.
- Plain views, not materialized: fine for one school's size.
- The fees app's row-by-row import RPC and "corrected payment" RPC refuse
  with a message: the app's own import screens and Payment Desk do that work.
