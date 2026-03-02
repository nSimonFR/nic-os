#!/usr/bin/env python3
"""
Firefly III Sumeria Bank Statement Importer

Parses Sumeria/LYDI CSV bank statements and imports transactions to Firefly III.
Handles card transactions and internal transfers.

Usage:
    python3 sumeria_import.py <csv_file> [--dry-run] [--token TOKEN] [--api-url URL]

Environment:
    FIREFLY_TOKEN - API token (or pass --token)
    FIREFLY_API_URL - API base URL (default: http://localhost:8080/api/v1)
"""

import os
import sys
import csv
import json
import argparse
import hashlib
from datetime import datetime
from typing import List, Dict, Optional, Tuple
import requests

# Configuration
DEFAULT_API_URL = "http://localhost:8080/api/v1"
SUMERIA_ACCOUNT_ID = 9  # Account ID for Sumeria Savings
LIVRET_A_ACCOUNT_ID = 8  # Account ID for Livret A
DEFAULT_CATEGORY_ID = 12  # Unknown

# Category mappings
CATEGORY_MAPPINGS = {
    # Auto-detect from description
    "CLAUDE.AI": 7,  # Professional
    "OPENAI": 7,  # Professional
    "ANTHROPIC": 7,  # Professional
    "INSTITUT D UROL": 4,  # Health
    "PICARD": 3,  # Food
    "MAISON SEGHAIER": 9,  # Essentials
    "RESTAURANT": 3,  # Food (fallback)
    "CAFE": 3,  # Food
    "SUSHI": 3,  # Food
    "MEKONG": 3,  # Food
    "LE TABLIER": 3,  # Food
    "LEBOUILLON": 3,  # Food
    "ANJU": 3,  # Food
    "AUX SAVEURS": 3,  # Food
    "AMAZON": 9,  # Essentials
    "UBER": 6,  # Auto & Transport
    "R ET R": 3,  # Food (restaurant)
    "FLEUR D'EDEN": 9,  # Essentials (florist)
    "WALLABIES": 9,  # Essentials
    "LUDIFOLIE": 9,  # Essentials (toy store)
    "BILLETREDUC": 10,  # Gifts
    "CRF MKT": 3,  # Food (market)
    "LE NOUVEAU": 3,  # Food (bakery/cafe)
    "LA FABRIQUE": 3,  # Food
    "G20": 9,  # Essentials (convenience)
}

