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
 out=[f'🎲 *{esc(e.title)}*']
 details=[date_line(e), f'💶 {esc(e.price)}' if e.price else None, f'👥 {e.remaining_seats} places' if e.remaining_seats is not None else None]
 out.append(' · '.join(value for value in details if value))
 if e.registration_url or e.event_url: out.append(f'👉 {e.registration_url or e.event_url}')
 return '\n'.join(line for line in out if line)
def render_digest(changes,now=None):
 if not changes.new:return ''
 return '✨ *Nouveaux événements cette semaine*\n\n'+'\n\n'.join(card(e) for e in changes.new)
def telegram_send(token,chat_id,text):
 data=json.dumps({'chat_id':chat_id,'text':text,'parse_mode':'Markdown'}).encode(); r=Request(f'https://api.telegram.org/bot{token}/sendMessage',data=data,headers={'Content-Type':'application/json'})
 with urlopen(r,timeout=30) as x:return json.load(x)
