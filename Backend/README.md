# Managed ZeitHeld backend

Node 22 or newer. Firebase Admin uses Application Default Credentials. Deploy
into your own Google Cloud/Firebase project; the repository has no server key.

## Required configuration

| Runtime value | Purpose |
| --- | --- |
| `GOOGLE_CLOUD_PROJECT` | Firebase/Firestore and Cloud Tasks project |
| `SERVICE_URL` | Exact HTTPS origin of this Cloud Run service and task OIDC audience |
| `OPENAI_API_KEY` | Secret Manager-injected OpenAI service credential |
| `IDENTITY_HASH_SECRET` | Secret Manager-injected random secret, at least 32 characters |
| `PUBLIC_ACCESS_ENABLED` | Keep `false` until public child-service requirements are verified |
| `UNLIMITED_EMAIL_SHA256` | Optional SHA-256 of one normalized, verified adult test email; omit for no exception |
| `MAX_SESSION_SECONDS` | Default 600 seconds per session reservation |
| `GLOBAL_DAILY_SECONDS` | Default 7200 reserved seconds per UTC day; conservative reservations are not refunded |

Use a dedicated runtime service account named `zeitheld-runtime` in your project,
with only required Firebase Auth administration, Firestore, Secret Manager and
Cloud Tasks permissions. Configure the `live-deadlines` queue in `europe-west3`;
it must retry failed close requests. The runtime creates tasks carrying its own
OIDC identity. The close endpoint independently checks audience and that exact
verified service-account identity. Set `SERVICE_URL` to the deployed origin.

Build from this directory with the Dockerfile and deploy to Cloud Run. Preserve
existing secret bindings when updating a service; do not put secret values in
command arguments, build arguments, images or logs. The container runs as `node`.
Recommended initial bounds: minimum zero instances, maximum three, 512 MiB,
1 CPU, request timeout 300 seconds and bounded request concurrency. These are
operator configuration, not guarantees established by the source.

Enable Sign in with Apple in Firebase Auth and for the iOS App ID. Configure
Apple's authorization-code revocation requirements for account deletion. The
client's Firebase project and backend ADC project must match. Deploy the deny-all
client rules from the repository. Set Firestore TTL on `deleteAfter` for both
`liveSessions` and `parentAccess`; TTL deletion is asynchronous.

## Permission and usage model

`POST /v1/consent` accepts the current version, explicit adult/notice/terms
confirmation and separate voice/hero permissions. The server sets receipt times
and associates the record with the verified Firebase UID. This private beta also
requires the adult to affirm fictional test content for online features.

`DELETE /v1/consent` disables new admissions before closing an active voice
session. It reports `cleanupPending` when earlier work is still finishing.
Account deletion first persists a deleting state. Previously authenticated
requests cannot reserve or activate new work; an admitted Hero operation must
finish before deletion reports success. Deleted account permission records have
a 30-day expiry. The last accepted document remains in the current receipt after
withdrawal. This implementation is not verification of a child's legal guardian.

Stable Apple identities are HMAC-hashed for a one-time 300-second (five-minute) family trial,
shared across devices. One session per family, bounded answer delegation and
scheduled closure limit usage. Normal Hero allowances are three image attempts
and ten audio attempts, with a 15-second cooldown. Invalid audio attempts count
before decoding or native parsing. Two parser slots per instance bound native
work; temporary uploads are removed after processing.

Direct WebRTC avoids relaying continuous audio. Session deadlines depend on
Cloud Tasks and provider availability; delayed shutdown can still incur cost.
A finite time allowance is not an absolute monetary billing cap. Configure
provider budgets/alerts and monitor operational failures without logging content.

## Validation

```bash
npm ci
npm test
npm audit --omit=dev
```

For real Firestore transaction validation, explicitly set
`ZEITHELD_FIREBASE_PROJECT` to your project and
`ZEITHELD_RUN_LEDGER_INTEGRATION` to `1`, then run
`node --use-system-ca src/ledger.integration.mjs`. It uses isolated synthetic
records, never the production quota ledger, and cleans them up. It requires an
authenticated gcloud CLI and does not call OpenAI.

Public child access remains a deployment decision requiring provider retention,
parental authorization, privacy disclosures and safety review. `store: false`
is not proof of Zero Data Retention. Firebase App Check enforcement is not yet
implemented and must not be described as an active control.
