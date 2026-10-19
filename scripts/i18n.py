#!/usr/bin/env python3
"""Keeps the translations in Resources/Localization in step with the code.

    scripts/i18n.py            # extract, merge into every <lang>.lproj, report what's missing
    scripts/i18n.py --check    # only report (exit 1 when something is untranslated)

Keys are the English text as written in the code. Collected from SwiftUI initializers that take a
literal (Text("…"), Button("…"), Label("…", …), .help("…")…) and from String(localized: "…").
Interpolations become format specifiers the way Foundation builds the key: counts and other integers
→ %lld, everything else → %@ (a wrong guess only means that string stays in English).
New keys are added with the English text and a /* TODO */ comment; keys no longer in the code are dropped.
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
# The scripting API reference (ScriptHost) and example scripts stay English: they document code.
EXCLUDED = {"ScriptHost.swift", "ScriptExamples.swift"}
sources = sorted(p for p in (root / "Sources/Wayfile").rglob("*.swift") if p.name not in EXCLUDED)
loc_dir = root / "Resources/Localization"

VIEWS = ("Text", "Button", "Label", "Toggle", "Picker", "Section", "TextField", "SecureField", "Menu",
         "ContentUnavailableView", "LabeledContent", "DisclosureGroup", "Stepper", "GroupBox", "Link",
         "ProgressView", "navigationTitle", "help", "confirmationDialog", "alert", "accessibilityLabel",
         "accessibilityHint", "SettingsLink", "Tab", "InspectorSection", "searchable", "TableColumn", "Window", "WindowGroup", "CommandMenu",
         # Wayfile components / helpers whose first argument is a title shown through Text(key:)
         "ActionTile", "InfoRow", "header", "column", "section", "sectionHeader", "filterLabel", "versionLine",
         "badge", "list", "group", "row", "info", "errorBar", "chip", "tile", "card", "widgetCard", "settingRow")
LITERAL = r'"'  # patterns match up to the opening quote; parse_literal reads the rest
patterns = [
    re.compile(r'(?<![\w.])(?:' + "|".join(VIEWS) + r')\(\s*' + LITERAL),
    re.compile(r'\.(?:help|navigationTitle|accessibilityLabel|accessibilityHint)\(\s*' + LITERAL),
    re.compile(r'String\(localized:\s*' + LITERAL),
    re.compile(r'LocalizedStringKey\(\s*' + LITERAL),
    re.compile(r'\b(?:prompt|description|label|message):\s*Text\(\s*' + LITERAL),
    # Keyword arguments that carry UI text into components (InfoRow(label:), PaletteAction(title:)…)
    re.compile(r'\b(?:title|label|empty|subtitle|placeholder|summary|detail|category):\s*' + LITERAL),
    # Helpers whose label is the second argument: info("clock", "Last opened", …), row("bolt", "Trigger", …)
    re.compile(r'(?<![\w.])(?:info|row)\(\s*"[^"\n]*",\s*' + LITERAL),
]

INTEGER_HINTS = re.compile(r'(count|Count|total|Total|index|minutes|seconds|days|hours|number|Number|limit|\.offset|\bn\b|\bi\b|steps|level|width|height|status|line|ahead|behind|changed|conflicts|problems|files|folders|min|max|fontSize|retention)\b|\bInt\(')


def parse_literal(source, start):
    """Reads a Swift string literal whose opening quote is at source[start - 1]; handles escapes and
    interpolations containing their own string literals. Returns (raw text, end index) or None."""
    i, depth, out = start, 0, []
    while i < len(source):
        c = source[i]
        if depth == 0:
            if c == "\n":
                return None
            if c == '"':
                return "".join(out), i + 1
            if c == "\\" and source.startswith("\\(", i):
                depth = 1
                out.append("\\(")
                i += 2
                continue
            if c == "\\":
                out.append(source[i:i + 2])
                i += 2
                continue
            out.append(c)
            i += 1
        else:
            if c == '"':
                inner = parse_literal(source, i + 1)
                if inner is None:
                    return None
                out.append('"' + inner[0] + '"')
                i = inner[1]
                continue
            depth += {"(": 1, ")": -1}.get(c, 0)
            out.append(c)
            i += 1
    return None


def interpolations_to_format(text):
    """"\\(items.count) items" → "%lld items"; returns the key."""
    out, i = [], 0
    while i < len(text):
        if text.startswith("\\(", i):
            depth, j = 1, i + 2
            while j < len(text) and depth:
                depth += {"(": 1, ")": -1}.get(text[j], 0)
                j += 1
            expr = text[i + 2:j - 1]
            if "specifier:" in expr:
                out.append(re.search(r'specifier:\s*"([^"]*)"', expr).group(1))
            elif INTEGER_HINTS.search(expr) and not re.search(r'(name|title|path|text|String|description|formatted|Formatters|\?\?\s*"|\.size\b|bytes|Bytes)', expr):
                out.append("%lld")
            else:
                out.append("%@")
            i = j
        else:
            # A literal % in the text is %% in the key (Foundation escapes it the same way).
            out.append("%%" if text[i] == "%" else text[i])
            i += 1
    return "".join(out)


def unescape_swift(text):
    return (text.replace('\\"', '"').replace("\\n", "\n").replace("\\t", "\t").replace("\\\\", "\\"))


def escape_strings(text):
    return text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def extract():
    keys = {}
    for path in sources:
        source = path.read_text()
        # Skip comment lines (doc examples aren't UI).
        source = "\n".join("" if line.lstrip().startswith("//") else line for line in source.split("\n"))
        for pattern in patterns:
            for match in pattern.finditer(source):
                parsed = parse_literal(source, match.end())
                if parsed is None:
                    continue
                raw = parsed[0]
                if not raw.strip() or raw.startswith("\\(") and raw.endswith(")") and raw.count("\\(") == 1:
                    continue  # pure interpolation: nothing to translate
                key = unescape_swift(interpolations_to_format(raw))
                if re.fullmatch(r'[\W\d_%@lfd ]*', key):
                    continue  # symbols, numbers only
                keys.setdefault(key, set()).add(str(path.relative_to(root)))
    return keys


ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";', re.M)


def read_strings(path):
    if not path.exists():
        return {}
    unescape = lambda s: s.replace('\\"', '"').replace("\\n", "\n").replace("\\t", "\t").replace("\\\\", "\\")
    text = path.read_text()
    entries = {}
    for match in ENTRY.finditer(text):
        before = text[:match.start()].rsplit("\n", 2)[-2] if "\n" in text[:match.start()] else ""
        entries[unescape(match.group(1))] = (unescape(match.group(2)), "TODO" in before)
    return entries


def write_strings(path, keys, existing, english):
    lines = [f"/* Wayfile — {path.parent.stem}. Generated by scripts/i18n.py: edit values, keep keys. */", ""]
    for key in sorted(keys, key=str.lower):
        value, todo = existing.get(key, (key, True))
        if english:
            value, todo = key, False
        if todo:
            lines.append("/* TODO */")
        lines.append(f'"{escape_strings(key)}" = "{escape_strings(value)}";')
    path.write_text("\n".join(lines) + "\n")


PLURALS = loc_dir / "plurals.json"


def write_stringsdict(path, plurals, language):
    """Plural keys ("%lld items") get one/few/many/other forms in <lang>.lproj/Localizable.stringsdict."""
    from xml.sax.saxutils import escape
    out = ['<?xml version="1.0" encoding="UTF-8"?>',
           '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
           '<plist version="1.0">', '<dict>']
    for key in sorted(plurals, key=str.lower):
        forms = plurals[key].get(language)
        if not forms:
            continue
        # The first integer argument decides the form; the others are passed through.
        spec = "lld"
        out += [f"    <key>{escape(key)}</key>", "    <dict>",
                "        <key>NSStringLocalizedFormatKey</key>", f"        <string>{escape(_with_variable(key))}</string>",
                "        <key>n</key>", "        <dict>",
                "            <key>NSStringFormatSpecTypeKey</key>", "            <string>NSStringPluralRuleType</string>",
                "            <key>NSStringFormatValueTypeKey</key>", f"            <string>{spec}</string>"]
        for form in ("zero", "one", "two", "few", "many", "other"):
            if form in forms:
                out += [f"            <key>{form}</key>", f"            <string>{escape(_positional(forms[form]))}</string>"]
        out += ["        </dict>", "    </dict>"]
    out += ["</dict>", "</plist>", ""]
    path.write_text("\n".join(out))


def _with_variable(key):
    """Plural keys hold just the count ("%lld items"); the whole text is the plural variable.
    Sentences with more arguments use a plural key as one of their arguments."""
    if len(re.findall(r'%(?:lld|@|lf|d)', key)) != 1 or "%lld" not in key:
        sys.exit(f"plural key must contain exactly one %lld and nothing else to format: {key!r}")
    return "%#@n@"


def _positional(form):
    return form


def main():
    check = "--check" in sys.argv
    keys = extract()
    import json
    plurals = json.loads(PLURALS.read_text()) if PLURALS.exists() else {}
    unknown = [k for k in plurals if k not in keys]
    if unknown:
        print("plurals.json keys not in the code:", ", ".join(unknown))
    keys = {k: v for k, v in keys.items() if k not in plurals}
    languages = sorted(p.stem for p in loc_dir.glob("*.lproj")) if loc_dir.exists() else []
    missing_total = 0
    for language in languages:
        path = loc_dir / f"{language}.lproj/Localizable.strings"
        existing = read_strings(path)
        missing = [k for k in keys if k not in existing or existing[k][1]]
        dropped = [k for k in existing if k not in keys]
        if language != "en":
            missing_total += len(missing)
        if not check:
            write_strings(path, keys, existing, english=(language == "en"))
            write_stringsdict(path.with_suffix(".stringsdict"), plurals, language)
        missing_plurals = [k for k, v in plurals.items() if language not in v]
        if missing_plurals:
            print(f"{language}: plurals without forms: " + ", ".join(missing_plurals))
            missing_total += len(missing_plurals) if language != "en" else 0
        print(f"{language}: {len(keys)} strings, {0 if language == 'en' else len(missing)} untranslated, {len(dropped)} no longer used")
    if check and missing_total:
        sys.exit(1)


if __name__ == "__main__":
    main()
