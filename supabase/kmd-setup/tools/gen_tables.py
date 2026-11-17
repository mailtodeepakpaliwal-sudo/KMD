#!/usr/bin/env python3
"""Draft CREATE TABLE statements for the fee tables from the evidence:
typed records in src/platform/db/types.ts plus columns the code uses.
Views (v_*) are skipped: they are written by hand."""
import json, re, sys

cols = json.load(open(sys.argv[1]))
types_src = open(sys.argv[2]).read()
OUT = sys.argv[3]

def snake(n): return re.sub(r"(?<!^)([A-Z])", r"_\1", n).lower().replace("_i_d", "_id")

# record name -> table
REC = {"UserRecord": "users", "ClassRecord": "classes", "TransportRouteRecord": "transport_routes",
       "FeeSettingRecord": "fee_settings", "SchoolFeeDefaultRecord": "school_fee_defaults",
       "FeePolicyConfigRecord": "fee_policy_configs", "StudentFeeOverrideRecord": "student_fee_overrides",
       "InstallmentRecord": "installments", "ReceiptRecord": "receipts", "PaymentRecord": "payments",
       "PaymentAdjustmentRecord": "payment_adjustments", "AuditLogRecord": "audit_logs",
       "ImportBatchRecord": "import_batches", "ImportRowRecord": "import_rows",
       "ConfigChangeBatchRecord": "config_change_batches",
       "ConfigChangeBlockedInstallmentRecord": "config_change_blocked_installments",
       "SetupProgressRecord": "setup_progress"}

typed = {}
for m in re.finditer(r"export type (\w+Record) = \{(.*?)\n\};", types_src, re.S):
    t = REC.get(m.group(1))
    if not t: continue
    fields = {}
    depth = 0
    for line in m.group(2).split("\n"):
        if depth == 0:
            fm = re.match(r"\s{2}(\w+)\??:\s*(.+?);?$", line)
            if fm: fields[snake(fm.group(1))] = fm.group(2)
        depth += line.count("{") + line.count("<") - line.count("}") - line.count(">")
    typed[t] = fields

def ts_type(col, ts):
    nullable = "null" in ts
    base = ts.replace("| null", "").strip()
    if col == "id": return "uuid primary key default gen_random_uuid()"
    if base.startswith(("Record", "Array", "{")) or base.endswith("[]"): t = "jsonb"
    elif base == "boolean": t = "boolean"
    elif base == "number": t = guess(col)
    elif base == "PaymentMode": t = "public.payment_mode"
    elif base == "StaffRole": t = "public.staff_role"
    else: t = guess(col)
    return t + ("" if nullable else " not null")

AMOUNT = re.compile(r"(amount|_fee|fee_|total|paid|pending|balance|due$|charge|_delta|outstanding|collected|quoted|overpaid|refundable)")
def guess(col):
    if col == "id": return "uuid primary key default gen_random_uuid()"
    if col in ("admission_no", "roll_no", "tc_number", "receipt_number", "reference_number", "route_code",
               "client_request_id", "external_id", "phone", "primary_phone", "secondary_phone", "guardian_phone",
               "father_phone", "mother_phone", "session_label", "source_session_label", "target_session_label",
               "academic_session_label", "permission", "key", "record_id"):
        return "text"
    if col.startswith("provider_") or col.endswith(("message_id", "payment_id_text", "_wamid")) or col in ("public_ref",):
        return "text"
    if col in ("template_params",): return "jsonb"
    if col in ("received_by",): return "text"
    if col.endswith("_by") or col.endswith("_id") or col in ("created_by", "updated_by", "changed_by", "approved_by", "closed_by",
                                      "processed_by", "received_by", "activated_by", "reviewed_by", "requested_by", "decided_by"):
        return "uuid"
    if col.endswith("_at"): return "timestamptz"
    if col.endswith(("_on", "_date")) or col in ("date_of_birth", "day"): return "date"
    if col.startswith(("is_", "has_")) or col.endswith(("_enabled", "_flag", "_applies_default", "_applied")) or col in ("granted", "active", "enabled", "locked", "held_out"):
        return "boolean"
    if col.endswith(("_bytes", "_count", "_rows", "_no", "_index", "sort_order", "revision", "policy_version", "_months", "sequence_no", "_days")):
        return "integer"
    if AMOUNT.search(col): return "integer"
    if col in ("metadata", "payload", "details", "before", "after", "summary", "snapshot", "errors", "warnings") or col.endswith(("_payload", "_snapshot", "_data", "_summary", "_heads", "_mapping", "_headers", "_json")):
        return "jsonb"
    return "text"

order = [t for t in cols if t != "_joins" and not t.startswith("v_") and t != "staff_profiles"
         and t not in ("student_repayment_plans",)]
lines = []
for t in sorted(set(order) | set(typed)):
    c_ev = cols.get(t, {})
    fields = dict(typed.get(t, {}))
    out = []
    seen = set()
    for c, ts in fields.items():
        if c in ("created_at", "updated_at"): continue
        out.append(f"  {c} {ts_type(c, ts)}"); seen.add(c)
    for c in c_ev:
        if c in seen or c.endswith("_fkey") or c in ("count", "created_at", "updated_at"): continue
        out.append(f"  {c} {guess(c)}"); seen.add(c)
    if "id" not in seen:
        out.insert(0, "  id uuid primary key default gen_random_uuid()")
    for c in ("created_at", "updated_at"):
        if c not in seen and t not in ("app_settings",):
            out.append(f"  {c} timestamptz not null default now()")
    body = ",\n".join(o.replace("created_at timestamptz not null", "created_at timestamptz not null default now()").replace("updated_at timestamptz not null", "updated_at timestamptz not null default now()").replace("default now() default now()", "default now()") for o in out)
    lines.append(f"create table public.{t} (\n{body}\n);\n")
open(OUT, "w").write("\n".join(lines))
print(len(lines), "tables")
