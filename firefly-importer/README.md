# Firefly III Bank Statement Importer

Scripts and tools to import bank statements into Firefly III.

## Scripts

### sumeria_import.py
Imports Sumeria/LYDI CSV bank statements to Firefly III.

**Usage:**
```bash
# Test run (preview only)
python3 sumeria_import.py ~/bank-statements/sumeria/2026-02.csv --dry-run

# Import live
python3 sumeria_import.py ~/bank-statements/sumeria/2026-02.csv

# With custom API URL or token
python3 sumeria_import.py ~/bank-statements/sumeria/2026-02.csv --api-url http://localhost:8080/api/v1 --token YOUR_TOKEN
```

**Environment:**
```bash
export FIREFLY_TOKEN=your_token_here
python3 sumeria_import.py ~/bank-statements/sumeria/2026-02.csv
```

**Features:**
- ✅ Parses Sumeria CSV format (metadata + transactions)
- ✅ Auto-categorizes by description (food, transport, health, etc.)
- ✅ Handles internal transfers (detects "Internal bank transfer" label)
- ✅ Supports dry-run mode (preview before importing)
- ✅ Deduplication via Firefly's import hash
- ✅ Error handling and reporting

**Category Mappings:**
- `CLAUDE.AI`, `OPENAI`, `ANTHROPIC` → Professional (7)
- `INSTITUT D UROL` → Health (4)
- Food keywords: `CAFE`, `SUSHI`, `MEKONG`, `LE TABLIER`, `AUX SAVEURS`, etc. → Food (3)
- `UBER` → Auto & Transport (6)
- `MAISON SEGHAIER`, `AMAZON`, `WALLABIES` → Essentials (9)
- `BILLETREDUC` → Gifts (10)
- `Internal bank transfer` → Internal Transfer (16)
- Other card transactions → Unknown (12)

**CSV Format Expected:**
```
Firstname Lastname,Nicolas Simon
Account name,Current
...metadata...
Date,Label,Debit,Credit,Balance
01/02/2026,Card transaction: EXAMPLE,-10.00,,100.00
```

## Bank Statements Folder

Store your CSV files in: `~/bank-statements/sumeria/`

**Naming convention:**
- `YYYY-MM.csv` (e.g., `2026-02.csv`, `2026-03.csv`)
- Organize by bank/account: `sumeria/`, `societe-generale/`, etc.

**Example structure:**
```
~/bank-statements/
├── sumeria/
│   ├── 2026-02.csv
│   ├── 2026-03.csv
│   └── 2026-04.csv
└── societe-generale/
    ├── 2026-02.csv
    └── 2026-03.csv
```

## Workflow

1. **Download** CSV from your bank
2. **Save** to `~/bank-statements/BANK_NAME/YYYY-MM.csv`
3. **Test** with `--dry-run` flag first
4. **Import** when satisfied with preview
5. **Review** in Firefly III and adjust categories if needed

## Adding New Bank/Format

Edit `sumeria_import.py`:
1. Modify `parse_csv()` to match your bank's format
2. Update `_parse_transaction_row()` date/amount parsing
3. Add category keywords to `CATEGORY_MAPPINGS`
4. Create a new script or add a `--format` parameter

## Troubleshooting

**Error: FIREFLY_TOKEN not set**
```bash
export FIREFLY_TOKEN=$(cat ~/.secrets/openclaw.env | grep FIREFLY_TOKEN | cut -d= -f2)
python3 sumeria_import.py sumeria/2026-02.csv
```

**Error: File not found**
- Check path is correct: `~/bank-statements/sumeria/2026-02.csv`
- Expand `~`: Use `$HOME/bank-statements/...` or full path

**Transactions not imported**
- Run with `--dry-run` first to see errors
- Check Firefly API is running: `curl http://localhost:8080/api/v1/about`
- Verify token: `echo $FIREFLY_TOKEN`

**Duplicate transactions**
- Firefly deduplicates via import hash (description + date + amount)
- Safe to re-import same CSV multiple times
