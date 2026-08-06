"""Generic config-driven fetch and extraction. Source-specific rules are JSON data."""
from __future__ import annotations
import json,re
from html import unescape
from html.parser import HTMLParser
from urllib.parse import urljoin
from urllib.request import Request,urlopen
from .ics import parse_ics
from .normalize import normalize

def fetch(url):
 r=Request(url,headers={'User-Agent':'weekly-events/1.0','Accept':'application/json,text/html,application/xml;q=0.9,*/*;q=0.8'})
 with urlopen(r,timeout=30) as x:return x.read().decode(x.headers.get_content_charset() or 'utf-8','replace')
def get_path(v,path):
 for k in filter(None,path.split('.')):
  if isinstance(v,dict):v=v.get(k)
  else:return None
 return v
def clean_html(v):return re.sub(r'\s+',' ',re.sub(r'<[^>]+>',' ',unescape(str(v or '')))).strip()
def json_events(source):
 c=source['config'];data=json.loads(fetch(c['url']));rows=get_path(data,c.get('items_path','')) or data;rows=rows if isinstance(rows,list) else [rows];out=[]
 for row in rows:
  raw={f:get_path(row,p) for f,p in c['fields'].items()}
  # Extraction rules are data: regexes can derive dates/availability from any API text fields.
  for target, rule in c.get('extract', {}).items():
   inputs = rule.get('inputs') or [rule.get('from')]
   text = ' '.join(clean_html(get_path(row, p)) for p in inputs if p)
   match = re.search(rule['regex'], text, re.S | re.I)
   if match:
    groups = match.groups()
    raw[target] = rule.get('template', '{0}').format(*groups, year=rule.get('year') or __import__('datetime').datetime.now().year)
  for key, value in c.get('defaults', {}).items(): raw.setdefault(key, value)
  for k in ('title','description','venue','price','organizer'):raw[k]=clean_html(raw.get(k))
  for k in ('event_url','registration_url'):
   if raw.get(k):raw[k]=urljoin(source['base_url'],str(raw[k]))
  if any(not raw.get(field) for field in c.get('required_fields', [])): continue
  out.append(normalize(source['id'],raw,source.get('timezone','Europe/Paris')))
 return out
def ics_events(source):return parse_ics(fetch(source['config']['url']),source['id'],source.get('timezone','Europe/Paris'))
def html_events(source):
 c=source['config'];html=fetch(c['url']);out=[]
 # event_pattern segments the listing; each field pattern is a capture-group regex.
 for segment in re.findall(c['event_pattern'],html,re.S|re.I):
  raw={}
  for field,pattern in c.get('field_patterns',{}).items():
   m=re.search(pattern,segment,re.S|re.I);raw[field]=clean_html(m.group(1)) if m else None
  if raw.get('event_url'):raw['event_url']=urljoin(source['base_url'],raw['event_url'])
  if raw.get('registration_url'):raw['registration_url']=urljoin(source['base_url'],raw['registration_url'])
  if raw.get('calendar_url'):raw['calendar_url']=urljoin(source['base_url'],raw['calendar_url'])
  if not raw.get('title') or not (raw.get('external_id') or raw.get('event_url') or raw.get('registration_url')): continue
  if raw.get('capacity') and '/' in raw['capacity']:
   registered,capacity=re.findall(r'\d+',raw['capacity'])[:2];raw['registered']=registered;raw['capacity']=capacity
  out.append(normalize(source['id'],raw,source.get('timezone','Europe/Paris')))
 return out
def parse_source(source):
 errors=[];empty=None
 for method in source.get('methods',[]):
  try:events={'json':json_events,'ics':ics_events,'html':html_events,'rss':html_events}[method](source)
  except Exception as e:errors.append(f'{method}: {e}');continue
  if events:return events,method
  # A method that fetched and parsed but found nothing is a real "no upcoming events"
  # answer: remember it, keep trying lower-priority methods, and fall back to it rather
  # than raising — otherwise a quiet calendar looks like a failure and strands stale events.
  if empty is None:empty=method
 if empty is not None:return [],empty
 raise RuntimeError('; '.join(errors) or 'no methods configured')
def deduplicate(events):
 seen={}
 for e in events:seen.setdefault((e.start_at,e.title.casefold(),(e.venue or '').casefold()),e)
 return list(seen.values())
