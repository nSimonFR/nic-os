# Supabase Skill

**Integration:** Supabase (PostgreSQL database + APIs)

## Description

Supabase skill provides access to structured data stored in Supabase PostgreSQL databases. Use this for:
- Querying changelog data (releases, features)
- Storing automation logs and state
- Managing user preferences and configuration
- Real-time data synchronization

## Setup

### Environment Variables

Add to `~/.secrets/openclaw.env`:

```bash
SUPABASE_URL="https://your-project.supabase.co"
SUPABASE_ANON_KEY="your-anon-key"
SUPABASE_SERVICE_KEY="your-service-key"  # Optional, for admin operations
```

### Get Credentials

1. Log in to [Supabase](https://supabase.com)
2. Select your project
3. Go to **Settings → API**
4. Copy `Project URL` and `Anon Key`

## Usage

### Query Data

```bash
# Via supabase CLI or API
curl -X POST "https://your-project.supabase.co/rest/v1/releases" \
  -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
  -H "Content-Type: application/json"
```

### Update State

```javascript
// Store automation state
await supabase
  .from('automation_state')
  .upsert({ repo: 'openclaw', last_checked: new Date() })
```

## SQL Schemas (Recommended)

```sql
-- Changelog state
CREATE TABLE releases (
  id TEXT PRIMARY KEY,
  repo TEXT,
  version TEXT,
  date TEXT,
  features TEXT,  -- JSON array
  announced BOOLEAN,
  created_at TIMESTAMP DEFAULT NOW()
);

-- Automation logs
CREATE TABLE logs (
  id BIGINT PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
  automation TEXT,
  status TEXT,
  message TEXT,
  created_at TIMESTAMP DEFAULT NOW()
);

-- Configuration
CREATE TABLE config (
  key TEXT PRIMARY KEY,
  value JSONB,
  updated_at TIMESTAMP DEFAULT NOW()
);
```

## Examples

### Store changelog automation state

```javascript
const { data, error } = await supabase
  .from('releases')
  .insert([{
    repo: 'openclaw/openclaw',
    version: 'v0.15.2',
    date: '2026-02-28',
    features: JSON.stringify(['Feature 1', 'Feature 2']),
    announced: false
  }])
```

### Query unannounced releases

```sql
SELECT * FROM releases 
WHERE announced = false 
ORDER BY date DESC
```

## Notes

- For local SQLite alternative, use `sqlite3` CLI
- Supabase provides PostgreSQL with REST/GraphQL APIs
- Use `SUPABASE_ANON_KEY` for client-side operations
- Use `SUPABASE_SERVICE_KEY` for admin/server operations

## References

- [Supabase Docs](https://supabase.com/docs)
- [Supabase JavaScript Client](https://github.com/supabase/supabase-js)
