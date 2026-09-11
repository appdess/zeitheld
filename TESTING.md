# Testing ZeitHeld

Use synthetic profiles and fictional ideas. Do not put a child's voice, personal
information, tokens or provider credentials in test artifacts or GitHub issues.

## Deterministic local checks

Generate the project after adding/removing source files or local Firebase config:

```bash
xcodegen generate
xcodebuild test -project WatchLearn.xcodeproj -scheme WatchLearn \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' \
  -parallel-testing-enabled NO
```

Use an installed compatible Simulator version if 26.2 is unavailable. Keep normal
Simulator ad-hoc signing for Keychain tests. Disabling signing can remove its
entitlement and invalidate the key-persistence scenario.

The normal suite covers curriculum/grading, child profile persistence and reset,
audio/session state, prompt and image boundaries, cancellation, navigation,
privacy confirmation, optional purpose separation and withdrawal. UI tests use
explicit Debug-only fixtures; they do not prove live model behavior.

The Hero Lab fixture shows recording, processing and accepted text without using
a microphone. Generation and transcription pause at a Debug-only request gate.
XCTest first observes the pending UI state, then taps the fixture completion
control; no wall-clock delay determines whether the state can be observed.
These controls exist only for the explicit fixture launch and are excluded from
Release builds. Hosted UI tests use Apple Silicon; Intel analysis and Release
builds separately retain compiler and architecture coverage.

For the backend:

```bash
cd Backend
npm ci --ignore-scripts
npm test
npm audit --omit=dev
```

The optional real Firestore transaction test is described in Backend/README.md.
It uses a unique synthetic namespace and cleans up. Unit mocks exercise ordering
and state transitions, while that separate check verifies actual transactions.

## Release checks

CI also runs the privacy-review scrolling/back path and real system Keychain
persistence against the Release configuration with `ENABLE_TESTABILITY=YES`.
The navigation check does not accept an agreement. This caught a modal
presentation regression that the earlier Debug-only signup coverage missed.
Distribution builds are built separately without enabling testability.

```bash
./Scripts/security-check.sh
./Scripts/test-release-guards.sh
xcodebuild analyze -project WatchLearn.xcodeproj -scheme WatchLearn \
  -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator'
```

Build a Release app and run `Scripts/verify-release-binary.sh` and
`Scripts/verify-release-bundle.py` with the arguments documented by those scripts.
Do not distribute UI fixtures, test keys, local configuration, diagnostic output
or an XCTest-enabled build. A Simulator archive is not an installable iPhone
or TestFlight package.

## Optional paid integration tests

All live tests are skipped by default. Enabling them is an explicit decision
that can incur provider costs. Supply secrets through private temporary files or
secure runtime configuration, never the app bundle or command-line arguments.

- `WATCHLEARN_RUN_SIGNED_IN_HANDSHAKE=1`: physical-device native WebRTC setup,
  cancellation-safe close, reconnect and account settlement. Uses the existing
  signed-in adult account and its current consent receipt. It never enables
  microphone capture. The parent must personally confirm new real agreements.
- `WATCHLEARN_RUN_MANAGED_LIVE=1`: German and English synthetic WebRTC audio.
  Requires private token and PCM files as documented in
  `ManagedLiveIntegrationTests.swift`, and a configured backend URL.
- Additional direct-provider, recorder and legacy transport test flags are in
  their respective `Live*Tests.swift`/integration test files. Retained Realtime
  tests do not establish native GPT-Live functionality.

A successful account/readiness check does not demonstrate working audio. Before
inviting families, separately validate two-way sound, interruptions, reconnect,
background/navigation shutdown, first-lesson pedagogy, wrong/right answers and
parental permission withdrawal on the actual supported iPhone/iPad versions.

## Evidence limits

Keep build success, UI fixture success, real provider conversation, deployment
readback, installed device version and App Store availability as separate results.
Security review and test success do not establish child-privacy compliance.
