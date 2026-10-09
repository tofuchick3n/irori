# Contributing

Thanks for wanting to make irori better. This repository doesn't accept pull requests: they are closed automatically without review. That's not a judgment on your change. irori is small and opinionated, and it's kept that way on purpose.

What you can do instead:

- **Fork it and make it yours.** irori is licensed under the [GPL-3.0](LICENSE). Change anything, ship your own build, and share it; if you distribute it, share your source under the same license. Give your fork its own name and icon: "irori" and its icon aren't part of the license.
- **Fix it in your fork** if something is broken. Issues are turned off and there is no support.
- **Report security problems privately.** See [SECURITY.md](SECURITY.md).

## Rebranding a fork

If you ship your own build, give it its own identity so it doesn't collide with irori on people's Macs or pick up irori's updates.

1. **Name and folders.** In `scripts/brand.env`, set `APP_NAME`, `SUPPORT_FOLDER`, and `BUNDLE_ID` (a reverse-DNS id you control). Keep `Sources/Desk/Brand.swift` in sync: `name`, `slug`, `supportFolder`, and `repository` (your fork's URL, used by the About panel's source link). `takibiSite` can stay or go.
2. **Updates.** irori updates through [Sparkle](https://sparkle-project.org). A fork must not use irori's feed or key:
   - Set `FEED_URL` in `scripts/brand.env` to your own `appcast.xml`, for example `https://github.com/<you>/<repo>/releases/latest/download/appcast.xml`.
   - After a first `swift build --disable-sandbox`, run `.build/artifacts/sparkle/Sparkle/bin/generate_keys` to create your own EdDSA key in your login keychain, and put the public key it prints in `SPARKLE_PUBLIC_KEY`. Back up the private key; without it, your users can't get updates.
3. **Signing.** `scripts/make-app` signs ad-hoc by default. `scripts/install-app` and `scripts/make-dmg` use the first "Developer ID Application" identity in your keychain, or the one in `DESK_SIGN_IDENTITY`. For notarization, create a `notarytool` profile with your own Apple ID and team ID; [docs/RELEASING.md](docs/RELEASING.md) has the steps.
4. **Workflows.** If you keep `.github/workflows/close-pull-requests.yml`, change the CONTRIBUTING link in its comment to your fork.
5. **Data migration.** `Sources/Desk/LegacyData.swift` moves data over from the app's earlier names. A fresh fork can leave it alone; if you rename your own app later, add your old folder there.
6. **Icon and packaging.** The icon is drawn by `scripts/make-icon.swift`. `packaging/homebrew/irori.rb` is a Homebrew cask template; rename it and point its `url`, `homepage`, and `zap` paths at your fork.

The SwiftPM target and executable are called `Desk`; you don't need to rename them.

## Working on the code

[AGENTS.md](AGENTS.md) holds the principles and commands, for people and coding agents alike. In short: stock SwiftUI, one agent speaks at a time, the app owns no tools of its own, and always pass `--disable-sandbox` to SwiftPM.

irori works with [Takibi Base](https://takibibase.com), but nothing in it requires Takibi. If your fork drops the Takibi settings, the rest of the app keeps working.
