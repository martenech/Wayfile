# Localization

Wayfile is in English and Slovak. The language follows macOS. You can also pick it in
**Settings → General → Language**, and it applies after a restart.

## How it works

- The **keys are the English text** written in the code: `Text("Move to Trash")`, `Button("Rename")`,
  `String(localized: "Recent Documents")`. English needs no table of its own.
- Translations live in `Resources/Localization/<language>.lproj/Localizable.strings`.
  `scripts/build-app.sh` copies them into the app.
- **Counts** use plural rules, because Slovak has three forms: 1 súbor, 2–4 súbory, 5+ súborov.
  - These keys hold just the number: `"%lld files"`. Their forms are in `Resources/Localization/plurals.json`.
  - `i18n.py` turns them into `Localizable.stringsdict`.
  - A sentence with more arguments uses a plural key as one of them:
    `String(localized: "Downloading \(String(localized: "\(n) items")) from \(bucket)")`.

## Writing UI text

- Use a literal where SwiftUI expects text (`Text`, `Button`, `Label`, `Toggle`, `.help`…). It is
  localized automatically.
- Text produced outside a view (alerts, operation titles, model `title` properties) goes through
  `String(localized: "…")`.
- A component that takes a title as a `String` shows it with `Text(key:)` or `Label(key:systemImage:)`.
  Add the component's name to `VIEWS` in `scripts/i18n.py` so its literals are picked up.
- Don't build plurals by hand (`"file\(n == 1 ? "" : "s")"`). Write `"\(n) files"` and add the key to
  `plurals.json`.
- Don't glue sentences together with `+`. Use one interpolated string so translators can reorder it.

## Updating translations

```sh
scripts/i18n.py           # adds new keys (marked /* TODO */), drops removed ones, rebuilds .stringsdict
scripts/i18n.py --check   # only reports; selftest.sh runs this too
```

Translate the `/* TODO */` entries and remove the marker. Keep format specifiers (`%@`, `%lld`) — their
number must match the key.

## Adding a language

1. Create `Resources/Localization/<code>.lproj/` (for example `cs.lproj`) with an empty `Localizable.strings`.
2. Run `scripts/i18n.py`. Every key appears there as `/* TODO */`.
3. Translate the entries, and add the language's forms to each entry in `plurals.json` (`one`, `few`,
   `many`, `other` — whatever the language uses).
4. Add the code to `CFBundleLocalizations` in `scripts/build-app.sh`, and to `AppLanguage` in
   `SettingsView.swift` for the language picker.

## Checking

Run the built app in a language without changing the system:

```sh
build/Wayfile.app/Contents/MacOS/Wayfile -AppleLanguages '(sk)' -NSShowNonLocalizedStrings YES
```

`NSShowNonLocalizedStrings` logs keys that have no translation.
