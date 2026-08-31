from __future__ import annotations
import argparse,json,logging,os
from datetime import datetime,timezone
from pathlib import Path
from .changes import ChangeDetector
from .normalize import is_future
from .notify import render_digest,telegram_send
from .parsers import deduplicate,parse_source
from .store import EventStore

def run(config_path,state_path,send=False):
 cfg=json.loads(Path(config_path).read_text()); now=datetime.now(timezone.utc); log=logging.getLogger('weekly_events')
 store=EventStore(state_path); old,_=store.load_snapshot(); current={}; runs={}
 for source in cfg['sources']:
  try:
   events,method=parse_source(source); events=[x for x in deduplicate(events) if is_future(x,now)]
   current.update({x.key:x for x in events});runs[source['id']]=f'ok:{method}:{len(events)}';log.info('source_ok source=%s method=%s events=%s',source['id'],method,len(events))
  except Exception as exc:
   runs[source['id']]=f'failed:{exc}';log.exception('source_failed source=%s',source['id'])
   current.update({k:v for k,v in old.items() if v.source_id==source['id']})
 changes=ChangeDetector().compare(old,current); text=render_digest(changes,now)
 # Deliver new events only; silently synchronize every other change.
 if send and changes.new:
  token=os.environ.get('TELEGRAM_BOT_TOKEN') or Path(os.environ.get('TELEGRAM_BOT_TOKEN_FILE','/run/agenix/telegram-bot-token')).read_text().strip()
  chat=os.environ['TELEGRAM_CHAT_ID'];telegram_send(token,chat,text)
 store.replace_snapshot(current,runs)
 return text,runs

def main():
 p=argparse.ArgumentParser();p.add_argument('--config',default='sources.json');p.add_argument('--state',default='data/events.sqlite3');p.add_argument('--send',action='store_true');p.add_argument('--log-level',default='INFO');a=p.parse_args()
 logging.basicConfig(level=a.log_level,format='%(asctime)s %(levelname)s %(name)s %(message)s'); text,_=run(a.config,a.state,a.send)
 if not a.send or text != '🎲 Weekly Events\n\nNo new or updated events.': print(text)
if __name__=='__main__':main()
