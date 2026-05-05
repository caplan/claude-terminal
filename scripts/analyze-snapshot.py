#!/usr/bin/env python3
"""
Retrospective context-usefulness analyzer for a saved JSONL snapshot.

For the last N assistant turns (default 10), figure out how much of the
context that was *loaded into the prompt* during that window the model
actually referred back to. Mirrors `Sources/ContextWasteTracker.swift`
semantics but runs offline against a snapshot file, with no lag-window
grace (the whole window is the comparison span).

Definitions
-----------
- Window = last N assistant turns of the JSONL, deduped by message.id.
- Pre-window artifacts = every Read/Edit/Write/Bash/Glob/Grep/WebFetch/
  WebSearch/Task/MCP tool_use that landed BEFORE the window's first
  assistant turn. Token estimate = chars/4 of its tool_result.
- In-window artifacts = same, but loaded inside the window.
- Referenced = anchor (file basename, command name, host, first ≥3-char
  word of pattern/query/subject) appears as a substring in the union of
  all assistant text + tool_use input JSON within the window.

"Useful tokens" = referenced-artifact estTokens.
"Useful %"     = useful / tracked.

Usage:
  python3 scripts/analyze-snapshot.py docs/snapshots/2026-05-05-context-waste-build.jsonl
  python3 scripts/analyze-snapshot.py <file> --turns 20
  python3 scripts/analyze-snapshot.py <file> --verbose
"""
from __future__ import annotations
import argparse
import json
import os
import pathlib
import re
import sys
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class Turn:
    idx: int
    role: str
    timestamp: str
    message_id: Optional[str]
    text_blocks: list[str] = field(default_factory=list)
    tool_uses: list[dict] = field(default_factory=list)
    tool_results: list[dict] = field(default_factory=list)
    usage: Optional[dict] = None


@dataclass
class Artifact:
    turn_idx: int
    tool_use_id: str
    tool_name: str
    anchor: str  # primary anchor (display key)
    anchors: set[str] = field(default_factory=set)  # primary + symbols
    est_tokens: int = 0  # filled when matching tool_result arrives
    referenced: bool = False
    reused_by_later_tool: bool = False


def parse_session(path: pathlib.Path) -> list[Turn]:
    turns: list[Turn] = []
    for line in path.open():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = obj.get("type")
        if t not in ("assistant", "user"):
            continue
        msg = obj.get("message", {})
        content = msg.get("content", [])
        text_blocks: list[str] = []
        tool_uses: list[dict] = []
        tool_results: list[dict] = []
        if isinstance(content, str):
            text_blocks.append(content)
        elif isinstance(content, list):
            for blk in content:
                if not isinstance(blk, dict):
                    continue
                bt = blk.get("type")
                if bt == "text":
                    text_blocks.append(blk.get("text", ""))
                elif bt == "thinking":
                    text_blocks.append(blk.get("thinking", ""))
                elif bt == "tool_use":
                    tool_uses.append(blk)
                elif bt == "tool_result":
                    tool_results.append(blk)
        usage = msg.get("usage") if t == "assistant" else None
        turns.append(Turn(
            idx=len(turns),
            role=t,
            timestamp=obj.get("timestamp", ""),
            message_id=msg.get("id"),
            text_blocks=text_blocks,
            tool_uses=tool_uses,
            tool_results=tool_results,
            usage=usage,
        ))
    return turns


# ---- Anchor extraction (mirrors ContextWasteTracker.swift) -----------------

_FIRST_WORD_RE = re.compile(r"[A-Za-z0-9_]+")


def first_word_token(s: str) -> Optional[str]:
    if not s:
        return None
    m = _FIRST_WORD_RE.search(s)
    if not m:
        return None
    tok = m.group(0)
    return tok if len(tok) >= 3 else None


def bash_anchor(cmd: str) -> Optional[str]:
    for raw in re.split(r"[ \t\n|;&]+", cmd):
        tok = raw.strip()
        if not tok or tok.startswith("-"):
            continue
        # skip env-prefix like FOO=bar
        if "=" in tok:
            head = tok.split("=", 1)[0]
            if head and all(c.isupper() or c == "_" for c in head):
                continue
        return os.path.basename(tok)
    return None


