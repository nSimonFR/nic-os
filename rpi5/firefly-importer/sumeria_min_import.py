#!/usr/bin/env python3
import csv, json, hashlib, os, re, sys
from datetime import datetime
from urllib import request, error, parse

API = os.environ.get("FIREFLY_API_URL", "http://localhost:8080/api/v1")
TOKEN = os.environ.get("FIREFLY_TOKEN")

if not TOKEN:
    env = os.path.expanduser("~/.secrets/openclaw.env")
    if os.path.exists(env):
        for line in open(env, "r", encoding="utf-8"):
            if line.startswith("FIREFLY_TOKEN="):
                TOKEN = line.strip().split("=", 1)[1]
                break
if not TOKEN:
    print("Missing FIREFLY_TOKEN")
    sys.exit(1)

if len(sys.argv) < 2:
    print("Usage: sumeria_min_import.py <statement.csv>")
    sys.exit(1)

CSV_PATH = sys.argv[1]


def api(method, path, payload=None):
    headers = {"Authorization": f"Bearer {TOKEN}", "Accept": "application/json"}
    data = None
    if payload is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(payload).encode("utf-8")
    req = request.Request(API + path, data=data, method=method, headers=headers)
    try:
        with request.urlopen(req, timeout=30) as r:
            body = r.read().decode("utf-8", "ignore")
            return r.status, (json.loads(body) if body else {})
    except error.HTTPError as e:
        body = e.read().decode("utf-8", "ignore")
        try:
            return e.code, json.loads(body)
        except Exception:
            return e.code, {"message": body}


def parse_statement(path):
    meta = {}
    rows = []
    with open(path, "r", encoding="utf-8") as f:
        r = csv.reader(f)
        for row in r:
            if not row:
                continue
            if row[0] == "Date":
                break
            if len(row) >= 2:
                meta[row[0].strip()] = row[1].strip()
        for row in r:
            if len(row) < 5 or not row[0].strip():
                continue
            d = datetime.strptime(row[0].strip(), "%d/%m/%Y").strftime("%Y-%m-%d")
            rows.append({
                "date": d,
                "label": row[1].strip(),
                "debit": row[2].strip(),
                "credit": row[3].strip(),
            })
    return meta, rows


def ensure_asset_account(account_name, iban, bic):
    target = f"Sumeria {account_name}".strip()
    code, res = api("GET", "/accounts?type=asset&limit=200")
    if code != 200:
        raise RuntimeError(f"Cannot list accounts: {code} {res}")

    for acc in res.get("data", []):
        a = acc.get("attributes", {})
        if a.get("name") == target:
            acc_id = acc["id"]
            patch = {
                "name": target,
                "type": "asset",
                "account_role": "defaultAsset",
                "currency_code": "EUR",
                "iban": iban,
                "bic": bic,
            }
            api("PUT", f"/accounts/{acc_id}", patch)
            return acc_id, target

    payload = {
        "name": target,
        "type": "asset",
        "account_role": "defaultAsset",
        "currency_code": "EUR",
        "iban": iban,
        "bic": bic,
    }
    code, res = api("POST", "/accounts", payload)
    if code not in (200, 201):
        raise RuntimeError(f"Cannot create account: {code} {res}")
    return res["data"]["id"], target


def month_tag(meta, account_name):
    period = meta.get("Period", "")
    m = re.search(r"(\d{2}/\d{2}/\d{4})", period)
    if m:
        dt = datetime.strptime(m.group(1), "%d/%m/%Y")
        month = dt.strftime("%Y-%m")
    else:
        month = datetime.now().strftime("%Y-%m")
    return f"import-sumeria-{account_name.lower()}-{month}"


def iter_day_journals(day, tx_type=None):
    q = f"/transactions?start={day}&end={day}&limit=200"
    if tx_type:
        q = f"/transactions?type={tx_type}&start={day}&end={day}&limit=200"
    code, res = api("GET", q)
    if code != 200:
        return []
    return res.get("data", [])


