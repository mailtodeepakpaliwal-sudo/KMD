export { schoolBrand } from "./school-brand";

export const schoolProfile = {
  name:
    process.env.NEXT_PUBLIC_SCHOOL_NAME?.trim() ||
    "KMD Public School",
  shortName: "KMD Public School",
  // Printed receipt header info. All three default to empty so the receipt
  // gracefully omits the line when the env var is not set; populate via env
  // (`NEXT_PUBLIC_SCHOOL_ADDRESS` / `_PHONE` / `_EMAIL`) without code change.
  address: process.env.NEXT_PUBLIC_SCHOOL_ADDRESS?.trim() ?? "",
  phone: process.env.NEXT_PUBLIC_SCHOOL_PHONE?.trim() ?? "",
  email: process.env.NEXT_PUBLIC_SCHOOL_EMAIL?.trim() ?? "",
  // The number staff call from the teacher screens' "Call the office". Until
  // `NEXT_PUBLIC_SCHOOL_PHONE` is set it is the office number the fee app
  // already gives parents in every WhatsApp message (schoolfees
  // `modules/whatsapp/domain/campaign-bodies*.ts`). Receipts and certificates
  // keep `phone`, which stays empty until the owner sets it.
  officePhone: process.env.NEXT_PUBLIC_SCHOOL_PHONE?.trim() || "",
  // The contact line under the school name on a parent's receipt and PDF.
  // Fees prints it from its own NEXT_PUBLIC_SCHOOL_* variables, which One's
  // deployment does not carry, so One's receipt came out without it. These
  // defaults are the line Fees prints on every receipt today (Fees receipt
  // SVP20261105-0004, 7 Nov 2026), so a receipt from either app reads the same.
  // The env variables above still win where they are set.
  letterhead: {
    address: process.env.NEXT_PUBLIC_SCHOOL_ADDRESS?.trim() || "Lal Bhawan, Barkat Nagar, Jaipur – 302015",
    phone: process.env.NEXT_PUBLIC_SCHOOL_PHONE?.trim() || "",
    email: process.env.NEXT_PUBLIC_SCHOOL_EMAIL?.trim() || "",
  },
  appMode: process.env.APP_MODE?.trim() || "production",
  adminOnly: true,
  receiptPrefix: "KMD",
  staffAudience: "Office and accounts staff",
} as const;

