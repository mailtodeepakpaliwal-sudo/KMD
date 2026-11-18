import { afterEach, describe, expect, it, vi } from "vitest";

// The fees app mocks these once in tests/setup.ts; One has no shared setup
// file, so each ported test carries the same three (go-live Phase D).
vi.mock("server-only", () => ({}));
vi.mock("next/cache", () => ({
  revalidatePath: vi.fn(),
  revalidateTag: vi.fn(),
  updateTag: vi.fn(),
  unstable_cache:
    <T extends (...args: unknown[]) => unknown>(callback: T) =>
    callback,
}));
afterEach(() => {
  vi.clearAllMocks();
  vi.restoreAllMocks();
  vi.unstubAllEnvs();
});

/**
 * The UPI ID is read from `NEXT_PUBLIC_SCHOOL_UPI_ID` when the module loads
 * (18 Nov 2026: it used to be the old school's HDFC ID, fixed in code). So each
 * case loads the modules afresh under the value it needs. The ID below is
 * made up.
 */
async function load(upiId: string) {
  vi.resetModules();
  vi.stubEnv("NEXT_PUBLIC_SCHOOL_UPI_ID", upiId);
  const upi = await import("@/modules/payments/domain/upi");
  const open = await import("@/modules/payments/domain/upi-open");
  return { ...upi, ...open };
}

const SAMPLE_ID = "kmdschool@examplebank";

describe("the school's UPI ID", () => {
  it("is not set until the owner sets it, so no QR or link is drawn", async () => {
    const { schoolUpiConfigured, SCHOOL_UPI_PAYMENT_CONFIG } = await load("");
    expect(SCHOOL_UPI_PAYMENT_CONFIG.vpa).toBe("");
    expect(schoolUpiConfigured()).toBe(false);
  });

  it("never falls back to the old school's account", async () => {
    const { SCHOOL_UPI_PAYMENT_CONFIG } = await load("");
    expect(SCHOOL_UPI_PAYMENT_CONFIG.vpa).not.toContain("shriveerpatta");
    expect(SCHOOL_UPI_PAYMENT_CONFIG.payeeName).toBe("KMD PUBLIC SCHOOL");
  });
});

describe("buildOpenSchoolUpiPayment", () => {
  it("pays the school's account with no amount, so the parent types it", async () => {
    const { buildOpenSchoolUpiPayment, schoolUpiConfigured } = await load(SAMPLE_ID);
    expect(schoolUpiConfigured()).toBe(true);
    const payment = buildOpenSchoolUpiPayment();

    expect(payment.uri).toBe("upi://pay?pa=kmdschool%40examplebank&pn=KMD%20PUBLIC%20SCHOOL&cu=INR&tn=School%20fee");
    expect(payment.uri).not.toContain("am=");
    expect(payment.vpa).toBe(SAMPLE_ID);
  });
});

describe("buildStudentFeeUpiPayment", () => {
  it("builds a school UPI intent with exact rupee amount and admission reference", async () => {
    const { buildStudentFeeUpiPayment, SCHOOL_UPI_PAYMENT_CONFIG } = await load(SAMPLE_ID);
    const payment = buildStudentFeeUpiPayment({
      admissionNo: "ADM1234",
      amount: 8000,
    });

    expect(payment.uri).toBe(
      "upi://pay?pa=kmdschool%40examplebank&pn=KMD%20PUBLIC%20SCHOOL&am=8000&cu=INR&tn=Fee%20ADM1234",
    );
    expect(payment.displayReference).toBe("Fee ADM1234");
    expect(payment.payeeName).toBe(SCHOOL_UPI_PAYMENT_CONFIG.payeeName);
  });

  it("caps the UPI note to a short office-readable reference", async () => {
    const { buildStudentFeeUpiPayment } = await load(SAMPLE_ID);
    const payment = buildStudentFeeUpiPayment({
      admissionNo: "VERY-LONG-ADMISSION-NUMBER-123456789",
      amount: 12500.75,
    });

    expect(payment.displayReference.length).toBeLessThanOrEqual(35);
    expect(payment.uri).toContain("am=12501");
    expect(payment.uri).toContain("tn=");
  });
});
