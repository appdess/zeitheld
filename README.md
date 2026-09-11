<p align="center">
  <img src="WatchLearn/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="128" alt="ZeitHeld clock superhero icon">
</p>

# ZeitHeld · Time Hero

A playful iPhone and iPad app for learning to read an analog clock, in German
and English. Built as a personal family project and shared under the MIT license.

[![iOS CI](https://github.com/appdess/zeitheld/actions/workflows/ci.yml/badge.svg)](https://github.com/appdess/zeitheld/actions/workflows/ci.yml)
[![CodeQL](https://github.com/appdess/zeitheld/actions/workflows/codeql.yml/badge.svg)](https://github.com/appdess/zeitheld/actions/workflows/codeql.yml)
[![MIT license](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**Status:** development beta. Offline learning works without an account or API
key. Hosted online access is restricted to approved adults testing fictional
content. Public child cloud access, App Store release and a public TestFlight
invitation are not available yet. Publishing this source does not enable them.

## Learn, talk, create

- Practice full hours, half hours, quarters, five-minute steps and exact minutes.
- Follow a separate saved learning journey for each child, including correct and
  incorrect answers. Reset one journey without removing the others.
- Use the device language automatically, or choose German/English in Settings.
- Describe an original hero first; optionally pick appearance and scene details.
  Voice entry shows recording, processing and accepted-text feedback.
- Optional GPT-Live voice uses native, full-duplex WebRTC. A short first
  conversation asks about familiarity with clocks and numbers; local code grades
  clock answers. AI responses can be wrong and need adult supervision.
- Review privacy before Apple sign-in. Voice and Hero Lab have separate optional
  permissions, a versioned account receipt, and withdrawal in Settings.

There are no advertisements or Firebase Analytics. Apple/Firebase authentication
is used for the optional managed parent account. Read [PRIVACY.md](PRIVACY.md)
and [TERMS.md](TERMS.md) for the actual beta boundaries.

## Run offline

Use Xcode 26.2 or newer, Swift 6, and iOS/iPadOS 17 or newer. Generate the project
before opening it; local Firebase configuration is deliberately not distributed.

```bash
./Scripts/install-xcodegen.sh
.tools/xcodegen/bin/xcodegen generate
open WatchLearn.xcodeproj
```

Choose the `WatchLearn` scheme and an iPhone Simulator. A new checkout has no
managed endpoint or credentials and runs offline. To install on a phone, select
your own Apple signing team and bundle identifier.

## Configure your own online service

The reusable OpenAI key belongs in the backend's secret manager, never in the
app or repository. The iOS client receives a bounded session connection, while
continuous audio travels directly between the device and OpenAI.

```mermaid
flowchart LR
  Parent[Parent: privacy choices + Apple sign-in] --> Firebase[Firebase Auth]
  App[iOS app] -->|Verified token, consent, session setup| Backend[Cloud Run backend]
  Backend -->|Permissions and usage ledger| Firestore[Firestore]
  Backend -->|Scheduled session shutdown| Tasks[Cloud Tasks]
  Backend -->|Server credential| OpenAI[OpenAI]
  App <-->|Live audio over WebRTC| OpenAI
```

1. Configure your own Firebase iOS app and Apple sign-in provider. Download its
   `GoogleService-Info.plist` into `WatchLearn/Resources/` (git-ignored).
2. Deploy the Node backend using [Backend/README.md](Backend/README.md).
3. Create an ignored root `Secrets.xcconfig` with your service URL:

   ```xcconfig
   ZEITHELD_SERVICE_URL = https:/$()/your-service.example.com
   ```

4. Regenerate the Xcode project, build, and review privacy before signing in.

The unusual URL spelling avoids xcconfig treating `//` as a comment. Firebase
client configuration is public configuration rather than an administrator secret;
we omit the maintainer's configuration so forks do not target the hosted service.

Debug builds also offer a private API-key option. Keys stay in the device-only
Keychain and are not synchronized from the Mac. It is intended for adult testing
and has separate provider billing. Release Settings hides key entry.

## Tests and security

[TESTING.md](TESTING.md) explains deterministic Simulator tests and opt-in live
checks. Paid tests are disabled in normal CI. The backend has unit tests and an
explicit, isolated Firestore transaction check.

```bash
cd Backend
npm ci
npm test
npm audit --omit=dev
```

Read [SECURITY.md](SECURITY.md) before deploying or releasing. A source audit,
passing tests or an acceptance checkbox is not a guarantee of security, valid
parental authorization or legal compliance. Operator details, provider retention,
child privacy, store disclosures and release controls still need verification.

## Feedback and contributions

Found a bug or have a learning idea? [Open a GitHub issue](https://github.com/appdess/zeitheld/issues/new/choose).
Do not include children's names, recordings, transcripts, credentials or other
private information. Report security issues through
[private vulnerability reporting](https://github.com/appdess/zeitheld/security/advisories/new).

GitHub can email issue notifications and accept replies to an existing thread.
A private support mailbox is a separate service; no automatic email-to-public-
issue forwarding is configured. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE) for the application source and original bundled project assets;
see [ASSET_PROVENANCE.md](ASSET_PROVENANCE.md).
Dependencies are fetched through the pinned Swift/npm manifests and retain their
own licenses.
Hosted beta terms, provider services and third-party licenses apply separately.
This is a personal project, not an official OpenAI product.
