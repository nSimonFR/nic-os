#!/bin/bash
# Simple curl-based downloader

OUTPUT_DIR="bank-statements/sumeria"
mkdir -p "$OUTPUT_DIR"

AUTH="eyJhbGciOiJFZERTQSIsImtpZCI6IjMzMjE4ZDgxIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2F1dGhvcml6YXRpb24ubHlkaWEtYXBwLmNvbS8iLCJzdWIiOiIxODc4MDQiLCJhdWQiOlsiaHR0cHM6Ly9hcGkubHlkaWEtYXBwLmNvbS8iXSwiZXhwIjoxNzcyNDU5NzYxLCJuYmYiOjE3NzI0NTc5NjEsImlhdCI6MTc3MjQ1Nzk2MSwianRpIjoiOGVmODg2NDYtZTQ0Ni00ZmZkLThkMzktMWI1ZjQwNWUxZTQ1Iiwic2NvcGUiOiJnYXRld2F5IiwiY2xpZW50X2lkIjoiN180OHJ4ZnQzY3R5Y2tnY2t3ODhrMDBzazQ4Z2drb2tzOHc0MGcwNDBvNDhjZ29jZ2tnayJ9.5SsbaL3SNJuqjtmqtzJuekmaOkooiSyMB7noOi7jAMhIyz57iQmPcSVIFa_YdFdBg3Ittqovsc3-mlF3OqyqBQ"
DEVICE="eyJhbGciOiJIUzI1NiIsImtpZCI6IjAxOWMyMjgwLTY2MzktN2VjMC1iNjE4LTFkYTY5ZWU0MGFkYyIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJodHRwczovL2FwaS5seWRpYS1hcHAuY29tLyIsInN1YiI6IjE4NzgwNCIsImF1ZCI6WyJicm93c2VyOnRydXN0aW5nIl0sImV4cCI6MTc4MDIzMzk2MSwiaWF0IjoxNzcyNDU3OTYxLCJmcCI6ImRkNGQxMGJlNDY0N2I3ZTUwYjUzNjQyNWI5MzNlMGQwNDU3NTdjYWUxYmJjMmExNTFkMzMyNGU3YmI1YTc5MzgiLCJ2IjoxfQ.lNS4bo_gf-dWipfXWQpmcKYwwzl_QmAKCNpBPrdQfgw"

download_month() {
  local year=$1 month=$2
  local filename="${year}-$(printf "%02d" $month).csv"
  
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
  
  echo -n "📥 $filename ... "
  
  curl -s -o "$OUTPUT_DIR/$filename" \
    "https://api.lydia-app.com/bankstatementcsv?account_id=357390&account_type=collect&start_date=${year}-$(printf "%02d" $month)-01T00%3A00%3A00%2B01%3A00&end_date=${year}-$(printf "%02d" $month)-${days}T23%3A59%3A59%2B01%3A00" \
    -H "authorization: Bearer $AUTH" \
    -b "__Host-trusted-device-token=$DEVICE" \
    -H 'origin: https://app.sumeria.eu' \
    -H 'x-app-source: banking-web'
  
  if head -1 "$OUTPUT_DIR/$filename" | grep -q "Firstname\|Date"; then
    COUNT=$(grep -c "^20" "$OUTPUT_DIR/$filename" 2>/dev/null || echo 0)
    echo "✓ ($COUNT transactions)"
  else
    echo "✗"
    rm -f "$OUTPUT_DIR/$filename"
  fi
}

echo "📥 Lydia Bank Statement Downloader"
echo "Output: $OUTPUT_DIR"
echo
echo "2025:"
for m in {1..12}; do download_month 2025 $m; done

echo
echo "2026:"
download_month 2026 1
download_month 2026 2

echo
echo "✅ Downloads complete!"
ls -lh "$OUTPUT_DIR"/*.csv 2>/dev/null | awk '{printf "  %s (%s)\n", $9, $5}'
