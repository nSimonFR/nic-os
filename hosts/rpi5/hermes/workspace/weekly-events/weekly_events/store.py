from __future__ import annotations
import json, sqlite3
from pathlib import Path
from .model import Event
class EventStore:
 def __init__(self,path):
  self.path=Path(path);self.path.parent.mkdir(parents=True,exist_ok=True)
  with sqlite3.connect(self.path) as c:c.execute('CREATE TABLE IF NOT EXISTS snapshots (key TEXT PRIMARY KEY, event TEXT NOT NULL)');c.execute('CREATE TABLE IF NOT EXISTS runs (source_id TEXT PRIMARY KEY,status TEXT NOT NULL)')
 def load_snapshot(self):
  with sqlite3.connect(self.path) as c:
   events={k:Event.from_dict(json.loads(v)) for k,v in c.execute('SELECT key,event FROM snapshots')}; runs=dict(c.execute('SELECT source_id,status FROM runs'))
  return events,runs
 def replace_snapshot(self,events,runs):
  with sqlite3.connect(self.path) as c:
   c.execute('DELETE FROM snapshots');c.executemany('INSERT INTO snapshots VALUES (?,?)',[(k,json.dumps(e.to_dict(),ensure_ascii=False)) for k,e in events.items()]);c.execute('DELETE FROM runs');c.executemany('INSERT INTO runs VALUES (?,?)',runs.items())

# A source that fails keeps its previous events: failures never create false removals.
