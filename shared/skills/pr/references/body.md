# PR body

Adapted from mattpocock/skills' `pr` — credits and licence in [`CREDITS.md`](CREDITS.md).

Write for a reviewer who has not seen the conversation, in the domain's own words (the
repo's glossary, if it has one). No preamble; keep prose short.

```markdown
Closes <ISSUE>            ← only if the repo links issues from the body

## Summary

<one or two sentences, then the smallest visual that makes the point>

## Evidence

- **Before:** <screenshot / output / failing test>
  **After:** <screenshot / output / passing test>

## Merge danger

**Door:** <one-way | two-way>  **Blast radius:** <one word>

<only if non-obvious: migration, flag, breaking payload, what a rollback costs>
```

## Summary

Pick the smallest view that makes the key point; one is usual, several is fine, all is noise.
Keep only the calls, files, states and boundaries the reviewer needs.

| Change shape                          | Visual                                    |
| ------------------------------------- | ----------------------------------------- |
| logic, an algorithm                   | pseudocode                                |
| runtime control flow                  | call tree                                 |
| UI structure                          | component tree, with state and module seams |
| file responsibilities, broad refactor | shallow file tree with one-line comments  |
| interaction between parts             | Mermaid sequence/flow diagram             |
| a change to an existing shape         | `diff` of any of the above                |

The `diff` form is usually the sharpest, because it shows the change against the shape that
already exists:

```diff
 submitForm
   createSession
     persistPrompt
+    expandSkillMention
     launchAgent
```

Show the whole block instead when most of it is new, or when cutting context would hide
ownership or order.

## Evidence

Before and after, concrete. A screenshot is the strongest evidence when the change is visual
and the environment can take one. Next best is execution: the exact test that went from red
to green, or the command output. For config or infra, the evaluated diff or the live state
read back.

## Merge danger

- **Door**: two-way if a revert fully undoes it; one-way if it destroys data, migrates a
  schema, publishes something, or changes what another party relies on.
- **Blast radius**: who or what breaks if it is wrong: consumers, layout, mobile, one host,
  every deploy. Consider all of them, then write the widest.
