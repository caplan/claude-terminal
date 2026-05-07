# How context waste is calculated

Implementation reference for the "orange sliver" on the sidebar's Context bar
and its tooltip. Source of truth:
[`Sources/ContextWasteTracker.swift`](../Sources/ContextWasteTracker.swift), wired in
from [`Sources/TranscriptTailer.swift`](../Sources/TranscriptTailer.swift), and rendered
in `contextSection(_:)` in [`Sources/SidebarView.swift`](../Sources/SidebarView.swift).

## What we're trying to measure

For each tool call the assistant makes, something gets pulled into the prompt
cache — file contents, command output, web fetches, etc. Those tokens stay in
the cache for the rest of the session. We want to estimate what fraction of
those loaded tokens never got used again after being loaded — i.e., context
that's costing cache tokens for nothing.

The answer is a heuristic, not ground truth. We don't have access to the model's
internal attention, so "used" is approximated by string matches in later turns.

## The data model

Each tool call becomes an **Artifact** (`ContextWasteTracker.Artifact`) with:

- `toolUseId` — matches the later `tool_result`.
- `anchors: Set<String>` — short strings that, if they appear later, are
  evidence this artifact is being referenced.
- `displayKey` — the primary anchor; what shows up in "Top dead artifacts".
- `tool`, `turnIdx`, `estTokens`.
- `reusedByLaterTool: Bool` — set when a *later* tool's input contains one of
  this artifact's anchors.

A rolling **window** of recent assistant turns holds a `haystack` per turn:
the concatenation of the turn's assistant text, thinking blocks, and
JSON-encoded tool_use inputs (see `TranscriptTailer.haystack`). Window size is
`contextWasteWindowTurns` (default 10, configurable in Preferences, 3–50).

## Anchors

Anchors come from two places.

### 1. Tool-input anchor (extracted at `recordToolUse`)

One primary anchor per artifact, picked from the tool's input:

| Tool                                 | Anchor                                                                                              |
| ------------------------------------ | --------------------------------------------------------------------------------------------------- |
| `Read` / `Edit` / `Write`            | `basename(file_path)`                                                                               |
| `NotebookEdit`                       | `basename(notebook_path)`                                                                           |
| `Bash`                               | first non-flag, non-`FOO=bar` token, reduced to basename; **previewer commands are skipped** (see below) |
| `Glob` / `Grep`                      | first ≥3-char alphanumeric/underscore word of `pattern`                                             |
| `WebFetch`                           | URL host                                                                                            |
| `WebSearch`                          | first ≥3-char word of `query`                                                                       |
| `Task` / `TaskCreate` / `TaskUpdate` | first ≥3-char word of `subject`/`description`/`prompt`                                              |
| `mcp__*`                             | first ≥3-char word of `query`/`url`/`path`/`name`/`id`                                              |
| anything else                        | skipped (no artifact recorded)                                                                      |

If no anchor can be extracted, no artifact is recorded.

#### Bash previewer skip

The commands `cat`, `head`, `tail`, `less`, `more`, `nl`, `bat` are treated as
previewers: the anchor advances past the command to the next non-flag token
(typically the file being loaded). So `head -20 AuthMiddleware.kt` anchors on
`AuthMiddleware.kt`, not `head`. Previewer results are also symbol-mined (see
below), so this Bash call behaves like a `Read`. If a previewer has no
subsequent argument (e.g. piped from stdin), the command name is kept as the
anchor and no symbol mining happens.

### 2. Symbol anchors (extracted at `recordToolResult`)

For code-likely tool calls — `Read`, `Edit`, `Write`, `NotebookEdit`, `Grep`,
and `Bash` when the command is a previewer — we regex-scan the first 64 KB of
the tool result for top-level declarations across common languages:

```
class|struct|enum|protocol|interface|trait|impl|type|
func|fn|function|def|sub|object|record|module|package
```

plus JS/TS `export (default)? (async)? (class|function|const|let|var)`. The
captured name is kept if it's ≥4 chars and not in a small stopword list
(`init`, `main`, `Data`, `Util`, `Test`, …). All surviving names get added to
the artifact's anchor set.

So a `Read` of `AuthMiddleware.kt` anchors on `AuthMiddleware.kt` **and** on
every distinctive symbol declared inside — later references to
`AuthMiddleware.refreshToken` count as a hit even if the filename never
reappears.

Non-previewer Bash output and other tool results are not symbol-mined (too
noisy).