def find_matching_internal_source(day, amount, dest_account_id):
    # Find prior internal-emitted withdrawal we can convert/merge into a transfer.
    for j in iter_day_journals(day, "withdrawal"):
        jid = j.get("id")
        for t in j.get("attributes", {}).get("transactions", []):
            desc = (t.get("description") or "").lower()
            if "internal bank transfer emitted" not in desc:
                continue
            try:
                t_amount = abs(float(str(t.get("amount", "0")).replace(",", ".")))
            except Exception:
                continue
            src_id = str(t.get("source_id") or "")
            dst_id = str(t.get("destination_id") or "")
            if t_amount == amount and src_id and src_id != str(dest_account_id):
                # avoid matching withdrawals already targeting this account
                if dst_id != str(dest_account_id):
                    return {"source_id": src_id, "journal_id": str(jid)}
    return None


def get_accounts_index():
    code, res = api("GET", "/accounts?limit=500")
    if code != 200:
        return {}
    out = {}
    for a in res.get("data", []):
        aid = str(a.get("id"))
        name = (a.get("attributes", {}).get("name") or "").strip().lower()
        if name:
            out[name] = aid
    return out


def parse_internal_target_label(label):
    m = re.search(r"internal bank transfer emitted\s*-\s*(.+)$", label, flags=re.I)
    return m.group(1).strip().lower() if m else None


def parse_internal_source_label(label):
    m = re.search(r"internal bank transfer received\s*-\s*(.+)$", label, flags=re.I)
    return m.group(1).strip().lower() if m else None


def resolve_destination_account_id(target_label, accounts_index, source_id):
    if not target_label:
        return None

    # Common Sumeria labels first.
    if target_label == "savings" and "sumeria savings" in accounts_index:
        aid = accounts_index["sumeria savings"]
        return aid if aid != str(source_id) else None
    if target_label == "current" and "sumeria current" in accounts_index:
        aid = accounts_index["sumeria current"]
        return aid if aid != str(source_id) else None

    # Generic name contains match.
    for name, aid in accounts_index.items():
        if target_label in name and aid != str(source_id):
            return aid
    return None


def has_existing_transfer(day, amount, source_id, destination_id=None):
    for j in iter_day_journals(day, "transfer"):
        for t in j.get("attributes", {}).get("transactions", []):
            try:
                t_amount = abs(float(str(t.get("amount", "0")).replace(",", ".")))
            except Exception:
                continue
            if t_amount != amount:
                continue
            if str(t.get("source_id") or "") != str(source_id):
                continue
            if destination_id and str(t.get("destination_id") or "") != str(destination_id):
                continue
            return True
    return False


def find_matching_internal_deposit(day, amount, source_id, target_label=None):
    # Used when destination account was imported first and stored as a deposit.
    for j in iter_day_journals(day, "deposit"):
        jid = j.get("id")
        for t in j.get("attributes", {}).get("transactions", []):
            desc = (t.get("description") or "").lower()
            if "internal bank transfer received" not in desc:
                continue
            if target_label and target_label not in desc:
                continue
            try:
                t_amount = abs(float(str(t.get("amount", "0")).replace(",", ".")))
            except Exception:
                continue
            if t_amount != amount:
                continue
            dst_id = str(t.get("destination_id") or "")
            if not dst_id or dst_id == str(source_id):
                continue
            return {"destination_id": dst_id, "journal_id": str(jid), "description": t.get("description") or ""}
    return None


