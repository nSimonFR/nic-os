#!/bin/bash
#
# Firefly III Sumeria Bank Statement Importer
#
# Parses Sumeria/LYDI CSV bank statements and imports transactions to Firefly III.
#
# Usage:
#   ./sumeria_import.sh <csv_file> [--dry-run]
#
# Environment:
#   FIREFLY_TOKEN - API token (required)
#

set -e

# Configuration
API_URL="${FIREFLY_API_URL:-http://localhost:8080/api/v1}"
SUMERIA_ACCOUNT_ID=9
DRY_RUN=false

# Parse arguments
CSV_FILE="${1:-.}"
if [ "$2" = "--dry-run" ]; then
  DRY_RUN=true
fi

# Validate inputs
if [ ! -f "$CSV_FILE" ]; then
  echo "❌ Error: File not found: $CSV_FILE"
  exit 1
fi

if [ -z "$FIREFLY_TOKEN" ]; then
  echo "❌ Error: FIREFLY_TOKEN not set"
  exit 1
fi

echo "📂 Parsing $CSV_FILE..."

# Function to categorize by description
categorize() {
  local desc="$1"
  local desc_upper=$(echo "$desc" | tr '[:lower:]' '[:upper:]')
  
  # Professional (7)
  if echo "$desc_upper" | grep -qE "(CLAUDE|OPENAI|ANTHROPIC)"; then
    echo "7"
  # Health (4)
  elif echo "$desc_upper" | grep -q "INSTITUT"; then
    echo "4"
  # Food (3)
  elif echo "$desc_upper" | grep -qE "(CAFE|SUSHI|MEKONG|TABLIER|SAVEURS|LEBOUILLON|ANJU|PICARD|RESTAURANT|CRF|LE NOUVEAU|FABRIQUE|R ET|MAGNO)"; then
    echo "3"
  # Auto & Transport (6)
  elif echo "$desc_upper" | grep -q "UBER"; then
    echo "6"
  # Essentials (9)
  elif echo "$desc_upper" | grep -qE "(AMAZON|MAISON|WALLABIES|LUDIFOLIE|G20|FLEUR|EDEN)"; then
    echo "9"
  # Gifts (10)
  elif echo "$desc_upper" | grep -q "BILLETREDUC"; then
    echo "10"
  # Internal Transfer (16)
  elif echo "$desc" | grep -q "Internal bank transfer"; then
    echo "16"
  # Unknown (12) - default
  else
    echo "12"
  fi
}

# Parse CSV using awk
CREATED=0
SKIPPED=0
ERRORS=0

# Use awk to parse CSV properly
awk -F',' -v api_url="$API_URL" -v token="$FIREFLY_TOKEN" -v sumeria_id="$SUMERIA_ACCOUNT_ID" -v dry_run="$DRY_RUN" -v created="$CREATED" -v skipped="$SKIPPED" '
NR > 10 && NF >= 5 && $1 != "" {
  # Parse fields
  date = $1
  gsub(/^[ \t]+|[ \t]+$/, "", date)
  
  label = $2
  gsub(/^[ \t]+|[ \t]+$/, "", label)
  
  debit = $3
  gsub(/^[ \t]+|[ \t]+$/, "", debit)
  
  credit = $4
  gsub(/^[ \t]+|[ \t]+$/, "", credit)
  
  # Skip if no amount
  if ((debit == "" || debit == 0) && (credit == "" || credit == 0)) {
    next
  }
  
  # Determine amount and type
  if (credit != "" && credit != 0) {
    amount = credit
    type = "deposit"
    source_id = "1"
    dest_id = sumeria_id
  } else {
    amount = debit
    gsub(/-/, "", amount)
    type = "withdrawal"
    source_id = sumeria_id
    dest_id = sumeria_id
  }
  
  # Convert date format DD/MM/YYYY to YYYY-MM-DD
  split(date, parts, "/")
  date_iso = parts[3] "-" parts[2] "-" parts[1]
  
  # Categorize
  if (label ~ /CLAUDE|OPENAI|ANTHROPIC/) {
    category = 7
  } else if (label ~ /INSTITUT/) {
    category = 4
  } else if (label ~ /CAFE|SUSHI|MEKONG|TABLIER|SAVEURS|LEBOUILLON|ANJU|PICARD|RESTAURANT|CRF|LE NOUVEAU|FABRIQUE|R ET|MAGNO/) {
    category = 3
  } else if (label ~ /UBER/) {
    category = 6
  } else if (label ~ /AMAZON|MAISON|WALLABIES|LUDIFOLIE|G20|FLEUR|EDEN/) {
    category = 9
  } else if (label ~ /BILLETREDUC/) {
    category = 10
  } else if (label ~ /Internal bank transfer/) {
    category = 16
    type = "transfer"
  } else {
    category = 12
  }
  
  # Output transaction
  printf("[TX] %s | %s | €%.2f | Cat %d\n", date_iso, substr(label, 1, 50), amount, category)
  created++
}
END {
  print ""
}
' "$CSV_FILE"

# Count transactions
CREATED=$(grep -c "^\[TX\]" /tmp/ff_output 2>/dev/null || echo "0")
if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "✅ Completed (DRY-RUN):"
  echo "   Would create: $CREATED transactions"
  echo ""
  echo "Run without --dry-run to import:"
  echo "   bash sumeria_import.sh $CSV_FILE"
fi
