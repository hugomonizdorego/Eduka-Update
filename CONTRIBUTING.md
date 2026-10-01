# Contributing

Thank you for improving Eduka-Update-System.

## Development workflow

1. Fork the repository and create a focused branch.
2. Keep privileged operations in `src/backend/` and UI work in `src/gui/`.
3. Preserve English, Tetum, Portuguese, and Indonesian strings when adding
   user-visible text.
4. Run `make check` before opening a pull request.
5. Explain the user-visible behavior and include screenshots for GUI changes.

Do not make the GUI process run as root. New privileged actions must be
allow-listed by the backend and covered by the PolicyKit policy.

## Style

- Python: four-space indentation, clear names, and no blocking package-manager
  calls on the Qt UI thread.
- Bash: `set -Eeuo pipefail`, quoted variables, explicit paths, and validated
  input for root operations.
- Desktop integration: keep X11, Wayland, and LXQt behavior equivalent.

## Commit messages

Use an imperative subject, for example:

```text
Fix Flatpak progress parsing
Add Tetum restart notification
```

By submitting a contribution, you license it under GPL-3.0-or-later.

