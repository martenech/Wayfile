# Wayfile — TODO

`[x]` done · `[~]` partly done (what's missing is noted) · `[ ]` not started.
Effort: **S** small · **M** medium · **L** large. Items under "Needs a decision / tooling" are parked until resolved.

## Work order

1. Safe file operations — transfer queue, pause/resume, retry, per-item conflicts, verify after copy, Copy/Move To…, Drop Stack, directory diff & sync
2. Search & selection — regex/glob, rule-based selection, custom ranges, duplicates, large & unused files, Smart Collections, custom metadata
3. Navigation — folder tree / smart sidebar, workspaces, synced panes, quad pane, gestures, row density, Vim mode, custom toolbar
4. Inspector viewers — Markdown, JSON tree, hex, logs, media codecs, multi-file preview, versions, syntax highlighting, archive listing
5. Context menu — adaptive, customizable, relative/shell paths, checksum, hover actions
6. Scripts & automation — manager/editor/console, shell/Python/AppleScript/Shortcuts, custom actions, triggers, schedules, pipelines, JS API
7. Developer tools — project detection, dev paths, git diff/history/staging, Docker, text compare
8. Disks & archives — disk analyzer, archives as folders, compress options, links, custom metadata, clipboard history, rules
9. Permissions & security — xattrs, quarantine, ACLs, recursive permissions, encrypted vault, admin operations
10. Performance — progressive metadata, FSEvents, transfer recovery, integrity monitor
11. Personalization — Standard/Power mode, sidebar & toolbar customization, settings import/export, palette history
12. AI search (on-device Foundation Models), remote storage (WebDAV, S3), the rest

---

## 1. Navigation & interface

- [x] Dual pane, tabs with independent navigation per pane, editable address bar, back/forward history
- [x] Sessions — restore tabs and panes on launch
- [x] Remappable keyboard shortcuts
- [x] Per-folder view settings; themes
- [x] Quad pane (2×2)
- [x] Folder Tree — lazily loaded outline, reveals the current folder
- [x] Smart Sidebar — Places / Folders switch
- [x] Workspaces — named layouts (tabs, panes, folders, sidebar, inspector); sidebar, … menu, palette
- [x] Synchronized navigation of panes (into subfolders / up)
- [x] Vim mode — j/k, h/l, H/L, gg/G, /, dd, yy, x, p, r, u, t (Settings)
- [x] Gestures — three-finger swipe and mouse buttons 4/5 back/forward, pinch resizes items
- [x] Two-finger swipe back/forward — like Safari (respects the system setting); wide tables still scroll sideways until they reach the edge
- [x] Row density setting (compact / regular / comfortable)
- [x] Customizable toolbar — Settings → Toolbar (left/right items, order, separators)
- [x] Compact status bar option

## 2. Search & selection

- [x] Quick filter; advanced search (name, content, kind, size, date, tags, scope, Spotlight or scan); saved searches
- [x] Custom size / date range pickers
- [x] Regex and glob search (names; regex in contents via scan); invalid patterns flagged
- [x] Advanced selection — Select Matching… (⌥⌘A), Invert Selection (⇧⌘I), Select Same Kind
- [x] Smart Collections — six live presets in the sidebar (auto-refresh); saved searches act as custom collections
- [x] Duplicate finder (size → first 64 KB → SHA-256), auto-select keep newest/oldest/shortest, trash with undo
- [x] Large & unused files — "Not opened for N days" filter, Large Files / Not Opened collections, Find Large Files Here
- [x] Search by custom metadata — Metadata filter (key=value / key) in the search bar
- [x] Ask AI about files & folders — conversation over file text (PDFs too) or a folder's listing; context menu, inspector, palette
- [x] AI search — describe files in your own words (✨ in the search bar, palette); model of your choice in Settings → AI: Claude Pro/Max (Claude Code) or ChatGPT (Codex) with browser sign-in, Ollama, Apple on-device, or API keys (OpenAI-compatible, Anthropic, Gemini)

## 3. File operations

- [x] Transfer engine (copyfile, APFS clones, progress, cancel), operation history (Timeline), safe undo/redo
- [x] Advanced batch rename (regex, EXIF dates, numbering, live preview)
- [x] File templates; New file (TXT, Markdown, JSON, HTML, CSV, RTF, empty, user templates)
- [x] Checksums (MD5/SHA-1/SHA-256/SHA-512 + compare)
- [x] Smart conflict resolution — per-item Replace / Keep Both / Skip with size & date comparison, "Replace Older"
- [x] Operation simulator (dry run) — batch rename, sync, rule preview, script dry run
- [x] Transfer queue — sequential per destination volume, pause / resume (even mid-file), retry failed or cancelled
- [x] Verify integrity after copy (Settings; before deleting originals on cross-disk moves)
- [x] Copy / Move To… — pick a destination, recent destinations
- [x] Drop Stack — shelf to collect files, drag out, copy/move all here
- [x] Directory diff — Compare window (only left/right, newer, different, same; optional checksums)
- [x] Directory sync — update either way, mirror either way (extras to Trash), two-way without deletions; previewed, undoable
- [x] Two-way sync with deletions — remembers the last synced state per folder pair; deletions travel both ways, conflicts never lose data (Compare → Sync)
- [x] New file: Swift, Python, shell (executable), YAML, XML templates
- [x] File integrity monitor — folder fingerprint (baseline) and check: changed / added / removed

## 4. Previews & inspector

- [x] Permanent preview, Quick Look, Preview / Details / Actions tabs, quick actions, metadata, EXIF, HTML (WebKit) with zoom
- [x] Multi-selection preview — thumbnail grid
- [x] Advanced media info — codecs, sample rate, channels, bitrates
- [x] Markdown preview (rendered with WebKit, zoomable)
- [x] JSON tree viewer
- [x] Hex / binary viewer (unknown types)
- [x] Log viewer window for logs and large text (tail, filter, levels, live follow, handles rotation)
- [x] Code preview with syntax highlighting (Swift, JS/TS, Python, shell, Go, Rust, C-family, XML, YAML, CSS, SQL…)
- [x] Archive contents listing
- [x] File versions — list, open, restore (undoable) in Details
- [x] Compare… and scripts in the inspector Actions tab

## 5. Context menu

- [x] Open With, Quick Look, Copy Path, Open in Terminal, rename/compress/extract, tags, favorites, Get Info; separate folder / empty-space menus; icons + live shortcuts
- [x] Adaptive by file type — images (desktop picture, rotate, convert to JPEG/PNG/HEIC/TIFF), apps (package contents), code (open in editor), archives (extract)
- [x] Customizable — Settings → Context Menu: hide entries, reorder groups
- [x] Copy Path As — relative (to repo or folder), shell-escaped, file URL, name
- [x] Copy SHA-256
- [x] Compare With… (folders); Sync from the Compare window
- [x] Run script / Shortcut — Scripts submenu filtered by extension and item count
- [x] Quick actions on hover (optional; Quick Look, Copy Path, Trash in list & details)

## 6. Scripts & automation

- [x] Script manager + editor + console — Tools → Automation… (⌥⌘R): scripts, editor, live output, stop, run history
- [x] Shell / zsh / bash — selection as arguments, $WAYFILE_FOLDER / _OTHER_FOLDER / _SELECTION / _DRY_RUN
- [x] Python scripts (python3)
- [x] AppleScript (osascript, selection as argv)
- [x] Apple Shortcuts — listed, run with the selection as input (menus, palette, Automation)
- [x] Scripts in the context menu, Tools menu and command palette; shown by `@extensions` / `@count` / `@folders`
- [x] Declared permissions + confirmation on first run and after every edit; enforced for JavaScript
- [x] Folder triggers — `@trigger ~/Downloads` runs on new files (FSEvents, skips partial downloads, no self-loops)
- [x] Scheduled scripts — `@schedule <minutes>` while Wayfile runs
- [x] Dry run — JavaScript API describes every change; shell scripts get WAYFILE_DRY_RUN=1
- [x] Pipelines — `.pipeline` files chain scripts and Shortcuts, passing output paths along
- [x] JavaScript + `wayfile` API (list, read/write, move, copy, rename, trash, tag…), undoable from the Timeline
- [x] Rules — name/kind/age/size → move, copy, trash, tag, sort by kind/date, run script; ask-first queue (Pending), live preview, Run Now, Timeline entries (Automation → Rules)
- [x] Organization suggestions — screenshots, stale installers, kind folders in cluttered folders (folder menu / palette → Suggest Organization…)
- [~] Script library — 9 bundled examples (Automation → Library); community sharing / plugin SDK not planned yet

## 7. Developer tools

- [x] Git status columns, last commit, branches, pull/push/fetch, clone; open in VS Code / Xcode / editors; command palette
- [x] Project detection — Swift, Xcode, Node (npm/pnpm/yarn/bun scripts), Python, Rust, Go, Ruby, Maven, Gradle, .NET, PHP, Docker, Make targets; commands run in the Automation console (inspector, palette)
- [x] Developer links — Copy Path As: relative to repo, file URL, VS Code link, GitHub/GitLab/Bitbucket web link
- [x] Git window — changes with stage / unstage / discard, commit (amend), side-by-side diffs, repository & file history (follows renames)
- [x] Docker explorer — containers by compose project (start/stop/restart/remove, logs, shell, ports, project & mounted folders), images, volumes (Tools → Docker…)
- [x] Compare Files — side-by-side diff, folded unchanged lines, ignore whitespace (two selected files, other pane, Compare With…)

## 8. Remote storage

- [x] SMB / AFP / NFS — Connect to Server sheet (NetFS mounting, UNC paths), servers found on the network (Bonjour)
- [x] WebDAV — mounted by macOS through the same sheet (https://…), browses like a folder
- [x] S3 and compatible — AWS, R2, B2, Wasabi, MinIO; buckets, folders, upload (drop), download to the open folder, delete; SigV4 verified with AWS test vectors (Tools → S3 Storage…)
- [x] Saved servers in the sidebar (connected dot, disconnect) with Keychain passwords; S3 secrets in Keychain
- [x] SFTP / SSH — Tools → SFTP / SSH…

## 9. Disks, archives & organization

- [x] Tags & favorites; compress zip / extract many formats; recent files (Home) and Timeline
- [x] Disk usage — squarified treemap (two levels), size list, drill down, reveal, trash with undo (folder menu → Disk Usage…)
- [x] Archive browser — browse ZIP/TAR/7z/… folders read-only, extract selection or all, open a file (Browse Archive)
- [x] Compress… — ZIP / tar.gz / tar.bz2 / tar.xz / tar, level, ZIP password, skip Mac metadata
- [x] Links — Make Symbolic / Hard Link, inspector shows target / link count / Show Original, Find Broken Links…
- [x] Custom metadata — key/value fields in the inspector (extended attribute, travels with copies)
- [x] Clipboard history — files and paths copied in Wayfile (Edit menu, palette); other apps' text is never recorded
- [x] File version explorer (inspector Details)
- [x] Organizing rules (§6 Rules)

## 10. Permissions & security

- [x] POSIX permissions editor, owner & group inspector, Locked / Hidden flags, Trash, audit log (Timeline)
- [x] Extended attributes — inspector list with readable values (text, plist, hex), remove
- [x] Quarantine — source & date in the inspector, Remove Quarantine (recursive, apps too)
- [x] ACL editor — entries in the inspector, add allow/deny rules, remove
- [x] Recursive permissions — files/folders separately (octal or u+x style), preview, undoable from the Timeline
- [x] Encrypted vaults — AES-256 sparse bundles, sidebar lock/unlock, password via stdin (Tools → New Encrypted Vault…)
- [x] Administrator — Trash protected items (offered when permission is denied), change owner/group
- [x] Script execution safety (declared permissions, confirmation, JS enforcement)
- n/a Security-scoped bookmarks — only needed for a sandboxed App Store build

## 11. Performance & reliability

- [x] Virtualized lists, thumbnail cache shared by panes, folder monitoring, background hashing, symlink-safe copies
- [x] Progressive loading — quick pass with cheap attributes, type names & tags in a second pass; big lists sorted off the main thread (30k items listed in ~0.3 s, window stays responsive)
- [x] FSEvents monitoring — panes (content changes too), columns, folder-scoped searches (subtrees); kqueue fallback on network volumes
- [x] Transfer recovery — transfers are journaled; after a crash or force quit, Wayfile offers to resume (finished items skipped, partial ones redone)
- [x] Integrity verification after copy
- [x] Sync data-loss protection (preview, Trash instead of delete, undo)

## 12. Personalization & system

- [x] Themes / colours / accent, custom shortcuts, inspector tabs remembered
- [x] Standard / Power mode — Settings → Features, Tools menu
- [x] Customizable sidebar — show / hide / reorder sections (Settings → Layout)
- [x] Custom toolbar
- [x] Command palette history — recent commands first
- [x] Inspector configuration — choose sections (Settings → Layout)
- [x] Optional modules — automation, developer, cloud, security, disk tools, compare; hidden everywhere and background work paused when off
- [x] Workspace profiles — workspaces keep tabs, panes, folders, sidebar and inspector (§1)
- [x] Import / export settings — preferences, rules, scripts, templates (no secrets)
- [~] Accessibility — VoiceOver labels for icon-only buttons, tag dots and git badges; a full VoiceOver / keyboard audit needs hands-on testing

---

## Home dashboard

- [x] Customizable Home — greeting & quote (own background image), 12 widgets (Quick Access, Recent Files, Drives, Cloud Storage, Pinned Projects, Git Repositories, Tags, Transfer Queue, Notes, Scripts, Smart Collections, Recent Activity), drag to reorder, widget gallery, layouts Everyday / Developer / Minimal

## Timeline

- [x] Timeline of files, apps and actions — Opened / Created / Modified (Spotlight history), Moved / Deleted / Renamed (recorded live while Wayfile runs + Wayfile's own operations, undoable), app launches; filters, search, Today / Yesterday / 7 / 30 days, activity chart, day groups, details panel with the file's recent actions
- [x] Undo / redo of Wayfile's operations right in the Timeline (separate Activity view removed)

## Scripting engine v2

Builds on what exists (Automation window, `Script` headers, `JSScriptHost`, permissions, dry run, console, rules).

- [x] S1 Run log — every run persisted (script, trigger, start/end, duration, result incl. cancelled / dry run / interrupted by a crash, output, files changed); runs left "running" after a crash are marked interrupted
- [x] S2 Script runs in the Timeline — new "Scripts" filter, succeeded / failed / cancelled / simulated distinguishable, linked to the files the run changed
- [x] S3 JavaScript API v1 — `wayfile.version`, `selection` with attributes, `panel` (path, open, refresh, other pane), `dialogs` (alert, confirm, prompt, choose file / folder), `files.checksum`, `metadata` (dates, size, type, EXIF), `workspaces` (list, open), `transfer` through the transfer engine, `sleep`; errors with line numbers
- [x] S4 Dry-run plan — a dry run collects a structured plan (create / rename / move / trash / conflicts) shown as a table before running for real
- [x] S5 Code editor — syntax highlighting (JS, shell, Python, AppleScript), line numbers, auto-indent, `wayfile.` completion, syntax check before run, error line highlighted
- [x] S6 Script versions — each save keeps the previous version; history with diff-free restore
- [x] S7 Enable / disable per script; keyboard shortcut per script (`@shortcut`); pin to the context menu top level (`@menu pin`); run after a file operation (`@after copy|move|trash`); drop files on a script to run it
- [x] S8 Script packages — export / import `.wayfilescript` (manifest: name, version, description, compatibility, permissions + source); imported scripts are never run automatically, their triggers start disabled
- [x] S9 API documentation (in-app reference + docs/Scripting.md) and more examples
- [x] S10 Isolation — JavaScript runs in `wayfile-script-runner` (macOS pure-computation sandbox, API calls over a pipe, Stop kills it); in-process fallback without the helper; imported scripts never run automatically. Also fixed: Stop never reached scripts running inside an operation

## Plugins

- [x] Plugins with a native interface — `@panel inspector|window`, `render(ctx)` / `action(id, values, ctx)` with `ui.*` builders drawn in SwiftUI; long-lived sandboxed session, state kept between calls, actions undoable; examples Selection Insights and Rename Studio; New Plugin templates
- [x] API 1.1 — `wayfile.storage` (per-script saved values), `wayfile.images` (resize / convert, dry run + undo), `wayfile.git.status`, `wayfile.open`, live panels (`refreshEvery`)
- [x] Plugins Photo Info, Duplicate Check (Inspector), Folder Cleanup, Image Converter (windows)
- [ ] Plugin ideas: toolbar buttons, sidebar sections, preview handlers for file types, settings pages per plugin

## Localization

- [x] L1 Infrastructure — `Resources/Localization/<lang>.lproj/Localizable.strings` bundled into the app, CFBundleLocalizations, English as the base (keys are the English text)
- [x] L2 Language picker in Settings → General (System / English / Slovenčina), applies after a restart
- [x] L3 `scripts/i18n.py` — extracts every UI string (SwiftUI literals, `String(localized:)`, interpolations as format keys), merges into each language, reports what's missing
- [x] L4 Model and service titles (sidebar sections, smart collections, Timeline kinds and filters, modes, permissions…) through `String(localized:)`; palette and alert texts
- [x] L5 Slovak translation, checked in the running app

## Needs a decision / tooling

- **Open-source dependencies** — the app has none so far. These would use one:
  - [x] Integrated terminal with tabs/profiles, follows the active pane — SwiftTerm (MIT), ⌃`
  - [x] SFTP / SSH browser — Citadel (MIT): saved servers, password (Keychain) or SSH key, host key checked like ssh, upload / download / rename / delete (Tools → SFTP / SSH…)
  - [x] YAML tree viewer — Yams (MIT)
- **Needs full Xcode** (only Command Line Tools are installed):
  - Finder integration (Finder Sync extension), Share / Quick Look extensions, widgets
  - Wayfile actions in Apple Shortcuts (App Intents)
- **Before a public release**
  - Developer ID signing + notarization; auto-updates (Sparkle — also a dependency)
  - Hands-on QA of things verified only by code/tests: dialogs, popovers, drag & drop, Glass theme, shortcut recording, context menus
  - Performance pass on huge folders (10k+ items) and slow network volumes

## Done earlier (beyond the brief)

- Command palette, five layouts with grouping, Quick Look thumbnails, properties window, themes, archives, app icon,
  remembered panel widths, localized Finder tags with colours, tags in use in the sidebar
