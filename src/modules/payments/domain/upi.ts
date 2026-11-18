export type StudentFeeUpiPaymentInput = {
  admissionNo: string;
  amount: number;
};

export type StudentFeeUpiPayment = {
  uri: string;
  displayReference: string;
  payeeName: string;
  vpa: string;
  amount: number;
};

/**
 * KMD's UPI ID, from `NEXT_PUBLIC_SCHOOL_UPI_ID` (read literally so Next.js
 * inlines it into the browser bundles that draw the QR).
 *
 * Empty until the owner sets it (18 Nov 2026). The VPPS → KMD conversion kept
 * the old school's HDFC ID here under KMD's name, so a parent paying by the QR
 * would have paid that school. While it is empty no UPI QR or link is drawn
 * anywhere: check `schoolUpiConfigured()` before building one.
 */
export const SCHOOL_UPI_PAYMENT_CONFIG = {
  vpa: process.env.NEXT_PUBLIC_SCHOOL_UPI_ID?.trim() ?? "",
  payeeName: "KMD PUBLIC SCHOOL",
  currency: "INR",
} as const;

/** True only when the school has its own UPI ID set. */
export function schoolUpiConfigured(): boolean {
  return SCHOOL_UPI_PAYMENT_CONFIG.vpa.length > 0;
}

function wholeRupees(value: number) {
  return Math.max(0, Math.round(Number.isFinite(value) ? value : 0));
}

function paymentReference(admissionNo: string) {
  const normalized = admissionNo.replace(/\s+/g, " ").trim() || "STUDENT";
  return `Fee ${normalized}`.slice(0, 35);
}

export function buildStudentFeeUpiPayment(
  input: StudentFeeUpiPaymentInput,
): StudentFeeUpiPayment {
  const amount = wholeRupees(input.amount);
  const displayReference = paymentReference(input.admissionNo);
  const params = new URLSearchParams({
    pa: SCHOOL_UPI_PAYMENT_CONFIG.vpa,
    pn: SCHOOL_UPI_PAYMENT_CONFIG.payeeName,
    am: String(amount),
    cu: SCHOOL_UPI_PAYMENT_CONFIG.currency,
    tn: displayReference,
  });

  return {
    uri: `upi://pay?${params.toString().replaceAll("+", "%20")}`,
    displayReference,
    payeeName: SCHOOL_UPI_PAYMENT_CONFIG.payeeName,
    vpa: SCHOOL_UPI_PAYMENT_CONFIG.vpa,
    amount,
  };
}