class SumeriaImporter:
    def __init__(self, api_url: str, token: str, dry_run: bool = False):
        self.api_url = api_url
        self.token = token
        self.dry_run = dry_run
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {token}",
            "Accept": "application/json",
            "Content-Type": "application/json"
        })
        self.transactions_created = 0
        self.transactions_skipped = 0
        self.errors = []

    def parse_csv(self, filepath: str) -> Tuple[Dict, List[Dict]]:
        """Parse Sumeria CSV file."""
        metadata = {}
        transactions = []
        
        with open(filepath, 'r', encoding='utf-8') as f:
            reader = csv.reader(f)
            
            # Parse metadata header
            for _ in range(9):
                row = next(reader)
                if len(row) >= 2:
                    metadata[row[0]] = row[1]
            
            # Skip header row
            next(reader)
            
            # Parse transactions
            for row in reader:
                if len(row) < 5 or not row[0]:
                    continue
                
                try:
                    tx = self._parse_transaction_row(row)
                    if tx:
                        transactions.append(tx)
                except Exception as e:
                    self.errors.append(f"Error parsing row {row}: {str(e)}")
        
        return metadata, transactions

    def _parse_transaction_row(self, row: List[str]) -> Optional[Dict]:
        """Parse a single transaction row."""
        date_str, label, debit, credit, balance = row[0], row[1], row[2], row[3], row[4]
        
        # Parse date
        try:
            tx_date = datetime.strptime(date_str, "%d/%m/%Y").isoformat()
        except ValueError:
            return None
        
        # Determine amount and direction
        if credit and credit.strip():
            amount = float(credit.strip())
            tx_type = "deposit"
            is_internal = "Internal bank transfer" in label
        elif debit and debit.strip():
            amount = abs(float(debit.strip()))
            tx_type = "withdrawal"
            is_internal = False
        else:
            return None
        
        # Categorize
        category_id = self._categorize(label)
        
        # Create transaction object
        return {
            "date": tx_date,
            "description": label,
            "amount": amount,
            "type": tx_type,
            "category_id": category_id,
            "is_internal": is_internal,
            "source_id": SUMERIA_ACCOUNT_ID,
            "destination_id": SUMERIA_ACCOUNT_ID if not is_internal else None,
        }

    def _categorize(self, description: str) -> int:
        """Categorize transaction by description."""
        desc_upper = description.upper()
        
        for keyword, category_id in CATEGORY_MAPPINGS.items():
            if keyword in desc_upper:
                return category_id
        
        # Default: Internal transfers → Internal Transfer (16)
        if "Internal bank transfer" in description:
            return 16
        
        # Default for card transactions → Unknown (12)
        return DEFAULT_CATEGORY_ID

    def create_transaction(self, tx: Dict) -> bool:
        """Create transaction in Firefly III."""
        if self.dry_run:
            print(f"[DRY-RUN] Would create: {tx['date']} | {tx['description'][:50]} | €{tx['amount']}")
            return True
        
        payload = {
            "transactions": [
                {
                    "type": tx["type"],
                    "date": tx["date"],
                    "amount": str(tx["amount"]),
                    "description": tx["description"],
                    "source_id": str(tx["source_id"]),
                    "destination_id": str(tx["destination_id"] or tx["source_id"]),
                    "category_id": str(tx["category_id"]),
                }
            ]
        }
        
        try:
            resp = self.session.post(f"{self.api_url}/transactions", json=payload)
            if resp.status_code in [200, 201]:
                self.transactions_created += 1
                return True
            else:
                self.errors.append(f"HTTP {resp.status_code}: {resp.text[:100]}")
                self.transactions_skipped += 1
                return False
        except Exception as e:
            self.errors.append(f"Exception: {str(e)}")
            self.transactions_skipped += 1
            return False

    def import_file(self, filepath: str) -> bool:
        """Import all transactions from file."""
        print(f"📂 Parsing {filepath}...")
        metadata, transactions = self.parse_csv(filepath)
        
        print(f"📊 Metadata:")
        print(f"   Account: {metadata.get('Account name', 'N/A')}")
        print(f"   Period: {metadata.get('Period', 'N/A')}")
        print(f"   Transactions found: {len(transactions)}")
        print()
        
        if self.dry_run:
            print("🔍 [DRY-RUN MODE] Previewing transactions:")
        else:
            print(f"📤 Importing {len(transactions)} transactions...")
        
        for tx in transactions:
            self.create_transaction(tx)
        
        print()
        print(f"✅ Completed:")
        print(f"   Created: {self.transactions_created}")
        print(f"   Skipped: {self.transactions_skipped}")
        if self.errors:
            print(f"   Errors: {len(self.errors)}")
            for err in self.errors[:5]:
                print(f"      - {err}")
        
        return len(self.errors) == 0

def main():
    parser = argparse.ArgumentParser(
        description="Import Sumeria bank statements to Firefly III"
    )
    parser.add_argument("csv_file", help="CSV file to import")
    parser.add_argument("--dry-run", action="store_true", help="Preview without importing")
    parser.add_argument("--token", default=None, help="Firefly API token (env: FIREFLY_TOKEN)")
    parser.add_argument("--api-url", default=DEFAULT_API_URL, help="Firefly API URL")
    
    args = parser.parse_args()
    
    # Get token
    token = args.token or os.environ.get("FIREFLY_TOKEN")
    if not token:
        print("❌ Error: FIREFLY_TOKEN not set and --token not provided")
        sys.exit(1)
    
    # Verify file exists
    if not os.path.exists(args.csv_file):
        print(f"❌ Error: File not found: {args.csv_file}")
        sys.exit(1)
    
    # Import
    importer = SumeriaImporter(args.api_url, token, dry_run=args.dry_run)
    success = importer.import_file(args.csv_file)
    
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
