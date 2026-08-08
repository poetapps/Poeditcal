# Releasing Poeditcal

Poeditcal releases are built by GitHub Actions from version tags. The workflow signs the app with a Developer ID certificate, notarizes it with Apple, creates and notarizes a DMG, publishes a GitHub Release, signs a Sparkle appcast, and deploys the feed to GitHub Pages.

## One-time account setup

### 1. Apple Developer ID certificate

In Xcode, open **Settings → Accounts**, select the Apple Developer account, choose **Manage Certificates**, and create a **Developer ID Application** certificate if one is not already installed. Export that certificate and its private key from Keychain Access as a password-protected `.p12` file.

Create an App Store Connect API key with permission to submit notarization requests. Download its `.p8` file and record its Key ID and Issuer ID. Apple only offers the private key download once.

### 2. Sparkle key

The Sparkle EdDSA private key is stored in the local login Keychain under the account `poetapps`. Its matching public key is already included in `Packaging/Info.plist`. Export the private key with Sparkle's `generate_keys` tool and store it only as the `SPARKLE_PRIVATE_KEY` GitHub Actions secret. Never commit it.

### 3. GitHub repository secrets

Authenticate GitHub CLI using browser login, then add these Actions secrets in **Repository Settings → Secrets and variables → Actions**:

| Secret | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Ten-character Apple Developer Team ID |
| `DEVELOPER_ID_CERTIFICATE_P12` | Base64-encoded exported `.p12` file |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | Password chosen when exporting the `.p12` |
| `APPLE_API_KEY_P8` | Base64-encoded App Store Connect `.p8` file |
| `APPLE_API_KEY_ID` | App Store Connect API Key ID |
| `APPLE_API_ISSUER_ID` | App Store Connect Issuer ID |
| `SPARKLE_PRIVATE_KEY` | Sparkle EdDSA private key exported by `generate_keys` |

Enable GitHub Pages for the repository and select **GitHub Actions** as the source. The published feed URL is `https://poetapps.github.io/Poeditcal/appcast.xml`.

The Xcode project, bundle identifier, executable/module names, project UTI, and signing assets retain their original `PoetAudio`/`com.poetaudio` identifiers for update, document, and installation compatibility. They are internal identifiers; the GitHub repository, update feed, built product, and all customer-facing release labels use Poeditcal.

## Publish a release

1. Update `CFBundleShortVersionString` and increment `CFBundleVersion` in `Packaging/Info.plist`.
2. Set the matching `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in both Xcode target configurations.
3. Add `ReleaseNotes/<version>.md`.
4. Build and test locally.
5. Commit the release, create an annotated `v<version>` tag, and push the commit and tag.

Example for the first release:

```sh
./Scripts/validate-release.sh v1.0.0
git tag -a v1.0.0 -m "Poeditcal 1.0.0"
git push origin main
git push origin v1.0.0
```

The tag starts `.github/workflows/release.yml`. Do not create the GitHub Release manually; the workflow creates it only after signing and notarization succeed.

## Verify

Download the DMG from the GitHub Release on a Mac that does not have the development certificate. Install and launch Poeditcal, then use **Poeditcal → Check for Updates…**. A newly installed current version should report that it is up to date. Test a later version with a higher build number to verify the complete update path.