def extract_anchor(name: str, inp: dict) -> Optional[str]:
    if name in ("Read", "Edit", "Write"):
        p = inp.get("file_path")
        return os.path.basename(p) if p else None
    if name == "NotebookEdit":
        p = inp.get("notebook_path")
        return os.path.basename(p) if p else None
    if name == "Bash":
        cmd = inp.get("command")
        return bash_anchor(cmd) if cmd else None
    if name in ("Glob", "Grep"):
        return first_word_token(inp.get("pattern") or "")
    if name == "WebFetch":
        url = inp.get("url") or ""
        m = re.match(r"https?://([^/]+)", url)
        return m.group(1) if m else None
    if name == "WebSearch":
        return first_word_token(inp.get("query") or "")
    if name in ("Task", "TaskCreate", "TaskUpdate"):
        for k in ("subject", "description", "prompt"):
            tok = first_word_token(inp.get(k) or "")
            if tok:
                return tok
        return None
    if name.startswith("mcp__"):
        for k in ("query", "url", "path", "name", "id"):
            tok = first_word_token(inp.get(k) or "")
            if tok:
                return tok
    return None


def tool_result_text(blk: dict) -> str:
    c = blk.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        parts: list[str] = []
        for sub in c:
            if isinstance(sub, dict):
                if sub.get("type") == "text":
                    parts.append(sub.get("text", ""))
                elif sub.get("type") == "tool_result":
                    parts.append(json.dumps(sub))
            elif isinstance(sub, str):
                parts.append(sub)
        return "\n".join(parts)
    return ""


# ---- Symbol extraction (mirrors ContextWasteTracker.extractSymbols) --------

_SYMBOL_RE = re.compile(
    r"\b(?:class|struct|enum|protocol|interface|trait|impl|type|func|fn|"
    r"function|def|sub|object|record|module|package)\s+"
    r"([A-Za-z_][A-Za-z0-9_]{3,})"
)
_EXPORT_RE = re.compile(
    r"\bexport\s+(?:default\s+)?(?:async\s+)?"
    r"(?:class|function|const|let|var)\s+"
    r"([A-Za-z_][A-Za-z0-9_]{3,})"
)
_SYMBOL_STOPWORDS = {
    "init", "main", "self", "this", "true", "false", "null", "None",
    "make", "Make", "type", "Type", "Item", "Data", "Info", "Util",
    "Value", "Object", "String", "Number", "Array", "List", "Dict",
    "Map", "Set", "Bool", "char", "Char", "Test", "test", "Mock",
    "mock", "Stub", "stub", "Fake", "fake", "Base", "base",
    "Helper", "helper", "Default", "default",
}
_SYMBOL_TOOLS = {"Read", "Edit", "Write", "NotebookEdit", "Grep"}


def is_distinctive_symbol(name: str) -> bool:
    return len(name) >= 4 and name not in _SYMBOL_STOPWORDS


def extract_symbols(content: str) -> set[str]:
    if not content:
        return set()
    snippet = content[:65_536]
    out: set[str] = set()
    for m in _SYMBOL_RE.finditer(snippet):
        n = m.group(1)
        if is_distinctive_symbol(n):
            out.add(n)
    for m in _EXPORT_RE.finditer(snippet):
        n = m.group(1)
        if is_distinctive_symbol(n):
            out.add(n)
    return out


# ---- Analysis ---------------------------------------------------------------

def fmt_int(n: int) -> str:
    return f"{n:,}"


def fmt_pct(num: int, denom: int) -> str:
    return f"{(num / denom * 100):.1f}%" if denom else "—"


