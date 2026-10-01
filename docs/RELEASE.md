# Release procedure

1. Update `VERSION`, the source constants, icon manifest, and changelog.
2. Keep the visible version simple (for example `0.12`); do not add a build
   suffix.
3. Run `make check`.
4. Build an archive with `make source-archive`.
5. Test installation on Edukasaun OS in both X11 and Wayland LXQt sessions.
6. Verify APT-only, Flatpak-only, mixed, failed, and restart-required paths.
7. Tag the commit and publish the generated archive.

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

