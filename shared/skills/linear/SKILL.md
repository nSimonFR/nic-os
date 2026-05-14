---
name: linear
description: Read, create, and update Linear issues/projects/cycles using the Linear GraphQL API with a personal API key (no MCP required). Use when the user wants to look up, file, or edit Linear tickets.
metadata:
  short-description: Linear issue tracking via GraphQL + $LINEAR_KEY
---

<!-- vendored via npx skills add openai/skills@linear (--copy), then adapted to use the GraphQL API with $LINEAR_KEY instead of MCP. -->

# Linear

## How auth works here

A personal API key is exported in the shell as `LINEAR_KEY` (format `lin_api_…`). All Linear API calls go to `https://api.linear.app/graphql` with header `Authorization: $LINEAR_KEY` (no `Bearer` prefix — Linear personal keys are sent raw). If `LINEAR_KEY` is unset, stop and tell the user.

```bash
# Sanity check — should print your name
curl -sS -X POST https://api.linear.app/graphql \
  -H "Authorization: $LINEAR_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query":"{ viewer { id name email } }"}' | jq .
```

## Workflow

1. **Clarify scope.** Team, project, cycle, priority, labels — confirm before mutating.
2. **Read first.** List/get to build context (queries below).
3. **Mutate.** Create/update issues, add comments, change state. For bulk changes, explain the grouping before applying.
4. **Summarise.** State what changed, what's outstanding, and propose next actions.

## Cheat sheet (copy-paste, swap `$LINEAR_KEY`)

All examples assume a helper:

```bash
linear_q() {
  curl -sS -X POST https://api.linear.app/graphql \
    -H "Authorization: $LINEAR_KEY" \
    -H "Content-Type: application/json" \
    -d "$(jq -nc --arg q "$1" --argjson v "${2:-{}}" '{query:$q, variables:$v}')"
}
```

### Read

```bash
# Teams (id, key, name)
linear_q 'query { teams(first:50) { nodes { id key name } } }' | jq '.data.teams.nodes'

# My open issues
linear_q 'query { viewer { assignedIssues(filter:{state:{type:{nin:["completed","canceled"]}}}, first:50) { nodes { identifier title state { name } url } } } }' | jq '.data.viewer.assignedIssues.nodes'

# Issue by identifier (e.g. NIC-42)
linear_q 'query($id:String!){ issue(id:$id){ id identifier title description state{name} priority assignee{name} labels{nodes{name}} url } }' '{"id":"NIC-42"}' | jq '.data.issue'

# Search issues in a team
linear_q 'query($q:String!,$tid:String!){ issues(filter:{team:{id:{eq:$tid}}, title:{containsIgnoreCase:$q}}, first:25){ nodes{ identifier title state{name} url } } }' '{"q":"flaky","tid":"<team-id>"}' | jq

# Workflow states for a team
linear_q 'query($tid:String!){ team(id:$tid){ states{ nodes{ id name type } } } }' '{"tid":"<team-id>"}' | jq
```

### Create

```bash
# Create an issue
linear_q 'mutation($i:IssueCreateInput!){ issueCreate(input:$i){ success issue{ identifier url } } }' \
  '{"i":{"teamId":"<team-id>","title":"Fix flaky test","description":"Repro steps…","priority":2}}' | jq

# Add a comment
linear_q 'mutation($i:CommentCreateInput!){ commentCreate(input:$i){ success comment{ id url } } }' \
  '{"i":{"issueId":"<issue-uuid>","body":"Update: deployed v1.2.3"}}' | jq
```

### Update

```bash
# Update title / state / assignee
linear_q 'mutation($id:String!,$i:IssueUpdateInput!){ issueUpdate(id:$id, input:$i){ success } }' \
  '{"id":"<issue-uuid>","i":{"stateId":"<state-uuid>","assigneeId":"<user-uuid>"}}' | jq
```

Notes:
- `issueUpdate` and `commentCreate` need the issue's **UUID**, not its identifier (`NIC-42`). Resolve `issue(id:"NIC-42"){ id }` first when needed.
- `priority`: 0 = none, 1 = urgent, 2 = high, 3 = medium, 4 = low.
- `state` types: `triage`, `backlog`, `unstarted`, `started`, `completed`, `canceled`.

## Common workflows

- **Triage**: `viewer.assignedIssues` filtered by `priority:{lte:2}`, then `issueUpdate` to bump state to "In Progress".
- **Sprint planning**: list current `cycle` for a team, list backlog issues, batch-create assignments.
- **Status updates**: for each issue in a list, `commentCreate` with the latest status.
- **Label hygiene**: `team.labels.nodes`, then `issueUpdate` with `labelIds:[…]`.

## Troubleshooting

- `401`: `LINEAR_KEY` empty/invalid — verify with the viewer query at the top.
- `400 / GraphQL errors`: read the `errors[].message` in the response — usually a missing required field or wrong UUID vs identifier.
- Rate limits: batch reads; Linear allows ~1500 req/hour per API key.

## Reference

- Linear API docs: https://developers.linear.app/docs/graphql/working-with-the-graphql-api
- GraphQL schema explorer: https://studio.apollographql.com/public/Linear-API/home (read-only)