## Token estimate

`estTokens = max(1, toolResultChars / 4)` over the text extracted by
`TranscriptTailer.toolResultText` (string form, or concatenated `text` blocks
from a content array). This mirrors the chars/4 heuristic used by
`scripts/analyze-snapshot.py`.

## Is an artifact "referenced"?

Three signals, checked in order (strongest first):

1. **Tool-call reuse** (`reusedByLaterTool`).
   At every new `recordToolUse`, we JSON-encode the new tool's input and scan
   it for any existing artifact's anchors (≥4 chars). Match → the earlier
   artifact is marked reused for the rest of the session. **Bypasses the
   noise filter** — if a downstream `Edit`/`Bash`/`Grep` targets an earlier
   chunk's basename or symbol, that chunk was used.

2. **Haystack substring match.**
   For each window turn with `turnIdx > artifact.turnIdx`, any non-noisy
   anchor appearing as a substring counts as a reference.

3. **Noise filter.**
   An anchor that appears in more than half of the window's haystacks is
   "noisy" (e.g., `main.swift`, `Bash`, frequently-typed command names) and
   earns no credit on its own. Implemented in `computeNoisyAnchors()`; only
   kicks in when `window.count >= 4`. Reuse-by-later-tool is immune.

`isReferenced(a, noisy:)`:

```
reusedByLaterTool                                       → referenced
∃ window turn with turnIdx > a.turnIdx where any
   anchor ∈ a.anchors, anchor ∉ noisy, present in haystack → referenced
otherwise                                               → unreferenced (dead)
```

## Session summary

`summary(currentTurnIdx:)`:

- Sum `estTokens` over every artifact with `estTokens > 0` **and**
  `turnIdx < currentTurnIdx` — artifacts loaded in the current turn are
  excluded because they haven't had a chance to be referenced yet.
- `unusedTokens` = sum over that set where `isReferenced == false`.
- Return `nil` if no turns have been scanned, or if `total < 500` tokens
  (sample too small).
- Otherwise return `(unusedPct = round(unused/total * 100), total, unused)`.

Artifacts are **not evicted by age** — an artifact loaded 100 turns ago still
occupies cache tokens, so it stays in the denominator forever. Only the
*reference-check* window is rolling.

## Top dead artifacts

`topDeadArtifacts(currentTurnIdx:limit:5)` returns the same unreferenced set,
sorted by `estTokens` desc, trimmed to `limit`. Each entry carries `displayKey`,
`tool`, `estTokens`, `turnIdx` for the tooltip's "Top dead artifacts" list.

## Turn indexing

`TranscriptTailer.assistantTurnCounter` increments once per unique assistant
LLM request (deduped by `message.id`). `recordToolUse` and `scanReferences` both
use this counter so an artifact can't match its own loading turn.

## How the UI consumes it

`TranscriptSnapshot` carries:

- `contextUnusedPct` — the orange-sliver percentage of the used portion.
- `contextUnusedTokens`, `contextTrackedTokens` — for the tooltip line
  "of X tracked tokens, Y were never re-referenced".
- `contextDeadArtifacts: [DeadArtifactEntry]` — populates the tooltip's
  bulleted list.

In `SidebarView.contextSection`, the context bar's filled width is
`usedFrac * totalWidth`, and the orange sliver is `usedFrac * (unusedPct/100)`
of that, floored at 3 px when any waste is present so a 2 % sliver doesn't
disappear sub-pixel. The orange width is taken out of the blue half so the
blue+orange width still equals the real used fraction.

## Known limitations

- **String matching ≠ attention.** A model can re-use loaded context without
  repeating any anchor string; we'd score that as dead.
- **Anchor coverage gaps.** Tools outside the switch in `extractAnchor` (most
  non-mcp tools not listed above) produce no artifact at all, so their loads
  are invisible to both the numerator and denominator. Bash commands outside
  the previewer set are tracked but anchor only on the command name, which is
  usually noise rather than a meaningful reference signal.
- **chars/4 is rough.** Off by ±30 % on code vs. prose. Fine for ratios, not
  for absolute token accounting.
- **Denominator never shrinks.** A long session accumulates artifacts forever;
  a very stale load will almost always look dead once its anchor drops out of
  the window. Expected by design — those tokens really are still in cache —
  but it means `unusedPct` trends upward over long sessions even if recent
  behavior is efficient.
- **Noise filter needs ≥4 window turns** to activate; very short sessions see
  no filtering.
