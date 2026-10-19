# Scripting Wayfile

Wayfile runs your own scripts on the files you select. You can start a script from:

- the context menu or the command palette
- a keyboard shortcut
- dropping files on it

Scripts can also run on their own: when new files appear in a folder, after a Wayfile operation, or on a
schedule.

Scripts are plain files in `~/Library/Application Support/Wayfile/Scripts`. You manage them in the
**Automation** window.

## Languages

| Language | File | How it gets the selection | Permissions |
|---|---|---|---|
| JavaScript | `.js` | `wayfile.selection` / `wayfile.items` | **Enforced** — only the declared ones work |
| Shell (sh, zsh, bash) | `.sh` `.zsh` `.bash` | arguments `"$@"` | Informational — runs with your user's access |
| Python | `.py` | `sys.argv[1:]` | Informational |
| AppleScript | `.applescript` | `on run argv` | Informational |
| Pipeline | `.pipeline` | one step per line; a step's output paths feed the next | Per step |
| Apple Shortcuts | (in Shortcuts) | input files | — |

Shell, Python and AppleScript scripts also get these environment variables:

| Variable | Contains |
|---|---|
| `WAYFILE_SELECTION` | The selected paths, one per line |
| `WAYFILE_COUNT` | Number of selected items |
| `WAYFILE_FOLDER` | The active pane's folder |
| `WAYFILE_OTHER_FOLDER` | The other pane's folder |
| `WAYFILE_DRY_RUN` | `1` in a dry run — the script itself must honour it |

Any existing path that a script prints becomes its output. In a pipeline, that output is the next step's
selection.

JavaScript is the managed language:

- Its file changes go through Wayfile, so they can be undone from the Timeline and planned in a dry run.
- It can't reach files, processes or the network except through the API below.

## The header

Settings live in comments at the top of the file. Use `//` for JavaScript, `#` for shell, Python and
pipelines, and `--` for AppleScript.

```js
// @name Rename Photos by Date
// @description Uses the EXIF capture date
// @version 1.0
// @extensions jpg, jpeg, heic
// @count 1+
// @permissions metadata, write
```

| Key | Meaning |
|---|---|
| `@name` | Shown in menus (default: the file name) |
| `@description` | One line shown in the manager |
| `@version` | Free-form version, e.g. `1.2` (exported with the package) |
| `@extensions` | File types the script applies to (none = any file) |
| `@count` | How many items: `1`, `1+`, `2-5`, `0` (runs on the folder), `any` |
| `@folders` | `yes` — folders too; `only` — only folders |
| `@permissions` | `read`, `metadata`, `write`, `delete`, `network` |
| `@menu` | `no` — hide from menus; `pin` — directly in the context menu instead of the Scripts submenu |
| `@shortcut` | Keyboard shortcut, e.g. `cmd+shift+L`, `ctrl+alt+f5`, `⌃⌘T` (needs ⌘ or ⌃) |
| `@trigger` | A folder: runs on new files there (after a short debounce) |
| `@after` | `copy`, `move`, `rename`, `trash`, `create` — runs on what those Wayfile operations produced |
| `@schedule` | Minutes between runs |
| `@panel` | `inspector` or `window` — a plugin with an interface (JavaScript, see below) |

## Running

You can run a script yourself from:

- the Automation window (**Run** or **Dry Run**)
- the context menu (the Scripts submenu, or directly if the script is pinned)
- the command palette (**Run Script: …**)
- the Inspector or the Home widget
- its `@shortcut`
- dropping files on the script in the Automation sidebar

Scripts run on their own through `@trigger`, `@after` and `@schedule`. For that, a script must be:

- **allowed** — the first manual run asks
- **enabled**
- for imported scripts, explicitly allowed to run automatically

A script never triggers itself:

- Files a running script creates don't trigger it again.
- Operations made by scripts don't fire `@after`.

To **disable** a script, use the switch in its header. A disabled script stays in the manager, but it isn't
offered anywhere and never runs on its own.

## Permissions and safety

Before the first run, and after every edit, Wayfile shows what the script declares and asks you to allow
it.

