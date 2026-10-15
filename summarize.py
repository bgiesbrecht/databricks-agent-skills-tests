#!/usr/bin/env python3
"""Summarize skill test results from stream-json output.

Usage:
    python3 tests/skill-tests/summarize.py /tmp/lakeflow-connect-results
"""
import glob
import json
import os
import sys

results_dir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/lakeflow-connect-results"

for path in sorted(glob.glob(os.path.join(results_dir, "p*.json"))):
    tag = os.path.basename(path).replace(".json", "")
    skills_loaded = []
    files_read = []
    answer_parts = []

    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue

            msg_type = obj.get("type", "")

            # Capture tool uses (skill loads, file reads)
            if msg_type == "tool_use":
                tool = obj.get("tool", obj.get("name", ""))
                tool_input = obj.get("input", {})
                if tool == "Skill":
                    skills_loaded.append(tool_input.get("skill", "?"))
                elif tool == "Read":
                    fp = tool_input.get("file_path", "")
                    if any(kw in fp.lower() for kw in ["lakeflow", "lfc", "lakebase", "database-connector", "query-based", "troubleshoot", "decision"]):
                        files_read.append(os.path.basename(fp))

            # stream-json assistant messages wrap tool_use blocks in message.content
            if msg_type == "assistant":
                for block in obj.get("message", {}).get("content", []):
                    if block.get("type") != "tool_use":
                        continue
                    tool = block.get("name", "")
                    inp = block.get("input", {})
                    if tool == "Skill":
                        skills_loaded.append(inp.get("skill", "?"))
                    elif tool == "Read":
                        fp = inp.get("file_path", "")
                        if fp:
                            files_read.append(os.path.basename(fp))

            # content_block_start with tool_use
            if msg_type == "content_block_start":
                cb = obj.get("content_block", {})
                if cb.get("type") == "tool_use":
                    tool = cb.get("name", "")
                    inp = cb.get("input", {})
                    if tool == "Skill":
                        skills_loaded.append(inp.get("skill", "(pending)"))
                    elif tool == "Read":
                        fp = inp.get("file_path", "")
                        if fp:
                            files_read.append(os.path.basename(fp))

            # Assistant text
            if msg_type == "text" and obj.get("role") == "assistant":
                answer_parts.append(obj.get("content", obj.get("text", "")))

            # stream-json text deltas
            if msg_type == "content_block_delta":
                delta = obj.get("delta", {})
                if delta.get("type") == "text_delta":
                    answer_parts.append(delta.get("text", ""))

            # Result message (some CLI versions)
            if msg_type == "result":
                result_text = obj.get("result", "")
                if result_text:
                    answer_parts.append(result_text)
                for sub in obj.get("subMessages", []):
                    if sub.get("type") == "tool_use":
                        tool = sub.get("tool", sub.get("name", ""))
                        tool_input = sub.get("input", {})
                        if tool == "Skill":
                            skills_loaded.append(tool_input.get("skill", "?"))
                        elif tool == "Read":
                            fp = tool_input.get("file_path", "")
                            if fp:
                                files_read.append(os.path.basename(fp))

    answer = "".join(answer_parts)
    answer_preview = answer[:600].replace("\n", " ") if answer else "(no text output)"

    # Deduplicate while preserving order
    seen = set()
    skills_dedup = []
    for s in skills_loaded:
        if s not in seen and s != "(pending)":
            seen.add(s)
            skills_dedup.append(s)
    files_dedup = []
    seen = set()
    for f in files_read:
        if f not in seen and f != "(pending)":
            seen.add(f)
            files_dedup.append(f)

    print(f"{'='*60}")
    print(f"[{tag}]")
    print(f"  Skills loaded: {', '.join(skills_dedup) or '(none)'}")
    print(f"  Files read:    {', '.join(files_dedup) or '(none)'}")
    print(f"  Answer:        {answer_preview}")
    print()
