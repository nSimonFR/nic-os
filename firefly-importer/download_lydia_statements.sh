#!/bin/bash
#
# Lydia Bank Statement Downloader
# Downloads CSV statements from Lydia API and saves to bank-statements folder
#
# Usage:
#   ./download_lydia_statements.sh [--output-dir DIR]
#

set -e

# Configuration
OUTPUT_DIR="${1:-.}/bank-statements/sumeria"
API_URL="https://api.lydia-app.com/bankstatementcsv"
ACCOUNT_ID="357390"
ACCOUNT_TYPE="collect"

# Authorization headers
AUTH_BEARER="eyJhbGciOiJFZERTQSIsImtpZCI6IjMzMjE4ZDgxIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2F1dGhvcml6YXRpb24ubHlkaWEtYXBwLmNvbS8iLCJzdWIiOiIxODc4MDQiLCJhdWQiOlsiaHR0cHM6Ly9hcGkubHlkaWEtYXBwLmNvbS8iXSwiZXhwIjoxNzcyNDU5NzYxLCJuYmYiOjE3NzI0NTc5NjEsImlhdCI6MTc3MjQ1Nzk2MSwianRpIjoiOGVmODg2NDYtZTQ0Ni00ZmZkLThkMzktMWI1ZjQwNWUxZTQ1Iiwic2NvcGUiOiJnYXRld2F5IiwiY2xpZW50X2lkIjoiN180OHJ4ZnQzY3R5Y2tnY2t3ODhrMDBzazQ4Z2drb2tzOHc0MGcwNDBvNDhjZ29jZ2tnayJ9.5SsbaL3SNJuqjtmqtzJuekmaOkooiSyMB7noOi7jAMhIyz57iQmPcSVIFa_YdFdBg3Ittqovsc3-mlF3OqyqBQ"
DEVICE_TOKEN="eyJhbGciOiJIUzI1NiIsImtpZCI6IjAxOWMyMjgwLTY2MzktN2VjMC1iNjE4LTFkYTY5ZWU0MGFkYyIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJodHRwczovL2FwaS5seWRpYS1hcHAuY29tLyIsInN1YiI6IjE4NzgwNCIsImF1ZCI6WyJicm93c2VyOnRydXN0aW5nIl0sImV4cCI6MTc4MDIzMzk2MSwiaWF0IjoxNzcyNDU3OTYxLCJmcCI6ImRkNGQxMGJlNDY0N2I3ZTUwYjUzNjQyNWI5MzNlMGQwNDU3NTdjYWUxYmJjMmExNTFkMzMyNGU3YmI1YTc5MzgiLCJ2IjoxfQ.lNS4bo_gf-dWipfXWQpmcKYwwzl_QmAKCNpBPrdQfgw"

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}📥 Lydia Bank Statement Downloader${NC}"
echo "Output: $OUTPUT_DIR"
echo

# Function to download statement for date range
download_statement() {
  local start_date="$1"
  local end_date="$2"
  local filename="$3"
  
  echo -n "📥 Downloading $filename..."
  
  # URL encode dates
  START_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${start_date}'))")
  END_ENCODED=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${end_date}'))")
  
  # Build full URL
  URL="${API_URL}?account_id=${ACCOUNT_ID}&account_type=${ACCOUNT_TYPE}&start_date=${START_ENCODED}&end_date=${END_ENCODED}"
  
  # Download
  HTTP_CODE=$(curl -s -o "$OUTPUT_DIR/$filename" -w "%{http_code}" \
    -H 'accept: application/json, text/plain, */*' \
    -H 'accept-language: en-US,en;q=0.9,fr-FR;q=0.8,fr;q=0.7' \
    -H "authorization: Bearer $AUTH_BEARER" \
    -b "__Host-trusted-device-token=$DEVICE_TOKEN" \
    -H 'origin: https://app.sumeria.eu' \
    -H 'priority: u=1, i' \
    -H 'sec-ch-ua: "Chromium";v="145", "Not:A-Brand";v="99"' \
    -H 'sec-ch-ua-mobile: ?1' \
    -H 'sec-ch-ua-platform: "iOS"' \
    -H 'sec-fetch-dest: empty' \
    -H 'sec-fetch-mode: cors' \
    -H 'sec-fetch-site: cross-site' \
    -H 'sec-fetch-storage-access: none' \
    -H 'user-agent: Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1' \
    -H 'x-app-source: banking-web' \
    "$URL")
  
  if [ "$HTTP_CODE" = "200" ]; then
    # Check if file is valid CSV
    if head -1 "$OUTPUT_DIR/$filename" | grep -q "Firstname\|Date\|Label"; then
      LINE_COUNT=$(wc -l < "$OUTPUT_DIR/$filename")
      echo -e " ${GREEN}✓${NC} ($((LINE_COUNT - 11)) transactions)"
    else
      echo -e " ${RED}✗${NC} (Invalid response)"
      rm -f "$OUTPUT_DIR/$filename"
      return 1
    fi
  else
    echo -e " ${RED}✗${NC} (HTTP $HTTP_CODE)"
    rm -f "$OUTPUT_DIR/$filename"
    return 1
  fi
}

# Download date ranges
echo -e "${BLUE}📊 Downloading statements:${NC}\n"

# 2025 - monthly
for month in {01..12}; do
  download_statement "2025-${month}-01T00:00:00+01:00" "2025-${month}-31T23:59:59+01:00" "2025-${month}.csv"
done

# Jan 2026
download_statement "2026-01-01T00:00:00+01:00" "2026-01-31T23:59:59+01:00" "2026-01.csv"

# Feb 2026
download_statement "2026-02-01T00:00:00+01:00" "2026-02-28T23:59:59+01:00" "2026-02.csv"

echo
echo -e "${GREEN}✅ Download complete!${NC}"
echo
echo "Files saved to: $OUTPUT_DIR"
ls -lh "$OUTPUT_DIR"/*.csv 2>/dev/null | awk '{print "  " $9 " (" $5 ")"}'