For JavaScript, each API call checks its permission. A missing permission throws an error like this:
`The script needs the “delete” permission (add it to @permissions).`

JavaScriptCore is not a security sandbox by itself, so JavaScript runs in a separate helper,
`wayfile-script-runner`, bundled next to the app:

- The helper enters macOS's `pure-computation` sandbox before running the script, so it has no file,
  network or process access of its own.
- Each API call is sent to Wayfile over a pipe, and Wayfile checks it against the script's declared
  permissions there.
- **Stop** terminates the helper, which also ends a script stuck in an endless loop.

If the helper is missing, scripts run inside Wayfile with the same API and permission checks, but
without the process boundary.

Shell, Python and AppleScript scripts run as you, so their declared permissions can't be enforced. Wayfile
says so before running or importing them.

## Dry run

**Dry Run** runs a JavaScript script with `wayfile.dryRun = true`. Every change is reported instead of
made:

- create, overwrite, rename, move, copy, tag, trash and skip
- conflicts, such as name clashes and overwritten files, are flagged

The console shows the plan as a table with a **Run for Real** button.

A dry run can only plan changes made through the API. It can't simulate other side effects of shell or
Python scripts.

## Console, history and the Timeline

Every run is logged with:

- the script and what triggered it
- start time, duration and result
- the end of its output
- the files it changed

The log is kept across launches. A run interrupted by quitting or a crash is marked as interrupted.

Runs also appear in the **Timeline** under **Scripts**:

- Succeeded, failed, cancelled, interrupted and simulated runs are shown differently.
- You can undo all the files a run changed at once.

## Editor

- Syntax highlighting, line numbers and auto-indent.
- `wayfile.` completion: type a dot, or press Esc.
- A syntax check as you type, with the error line marked. JavaScript is checked with JavaScriptCore, shell
  with `-n` and Python with `ast`.
- Runtime errors show the line they came from.
- Version history: every save keeps the previous text, and **Version History…** restores one.

## Sharing scripts

**Export…** saves `Name.wayfilescript`. This is a JSON file with the source and a manifest containing:

- kind, name, version and description
- language, permissions and file types
- automatic triggers
- the minimum API version

**Import Script…** shows the manifest and the full source for you to review before anything is installed.

- Installing never runs the script.
- Its first run asks for permission.
- Its automatic runs stay off until you allow them.

Wayfile refuses a package if:

- its manifest doesn't match the source's header
- it needs a newer API
- it uses a newer package format

The `kind` and `minAPIVersion` fields leave room for other extension kinds and a community repository later.

## Plugins with an interface

A JavaScript script with `@panel inspector` or `@panel window` is a **plugin**:

- `@panel inspector` shows it as a section in the Inspector, for selections that match its `@extensions`
  and `@count`.
