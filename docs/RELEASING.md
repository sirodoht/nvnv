# Releasing nvnv

nvnv is distributed as a Developer ID-signed, Apple-notarized app in a ZIP archive
attached to a GitHub release.

## Prepare the release

1. In the `nvnv` target's General settings in Xcode, update **Version** to the
   release version and increment **Build**.
2. Add the release date and user-visible changes to `CHANGELOG.md`.
3. Run the release checks:

   ```sh
   swift test --package-path Packages/NVNVCore
   swift run --package-path Packages/NVNVCore nvnv-probes
   ./script/build_and_run.sh --verify
   ```

4. Commit the version and changelog changes.

## Archive and notarize

1. In Xcode, choose **Product > Archive**.
2. In Organizer, select the archive and click **Distribute App**.
3. Choose **Developer ID**, then **Upload**, and use automatic signing.
4. When the archive is **Ready to distribute**, choose **Export Notarized App**.
5. Put the exported app in `releases/<version>/`. The `releases/` directory is
   ignored by Git because it contains generated release artifacts.

## Verify and package

From the version's release directory, verify the signature, stapled notarization
ticket, and Gatekeeper assessment:

```sh
codesign --verify --deep --strict --verbose=2 ./nvnv.app
xcrun stapler validate ./nvnv.app
spctl --assess --type execute --verbose=2 ./nvnv.app
```

Expected results include `valid on disk`, `The validate action worked!`, and
`source=Notarized Developer ID`.

Create the ZIP and its SHA-256 checksum. The final argument to `ditto` is the
required destination path:

```sh
ditto -c -k --sequesterRsrc --keepParent ./nvnv.app nvnv-<version>-macos.zip
shasum -a 256 nvnv-<version>-macos.zip
```

## Tag and publish

Create an annotated tag on the release commit and push both the branch and tag:

```sh
git tag -a v<version> -m "v<version>"
git push origin main
git push origin v<version>
```

Create a GitHub release for the tag, attach `nvnv-<version>-macos.zip`, and put
the changelog highlights and SHA-256 checksum in the release notes. Download the
published asset and test its first launch on another Mac when possible.

Finally, update the version text and GitHub asset URLs in `website/index.html`.

## Published artifact checksums

| Version | Artifact | SHA-256 |
| --- | --- | --- |
| 1.0.0 | `nvnv-1.0.0-macos.zip` | `96a9c1647b604fb5c9f6e997f97c3e207f68a0a76e84175eac0b308d4a4bf564` |
| 1.1.0 | `nvnv-1.1.0-macos.zip` | `bb597be36a43a5ff98aace6b99a95772a8ee9c644df66150aa867df43a69176e` |
| 1.3.0 | `nvnv-1.3.0-macos.zip` | `b0387716de50a58b8c1e2fb57cdb44991cbcc92e9b50ae17e16a0442e3f247f4` |
