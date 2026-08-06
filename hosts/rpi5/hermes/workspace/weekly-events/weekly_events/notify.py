from __future__ import annotations
from datetime import datetime
from urllib.request import Request,urlopen
import json

def esc(s): return str(s).replace('_','\\_').replace('*','\\*').replace('[','\\[')
def date_line(event):
 if not event.start_at:return None
 try:return datetime.fromisoformat(event.start_at).strftime('📅 %a %d %b — %H:%M')
 except ValueError:return f'📅 {event.start_at}'
def card(e):
 out=[f'• {esc(e.title)}']
 for value in [date_line(e), f'📍 {esc(e.venue)}' if e.venue else None, f'💶 {esc(e.price)}' if e.price else None, f'👥 {e.remaining_seats} seats left' if e.remaining_seats is not None else None, f'🔗 {e.registration_url or e.event_url}' if (e.registration_url or e.event_url) else None]:
  if value:out.append(value)
 return '\n'.join(out)
def render_digest(changes,now=None):
 sections=[]
 if changes.new:sections.append('🆕 New\n\n'+'\n\n'.join(card(e) for e in changes.new))
 if changes.updated:
  rows=[]
  for u in changes.updated:
   diff=', '.join(f'{k.replace("_"," ")}: {a} → {b}' for k,(a,b) in u.fields.items()) or 'Details changed'
   rows.append(f'• {esc(u.event.title)}\n{esc(diff)}')
  sections.append('✏️ Updated\n\n'+'\n\n'.join(rows))
 if changes.cancelled:sections.append('❌ Cancelled\n\n'+'\n\n'.join(f'• {esc(e.title)}' for e in changes.cancelled))
 if changes.removed:sections.append('🗑 Removed\n\n'+'\n\n'.join(f'• {esc(e.title)}' for e in changes.removed))
 return '🎲 Weekly Events\n\n'+('\n\n'.join(sections) if sections else 'No new or updated events.')
def telegram_send(token,chat_id,text):
 data=json.dumps({'chat_id':chat_id,'text':text,'parse_mode':'Markdown'}).encode(); r=Request(f'https://api.telegram.org/bot{token}/sendMessage',data=data,headers={'Content-Type':'application/json'})
 with urlopen(r,timeout=30) as x:return json.load(x)
