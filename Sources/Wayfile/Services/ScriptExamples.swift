import Foundation

/// Ready-made scripts the user can install into the Scripts folder (Automation → Library).
enum ScriptExamples {
    struct Example: Identifiable {
        let fileName: String
        let text: String
        var id: String { fileName }
        var script: Script? { Script(url: URL(fileURLWithPath: "/examples").appendingPathComponent(fileName), text: text) }
    }

    static let all: [Example] = [
        Example(fileName: "Resize for Web.zsh", text: """
        #!/bin/zsh
        # @name Resize for Web
        # @description JPEG copies at most 1600 px wide, next to the originals
        # @extensions jpg, jpeg, png, heic, tiff
        # @count 1+
        # @permissions read, write
        for file in "$@"; do
          out="${file:r}-web.jpg"
          if [[ "$WAYFILE_DRY_RUN" == 1 ]]; then echo "Would create $out"; continue; fi
          sips -Z 1600 -s format jpeg -s formatOptions 80 "$file" --out "$out" >/dev/null && echo "$out"
        done

        """),
        Example(fileName: "Dated Zip.zsh", text: """
        #!/bin/zsh
        # @name Zip with Date
        # @description Compresses the selection into “Name 2026-10-09.zip”
        # @count 1+
        # @folders yes
        # @permissions read, write
        base="${1:t:r}"
        (( $# > 1 )) && base="Archive"
        out="$WAYFILE_FOLDER/$base $(date +%Y-%m-%d).zip"
        n=2; while [[ -e "$out" ]]; do out="$WAYFILE_FOLDER/$base $(date +%Y-%m-%d) $((n++)).zip"; done
        if [[ "$WAYFILE_DRY_RUN" == 1 ]]; then echo "Would create $out"; exit 0; fi
        cd "$WAYFILE_FOLDER" && zip -qry "$out" "${@:t}" -x '*.DS_Store' && echo "$out"

        """),
        Example(fileName: "Count Lines.py", text: """
        #!/usr/bin/env python3
        # @name Count Lines
        # @description Lines, words and characters of text files
        # @extensions txt, md, swift, js, ts, py, json, csv, html, css, sh, yml, yaml
        # @count 1+
        # @permissions read
        import os, sys

        total = 0
        for path in sys.argv[1:]:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
            lines = text.count("\\n") + (0 if text.endswith("\\n") or not text else 1)
            total += lines
            print(f"{lines:>8}  {len(text.split()):>8} words  {os.path.basename(path)}")
        if len(sys.argv) > 2:
            print(f"{total:>8}  total")

        """),
        Example(fileName: "Lowercase Names.js", text: """
        // @name Lowercase Names
        // @description Renames the selection to lower case (try Dry Run first)
        // @count 1+
        // @folders yes
        // @permissions read, write
        const renamed = []
        for (const path of wayfile.selection) {
          const name = path.split('/').pop()
          const lower = name.toLowerCase()
          renamed.push(lower === name ? path : wayfile.rename(path, lower))
        }
        renamed

        """),
        Example(fileName: "Sort by Kind.js", text: """
        // @name Sort Folder by Kind
        // @description Moves files of the current folder into Images, Documents, Archives… subfolders
        // @count 0
        // @permissions read, write
        const kinds = {
          Images: ['jpg', 'jpeg', 'png', 'gif', 'heic', 'webp', 'tiff', 'svg'],
          Documents: ['pdf', 'doc', 'docx', 'pages', 'txt', 'md', 'rtf', 'xls', 'xlsx', 'numbers', 'key', 'ppt', 'pptx'],
          Archives: ['zip', 'tar', 'gz', 'tgz', '7z', 'rar', 'dmg'],
          Audio: ['mp3', 'm4a', 'wav', 'aiff', 'flac'],
          Video: ['mp4', 'mov', 'm4v', 'mkv', 'avi'],
        }
        let moved = 0
        for (const path of wayfile.list(wayfile.folder)) {
          if (wayfile.isDirectory(path)) continue
          const ext = path.split('.').pop().toLowerCase()
          const kind = Object.keys(kinds).find(k => kinds[k].includes(ext))
          if (!kind) continue
          wayfile.move(path, wayfile.folder + '/' + kind)
          moved++
        }
        wayfile.log((wayfile.dryRun ? 'Would move ' : 'Moved ') + moved + ' files')

        """),
        Example(fileName: "Archive Old Downloads.js", text: """
        // @name Archive Old Downloads
        // @description Moves files older than 30 days from Downloads to Downloads/Old (runs daily)
        // @count 0
        // @menu no
        // @schedule 1440
        // @permissions read, write
        const downloads = wayfile.folder || (wayfile.home + '/Downloads')
        const cutoff = Date.now() - 30 * 24 * 3600 * 1000
        for (const path of wayfile.list(downloads)) {
          if (wayfile.isDirectory(path)) continue
          if (wayfile.modified(path) < cutoff) wayfile.move(path, downloads + '/Old')
        }

        """),
        Example(fileName: "Tag New Screenshots.js", text: """
        // @name Tag New Screenshots
        // @description Tags screenshots that land on the Desktop
        // @extensions png, jpg
        // @menu no
        // @trigger ~/Desktop
        // @permissions read, write
        for (const path of wayfile.selection) {
          const name = path.split('/').pop()
          if (name.startsWith('Screenshot') || name.startsWith('Snímka obrazovky')) wayfile.tag(path, 'Screenshot')
        }

        """),
        Example(fileName: "Rename Photos by Date.js", text: """
        // @name Rename Photos by Date
        // @description “2026-05-01 14.03.22.jpg” from the EXIF capture date (try Dry Run first)
        // @version 1.0
        // @extensions jpg, jpeg, heic, png, tiff
        // @count 1+
        // @permissions metadata, write
        const renamed = []
        for (const item of wayfile.items) {
          const exif = (wayfile.metadata(item.path).image || {}).exif || {}
          const taken = exif.DateTimeOriginal   // "2026:05:01 14:03:22"
          if (!taken) { console.warn(`${item.name}: no capture date`); continue }
          const [date, time] = taken.split(' ')
          const name = `${date.replaceAll(':', '-')} ${time.replaceAll(':', '.')}.${item.ext}`
          renamed.push(name === item.name ? item.path : wayfile.rename(item.path, name))
        }
        renamed

        """),
        Example(fileName: "Checksums.js", text: """
        // @name Write Checksums
        // @description Saves a SHA-256 list of the selected files as checksums.sha256
        // @version 1.0
        // @count 1+
        // @permissions read, write
        const lines = []
        for (const item of wayfile.items) {
          if (item.isDirectory) continue
          lines.push(`${wayfile.checksum(item.path)}  ${item.name}`)
        }
        const out = wayfile.writeText('checksums.sha256', lines.join('\\n') + '\\n')
        wayfile.log(`${lines.length} checksums → ${out}`)
        out

        """),
        Example(fileName: "Sort into Folders.js", text: """
        // @name Sort into Folders
        // @description Moves the selection into Images, Documents, Archives… after asking
        // @version 1.0
        // @count 1+
        // @permissions write
        const groups = { Images: ['jpg', 'jpeg', 'png', 'heic', 'gif', 'tiff', 'webp'], Movies: ['mov', 'mp4', 'm4v'],
                         Audio: ['mp3', 'm4a', 'wav', 'aiff'], Archives: ['zip', 'dmg', 'tar', 'gz', '7z'],
                         Documents: ['pdf', 'doc', 'docx', 'pages', 'txt', 'md', 'xlsx', 'numbers', 'key', 'pptx'] }
        const plan = {}
        for (const item of wayfile.items) {
          if (item.isDirectory) continue
          const folder = Object.keys(groups).find(g => groups[g].includes(item.ext)) || 'Other'
          ;(plan[folder] = plan[folder] || []).push(item.path)
        }
        const summary = Object.entries(plan).map(([f, l]) => `${f}: ${l.length}`).join(', ')
        if (wayfile.dryRun || wayfile.dialogs.confirm('Sort the selection?', summary)) {
          for (const [folder, paths] of Object.entries(plan)) {
            wayfile.transfer(paths, wayfile.folder + '/' + folder, { mode: 'move', conflict: 'keepBoth' })
          }
          wayfile.panel.refresh()
        }

        """),
        Example(fileName: "Tag with Prompt.js", text: """
        // @name Tag…
        // @description Asks for a tag name and adds it to the selection
        // @version 1.0
        // @count 1+
        // @folders yes
        // @permissions write
        // @shortcut ctrl+cmd+t
        const tag = wayfile.dialogs.prompt('Tag name', 'Review')
        if (tag) {
          for (const path of wayfile.selection) wayfile.tag(path, tag)
        }

        """),
        Example(fileName: "Selection Insights.js", text: """
        // @name Selection Insights
        // @description Size by type, the largest files and quick tagging — an Inspector plugin example
        // @version 1.0
        // @panel inspector
        // @count 1+
        // @folders yes
        // @permissions read, write
        let note = ''

        function render(ctx) {
          const files = []
          for (const item of ctx.items) {
            if (!item.isDirectory) { files.push(item); continue }
            for (const path of wayfile.list(item.path).slice(0, 300)) {
              if (wayfile.isDirectory(path)) continue
              const name = path.split('/').pop()
              files.push({ path, name, ext: name.includes('.') ? name.split('.').pop().toLowerCase() : '', size: wayfile.size(path) })
            }
          }
          const total = files.reduce((sum, file) => sum + file.size, 0)
          const byType = {}
          for (const file of files) byType[file.ext || 'other'] = (byType[file.ext || 'other'] || 0) + file.size
          const types = Object.entries(byType).sort((a, b) => b[1] - a[1]).slice(0, 5)
          const largest = files.slice().sort((a, b) => b.size - a.size).slice(0, 5)
          return ui.vstack(
            ui.hstack(ui.heading(`${files.length} file${files.length === 1 ? '' : 's'}`), ui.spacer(), ui.badge(size(total), { color: 'blue' })),
            types.map(([ext, bytes]) => ui.progress(total ? bytes / total : 0, { label: ext.toUpperCase(), detail: size(bytes) })),
            largest.length > 1 && ui.caption('Largest — click to reveal'),
            largest.length > 1 && ui.list(largest.map(file => ({ title: file.name, detail: size(file.size), path: file.path, id: 'reveal:' + file.path }))),
            ui.hstack(ui.textField('tag', { placeholder: 'Tag name', value: 'Review', action: 'tag' }), ui.button('Tag', 'tag', { symbol: 'tag' })),
            note && ui.caption(note)
          )
        }

        function action(id, values, ctx) {
          if (id.startsWith('reveal:')) {
            const path = id.slice('reveal:'.length)
            wayfile.panel.open(path.slice(0, path.lastIndexOf('/')))
            wayfile.panel.select([path])
          } else if (id === 'tag' && values.tag) {
            for (const path of ctx.selection) wayfile.tag(path, values.tag)
            note = `Tagged ${ctx.selection.length} item(s) “${values.tag}” — undo with ⌘Z`
          }
        }

        function size(bytes) {
          const units = ['B', 'KB', 'MB', 'GB', 'TB']
          let i = 0
          while (bytes >= 1000 && i < units.length - 1) { bytes /= 1000; i++ }
          return `${bytes.toFixed(i ? 1 : 0)} ${units[i]}`
        }

        """),
        Example(fileName: "Rename Studio.js", text: """
        // @name Rename Studio
        // @description Find & replace, prefix, case and numbering with a live preview — a window plugin example
        // @version 1.0
        // @panel window
        // @permissions write
        let note = ''

        function plan(items, v) {
          return items.map((item, i) => {
            const dot = item.isDirectory ? -1 : item.name.lastIndexOf('.')
            let base = dot > 0 ? item.name.slice(0, dot) : item.name
            const ext = dot > 0 ? item.name.slice(dot) : ''
            if (v.find) base = base.split(v.find).join(v.replace || '')
            if (v.case === 'lower') base = base.toLowerCase()
            if (v.case === 'UPPER') base = base.toUpperCase()
            if (v.number) base = `${String(i + 1).padStart(2, '0')} ${base}`
            return { item, name: (v.prefix || '') + base + ext }
          })
        }

        function render(ctx) {
          if (!ctx.items.length) {
            return ui.vstack(ui.heading('Rename Studio'), ui.text('Select files in a Wayfile window — this panel follows the selection.', { style: 'secondary' }), note && ui.caption(note))
          }
          const steps = plan(ctx.items, ctx.values || {})
          const names = steps.map(step => step.name)
          const clashes = names.filter((name, i) => names.indexOf(name) !== i).length
          const changed = steps.filter(step => step.name !== step.item.name).length
          return ui.vstack(
            ui.heading(`Rename ${ctx.items.length} item${ctx.items.length === 1 ? '' : 's'}`),
            ui.section('Rules',
              ui.hstack(ui.textField('find', { placeholder: 'Find', action: 'preview' }), ui.textField('replace', { placeholder: 'Replace with', action: 'preview' })),
              ui.textField('prefix', { placeholder: 'Prefix', action: 'preview' }),
              ui.picker('case', 'Case', ['Keep', 'lower', 'UPPER'], { action: 'preview', style: 'segmented' }),
              ui.toggle('number', 'Number them (01, 02…)', { action: 'preview' })),
            ui.hstack(ui.caption(`${changed} will change`), clashes > 0 && ui.badge(`${clashes} duplicate name${clashes === 1 ? '' : 's'}`, { color: 'red' }), ui.spacer(),
                      ui.button('Preview', 'preview', { symbol: 'eye' })),
            ui.list(steps.slice(0, 40).map(step => ({ title: step.name, subtitle: step.name === step.item.name ? 'unchanged' : 'was ' + step.item.name, path: step.item.path }))),
            steps.length > 40 && ui.caption(`and ${steps.length - 40} more`),
            ui.button('Rename', 'rename', { style: 'prominent', symbol: 'pencil', disabled: changed === 0 || clashes > 0 }),
            note && ui.caption(note)
          )
        }

        function action(id, values, ctx) {
          if (id !== 'rename') return
          let done = 0
          for (const step of plan(ctx.items, values)) {
            if (step.name !== step.item.name) { wayfile.rename(step.item.path, step.name); done++ }
          }
          note = `Renamed ${done} — undo with ⌘Z or from the Timeline`
          wayfile.panel.refresh()
        }

        """),
        Example(fileName: "Photo Info.js", text: """
        // @name Photo Info
        // @description Camera, lens, exposure and location of a photo; rename it by its capture date
        // @version 1.0
        // @panel inspector
        // @extensions jpg, jpeg, heic, heif, png, tiff, dng
        // @count 1
        // @permissions metadata, write
        function details(item) {
          const image = wayfile.metadata(item.path).image || {}
          const exif = image.exif || {}, tiff = image.tiff || {}, gps = image.gps || {}
          const location = gps.Latitude == null ? null : {
            lat: gps.Latitude * (gps.LatitudeRef === 'S' ? -1 : 1),
            lon: gps.Longitude * (gps.LongitudeRef === 'W' ? -1 : 1),
          }
          return { image, exif, camera: [tiff.Make, tiff.Model].filter(Boolean).join(' '), location }
        }

        function render(ctx) {
          const item = ctx.items[0]
          const { image, exif, camera, location } = details(item)
          const iso = exif.ISOSpeedRatings && [].concat(exif.ISOSpeedRatings)[0]
          const exposure = [
            exif.FNumber && `ƒ/${exif.FNumber}`,
            exif.ExposureTime && (exif.ExposureTime >= 1 ? `${exif.ExposureTime} s` : `1/${Math.round(1 / exif.ExposureTime)} s`),
            iso && `ISO ${iso}`,
            exif.FocalLength && `${Math.round(exif.FocalLength)} mm`,
          ].filter(Boolean).join('  ·  ')
          return ui.vstack(
            ui.hstack(ui.image({ symbol: 'camera', color: 'blue' }), ui.heading(camera || 'No camera data'), ui.spacer(),
                      image.width && ui.badge(`${image.width} × ${image.height}`)),
            exif.LensModel && ui.row('Lens', exif.LensModel),
            exposure && ui.row('Exposure', exposure),
            exif.DateTimeOriginal && ui.row('Taken', exif.DateTimeOriginal.replace(/^(\\d+):(\\d+):(\\d+)/, '$1-$2-$3')),
            location && ui.row('Location', `${location.lat.toFixed(5)}, ${location.lon.toFixed(5)}`),
            ui.hstack(
              location && ui.button('Show in Maps', 'maps', { symbol: 'map' }),
              exif.DateTimeOriginal && ui.button('Rename by Date', 'rename', { symbol: 'calendar' })
            )
          )
        }

        function action(id, values, ctx) {
          const item = ctx.items[0]
          const { exif, location } = details(item)
          if (id === 'maps' && location) {
            wayfile.open(`maps://?ll=${location.lat},${location.lon}&q=${encodeURIComponent(item.name)}`)
          } else if (id === 'rename' && exif.DateTimeOriginal) {
            const [date, time] = exif.DateTimeOriginal.split(' ')
            wayfile.rename(item.path, `${date.replaceAll(':', '-')} ${time.replaceAll(':', '.')}.${item.ext}`)
          }
        }

        """),
        Example(fileName: "Duplicate Check.js", text: """
        // @name Duplicate Check
        // @description Finds identical files in the selection (or the selected folders) and trashes the extra copies
        // @version 1.0
        // @panel inspector
        // @count 1+
        // @folders yes
        // @permissions read, delete
        let result = null   // { key, groups, wasted } for the selection it was computed for

        function files(ctx) {
          const list = []
          for (const item of ctx.items) {
            if (!item.isDirectory) { list.push({ path: item.path, name: item.name, size: item.size }); continue }
            for (const path of wayfile.list(item.path).slice(0, 2000)) {
              if (!wayfile.isDirectory(path)) list.push({ path, name: path.split('/').pop(), size: wayfile.size(path) })
            }
          }
          return list
        }

        function render(ctx) {
          const key = ctx.selection.join('\\n')
          const all = files(ctx)
          const sizes = {}
          for (const file of all) if (file.size > 0) (sizes[file.size] = sizes[file.size] || []).push(file)
          const candidates = Object.values(sizes).filter(group => group.length > 1).flat()
          if (!result || result.key !== key) {
            return ui.vstack(
              ui.text(`${all.length} files · ${candidates.length} share a size with another file`, { style: 'secondary' }),
              ui.button('Find Duplicates', 'scan', { symbol: 'doc.on.doc', disabled: candidates.length === 0 })
            )
          }
          if (result.groups.length === 0) return ui.vstack(ui.badge('No duplicates', { color: 'green' }), ui.button('Scan Again', 'scan', { style: 'link' }))
          const extra = result.groups.reduce((n, group) => n + group.length - 1, 0)
          return ui.vstack(
            ui.hstack(ui.heading(`${result.groups.length} set${result.groups.length === 1 ? '' : 's'} of duplicates`), ui.spacer(), ui.badge(`${size(result.wasted)} extra`, { color: 'orange' })),
            result.groups.slice(0, 8).map(group => ui.section(`${group[0].name} — ${group.length} copies, ${size(group[0].size)} each`,
              ui.list(group.map((file, i) => ({ title: file.name, subtitle: folder(file.path), detail: i === 0 ? 'keep' : 'extra', path: file.path, id: 'reveal:' + file.path }))))),
            result.groups.length > 8 && ui.caption(`and ${result.groups.length - 8} more sets`),
            ui.button(`Move ${extra} Extra Cop${extra === 1 ? 'y' : 'ies'} to Trash`, 'trash', { style: 'destructive', symbol: 'trash' }),
            ui.caption('Keeps the first file of each set (shortest path). Undo with ⌘Z.')
          )
        }

        function action(id, values, ctx) {
          if (id === 'scan') {
            const sizes = {}
            for (const file of files(ctx)) if (file.size > 0) (sizes[file.size] = sizes[file.size] || []).push(file)
            const byHash = {}
            for (const group of Object.values(sizes)) {
              if (group.length < 2) continue
              for (const file of group) {
                const key = file.size + ':' + wayfile.checksum(file.path, 'md5')
                ;(byHash[key] = byHash[key] || []).push(file)
              }
            }
            const groups = Object.values(byHash).filter(group => group.length > 1)
              .map(group => group.sort((a, b) => a.path.length - b.path.length || a.path.localeCompare(b.path)))
            result = { key: ctx.selection.join('\\n'), groups, wasted: groups.reduce((n, group) => n + group[0].size * (group.length - 1), 0) }
          } else if (id === 'trash' && result) {
            for (const group of result.groups) for (const file of group.slice(1)) wayfile.trash(file.path)
            result = null
            wayfile.panel.refresh()
          } else if (id.startsWith('reveal:')) {
            const path = id.slice(7)
            wayfile.panel.open(path.slice(0, path.lastIndexOf('/')))
            wayfile.panel.select([path])
          }
        }

        function folder(path) { return path.slice(0, path.lastIndexOf('/')).replace(wayfile.home, '~') }
        function size(bytes) {
          const units = ['B', 'KB', 'MB', 'GB', 'TB']
          let i = 0
          while (bytes >= 1000 && i < units.length - 1) { bytes /= 1000; i++ }
          return `${bytes.toFixed(i ? 1 : 0)} ${units[i]}`
        }

        """),
        Example(fileName: "Folder Cleanup.js", text: """
        // @name Folder Cleanup
        // @description Old files, installers and large files in the current folder — review, then move them to the Trash
        // @version 1.0
        // @panel window
        // @permissions read, delete
        const ages = { '1 month': 30, '3 months': 90, '6 months': 182, '1 year': 365 }
        let note = ''

        function settings(values) {
          const saved = wayfile.storage.get('settings') || {}
          return {
            age: values.age || saved.age || '6 months',
            old: values.old ?? saved.old ?? true,
            installers: values.installers ?? saved.installers ?? true,
            large: values.large ?? saved.large ?? true,
          }
        }

        function candidates(folder, s) {
          const now = Date.now(), found = []
          for (const path of wayfile.list(folder)) {
            const name = path.split('/').pop(), dir = wayfile.isDirectory(path)
            const ext = name.includes('.') ? name.split('.').pop().toLowerCase() : ''
            const bytes = dir ? 0 : wayfile.size(path), days = (now - wayfile.modified(path)) / 86400000
            let reason = null
            if (s.installers && ['dmg', 'pkg', 'mpkg', 'iso'].includes(ext)) reason = 'Installer'
            else if (s.large && bytes > 500e6) reason = 'Large'
            else if (s.old && days > ages[s.age]) reason = `Untouched ${Math.round(days)} days`
            if (reason) found.push({ path, name, bytes, reason })
          }
          return found.sort((a, b) => b.bytes - a.bytes)
        }

        function render(ctx) {
          const folder = ctx.items.length === 1 && ctx.items[0].isDirectory ? ctx.items[0].path : ctx.folder
          if (!folder) return ui.text('Open a folder in Wayfile first.', { style: 'secondary' })
          const s = settings(ctx.values || {})
          const found = candidates(folder, s)
          const total = found.reduce((n, f) => n + f.bytes, 0)
          return ui.vstack(
            ui.hstack(ui.image({ symbol: 'folder', color: 'blue' }), ui.heading(folder.split('/').pop() || folder), ui.spacer(), ui.badge(`${found.length} · ${size(total)}`, { color: found.length ? 'orange' : 'green' })),
            ui.section('Look for',
              ui.toggle('installers', 'Installers (.dmg, .pkg, .iso)', { value: s.installers, action: 'settings' }),
              ui.toggle('large', 'Files over 500 MB', { value: s.large, action: 'settings' }),
              ui.hstack(ui.toggle('old', 'Untouched for', { value: s.old, action: 'settings' }),
                        ui.picker('age', '', Object.keys(ages), { value: s.age, action: 'settings' }))),
            found.length === 0 ? ui.caption('Nothing to clean up here.') :
              ui.list(found.slice(0, 50).map(f => ({ title: f.name, subtitle: f.reason, detail: f.bytes ? size(f.bytes) : '', path: f.path, id: 'reveal:' + f.path }))),
            found.length > 50 && ui.caption(`and ${found.length - 50} more`),
            found.length > 0 && ui.button(`Move ${found.length} to Trash`, 'trash', { style: 'destructive', symbol: 'trash' }),
            note && ui.caption(note),
            ui.caption('Looks at the folder itself, not its subfolders. Choices are remembered.')
          )
        }

        function action(id, values, ctx) {
          const folder = ctx.items.length === 1 && ctx.items[0].isDirectory ? ctx.items[0].path : ctx.folder
          const s = settings(values)
          if (id === 'settings') wayfile.storage.set('settings', s)
          if (id === 'trash') {
            const found = candidates(folder, s)
            for (const f of found) wayfile.trash(f.path)
            note = `Moved ${found.length} item(s) to the Trash — undo with ⌘Z`
            wayfile.panel.refresh()
          }
          if (id.startsWith('reveal:')) wayfile.panel.select([id.slice(7)])
        }

        function size(bytes) {
          const units = ['B', 'KB', 'MB', 'GB', 'TB']
          let i = 0
          while (bytes >= 1000 && i < units.length - 1) { bytes /= 1000; i++ }
          return `${bytes.toFixed(i ? 1 : 0)} ${units[i]}`
        }

        """),
        Example(fileName: "Image Converter.js", text: """
        // @name Image Converter
        // @description Resized or converted copies of the selected images (JPEG, PNG, HEIC, TIFF, WebP)
        // @version 1.0
        // @panel window
        // @permissions read, write
        const sizes = ['Original', '3000', '2000', '1600', '1200', '800']
        const qualities = { High: 0.9, Medium: 0.75, Small: 0.55 }
        let made = []

        function settings(values) {
          const saved = wayfile.storage.get('settings') || {}
          const formats = wayfile.images.formats()
          const format = values.format || saved.format || 'jpeg'
          return {
            formats,
            format: formats.includes(format) ? format : formats[0],
            size: values.size || saved.size || '2000',
            quality: values.quality || saved.quality || 'High',
            subfolder: values.subfolder ?? saved.subfolder ?? true,
          }
        }

        function images(ctx) {
          return ctx.items.filter(item => ['jpg', 'jpeg', 'png', 'heic', 'heif', 'tiff', 'tif', 'webp', 'gif', 'bmp'].includes(item.ext))
        }

        function render(ctx) {
          const s = settings(ctx.values || {})
          const list = images(ctx)
          return ui.vstack(
            ui.heading(list.length ? `${list.length} image${list.length === 1 ? '' : 's'} selected` : 'Select images in Wayfile'),
            ui.section('Output',
              ui.picker('format', 'Format', s.formats, { value: s.format, style: 'segmented', action: 'settings' }),
              ui.picker('size', 'Longest side', sizes, { value: s.size, action: 'settings' }),
              s.format !== 'png' && s.format !== 'tiff' && ui.picker('quality', 'Quality', Object.keys(qualities), { value: s.quality, style: 'segmented', action: 'settings' }),
              ui.toggle('subfolder', 'Put copies in a “Converted” folder', { value: s.subfolder, action: 'settings' })),
            ui.button(`Convert ${list.length || ''}`.trim(), 'convert', { style: 'prominent', symbol: 'photo.on.rectangle', disabled: list.length === 0 }),
            made.length > 0 && ui.caption(`Made ${made.length} — undo with ⌘Z`),
            made.length > 0 && ui.list(made.slice(0, 20).map(path => ({ title: path.split('/').pop(), detail: size(wayfile.size(path)), path, id: 'reveal:' + path })))
          )
        }

        function action(id, values, ctx) {
          const s = settings(values)
          if (id === 'settings') wayfile.storage.set('settings', { format: s.format, size: s.size, quality: s.quality, subfolder: s.subfolder })
          if (id === 'convert') {
            const list = images(ctx)
            if (!list.length) return
            const folder = list[0].path.slice(0, list[0].path.lastIndexOf('/'))
            made = wayfile.images.convert(list.map(item => item.path), {
              format: s.format,
              maxSize: s.size === 'Original' ? undefined : Number(s.size),
              quality: qualities[s.quality],
              toFolder: s.subfolder ? folder + '/Converted' : undefined,
            })
            wayfile.panel.refresh()
          }
          if (id.startsWith('reveal:')) {
            const path = id.slice(7)
            wayfile.panel.open(path.slice(0, path.lastIndexOf('/')))
            wayfile.panel.select([path])
          }
        }

        function size(bytes) {
          const units = ['B', 'KB', 'MB', 'GB']
          let i = 0
          while (bytes >= 1000 && i < units.length - 1) { bytes /= 1000; i++ }
          return `${bytes.toFixed(i ? 1 : 0)} ${units[i]}`
        }

        """),
        Example(fileName: "Notify.applescript", text: """
        -- @name Show Notification
        -- @description Posts a macOS notification with the selection count
        -- @count any
        -- @permissions read
        on run argv
        \tdisplay notification ((count of argv) as text) & " item(s) selected" with title "Wayfile"
        end run

        """),
        Example(fileName: "Web Images.pipeline", text: """
        # @name Web Images → Lowercase
        # @description Pipeline: resize for web, then lowercase the new files' names
        # @extensions jpg, jpeg, png, heic, tiff
        # @count 1+
        # @permissions read, write
        Resize for Web.zsh
        Lowercase Names.js

        """),
    ]

    static func isInstalled(_ example: Example, in folder: URL = ScriptLibrary.folder) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(example.fileName).path)
    }

    @discardableResult
    static func install(_ example: Example, in folder: URL = ScriptLibrary.folder) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(example.fileName)
        try example.text.write(to: url, atomically: true, encoding: .utf8)
        if Script.Language(fileExtension: url.pathExtension)?.isExecutableFile == true {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return url
    }
}
