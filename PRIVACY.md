# ZeitHeld privacy notice — pre-release build

Updated: 11 September 2026. This describes build 12 and the managed backend implementation. Deployment verification is recorded separately.
Public cloud access remains disabled pending the release requirements below.

## Learning on the device

Clock practice works without an account or internet. Child profile names,
selected profile, learning level, stars, correct/incorrect totals, mastered
levels and the latest 500 answers per profile are saved on the device. Each
answer includes its date, exercise level, displayed time, selected/spoken time
and correctness. A per-profile flag remembers whether voice learning has started;
resetting that profile also resets its introduction. Names and individual saved
answer histories are not uploaded by the app.
Settings include a device-language preference or explicit German/English choice.

Settings can reset the selected child's journey after confirmation; other
profiles are preserved. Generated hero pictures can be deleted separately.
Local profile data is not synchronized by ZeitHeld between devices. Device
backup behavior is separate from app synchronization.

The app has no advertising, cross-app tracking, location, Contacts, or camera
feature. Firebase Analytics is not included.

## Parent account and trial

An adult can sign in with Apple through Firebase Authentication. Apple may
provide the shared or private-relay email address and an account identifier.
Firebase stores the authentication account and manages its sign-in credentials.
The app does not receive an Apple password.

The ZeitHeld backend verifies Firebase tokens and Apple sign-in before allowing
cloud operations. It keeps a keyed hash of the stable Apple account identifier,
trial seconds, active session reservation and request counters. This associates
the one-time ten-minute voice trial across devices and local child profiles.
An explicitly designated verified adult test account has unlimited test access,
subject to per-session and service-wide limits. There are no automatic payments.

Settings offers account deletion after fresh Apple authorization. This deletes
the Firebase account and revokes its Apple authorization. A pseudonymous trial
ledger remains to prevent repeatedly redeeming the trial by recreating an
account. This is distinct from deleting local profiles and pictures.

## Privacy confirmation and permissions

Before the Apple sign-in button is enabled, the adult reviews the notice and
beta terms, affirms adult responsibility and explicitly confirms them. Voice
and Hero Lab permissions are separate and initially unselected. The private
online beta also requires confirmation that the adult will use fictional test
content rather than transmit a child's data. Offline learning needs no account
or optional permission.

The device records the notice version, choices and local confirmation time.
After Apple sign-in, the backend records the same document with server-set times
and the Firebase account identifier. The app displays this receipt in Settings.
No signature image, extra name, birth date or child identity is requested.
This click confirmation does not independently verify legal guardianship.

Permission withdrawal immediately turns local cloud features off and asks the
backend to block new operations and close the voice session. The app distinguishes
server-confirmed withdrawal from a network failure or cleanup still in progress.
Requests already processed by a provider cannot be recalled by withdrawal.
Signing out clears local permissions; it does not revoke another device's access.

The current acceptance document is retained with the account, including after
withdrawal. Account deletion marks its record for expiry after 30 days; deletion
is asynchronous. The stable pseudonymous trial ledger is retained separately.
An updated notice version requires a new explicit confirmation.

## Optional live voice

Talk to your Time Hero is off until the relevant permission is confirmed by an adult. While it is active, microphone
audio travels over encrypted WebRTC directly between the device and OpenAI's
GPT-Live service. ZeitHeld's Google Cloud backend authorizes and creates the
session, limits its duration and closes it; it does not relay continuous audio.
A short provider connection at shutdown obtains final usage. Mirrored audio on
that connection is ignored and is not retained by our code.

OpenAI receives live audio, transient conversation text, the selected language,
clock exercise context and a pseudonymous safety identifier. Voice context also
includes whether an introduction is needed, the total practice-attempt count,
and correct/attempt counts for the latest five answers, to adapt its guidance.
These aggregates are processed by the voice provider only while voice is enabled.
The managed live
path does not upload a clock image or camera image. When the live model asks for
an answer to be checked, fresh transcript text is sent through the backend to a
bounded text model to extract the attempted time. The app checks correctness
locally. Transcript text is held in memory and is not written to our database
or application logs. The provider still processes this content under its own
applicable data controls.

Session accounting records contain opaque session IDs, timestamps, counters,
status and measured final usage. Firestore is configured to expire these session
records after 30 days; expiry deletion is asynchronous. Trial ledgers and daily
aggregate counters have separate retention as described above. Cloud platform
request/security logs can contain network and operational metadata.

## Optional Hero Lab

Appearance buttons work offline. Creating a picture sends selected fictional
traits and the optional short idea through the backend to OpenAI for moderation
and image generation. The generated picture is checked again before returning.
The backend does not persist the idea or generated image.

Recording a hero idea creates a short temporary audio file. The backend admits and counts the attempt before decoding or native parsing, then validates
its size, audio format and duration before transcription. Invalid media attempts
also count against the allowance. Its temporary copy is
deleted after processing, including failure. The app removes its temporary copy
after transcription or cancellation. This separate transcription feature is not
the live voice conversation transport.

Accepted images stay in the app's Application Support directory with complete
file protection and verified exclusion from backup. Deleting them also clears a
selected generated background. The initial managed trial additionally limits
image and voice-idea requests; test accounts and service-wide safeguards have
separate limits. No content is posted publicly by the app.

## Secrets and provider retention

The managed OpenAI key belongs to a dedicated service account and is stored in
Google Secret Manager. It is not embedded in the app. The app contains public
Firebase configuration and stores its own authentication credentials through the
Firebase SDK.

A development-only private-key option remains for adult testing. Such a key is
stored in the non-synchronizing iOS Keychain, accessible while unlocked, and can
be deleted in Settings. That route calls OpenAI directly. The public Release
settings screen does not offer private-key entry.

Live and answer-extraction requests use `store: false`. This does not establish
Zero Data Retention. The production OpenAI project's Zero Data Retention status
has not yet been verified. Until that is resolved, cloud tests are restricted to
adult/synthetic content and public cloud access is disabled. Offline learning
remains available. See OpenAI's [under-18 guidance](https://developers.openai.com/api/docs/guides/safety-checks/under-18-api-guidance)
and [API data controls](https://developers.openai.com/api/docs/guides/your-data).

## Before public distribution

The publisher must finish the provider retention setup, verified parental authorization
and child-safety evaluation, App Store privacy disclosures and Kids Category review,
launch-region decisions, and a monitored private privacy contact. An account
sign-in or supervision notice alone is not a complete parental-consent process.
Apple's [review guidelines](https://developer.apple.com/app-store/review/guidelines/)
include additional requirements for apps intended for children.

External Apple and OpenAI links leave the app and use those services' policies.
The current app includes this privacy notice locally. GitHub source, issue and security-report links lead to the project repository. Never put a child's name, recording,
transcript, private content or a credential in public feedback.
A private general privacy contact must be published before public launch.
