# KMD One — KMD Public School, Lal Bhawan, Barkat Nagar, Jaipur

This codebase was converted from "VPPS One" (Shri Veer Patta Sr. Sec. School,
Amet) for **KMD Public School, Lal Bhawan, Barkat Nagar, Jaipur (Raj.)**.

## What was changed

- School name everywhere people see it: screens, receipts, certificates,
  PDFs, WhatsApp messages, AI helper prompts, exports, app manifest
  (English: "KMD Public School", Hindi: "के.एम.डी. पब्लिक स्कूल").
- App name "VPPS One" → "KMD One"; the WhatsApp helper "Veer Patta AI" → "KMD AI".
- Address → "Lal Bhawan, Barkat Nagar, Jaipur (Raj.) – 302015"; place → Jaipur.
- Logo and app icons replaced with a placeholder KMD badge
  (`public/branding/school-logo.jpg`, `school-emblem.png`, `icon-192.png`, `icon-512.png`).
- The old school's **seal and principal's signature were removed**
  (`school-seal.png` and `authorised-signature.png` are now blank), and
  certificates default to **hand-signing** ("manual") until you add your own.
- The old school's phone numbers, email, website, trust name, registration,
  recognition, UDISE and PSP codes were removed (left blank, so the line is
  simply left off the page).
- Receipt prefix "SVP" → "KMD"; certificate number prefixes → `KMD/TC`, `KMD/CC`, ...
- The old WhatsApp number is replaced by the placeholder `+91 00000 00000`,
  so nothing can be sent from it.
- Web links `one.vpps.co.in` / `fees.vpps.co.in` → placeholders
  `one.kmd-school.example` / `fees.kmd-school.example`.

Internal technical names were deliberately **kept** (the `vppsone` database
schema, `VPPS_*` environment variable names, `getVppsOneEnvironment()`, the
`VPPSPDF*` font files, `qa.vpps.local` test accounts). Renaming them would
break the database migrations and gain nothing visible.

## What you still need to fill in

| Item | Where |
|---|---|
| Real logo | replace `public/branding/school-logo.jpg` (1500×1500), `school-emblem.png`, `icon-192.png`, `icon-512.png` |
| Principal's signature and school seal | `public/branding/authorised-signature.png` (560×168, transparent) and `school-seal.png` (640×640, transparent); then switch Certificate settings to "printed signature" |
| Phone, email | env `NEXT_PUBLIC_SCHOOL_PHONE`, `NEXT_PUBLIC_SCHOOL_EMAIL` (and Certificate settings in the app) |
| PIN code | 302015 was used for Barkat Nagar; correct it in `src/platform/config/school.ts` and `src/modules/certificates/domain/identity.ts` if different |
| Trust, registration no., recognition no., UDISE, PSP code | `src/modules/certificates/domain/identity.ts` (`OFFICIAL_LETTERHEAD`) or Certificate settings in the app |
| Website / app domain | search for `kmd-school.example` and replace with your real domain |
| WhatsApp number | `src/platform/whatsapp/numbers.ts`, `src/modules/whatsapp/domain/staff-link.ts`, `src/app/login/code-form.tsx`, `src/platform/whatsapp/config.ts` (search for `00000`) |
| Your own Supabase database | **Built** — project `uvvusynovvhtacauvrzc`; run the SQL Editor parts in `supabase/kmd-setup/` (see its README). The code already points at this project. |
| Fees app bridge | Not needed: KMD keeps fees in its own database (the bridge is off, and the nightly copy from the old school's Fees app is left out). |
| Fee amounts and bus routes | the starting defaults in `src/modules/fees/domain/workbook.ts` are still the old school's (Amet routes, tuition per class); set your own in Fee setup |

Older notes under `docs/` describe the original school's history and were left unchanged.
