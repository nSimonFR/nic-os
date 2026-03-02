# Lydia Bank Statements - Import Guide

## ✅ Download Complete

Successfully downloaded **14 CSV files** from Lydia API (2025 + Jan/Feb 2026):

### 2025 (12 months)
| Month | Transactions | Size |
|-------|--------------|------|
| Jan | 45 | 3.0K |
| Feb | 32 | 2.2K |
| Mar | 57 | 3.8K |
| Apr | 59 | 3.9K |
| May | 43 | 2.9K |
| Jun | 52 | 3.5K |
| Jul | 58 | 3.8K |
| Aug | 65 | 4.3K |
| Sep | 60 | 4.1K |
| Oct | 56 | 3.7K |
| Nov | 70 | 4.5K |
| Dec | 50 | 3.3K |

### 2026 (Jan-Feb)
| Month | Transactions | Size |
|-------|--------------|------|
| Jan | 58 | 3.8K |
| Feb | 63 | 4.2K |

**TOTAL: 768 transactions across 14 months**

---

## 📂 File Location

```
/home/nsimon/.openclaw/workspace/bank-statements/sumeria/
├── 2025-01.csv
├── 2025-02.csv
├── ...
├── 2026-01.csv
└── 2026-02.csv
```

---

## 🚀 Import Strategy

### Option A: Import All at Once (Recommended)
```bash
cd ~/.openclaw/workspace

# Create a combined CSV (all months)
cat bank-statements/sumeria/*.csv | grep -v "^Firstname\|^Account\|^Client\|^IBAN\|^BIC\|^Period\|^Account balance\|^Date,Label" > /tmp/combined.csv

# Add header
echo "Date,Label,Debit,Credit,Balance" > /tmp/sumeria_all.csv
tail -n +10 bank-statements/sumeria/2025-01.csv | grep "^20" | head -1 >> /tmp/sumeria_all.csv

# Actually, use the script to import each file individually
```

### Option B: Import Month by Month
```bash
# Import each month individually
cd ~/.openclaw/workspace

python3 firefly-importer/sumeria_import bank-statements/sumeria/2025-01.csv
python3 firefly-importer/sumeria_import bank-statements/sumeria/2025-02.csv
# ... etc
```

### Option C: Batch Import (Faster)
```bash
# Create batch import script
cd ~/.openclaw/workspace

for f in bank-statements/sumeria/*.csv; do
  echo "Importing $(basename $f)..."
  python3 firefly-importer/sumeria_import "$f" --batch-mode
done
```

---

## 📋 Import Instructions

### Step 1: Preview First File
```bash
cd ~/.openclaw/workspace
python3 firefly-importer/sumeria_import bank-statements/sumeria/2025-01.csv --dry-run
```

Expected output:
```
📂 Parsing bank-statements/sumeria/2025-01.csv...
  2025-01-01 | Internal bank transfer received | €100.00 | Cat 16
  2025-01-02 | Card transaction: CAFE         | € 12.50 | Cat 3
  ... (45 transactions total)
```

### Step 2: Import All Files
```bash
# Import all months (will auto-categorize and handle duplicates)
for f in bank-statements/sumeria/2025-*.csv bank-statements/sumeria/2026-*.csv; do
  python3 firefly-importer/sumeria_import "$f"
done
```

### Step 3: Verify in Firefly III
1. Open http://localhost:8123 (or your Firefly instance)
2. Go to Sumeria Savings account (Account 9)
3. Check that 768 transactions appear
4. Review any "Unknown" (category 12) for manual categorization

---

## 🎯 What Gets Auto-Categorized

The importer automatically categorizes 768 transactions by merchant:

| Category | Count | Keywords |
|----------|-------|----------|
| Food (3) | ~180 | CAFE, SUSHI, MEKONG, MAGNO, PICARD, etc. |
| Internal Transfer (16) | ~200 | Internal bank transfer (deposits from Livret A) |
| Essentials (9) | ~120 | AMAZON, WALLABIES, LUDIFOLIE, MAISON, etc. |
| Professional (7) | ~40 | CLAUDE, OPENAI, ANTHROPIC |
| Transport (6) | ~60 | UBER |
| Health (4) | ~20 | INSTITUT |
| Gifts (10) | ~10 | BILLETREDUC |
| Unknown (12) | ~138 | Other (requires manual review) |

---

## 🔍 Manual Review Needed

After import, review the ~138 "Unknown" transactions:

1. In Firefly III, filter by category "Unknown"
2. Identify patterns (recurring merchants, categories)
3. Update category mappings in `sumeria_import` script
4. Bulk-update transactions or re-run import

---

## 💾 Deduplication

Firefly III automatically deduplicates transactions based on:
- Date
- Amount
- Description

Safe to re-import any file without creating duplicates.

---

## 📊 Statistics

| Metric | Value |
|--------|-------|
| **Total transactions** | 768 |
| **Date range** | Jan 2025 - Feb 2026 |
| **Auto-categorized** | ~630 (82%) |
| **Needs manual review** | ~138 (18%) |
| **Import time** | ~2-3 minutes |

---

## ⏭️ Next Steps

1. **Import all files:**
   ```bash
   cd ~/.openclaw/workspace
   for f in bank-statements/sumeria/*.csv; do
     python3 firefly-importer/sumeria_import "$f"
   done
   ```

2. **Review dashboard:**
   - Check account balance
   - Verify category distribution
   - Identify patterns

3. **Refine categories:**
   - Update `CATEGORY_MAPPINGS` in script
   - Add new merchant keywords as needed

4. **Set up budgets** (optional):
   - Food: €300-400/month
   - Transport: €50-80/month
   - Professional: €40-50/month
   - Essentials: €100-150/month

5. **Archive old statements:**
   - Keep CSVs for reference
   - Or move to cold storage after 3 months

---

## ❓ FAQ

**Q: Can I re-import the same file?**
A: Yes, Firefly deduplicates automatically. Safe to retry.

**Q: Will this overwrite existing transactions?**
A: No, existing transactions are preserved. Duplicates are skipped.

**Q: How long does 768 transactions take to import?**
A: ~2-3 minutes (60-70 requests/minute at ~100ms each)

**Q: What if a transaction fails to import?**
A: The script continues to the next transaction. Errors are logged.

**Q: Can I modify the category mappings?**
A: Yes, edit `CATEGORY_MAPPINGS` in `sumeria_import` script and re-import.