def import_rows(rows, account_id, account_name, tag):
    created, failed, merged = 0, 0, 0
    accounts_index = get_accounts_index()
    for r in rows:
        is_credit = bool(r["credit"])
        amount = abs(float((r["credit"] or r["debit"]).replace(",", ".")))
        label_l = r["label"].lower()

        hsrc = f"{r['date']}|{r['label']}|{r['debit']}|{r['credit']}|{account_id}|{tag}"
        import_hash_v2 = hashlib.sha256(hsrc.encode()).hexdigest()

        tx = {
            "date": r["date"] + "T00:00:00+01:00",
            "amount": f"{amount:.2f}",
            "description": r["label"],
            "tags": [tag],
            "import_hash_v2": import_hash_v2,
        }

        if is_credit:
            matched_withdrawal_journal = None

            # If label points to a known source account, create transfer directly
            # even when source statement import happened later (reversed order).
            source_label = parse_internal_source_label(r["label"])
            direct_source_id = resolve_destination_account_id(source_label, accounts_index, account_id)

            src_match = find_matching_internal_source(r["date"], amount, account_id)
            if src_match:
                tx.update({"type": "transfer", "source_id": src_match["source_id"], "destination_id": str(account_id)})
                matched_withdrawal_journal = src_match.get("journal_id")
            elif direct_source_id:
                # avoid duplicate transfer creation if it already exists
                if has_existing_transfer(r["date"], amount, direct_source_id, account_id):
                    merged += 1
                    continue
                tx.update({"type": "transfer", "source_id": str(direct_source_id), "destination_id": str(account_id)})
            else:
                tx.update({"type": "deposit", "source_name": "External", "destination_id": str(account_id)})

            code, res = api("POST", "/transactions", {"transactions": [tx]})
            if code in (200, 201):
                created += 1
                # Auto-merge: remove prior duplicate internal-emitted withdrawal now replaced by this transfer.
                if matched_withdrawal_journal and tx.get("type") == "transfer":
                    d_code, _ = api("DELETE", f"/transactions/{matched_withdrawal_journal}")
                    if d_code in (200, 204):
                        merged += 1
            else:
                failed += 1
                print(f"FAIL {r['date']} {r['label'][:45]} :: {code} {res.get('message','')}")
            continue

        # Debit side internal transfer handling:
        # 1) dedupe by source+destination+day+amount when possible,
        # 2) reconcile previously-created deposit (destination imported first),
        # 3) otherwise create withdrawal fallback.
        if "internal bank transfer emitted" in label_l:
            target_label = parse_internal_target_label(r["label"])
            expected_dest_id = resolve_destination_account_id(target_label, accounts_index, account_id)

            if has_existing_transfer(r["date"], amount, account_id, expected_dest_id):
                merged += 1
                continue

            dep_match = find_matching_internal_deposit(r["date"], amount, account_id, target_label)
            if dep_match:
                transfer_tx = {
                    "type": "transfer",
                    "date": r["date"] + "T00:00:00+01:00",
                    "amount": f"{amount:.2f}",
                    "description": dep_match.get("description") or r["label"],
                    "source_id": str(account_id),
                    "destination_id": str(dep_match["destination_id"]),
                    "tags": [tag],
                    "import_hash_v2": import_hash_v2,
                }
                c_code, c_res = api("POST", "/transactions", {"transactions": [transfer_tx]})
                if c_code in (200, 201):
                    created += 1
                    d_code, _ = api("DELETE", f"/transactions/{dep_match['journal_id']}")
                    if d_code in (200, 204):
                        merged += 1
                    continue
                failed += 1
                print(f"FAIL {r['date']} {r['label'][:45]} :: {c_code} {c_res.get('message','')}")
                continue

        tx.update({"type": "withdrawal", "source_id": str(account_id), "destination_name": "Sumeria Expense"})
        code, res = api("POST", "/transactions", {"transactions": [tx]})
        if code in (200, 201):
            created += 1
        else:
            failed += 1
            print(f"FAIL {r['date']} {r['label'][:45]} :: {code} {res.get('message','')}")

    print(f"Done. created={created} failed={failed} merged={merged} tag={tag}")


meta, rows = parse_statement(CSV_PATH)
acc_name = meta.get("Account name", "Account")
iban = meta.get("IBAN", "")
bic = meta.get("BIC", "")
acc_id, full_name = ensure_asset_account(acc_name, iban, bic)
tag = month_tag(meta, acc_name)

print(f"Using account: {full_name} (id={acc_id})")
print(f"Tag: {tag}")
print(f"Rows: {len(rows)}")
import_rows(rows, acc_id, acc_name, tag)
