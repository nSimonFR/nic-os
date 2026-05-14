---
name: linear
description: Read, create, and update Linear issues/projects/cycles using the Linear GraphQL API with a personal API key (no MCP required). Use when the user wants to look up, file, or edit Linear tickets.
metadata:
  short-description: Linear issue tracking via GraphQL + $LINEAR_KEY
---

<!-- vendored via npx skills add openai/skills@linear (--copy), then adapted to use the GraphQL API with $LINEAR_KEY instead of MCP. -->

# Linear

## How auth works here

Two Linear workspaces are available:

| Env var | Workspace | Team | Key |
|---|---|---|---|
| `$LINEAR_KEY` | **nsimon** (personal) | nSimon (`NSI`) | **default** |
| `$LINEAR_KEY_TRUSK` | trusk (work) | — | use for trusk-specific queries |

**Default to `$LINEAR_KEY` (nsimon workspace) for all queries unless the user explicitly asks about Trusk.**

Keys are format `lin_api_…`. All API calls go to `https://api.linear.app/graphql` with header `Authorization: $LINEAR_KEY` (no `Bearer` prefix — Linear personal keys are sent raw). If `LINEAR_KEY` is unset, stop and tell the user.

```bash
# Sanity check — should print your name
curl -sS -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ viewer { id name email } }"}' | jq .
```

## Default team

For the nsimon workspace, the default team is **nSimon**:
- Team ID: `f70e4ca5-9442-4489-82f8-9a988269961b`
- Team key: `NSI`

When creating issues or searching, use this team ID unless told otherwise.

## Workflow

1. **Clarify scope.** Team, project, cycle, priority, labels — confirm before mutating.
2. **Read first.** List/get to build context (queries below).
3. **Mutate.** Create/update issues, add comments, change state. For bulk changes, explain the grouping before applying.
4. **Summarise.** State what changed, what's outstanding, and propose next actions.

## Cheat sheet

All examples use the default nsimon workspace (`$LINEAR_KEY`). For trusk, swap `$LINEAR_KEY` → `$LINEAR_KEY_TRUSK`.

```bash
linear_q() {
  curl -sS -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg q "$1" --argjson v "${2:-{}}" '{query:$q, variables:$v}')"
}

# nsimon team ID (default)
NSIMON_TEAM="f70e4ca5-9442-4489-82f8-9a988269961b"
```

### Read

```bash
# Teams (id, key, name)
linear_q 'query { teams(first:50) { nodes { id key name } } }' | jq '.data.teams.nodes'

# My open issues (nsimon)
linear_q 'query { viewer { assignedIssues(filter:{state:{type:{nin:["completed","canceled"]}}}, first:50) { nodes { identifier title state { name } url } } } }' | jq '.data.viewer.assignedIssues.nodes'

# Issue by identifier (e.g. NSI-42)
linear_q 'query($id:String!){ issue(id:$id){ id identifier title description state{name} priority assignee{name} labels{nodes{name}} url } }' '{"id":"NSI-42"}' | jq '.data.issue'

# Search issues in the nSimon team
linear_q 'query($q:String!,$tid:String!){ issues(filter:{team:{id:{eq:$tid}}, title:{containsIgnoreCase:$q}}, first:25){ nodes{ identifier title state{name} url } } }' '{"q":"flaky","tid":"'$NSIMON_TEAM'"}' | jq

# Workflow states for the nSimon team
linear_q 'query($tid:String!){ team(id:$tid){ states{ nodes{ id name type } } } }' '{"tid":"'$NSIMON_TEAM'"}' | jq

# List all open issues in nSimon team
linear_q 'query($tid:String!){ issues(filter:{team:{id:{eq:$tid}}, state:{type:{nin:["completed","canceled"]}}}, first:25){ nodes{ identifier title state{name} url } } }' '{"tid":"'$NSIMON_TEAM'"}' | jq
```

### Create

```bash
# Create an issue in nSimon (default team)
linear_q 'mutation($i:IssueCreateInput!){ issueCreate(input:$i){ success issue{ identifier url } } }' \
  '{"i":{"teamId":"'$NSIMON_TEAM'","title":"Fix flaky test","description":"Repro steps…","priority":2}}' | jq

# Add a comment
linear_q 'mutation($i:CommentCreateInput!){ commentCreate(input:$i){ success comment{ id url } } }' \
  '{"i":{"issueId":"<issue-uuid>","body":"Update: deployed v1.2.3"}}' | jq
```

### Update

```bash
# Update title / state / assignee
linear_q 'mutation($id:String!,$i:IssueUpdateInput!){ issueUpdate(id:$id, input:$i){ success } }' \
  '{"id":"<issue-uuid>","i":{"stateId":"<state-uuid>","assigneeId":"<user-uuid>"}}' | jq

# --- Trusk workspace queries ---
# For trusk-specific work, set LINEAR_KEY=$LINEAR_KEY_TRUSK before queries
```

Notes:
- `issueUpdate` and `commentCreate` need the issue's **UUID**, not its identifier (`NSI-42`). Resolve `issue(id:"NSI-42"){ id }` first when needed.
- `priority`: 0 = none, 1 = urgent, 2 = high, 3 = medium, 4 = low.
- `state` types: `triage`, `backlog`, `unstarted`, `started`, `completed`, `canceled`.

## Common workflows

- **Triage**: `viewer.assignedIssues` filtered by `priority:{lte:2}`, then `issueUpdate` to bump state to "In Progress".
- **Sprint planning**: list current `cycle` for the nSimon team, list backlog issues, batch-create assignments.
- **Status updates**: for each issue in a list, `commentCreate` with the latest status.
- **Label hygiene**: `team.labels.nodes`, then `issueUpdate` with `labelIds:[…]`.
- **Trusk work**: When the user asks about Trusk issues, swap to `$LINEAR_KEY_TRUSK` and use the trusk team IDs (e.g. `IN`, `EXTERN`).

## Troubleshooting

- `401`: `LINEAR_KEY` empty/invalid — verify with the viewer query at the top.
- `400 / GraphQL errors`: read the `errors[].message` in the response — usually a missing required field or wrong UUID vs identifier.
- Rate limits: batch reads; Linear allows ~1500 req/hour per API key.

## Reference

- Linear API docs: https://developers.linear.app/docs/graphql/working-with-the-graphql-api
- GraphQL schema explorer: https://studio.apollographql.com/public/Linear-API/home (read-only)
