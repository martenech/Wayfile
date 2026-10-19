#!/bin/bash
# Compiles the file-operation layer together with Tests/SelfTest and runs it.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/selftest"
mkdir -p "$(dirname "$OUT")"
S="$ROOT/Sources/Wayfile"
swiftc -swift-version 5 -o "$OUT" \
    "$S/Models/FileItem.swift" "$S/Models/Location.swift" "$S/Models/ViewSettings.swift" "$S/Models/Shortcuts.swift" "$S/Models/Theme.swift" "$S/Models/FileTemplate.swift" "$S/Models/BatchRename.swift" "$S/Models/SearchQuery.swift" "$S/Models/SmartCollection.swift" "$S/Models/Tags.swift" "$S/Models/ContextMenuConfig.swift" "$S/Models/Rules.swift" "$S/Models/Features.swift" "$S/Models/SwipeDecision.swift" "$S/Models/HomeDashboard.swift" "$S/Services/FolderWatcher.swift" \
    "$S/Services/Shell.swift" "$S/Services/Git.swift" "$S/Services/FileInfo.swift" "$S/Services/SearchEngine.swift" "$S/Services/DirectoryDiff.swift" "$S/Services/TwoWaySync.swift" "$S/Services/Integrity.swift" "$S/Services/DuplicateFinder.swift" "$S/Services/Stores.swift" "$S/Services/FileOperations.swift" "$S/Services/CopyEngine.swift" "$S/Services/ContextActions.swift" "$S/Services/Scripts.swift" "$S/Services/ScriptHost.swift" "$S/Services/CodeSyntax.swift" "$S/Services/ScriptPackage.swift" "$S/Services/PluginUI.swift" "$S/Services/ScriptExamples.swift" "$S/Services/DevTools.swift" "$S/Services/GitChanges.swift" "$S/Services/Docker.swift" "$S/Services/Servers.swift" "$S/Services/S3.swift" "$S/Services/DiskTools.swift" "$S/Services/Security.swift" "$S/Services/TransferJournal.swift" "$S/Services/SettingsTransfer.swift" "$S/Services/AIClient.swift" "$S/Services/NaturalSearch.swift" "$S/Services/AIContext.swift" "$S/Services/Activity.swift" "$S/Services/ScriptRunLog.swift" \
    "$S/State/OperationCenter.swift" "$S/State/Timeline.swift" "$S/State/ClipboardHistory.swift" \
    "$S/Views/InspectorViewers.swift" "$ROOT/Sources/ScriptBridge/ScriptEngine.swift" \
    "$ROOT/Tests/SelfTest/main.swift"
# The sandboxed JavaScript runner; JavaScript tests run through it (one test also runs in-process).
swiftc -swift-version 5 -o "$OUT-runner" "$ROOT/Sources/ScriptBridge/ScriptEngine.swift" "$ROOT/Sources/ScriptRunner/main.swift"
WAYFILE_SCRIPT_RUNNER="$OUT-runner" WAYFILE_SELFTEST_RUNNER="$OUT-runner" "$OUT"
# Translations: new UI text shows up here until it's translated (doesn't fail the run).
python3 "$ROOT/scripts/i18n.py" --check || echo "→ run scripts/i18n.py and translate the TODO entries in Resources/Localization"
