# Price Watch

Declarative products and conditions backed by a SQLite observation history.

```bash
python3 price_watch.py sync
python3 price_watch.py products
python3 -m unittest discover -s tests -v
```

`prices.sqlite3` is runtime state and is intentionally not tracked.
