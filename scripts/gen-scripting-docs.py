#!/usr/bin/env python3
"""Regenerates the API tables in docs/Scripting.md from ScriptAPI.members (Sources/Wayfile/Services/ScriptHost.swift).

The tables sit between <!-- api:begin --> and <!-- api:end -->; the rest of the document is hand-written.
"""
import pathlib
import re

root = pathlib.Path(__file__).resolve().parent.parent
src = (root / "Sources/Wayfile/Services/ScriptHost.swift").read_text()
doc_path = root / "docs/Scripting.md"

version = re.search(r'static let version = "([^"]+)"', src).group(1)
block = src[src.index("static let members"):src.index("/// Candidates for what")]
pattern = re.compile(
    r'\.init\(name: "([^"]+)", signature: "((?:[^"\\]|\\.)*)", summary: "((?:[^"\\]|\\.)*)", returns: "((?:[^"\\]|\\.)*)"(.*?)\),\n'
)
rows = []
for m in pattern.finditer(block):
    name, sig, summary, ret, rest = (g.replace('\\"', '"') for g in m.groups())
    perm = re.search(r"permission: \.(\w+)", rest)
    rows.append((name, sig, summary, ret, perm.group(1) if perm else "", "interactive: true" in rest))


def code(text):
    return "`" + text.replace("|", "\\|") + "`"


def table(keep):
    lines = ["| Member | Returns | Permission | Description |", "|---|---|---|---|"]
    for name, sig, summary, ret, perm, interactive in rows:
        if keep(name):
            note = " *(window only)*" if interactive else ""
            lines.append(f"| {code(name + sig)} | {code(ret)} | {perm or '—'} | {summary}{note} |")
    return "\n".join(lines)


spaces = []
for name, *_ in rows:
    parts = name.split(".")
    if len(parts) == 3 and parts[1] not in spaces:
        spaces.append(parts[1])
spaces_text = "\n\n".join(f"### `wayfile.{space}`\n\n" + table(lambda n, s=space: n.startswith(f"wayfile.{s}.")) for space in spaces)

api = f"""<!-- api:begin -->
## JavaScript API {version}

Relative paths resolve against the current folder. Errors are JavaScript exceptions (use `try`/`catch`);
uncaught ones are reported with their line. Async functions work — end the script with `main()`; what the
script returns (a path or an array of paths) becomes its output.

### Context & files

{table(lambda n: n.count(".") == 1)}

{spaces_text}

*Window only*: available when the script was started from a window; triggers, schedules and `@after` runs
have no window, so these calls throw there.
<!-- api:end -->"""

doc = doc_path.read_text()
doc = re.sub(r"<!-- api:begin -->.*?<!-- api:end -->", lambda _: api, doc, flags=re.S)
doc_path.write_text(doc)
print(f"{len(rows)} members documented (API {version})")
