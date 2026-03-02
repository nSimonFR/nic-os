#!/bin/bash
# Re-download with new tokens and account types

OUTPUT_BASE="bank-statements"
mkdir -p "$OUTPUT_BASE"

# Updated auth tokens (valid until specified expiry)
AUTH="eyJhbGciOiJFZERTQSIsImtpZCI6IjMzMjE4ZDgxIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2F1dGhvcml6YXRpb24ubHlkaWEtYXBwLmNvbS8iLCJzdWIiOiIxODc4MDQiLCJhdWQiOlsiaHR0cHM6Ly9hcGkubHlkaWEtYXBwLmNvbS8iXSwiZXhwIjoxNzcyNDYyMTQ4LCJuYmYiOjE3NzI0NjAzNDgsImlhdCI6MTc3MjQ2MDM0OCwianRpIjoiZjRiZDdlZTMtYjkzMC00M2E4LWIwZDUtMmFhODI2ZmU1M2U4Iiwic2NvcGUiOiJnYXRld2F5IiwiY2xpZW50X2lkIjoiN180OHJ4ZnQzY3R5Y2tnY2t3ODhrMDBzazQ4Z2drb2tzOHc0MGcwNDBvNDhjZ29jZ2tnayJ9.r2DoHKD6TqOSjRto4wm8qeoiXrn4g0mjmXbfOc0rwwnGxzcpF3niKY9nfgCVhW1JZnDg4l-ZhiIggMNWNY7zDA"
DEVICE="eyJhbGciOiJIUzI1NiIsImtpZCI6IjAxOWMyMjgwLTY2MzktN2VjMC1iNjE4LTFkYTY5ZWU0MGFkYyIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJodHRwczovL2FwaS5seWRpYS1hcHAuY29tLyIsInN1YiI6IjE4NzgwNCIsImF1ZCI6WyJicm93c2VyOnRydXN0aW5nIl0sImV4cCI6MTc4MDIzNjM0OCwiaWF0IjoxNzcyNDYwMzQ4LCJmcCI6ImRkNGQxMGJlNDY0N2I3ZTUwYjUzNjQyNWI5MzNlMGQwNDU3NTdjYWUxYmJjMmExNTFkMzMyNGU3YmI1YTc5MzgiLCJ2IjoxfQ.3gDfJVCRY9H6Q7SOj8ddfkm7h0N4KUT-8Bk2_8lPI-I"

# Account mappings (ID -> folder, type)
declare -A ACCOUNTS=(
  ["192264"]="account-192264:wallet"
  ["4542489"]="account-4542489:wallet"
  ["5837858"]="account-5837858:wallet"
)

download_month() {
  local account_id=$1 folder=$2 account_type=$3 year=$4 month=$5
  local filename="${year}-$(printf "%02d" $month).csv"
  local output_dir="$OUTPUT_BASE/$folder"
  
  mkdir -p "$output_dir"
  
  # Calculate days in month
  if [ $month -eq 2 ]; then
    if [ $(( (year % 4 == 0) && (year % 100 != 0 || year % 400 == 0) )) -eq 1 ]; then
      days=29
    else
      days=28
    fi
  elif [ $month -eq 4 ] || [ $month -eq 6 ] || [ $month -eq 9 ] || [ $month -eq 11 ]; then
    days=30
  else
    days=31
  fi
  
  echo -n "  $filename ... "
  
  curl -s -o "$output_dir/$filename" \
    "https://api.lydia-app.com/bankstatementcsv?account_id=${account_id}&account_type=${account_type}&start_date=${year}-$(printf "%02d" $month)-01T00%3A00%3A00%2B01%3A00&end_date=${year}-$(printf "%02d" $month)-${days}T23%3A59%3A59%2B01%3A00" \
    -H "authorization: Bearer $AUTH" \
    -b "__Host-trusted-device-token=$DEVICE" \
    -H 'origin: https://app.sumeria.eu' \
    -H 'x-app-source: banking-web' 2>/dev/null
  
  if head -1 "$output_dir/$filename" 2>/dev/null | grep -q "Firstname\|Date"; then
    COUNT=$(grep -c "^20" "$output_dir/$filename" 2>/dev/null || echo 0)
    echo "✓ ($COUNT tx)"
  else
    echo "✗"
    rm -f "$output_dir/$filename"
  fi
}

echo "📥 Lydia Re-Download (Updated Tokens)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo

# Download for each account
for account_config in "${ACCOUNTS[@]}"; do
  IFS=':' read -r folder account_type <<< "$account_config"
  
  # Extract account ID from folder name
  account_id=$(echo "$folder" | grep -o "[0-9]*" | head -1)
  
  echo "📊 Account $account_id ($folder) - Type: $account_type"
  
  echo "  2025:"
  for m in {1..12}; do download_month "$account_id" "$folder" "$account_type" 2025 $m; done
  
  echo "  2026:"
  download_month "$account_id" "$folder" "$account_type" 2026 1
  download_month "$account_id" "$folder" "$account_type" 2026 2
  echo
done

echo "✅ Download complete!"
echo
echo "Summary:"
for folder in "${ACCOUNTS[@]}" | sed 's/:.*//g'; do
  folder=$(echo "$folder" | sed 's/:.*//g')
  count=$(ls "$OUTPUT_BASE/$folder"/*.csv 2>/dev/null | wc -l)
  if [ $count -gt 0 ]; then
    txs=$(cat "$OUTPUT_BASE/$folder"/*.csv 2>/dev/null | grep -c "^20" || echo 0)
    echo "  $folder: $count files, $txs transactions"
  fi
done
