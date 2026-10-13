# Release procedure

1. Update `VERSION`, `version` in `Cargo.toml`, the launcher's `VERSION`,
   the icon manifest, and the changelog.
2. Keep the visible version simple (for example `0.14`); do not add a build
   suffix.
3. Run `make check` and `make screenshots` (English screenshots in
   `docs/screenshots`).
4. Refresh the downloadable package with `make releases`, commit, then push a
   `vX.Y` tag: the `Build .deb package` workflow publishes the GitHub release
   with the `.deb` packages and the self-contained Cubic installer.
5. Build an archive with `make source-archive`.
6. Test installation on Edukasaun OS in both X11 and Wayland LXQt sessions.
7. Verify APT-only, Flatpak-only, mixed, failed, and restart-required paths.
8. Tag the commit and publish the generated archive.

Example first publication:

```bash
git init -b main
git add .
git commit -m "Release Eduka-Update-System 0.12"
git remote add origin https://github.com/YOUR-ACCOUNT/eduka-update-system.git
git push -u origin main
git tag -a v0.12 -m "Eduka-Update-System 0.12"
git push origin v0.12
```

