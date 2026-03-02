#!/usr/bin/env python3
"""
Lydia Bank Statement Downloader
Downloads all 2025 + Jan/Feb 2026 bank statements
"""
import requests
import os
from datetime import datetime, timedelta
from dateutil.relativedelta import relativedelta

OUTPUT_DIR = os.path.expanduser("~/.openclaw/workspace/bank-statements/sumeria")
os.makedirs(OUTPUT_DIR, exist_ok=True)

# API config
API_URL = "https://api.lydia-app.com/bankstatementcsv"
ACCOUNT_ID = "357390"
ACCOUNT_TYPE = "collect"

# Auth tokens
AUTH_TOKEN = "eyJhbGciOiJFZERTQSIsImtpZCI6IjMzMjE4ZDgxIiwidHlwIjoiSldUIn0.eyJpc3MiOiJodHRwczovL2F1dGhvcml6YXRpb24ubHlkaWEtYXBwLmNvbS8iLCJzdWIiOiIxODc4MDQiLCJhdWQiOlsiaHR0cHM6Ly9hcGkubHlkaWEtYXBwLmNvbS8iXSwiZXhwIjoxNzcyNDU5NzYxLCJuYmYiOjE3NzI0NTc5NjEsImlhdCI6MTc3MjQ1Nzk2MSwianRpIjoiOGVmODg2NDYtZTQ0Ni00ZmZkLThkMzktMWI1ZjQwNWUxZTQ1Iiwic2NvcGUiOiJnYXRld2F5IiwiY2xpZW50X2lkIjoiN180OHJ4ZnQzY3R5Y2tnY2t3ODhrMDBzazQ4Z2drb2tzOHc0MGcwNDBvNDhjZ29jZ2tnayJ9.5SsbaL3SNJuqjtmqtzJuekmaOkooiSyMB7noOi7jAMhIyz57iQmPcSVIFa_YdFdBg3Ittqovsc3-mlF3OqyqBQ"
DEVICE_TOKEN = "eyJhbGciOiJIUzI1NiIsImtpZCI6IjAxOWMyMjgwLTY2MzktN2VjMC1iNjE4LTFkYTY5ZWU0MGFkYyIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJodHRwczovL2FwaS5seWRpYS1hcHAuY29tLyIsInN1YiI6IjE4NzgwNCIsImF1ZCI6WyJicm93c2VyOnRydXN0aW5nIl0sImV4cCI6MTc4MDIzMzk2MSwiaXQiOjE3NzI0NTc5NjEsImZwIjoiZGQ0ZDEwYmU0NjQ3YjdlNTBiNTM2NDI1YjkzM2UwZDA0NTc1N2NhZTFiYmMyYTE1MWQzMzI0ZTdiYjVhNzkzOCIsInYiOjF9.lNS4bo_gf-dWipfXWQpmcKYwwzl_QmAKCNpBPrdQfgw"

headers = {
    "accept": "application/json, text/plain, */*",
    "accept-language": "en-US,en;q=0.9,fr-FR;q=0.8,fr;q=0.7",
    "authorization": f"Bearer {AUTH_TOKEN}",
    "origin": "https://app.sumeria.eu",
    "sec-fetch-dest": "empty",
    "sec-fetch-mode": "cors",
    "sec-fetch-site": "cross-site",
    "user-agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15"
}

cookies = {
    "__Host-trusted-device-token": DEVICE_TOKEN
}

def download_month(year, month):
    """Download statement for a specific month"""
    # Get first and last day of month
    start = datetime(year, month, 1)
    if month == 12:
        end = datetime(year + 1, 1, 1) - timedelta(seconds=1)
    else:
        end = datetime(year, month + 1, 1) - timedelta(seconds=1)
    
    # Format dates with timezone
    start_str = start.strftime("%Y-%m-%dT00:00:00") + "%2B01:00"
    end_str = end.strftime("%Y-%m-%dT23:59:59") + "%2B01:00"
    
    filename = f"{year}-{month:02d}.csv"
    filepath = os.path.join(OUTPUT_DIR, filename)
    
    print(f"📥 Downloading {filename}...", end=" ", flush=True)
    
    params = {
        "account_id": ACCOUNT_ID,
        "account_type": ACCOUNT_TYPE,
        "start_date": start_str.replace("+", "%2B"),
        "end_date": end_str.replace("+", "%2B"),
    }
    
    try:
        # Build URL manually to avoid encoding issues
        url = f"{API_URL}?account_id={ACCOUNT_ID}&account_type={ACCOUNT_TYPE}&start_date={start_str}&end_date={end_str}"
        
        response = requests.get(url, headers=headers, cookies=cookies, timeout=30)
        
        if response.status_code == 200:
            # Check if response is valid CSV
            if "Firstname Lastname" in response.text or "Date,Label" in response.text:
                with open(filepath, 'w', encoding='utf-8') as f:
                    f.write(response.text)
                
                # Count transactions
                lines = response.text.split('\n')
                tx_count = len([l for l in lines if l and not any(x in l for x in ["Firstname", "Account", "Date,Label", "Period", "balance"])])
                print(f"✓ ({tx_count} transactions)")
                return True
            else:
                print(f"✗ (Invalid CSV)")
                return False
        else:
            print(f"✗ (HTTP {response.status_code})")
            return False
    except Exception as e:
        print(f"✗ ({str(e)[:30]})")
        return False

print("📥 Lydia Bank Statement Downloader\n")
print(f"Output: {OUTPUT_DIR}\n")
print("📊 Downloading statements:\n")

# Download 2025 (all months)
print("2025:")
success_2025 = 0
for month in range(1, 13):
    if download_month(2025, month):
        success_2025 += 1

print(f"\n2026:")
# Download Jan 2026
if download_month(2026, 1):
    success_2026 = 1
else:
    success_2026 = 0

# Download Feb 2026
if download_month(2026, 2):
    success_2026 += 1

print(f"\n✅ Complete!")
print(f"   2025: {success_2025}/12 months downloaded")
print(f"   2026: {success_2026}/2 months downloaded")
print(f"   Total: {success_2025 + success_2026} files\n")

print(f"Files saved to: {OUTPUT_DIR}\n")
os.system(f"ls -lh {OUTPUT_DIR}/*.csv 2>/dev/null | awk '{{printf \"  %s (%s)\\n\", $9, $5}}'")
