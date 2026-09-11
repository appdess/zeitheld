# Contributing to ZeitHeld

Thank you for helping. ZeitHeld began as a fun project for a child learning to
read an analog clock, and welcoming, practical contributions are encouraged.

## Good contributions

- Clock-learning correctness and pedagogy
- Accessibility and age-five usability
- German or English copy improvements
- Deterministic tests and failure handling
- Privacy, security, and cost-control improvements
- Original fictional themes with clear asset provenance

Please open an issue before a large architectural change. Small fixes can go
straight to a pull request.

## Local setup

1. Install Xcode 26.2+.
2. Run `./Scripts/install-xcodegen.sh` to install the checksum-verified XcodeGen
   2.44.1 binary under `.tools/xcodegen/bin`.
3. Run `.tools/xcodegen/bin/xcodegen generate`.
4. Open `WatchLearn.xcodeproj` or build from the command line.
5. Keep paid live tests disabled unless you are intentionally using your own
   restricted OpenAI project and accept the cost.

Before opening a pull request, run:

```bash
./Scripts/security-check.sh
./Scripts/test-release-guards.sh
.tools/xcodegen/bin/xcodegen generate
git diff --exit-code -- WatchLearn.xcodeproj
test -z "$(git status --porcelain --untracked-files=all -- WatchLearn.xcodeproj)"
xcodebuild test \
  -project WatchLearn.xcodeproj \
  -scheme WatchLearn \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2' \
  -parallel-testing-enabled NO
```

If that exact Simulator is unavailable, select one listed by
`xcodebuild -project WatchLearn.xcodeproj -scheme WatchLearn -showdestinations`.

The release-guard command is a separate shell regression suite; its result is
not part of the XCTest count.

## Pull requests

- Keep changes focused and explain the user-visible result.
- Add or update tests for behavior changes.
- Preserve offline tap learning when cloud features are unavailable.
- Keep German and English behavior aligned.
- Never weaken deterministic clock grading in favor of model judgment.
- Do not add analytics, ads, tracking, or a new network destination without an
  explicit design and privacy review.
- Update `PRIVACY.md`, `SECURITY.md`, or `ASSET_PROVENANCE.md` when relevant.
- Do not commit generated test results, build output, signing files, or secrets.

## Sensitive data and paid APIs

Never put real API keys, ephemeral tokens, child data, recordings, transcripts,
generated child content, or unredacted provider errors in source, tests, issues,
pull requests, screenshots, logs, or `.xcresult` bundles. Use obvious fake
credentials such as `sk-fixture-never-real` in tests.

Normal tests and CI must not call paid OpenAI endpoints. Live tests must remain
explicitly opt-in and must sanitize retained evidence.

Report vulnerabilities through GitHub's
[private vulnerability form](https://github.com/appdess/zeitheld/security/advisories/new),
not a public issue. See [SECURITY.md](SECURITY.md).

## Artwork

Do not submit franchise characters, logos, celebrity likenesses, copied styles,
or assets with unclear redistribution rights. Include source, model/tool, date,
prompt summary, edits, and license information in `ASSET_PROVENANCE.md`.

By contributing, you agree that your contribution is licensed under the
project's [MIT License](LICENSE) and that you have the right to submit it.

## Maintainer releases

Maintainers start `Simulator Release` manually from the current `main` branch
and enter the exact app version, for example `v1.0.0`. The workflow rejects any
other ref or commit, runs the full suite, and only then creates and reasserts a
lightweight tag immediately before publication. Before any release, repository
administrators must protect `main` with required iOS CI and CodeQL checks,
reviewed pull requests, and deletion/force-push/direct-update restrictions. A
`refs/tags/v*` ruleset must allow the GitHub Actions release job while
restricting creation, update, deletion, and non-fast-forward updates; blocking
force pushes alone does not block a fast-forward tag move. The workflow's
`release` environment must be restricted to `main`, require approval by a
reviewer other than the workflow initiator, and disallow bypass. GitHub
immutable releases are also required. No hosted control is considered proven
active until all four settings are read back from GitHub for the target
repository.
