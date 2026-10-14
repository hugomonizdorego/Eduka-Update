# Translations

EUS follows the active system/session locale automatically.

| Locale prefix | Language |
| --- | --- |
| `tet` | Tetum |
| `pt` | Portuguese |
| `id`, `in` | Indonesian |
| other | English |

GUI strings are in `crates/eus-gui/src/messages.json` (one table per
language, `{name}` placeholders; a missing entry falls back to English).
Progress messages of the maintenance tool are in
`crates/eus-core/src/i18n.rs`, notifier texts in the launcher script, and
the tray icon strings in `assets/eus-icons/eus-i18n.json`. `cargo test`
checks that every translated key exists in English.

When adding a user-visible string:

1. Add the English source string.
2. Add Tetum, Portuguese, and Indonesian translations in the same change.
3. Test with `LANG=tet_TL.UTF-8`, `LANG=pt_PT.UTF-8`, and
   `LANG=id_ID.UTF-8` where those locales are installed.
4. Keep product names, command names, and version numbers untranslated.

Translations must be concise enough for the compact default window and should
still work when the window is maximized or used with display scaling.

