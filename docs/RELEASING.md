# Releasing

1. Bump `APP_VERSION` and `BUILD_NUMBER` in `scripts/brand.env`.
2. Have a notarytool keychain profile. Any existing one for the team works (a profile is just stored
   credentials, not tied to an app). To create one, run in Terminal (it asks for an app-specific password):

   ```sh
   xcrun notarytool store-credentials <profile> --apple-id <your Apple ID> --team-id <your Team ID>
   ```

   If notarytool answers HTTP 403 "A required agreement is missing or has expired", the account holder must
   accept the updated agreement at developer.apple.com/account; it can take a few minutes to take effect.
3. Build, notarize, and write the update feed:

   ```sh
   NOTARY_PROFILE=<profile> scripts/make-dmg
   ```

   This produces `build/release/irori-<version>.dmg` and `build/release/appcast.xml`.
4. Create a GitHub release tagged `v<version>` and attach both files. Installed copies find the update through
   `releases/latest/download/appcast.xml`.
5. Update `sha256` and `version` in `packaging/homebrew/irori.rb` (`shasum -a 256` of the DMG).

The update feed is signed with the EdDSA key that `generate_keys` stored in the login keychain. Back it up
(`.build/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle-private-key`) somewhere safe: without it,
installed copies can't receive updates.
