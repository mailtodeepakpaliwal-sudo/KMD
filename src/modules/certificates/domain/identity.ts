import { z } from "zod";

/**
 * The school's certificate identity: the letterhead, who signs, where, under
 * which codes, and how the page is laid out. Entered once by a certificate
 * manager and frozen into every document prepared afterwards. School codes
 * live here, never in a student's external identifiers.
 *
 * The defaults are the school's official letterhead (Google Drive,
 * originally another school's letterhead; now KMD Public School, Jaipur), so a school that has
 * never opened Certificate settings still prints its real letterhead. A
 * manager can change any line; a line saved empty is left off the page.
 */
const text = (max: number, fallback = "") => z.string().trim().max(max).refine((value) => !/[{}<>]/.test(value), "Unsafe text").default(fallback);
const code = (fallback = "") => z.string().trim().max(40).regex(/^[A-Za-z0-9/ .-]*$/, "Use letters, numbers and / - . only").default(fallback);

export const OFFICIAL_LETTERHEAD = {
  nameHi: "के.एम.डी. पब्लिक स्कूल",
  trust: "",
  // KMD Public School, Lal Bhawan, Barkat Nagar, Jaipur. Blank lines below
  // (phone, email, codes) are left off the page until filled in Certificate
  // settings.
  address: "Lal Bhawan, Barkat Nagar, Jaipur (Raj.) – 302015",
  phone: "",
  email: "",
  website: "",
  registrationNo: "",
  recognitionNo: "",
  recognisedBy: "Government of Rajasthan",
  udiseCode: "",
  pspCode: "",
  place: "Jaipur",
} as const;

export const certificateIdentitySchema = z.object({
  principalName: text(80), principalDesignation: text(60).transform((value) => value || "Principal"),
  principalDesignationHi: text(60).transform((value) => value || "प्रधानाचार्य"),
  place: text(60, OFFICIAL_LETTERHEAD.place), udiseCode: code(OFFICIAL_LETTERHEAD.udiseCode), pspCode: code(OFFICIAL_LETTERHEAD.pspCode),
  recognitionNo: code(OFFICIAL_LETTERHEAD.recognitionNo), registrationNo: code(OFFICIAL_LETTERHEAD.registrationNo),
  recognisedBy: text(80, OFFICIAL_LETTERHEAD.recognisedBy), trust: text(100, OFFICIAL_LETTERHEAD.trust),
  nameHi: text(100, OFFICIAL_LETTERHEAD.nameHi), address: text(160, OFFICIAL_LETTERHEAD.address),
  phone: text(40, OFFICIAL_LETTERHEAD.phone), email: text(80, OFFICIAL_LETTERHEAD.email), website: text(80, OFFICIAL_LETTERHEAD.website),
  /**
   * `facsimile`: the principal's signature (the one on every receipt) and the
   * school seal are printed on every certificate prepared or approved by
   * someone allowed to issue them (owner's request, 7 Nov 2026; D-541).
   * `manual`: a clean line and an empty seal circle, signed and stamped by
   * hand. Turning the printed signature back on after that records who did
   * it and when.
   */
  signaturePolicy: z.enum(["manual", "facsimile"]).default("manual"),
  facsimileEnabledBy: z.string().max(80).nullable().default(null), facsimileEnabledAt: z.string().max(40).nullable().default(null),
  layout: z.enum(["classic", "preprinted"]).default("classic"),
  /** Millimetres to nudge text onto a pre-printed form, from a calibration print. */
  offsetX: z.number().min(-20).max(20).default(0), offsetY: z.number().min(-20).max(20).default(0),
});
export type CertificateIdentity = z.infer<typeof certificateIdentitySchema>;
export const DEFAULT_IDENTITY: CertificateIdentity = certificateIdentitySchema.parse({});

export function cleanIdentity(input: unknown): CertificateIdentity {
  const parsed = certificateIdentitySchema.safeParse(input ?? {});
  return parsed.success ? parsed.data : DEFAULT_IDENTITY;
}

/**
 * The record of who allowed a facsimile is kept by the server: switching it on
 * stamps the actor and time, switching it off clears them, and a save that
 * leaves the policy alone keeps the original stamp.
 */
export function stampIdentity(before: CertificateIdentity, after: CertificateIdentity, actor: string, now: string): CertificateIdentity {
  if (after.signaturePolicy === "manual") return { ...after, facsimileEnabledBy: null, facsimileEnabledAt: null };
  if (before.signaturePolicy === "facsimile") return { ...after, facsimileEnabledBy: before.facsimileEnabledBy, facsimileEnabledAt: before.facsimileEnabledAt };
  return { ...after, facsimileEnabledBy: actor, facsimileEnabledAt: now };
}
