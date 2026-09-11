# Security policy

## Supported versions

ZeitHeld is an early open-source prototype. Security fixes are applied to the
latest `main` branch. No App Store production release is currently supported.

## Report a vulnerability privately

Use GitHub
[Private Vulnerability Reporting](https://github.com/appdess/zeitheld/security/advisories/new).
Do not open a public issue for a suspected vulnerability.

Please include a concise impact description, affected commit/version,
reproduction conditions, and the smallest safe evidence needed to understand
the problem. Never send a real API key, child data, voice recording, transcript,
generated child content, or another person's private information.

As a personal project, ZeitHeld cannot promise a fixed response SLA, but good-
faith reports will be reviewed as promptly as practical. Please allow time for
a fix before public disclosure.

## Security model and known prototype boundaries

- Offline clock learning requires no account, network, microphone, or secret.
- Cloud features require a current, server-recorded agreement and separate
  permissions. The private online beta currently permits only adults using
  fictional test content; public child access remains disabled. Direct Settings access and the absence of an adult math gate are
  deliberate product requirements, not an authentication boundary.
- A user-provided OpenAI key is stored in the non-synchronizing iOS Keychain.
  This BYOK path is for private testing only; a reusable standard key cannot be
  secured inside a distributed mobile client.
- Managed mode uses an authenticated backend with server-side secrets,
  transactional quotas, per-account consent/lifecycle checks, bounded media
  admission and durable voice deadlines. Cloud IAM, outage handling, retention
  and appropriate child-data terms require separate deployment validation.
- The optional custom token-server URL is an advanced operator trust decision.
  It is not an arbitrary browsing feature and must point to an operator-owned
  HTTPS service.
- Generated images and temporary audio are bounded, validated, protected, and
  locally cleaned. Device backup/crash-report policy and provider retention
  still require production validation.
- Never consider model prompting or moderation a complete child-safety or
  output-security boundary.

The development credential previously used for live testing must be rotated;
it is not present in the tracked source tree and must never be reused for a
public build.

## Release security checks

The repository defines the following release checks. Local results and hosted
GitHub results must be recorded separately; a workflow file is not proof that a
hosted run or repository setting is active:

- OpenAI Daybreak / Codex Security source review;
- deterministic unit and Simulator UI tests;
- Swift and GitHub Actions CodeQL workflows;
- `xcodebuild analyze`, an ad-hoc-signed Simulator Release build, signature and
  bundle-ID verification, and a Release-configuration system Keychain persistence smoke (fresh store instances;
  app relaunch is covered separately in the Debug UI suite);
- local filename-only secret scanning;
- a Release-binary assertion that debug UI-test switches and fixture
  credentials are absent;
- a separate, non-XCTest shell regression suite with forbidden markers both
  early and late in a large binary-like file;
- static inspection of a current-`main`-only release workflow that checks the
  requested version, commit, and tag binding;
- dependency/action updates through Dependabot.

Before binary publication, four hosted controls are required release gates: a protected
`main` ruleset requiring the iOS CI and CodeQL checks while blocking deletion,
force-push, and unreviewed direct updates; a protected `release` environment
restricted to `main` and requiring approval by a reviewer other than the
workflow initiator; a `refs/tags/v*` ruleset that restricts creation, update,
deletion, and non-fast-forward changes; and GitHub immutable releases. None is considered proven active until its
repository setting is read back from GitHub. The initial reviewed source import
bootstraps main; protections apply before subsequent ordinary updates. Publishing
source does not authorize a binary release or enable public child cloud access.

Private Vulnerability Reporting, GitHub secret scanning, and push protection are
also required hosted repository controls. They must be enabled and read back when the public repository is created; a
configuration request alone is not evidence of activation.

These controls complement rather than replace a signed-device review, backend
penetration test, privacy review, and age-appropriate usability/safety testing.

Version-tag creation currently has no bypass actor. GitHub rejected the built-in
Actions actor for a personal-repository ruleset, so binary publication stays
blocked until a dedicated, narrowly scoped release GitHub App is installed and
approved as the bypass actor. Do not remove tag protections to make a release
pass. The protected release environment also requires an independent reviewer.
