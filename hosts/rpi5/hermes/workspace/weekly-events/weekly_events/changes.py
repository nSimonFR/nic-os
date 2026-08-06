from __future__ import annotations
from dataclasses import dataclass, field
from .model import Event

TRACKED = ("start_at", "end_at", "venue", "city", "registration_url", "price", "capacity", "registered", "remaining_seats", "status")
@dataclass
class Update: event: Event; previous: Event; fields: dict
@dataclass
class Changes:
    new:list[Event]=field(default_factory=list); updated:list[Update]=field(default_factory=list); cancelled:list[Event]=field(default_factory=list); removed:list[Event]=field(default_factory=list)
class ChangeDetector:
 def compare(self, old:dict[str,Event], current:dict[str,Event])->Changes:
  r=Changes()
  for key,event in current.items():
   previous=old.get(key)
   if not previous:
    (r.cancelled if event.status=='cancelled' else r.new).append(event); continue
   if event.status=='cancelled' and previous.status!='cancelled':r.cancelled.append(event);continue
   if event.content_hash!=previous.content_hash:
    r.updated.append(Update(event,previous,{f:(getattr(previous,f),getattr(event,f)) for f in TRACKED if getattr(previous,f)!=getattr(event,f)}))
  for key,event in old.items():
   if key not in current and event.status!='cancelled':r.removed.append(event)
  return r
