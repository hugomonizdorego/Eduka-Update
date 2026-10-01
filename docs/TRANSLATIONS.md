# Translations

EUS follows the active system/session locale automatically.

| Locale prefix | Language |
| --- | --- |
| `tet` | Tetum |
| `pt` | Portuguese |
| `id`, `in` | Indonesian |
| other | English |

Core GUI strings are defined in the Python GUI and shell components. Shared
icon/indicator strings are stored in `assets/eus-icons/eus-i18n.json`.

When adding a user-visible string:

1. Add the English source string.
2. Add Tetum, Portuguese, and Indonesian translations in the same change.
3. Test with `LANG=tet_TL.UTF-8`, `LANG=pt_PT.UTF-8`, and
   `LANG=id_ID.UTF-8` where those locales are installed.
4. Keep product names, command names, and version numbers untranslated.

Translations must be concise enough for the compact default window and should
still work when the window is maximized or used with display scaling.

