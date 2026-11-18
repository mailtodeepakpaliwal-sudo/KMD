import { schoolProfile } from "./school";

/**
 * The office number parents are told to call, from `NEXT_PUBLIC_SCHOOL_PHONE`.
 *
 * Empty until the owner sets it (18 Nov 2026). The VPPS → KMD conversion left
 * the old school's 9352205884 in the WhatsApp messages and an empty number in
 * the helper's replies ("call the office: "). Every message now reads its
 * number from here, and drops the "call the office" line or button when there
 * is none, rather than give a parent a wrong number or a blank one.
 */
function lastTenDigits(value: string): string {
  const digits = value.replace(/\D/g, "");
  return digits.length >= 10 ? digits.slice(-10) : "";
}

/** Ten digits, e.g. `9876543210`, or "" when the school has not set one. */
export const OFFICE_PHONE_DIGITS = lastTenDigits(schoolProfile.officePhone);

/** `+919876543210`, as a WhatsApp Call button needs it, or "". */
export const OFFICE_PHONE_E164 = OFFICE_PHONE_DIGITS ? `+91${OFFICE_PHONE_DIGITS}` : "";
