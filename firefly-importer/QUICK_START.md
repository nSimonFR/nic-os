# Firefly III Bank Statement Importer - Quick Start

## 📁 Paths

### Script Location
```
/home/nsimon/.openclaw/workspace/firefly-importer/sumeria_import
```

### Bank Statements Folder
```
/home/nsimon/.openclaw/workspace/bank-statements/sumeria/
```

Current file: `2026-02.csv` (59 transactions, February 2026)

---

## 🚀 Usage

### 1. Preview transactions (dry-run)
```bash
cd ~/.openclaw/workspace
python3 firefly-importer/sumeria_import bank-statements/sumeria/2026-02.csv --dry-run
```

### 2. Import to Firefly III
```bash
python3 firefly-importer/sumeria_import bank-statements/sumeria/2026-02.csv
```

### 3. Add new bank statements
1. Download CSV from Sumeria
2. Save as `bank-statements/sumeria/YYYY-MM.csv`
3. Run the import command

---

## 📊 Transaction Categories

The script auto-categorizes transactions:

| Keywords | Category | Code |
|----------|----------|------|
| CLAUDE, OPENAI, ANTHROPIC | Professional | 7 |
| INSTITUT | Health | 4 |
| CAFE, SUSHI, MEKONG, MAGNO, etc. | Food | 3 |
| UBER | Auto & Transport | 6 |
| AMAZON, MAISON, WALLABIES, LUDIFOLIE | Essentials | 9 |
| BILLETREDUC | Gifts | 10 |
| Internal bank transfer | Internal Transfer | 16 |
| Other | Unknown | 12 |

---

## 📋 February 2026 Summary

**File:** `bank-statements/sumeria/2026-02.csv`

**Statistics:**
- Total transactions: 59
- Internal transfers (Livret A → Sumeria): ~26 (€694.00)
- Card transactions: ~33 (€627.78 spending)
- Health: 1 (€40.00)
- Food: ~14 (€308.73)
- Transport: 3 (€24.86)
- Essentials: 5 (€127.03)
- Professional: 2 (€31.14)
- Gifts: 1 (€58.50)
- Unknown: 5 (€135.52)

---

## ⚙️ Configuration

**Environment variables:**
```bash
export FIREFLY_TOKEN="your_token"
export FIREFLY_API_URL="http://localhost:8080/api/v1"  # default
```

**Script reads from:**
- `FIREFLY_TOKEN` (required) - from `~/.secrets/openclaw.env`
- `FIREFLY_API_URL` (optional, default: http://localhost:8080/api/v1)

---

## 💾 Adding More Statements

### Folder structure
```
bank-statements/
├── sumeria/
│   ├── 2026-02.csv  (existing)
│   ├── 2026-03.csv  (add March here)
│   ├── 2026-04.csv  (add April here)
│   └── ...
└── autres-banques/
    ├── 2026-02.csv
    └── ...
```

### Steps
1. Download CSV from your bank
2. Save to `bank-statements/BANK_NAME/YYYY-MM.csv`
3. Run import: `python3 firefly-importer/sumeria_import bank-statements/BANK_NAME/YYYY-MM.csv --dry-run`
4. Review output and import: `python3 firefly-importer/sumeria_import bank-statements/BANK_NAME/YYYY-MM.csv`

---

## ✅ Verification

After import, verify in Firefly III:
1. Go to Sumeria Savings account (Account 9)
2. Check new transactions appear with correct categories
3. Review any "Unknown" (category 12) for manual categorization
4. Adjust category mappings if needed

---

## 🔧 Troubleshooting

### Error: FIREFLY_TOKEN not set
```bash
source ~/.secrets/openclaw.env
python3 firefly-importer/sumeria_import bank-statements/sumeria/2026-02.csv
```

### Transactions not imported
1. Verify Firefly is running: `curl http://localhost:8080/api/v1/about`
2. Check token is valid: `echo $FIREFLY_TOKEN`
3. Run with dry-run to see detailed output

### Duplicates
- Safe to re-import same CSV; Firefly deduplicates by (date + amount + description)