- `@panel window` gives it its own window, opened from the Scripts menu, the command palette ("Open Plugin:
  …") or the Automation window.

A plugin defines two functions:

- `render(ctx)` returns the interface, built with `ui.*`.
- `action(id, values, ctx)` (optional) runs when a button, a list row or a control with an `action` is used.

After each action, `render` runs again. The plugin keeps running while it's shown, so its own variables
survive between calls. File changes made in `action` are one undoable step (⌘Z or the Timeline).

`ctx` has `selection`, `items`, `folder`, `otherFolder` and `values` (what's in the controls). It follows the
current selection.

```js
// @name Counter
// @panel window
let count = 0
function render(ctx) {
  return ui.vstack(
    ui.heading(`${ctx.items.length} selected`),
    ui.hstack(ui.textField('note', { placeholder: 'Note' }), ui.button('Add', 'add', { style: 'prominent' })),
    count > 0 && ui.caption(`Clicked ${count}× — ${ctx.values.note}`)
  )
}
function action(id, values, ctx) { if (id === 'add') count++ }
```

| Builder | Shows |
|---|---|
| `ui.vstack(…)`, `ui.hstack(…)` | Columns / rows; optional first argument `{spacing, align: 'center'}`; `{refreshEvery: 10}` on the outermost one renders again every 10 s while shown |
| `ui.section(title, …)` | A titled group |
| `ui.text(text, {style})` | `style`: `title`, `headline`, `caption`, `secondary`, `mono`; or `color` |
| `ui.heading(text)`, `ui.caption(text)` | Shorthands |
| `ui.button(title, id, {style, symbol, disabled})` | `style`: `prominent`, `destructive`, `link`; `symbol`: an SF Symbol |
| `ui.textField(id, {placeholder, value, action})` | `action` runs on Return |
| `ui.toggle(id, title, {value, action})` | A checkbox |
| `ui.picker(id, title, options, {value, style: 'segmented', action})` | A menu or segmented control |
| `ui.progress(value, {label, detail, color})` | A bar, `value` from 0 to 1 |
| `ui.row(label, value)` | A label and a value |
| `ui.list(items)` | Rows of `{title, subtitle, detail, symbol, path, id}`; a row with `id` is clickable |
| `ui.image({path, size})` / `ui.image({symbol, color})` | A file thumbnail or an SF Symbol |
| `ui.badge(text, {color})` | A small coloured label |
| `ui.divider()`, `ui.spacer()` | Separators |

Falsy children are skipped, so `cond && ui.text(…)` works. Colours: red, orange, yellow, green, teal, blue,
indigo, purple, pink, gray.

A plugin runs its code as soon as it's shown, so the first time Wayfile asks before showing it. Plugins
run in the same sandboxed helper as scripts, with the same permission checks. For examples, see
**Selection Insights**, **Photo Info** and **Duplicate Check** (Inspector), and **Rename Studio**, **Folder Cleanup** and **Image Converter** (windows) in the Library.

<!-- api:begin -->
## JavaScript API 1.1

Relative paths resolve against the current folder. Errors are JavaScript exceptions (use `try`/`catch`);
uncaught ones are reported with their line. Async functions work — end the script with `main()`; what the
script returns (a path or an array of paths) becomes its output.

### Context & files

| Member | Returns | Permission | Description |
|---|---|---|---|
| `wayfile.version` | `string` | — | API version, e.g. "1.0". |
| `wayfile.selection` | `string[]` | — | Paths of the selected items (or the files a trigger saw). |
| `wayfile.items` | `object[]` | — | The selection with attributes: path, name, ext, isDirectory, size, modified, created (ms). |
| `wayfile.count` | `number` | — | Number of selected items. |
| `wayfile.folder` | `string \| null` | — | The active pane's folder. |
| `wayfile.otherFolder` | `string \| null` | — | The other pane's folder in dual-pane mode. |
| `wayfile.home` | `string` | — | Your home folder. |
| `wayfile.dryRun` | `boolean` | — | True in a dry run: changes are only described, nothing is touched. |
| `wayfile.log(...values)` | `undefined` | — | Prints to the console (also console.log / info / warn / error). |
| `wayfile.exists(path)` | `boolean` | — | Whether something exists at the path. |
| `wayfile.isDirectory(path)` | `boolean` | — | Whether the path is a folder. |
| `wayfile.size(path)` | `number` | — | Size in bytes. |
| `wayfile.modified(path)` | `number` | — | Modification date in ms since 1970 (use new Date(…)). |
| `wayfile.list(folder)` | `string[]` | read | Visible items in a folder, sorted. |
| `wayfile.readText(path)` | `string` | read | Reads a UTF-8 text file. |
| `wayfile.checksum(path, algorithm = "sha256")` | `string` | read | Hex checksum: "md5", "sha1" or "sha256". |
| `wayfile.metadata(path)` | `object` | metadata | Details: dates, size, type, uti, tags, and for images width, height and EXIF / GPS. |
| `wayfile.writeText(path, text)` | `string` | write | Writes a text file; an existing file goes to the Trash first (undoable). |
| `wayfile.mkdir(path)` | `string` | write | Creates a folder (with intermediate folders). |
| `wayfile.copy(path, toFolder)` | `string` | write | Copies into a folder; name clashes keep both. |
| `wayfile.move(path, toFolder)` | `string` | write | Moves into a folder; name clashes keep both. |
| `wayfile.transfer(paths, toFolder, {mode, conflict})` | `string[]` | write | Copies or moves many items through the transfer engine. mode: "copy" | "move"; conflict: "keepBoth" | "skip" | "replace" (replace needs delete). |
| `wayfile.rename(path, newName)` | `string` | write | Renames in place. |
| `wayfile.tag(path, tagName)` | `string` | write | Adds a Finder tag. |
| `wayfile.trash(path)` | `undefined` | delete | Moves to the Trash (undoable). |
| `wayfile.fetch(url, {method, headers, body})` | `{status, ok, text, headers}` | network | HTTP request (30 s timeout). |
| `wayfile.sleep(ms)` | `undefined` | — | Waits; Stop still works. |
| `wayfile.open(pathOrURL)` | `undefined` | — | Opens a file in its app, or an http(s) / maps / mailto link. *(window only)* |

### `wayfile.storage`

| Member | Returns | Permission | Description |
|---|---|---|---|
| `wayfile.storage.get(key)` | `any` | — | A value this script saved earlier (kept across runs and launches), or null. |
| `wayfile.storage.set(key, value)` | `undefined` | — | Saves a JSON value for this script (1 MB in total). |
| `wayfile.storage.remove(key)` | `undefined` | — | Forgets a saved value. |
| `wayfile.storage.keys()` | `string[]` | — | Keys this script saved. |

### `wayfile.images`

| Member | Returns | Permission | Description |
|---|---|---|---|
| `wayfile.images.convert(paths, {format, maxSize, quality, toFolder, suffix})` | `string[]` | write | Resized / converted copies; format "jpeg" | "png" | "heic" | "tiff" | "webp" (if the system can write it), maxSize in pixels, quality 0–1. Originals stay. |
| `wayfile.images.formats()` | `string[]` | — | Formats images.convert can write on this Mac. |

### `wayfile.git`

| Member | Returns | Permission | Description |
|---|---|---|---|
| `wayfile.git.status(folder)` | `object \| null` | read | Branch, ahead / behind and changed files of the repository containing the folder, or null. |

### `wayfile.panel`

| Member | Returns | Permission | Description |
|---|---|---|---|
| `wayfile.panel.path` | `string \| null` | — | The active pane's folder. |
| `wayfile.panel.otherPath` | `string \| null` | — | The other pane's folder. |
| `wayfile.panel.open(folder)` | `undefined` | — | Shows a folder in the active pane. *(window only)* |
| `wayfile.panel.select(paths)` | `undefined` | — | Selects items in the active pane. *(window only)* |
| `wayfile.panel.refresh()` | `undefined` | — | Reloads the panes (does nothing without a window). |

### `wayfile.dialogs`

| Member | Returns | Permission | Description |
|---|---|---|---|
| `wayfile.dialogs.alert(message, detail?)` | `undefined` | — | Shows a message. *(window only)* |
| `wayfile.dialogs.confirm(message, detail?)` | `boolean` | — | OK / Cancel question. *(window only)* |
| `wayfile.dialogs.prompt(message, defaultValue?)` | `string \| null` | — | Asks for text. *(window only)* |
| `wayfile.dialogs.chooseFile({folders, multiple, message})` | `string[] \| null` | — | Open panel; returns chosen paths. *(window only)* |

### `wayfile.workspaces`

| Member | Returns | Permission | Description |
|---|---|---|---|
| `wayfile.workspaces.list()` | `string[]` | — | Names of saved workspaces. *(window only)* |
| `wayfile.workspaces.open(name)` | `boolean` | — | Switches to a saved workspace. *(window only)* |

*Window only*: available when the script was started from a window; triggers, schedules and `@after` runs
have no window, so these calls throw there.
<!-- api:end -->

## Example

```js
// @name Write Checksums
// @count 1+
// @permissions read, write
const lines = wayfile.items
  .filter(item => !item.isDirectory)
  .map(item => `${wayfile.checksum(item.path)}  ${item.name}`)
wayfile.writeText('checksums.sha256', lines.join('\n') + '\n')
```

For more examples, open the Library in the Automation window.