def analyze(turns: list[Turn], window: int, verbose: bool) -> None:
    asst = [t for t in turns if t.role == "assistant" and t.usage]
    # dedup by message.id (Claude Code splits one response across records)
    seen = set()
    asst_unique: list[Turn] = []
    for t in asst:
        if t.message_id and t.message_id in seen:
            continue
        seen.add(t.message_id or f"_{t.idx}")
        asst_unique.append(t)

    if not asst_unique:
        print("No assistant turns with usage.")
        return

    window = min(window, len(asst_unique))
    sliced = asst_unique[-window:]
    first_idx = sliced[0].idx
    last_idx = sliced[-1].idx
    pre_idx = first_idx  # artifacts loaded at idx < first_idx are pre-window

    # Build artifact list across the WHOLE transcript, plus a tool_use_id ->
    # est_tokens map filled from tool_results. Two passes done inline:
    #   1. Strong-signal-first reuse: when a later tool's input contains
    #      an earlier artifact's anchor (length >= 4), mark it reused.
    #   2. Symbol extraction from tool_result content adds to anchors.
    artifacts: list[Artifact] = []
    by_id: dict[str, int] = {}
    for t in turns:
        if t.role == "assistant":
            for tu in t.tool_uses:
                tuid = tu.get("id") or ""
                if not tuid:
                    continue
                name = tu.get("name", "")
                inp = tu.get("input") or {}
                anchor = extract_anchor(name, inp)
                if not anchor:
                    continue
                input_json = json.dumps(inp, separators=(",", ":"))
                for prior in artifacts:
                    if prior.reused_by_later_tool or prior.tool_use_id == tuid:
                        continue
                    for ank in prior.anchors:
                        if len(ank) >= 4 and ank in input_json:
                            prior.reused_by_later_tool = True
                            break
                a = Artifact(turn_idx=t.idx, tool_use_id=tuid,
                             tool_name=name, anchor=anchor,
                             anchors={anchor})
                by_id[tuid] = len(artifacts)
                artifacts.append(a)
        elif t.role == "user":
            for tr in t.tool_results:
                tuid = tr.get("tool_use_id") or ""
                if tuid not in by_id:
                    continue
                txt = tool_result_text(tr)
                a = artifacts[by_id[tuid]]
                a.est_tokens = max(1, len(txt) // 4)
                if a.tool_name in _SYMBOL_TOOLS:
                    a.anchors |= extract_symbols(txt)

    # Build per-window-turn haystacks (used for noise-anchor detection
    # and the strict-`>` per-artifact match). Assistant outbound text +
    # tool_use input JSON for each in-window assistant turn.
    window_turn_haystacks: list[tuple[int, str]] = []
    by_idx: dict[int, list[str]] = {}
    for t in turns:
        if t.idx < first_idx or t.idx > last_idx:
            continue
        if t.role != "assistant":
            continue
        parts: list[str] = list(t.text_blocks)
        for tu in t.tool_uses:
            parts.append(json.dumps(tu.get("input", {}), separators=(",", ":")))
        by_idx.setdefault(t.idx, []).extend(parts)
    for idx in sorted(by_idx):
        window_turn_haystacks.append((idx, "\n".join(by_idx[idx])))

    # Noisy-anchor filter: anchors that show up in >50% of window turns
    # are too common to credit on their own.
    noisy: set[str] = set()
    if len(window_turn_haystacks) >= 4:
        all_anchors: set[str] = set()
        for a in artifacts:
            all_anchors |= a.anchors
        threshold = len(window_turn_haystacks) // 2
        for ank in all_anchors:
            hits = 0
            for _, h in window_turn_haystacks:
                if ank in h:
                    hits += 1
                    if hits > threshold:
                        break
            if hits > threshold:
                noisy.add(ank)

    # Mark referenced. Strong tool-call reuse beats everything; otherwise
    # any non-noisy anchor matched in a strictly-later window turn counts.
    for a in artifacts:
        if a.est_tokens <= 0:
            continue
        if a.reused_by_later_tool:
            a.referenced = True
            continue
        for w_idx, h in window_turn_haystacks:
            if w_idx <= a.turn_idx:
                continue
            for ank in a.anchors:
                if ank in noisy:
                    continue
                if ank in h:
                    a.referenced = True
                    break
            if a.referenced:
                break

    # Buckets: pre-window vs in-window
    pre = [a for a in artifacts if a.turn_idx < pre_idx and a.est_tokens > 0]
    inn = [a for a in artifacts
           if first_idx <= a.turn_idx <= last_idx and a.est_tokens > 0]

    def bucket_stats(items: list[Artifact]) -> tuple[int, int, int, int]:
        total_t = sum(a.est_tokens for a in items)
        used_t = sum(a.est_tokens for a in items if a.referenced)
        total_c = len(items)
        used_c = sum(1 for a in items if a.referenced)
        return total_t, used_t, total_c, used_c

    pre_tt, pre_ut, pre_tc, pre_uc = bucket_stats(pre)
    in_tt, in_ut, in_tc, in_uc = bucket_stats(inn)
    all_tt = pre_tt + in_tt
    all_ut = pre_ut + in_ut

    # Token usage stats for the window (deduped on message.id already)
    total_input = sum((t.usage.get("input_tokens") or 0) for t in sliced)
    cache_read = sum((t.usage.get("cache_read_input_tokens") or 0) for t in sliced)
    cache_create = sum((t.usage.get("cache_creation_input_tokens") or 0) for t in sliced)
    output = sum((t.usage.get("output_tokens") or 0) for t in sliced)
    full_input = total_input + cache_read + cache_create
    avg_prompt = full_input // window if window else 0

    # Header
    print(f"\nSnapshot: {len(turns)} records, {len(asst_unique)} unique assistant turns")
    print(f"Window:   last {window} assistant turns "
          f"(record idx {first_idx}..{last_idx})")
    print()
    print("Token flow over window:")
    print(f"  prompt loaded total:   {fmt_int(full_input)} tok "
          f"(avg {fmt_int(avg_prompt)}/turn)")
    print(f"    cache_read:          {fmt_int(cache_read)} tok  "
          f"({fmt_pct(cache_read, full_input)})")
    print(f"    cache_creation:      {fmt_int(cache_create)} tok  "
          f"({fmt_pct(cache_create, full_input)})")
    print(f"    fresh input:         {fmt_int(total_input)} tok  "
          f"({fmt_pct(total_input, full_input)})")
    print(f"  output:                {fmt_int(output)} tok")
    print()
    print("Artifact reference rate (token-weighted, anchor-substring match):")
    print(f"  pre-window artifacts:  {pre_tc} loaded, "
          f"{pre_uc} referenced in window  "
          f"({fmt_int(pre_ut)}/{fmt_int(pre_tt)} tok = "
          f"{fmt_pct(pre_ut, pre_tt)})")
    print(f"  in-window artifacts:   {in_tc} loaded, "
          f"{in_uc} referenced in window  "
          f"({fmt_int(in_ut)}/{fmt_int(in_tt)} tok = "
          f"{fmt_pct(in_ut, in_tt)})")
    print(f"  combined:              {pre_tc + in_tc} loaded, "
          f"{pre_uc + in_uc} referenced  "
          f"({fmt_int(all_ut)}/{fmt_int(all_tt)} tok = "
          f"{fmt_pct(all_ut, all_tt)})")
    print()
    print("Headline: of tracked artifact tokens visible during the window, "
          f"{fmt_pct(all_ut, all_tt)} were re-referenced.")
    print("(Note: token-weighted artifact view, not the full prompt — "
          "system prompt, conversation prose, screenshots, etc. are not tracked.)")

    if verbose:
        print()
        print("Top-30 dead artifacts by est_tokens (loaded but never re-referenced "
              f"in turns {first_idx}..{last_idx}):")
        dead = [a for a in artifacts if not a.referenced and a.est_tokens > 0
                and a.turn_idx <= last_idx]
        dead.sort(key=lambda a: a.est_tokens, reverse=True)
        for a in dead[:30]:
            print(f"  turn {a.turn_idx:>4}  {a.tool_name:<10}  "
                  f"{a.anchor:<40}  {fmt_int(a.est_tokens):>8} tok")
        if len(dead) > 30:
            print(f"  ... {len(dead) - 30} more")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("path", type=pathlib.Path,
                    help="Path to a JSONL transcript snapshot.")
    ap.add_argument("--turns", type=int, default=10,
                    help="Window size in unique assistant turns (default 10).")
    ap.add_argument("--verbose", action="store_true",
                    help="List the top dead artifacts.")
    args = ap.parse_args()

    if not args.path.exists():
        sys.stderr.write(f"No such file: {args.path}\n")
        return 1

    turns = parse_session(args.path)
    if not turns:
        sys.stderr.write("Empty / no parsable records.\n")
        return 1
    analyze(turns, args.turns, args.verbose)
    return 0


if __name__ == "__main__":
    sys.exit(main())
