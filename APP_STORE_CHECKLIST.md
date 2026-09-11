# Distribution checklist

Source publication is separate from hosted child access and an App Store release.
No public TestFlight invitation is asserted by this repository.

## Parent privacy and child use

- [x] Privacy review before Apple sign-in; separate optional voice/Hero permissions.
- [x] Server-dated acceptance record, current-version gate and withdrawal controls.
- [x] Offline learning without an account or optional cloud permission.
- [ ] Final legal operator name, contact, legal bases, retention and international-transfer disclosures.
- [ ] Verified, age-appropriate parental authorization where required; Apple sign-in and a checkbox alone are insufficient proof.
- [ ] OpenAI project retention/ZDR and under-18 requirements verified for the intended ages/data.
- [ ] Child-safety and learning experience evaluated; moderation is not a guarantee.
- [ ] App Store privacy labels, Kids Category decision, external-link/parental-gate requirements and review notes completed.

## App and backend

- [ ] Final signed-device rehearsal in German and English with the released build.
- [ ] Live microphone/speaker, interruptions, retries, cancellation and usage settlement confirmed.
- [ ] Cloud IAM, secret rotation, Firestore TTL, queues, spending alerts and public-access setting read back.
- [ ] Current security findings fixed and tested; current dependency and source hygiene checks recorded.
- [ ] Every account can withdraw permissions/delete its account; local journey/image deletion separately clear.
- [ ] Support/issue links resolve and public reports exclude private child data.

## Store and payments

- [ ] Apple agreements, membership/entity/trader details and export compliance answered by the responsible publisher.
- [ ] External-testing-eligible build uploaded and reviewed; internal-only uploads cannot provide the requested public invitation.
- [ ] Public TestFlight link verified after external review, or App Store submission/review completed.
- [ ] StoreKit products, signed server transaction verification, refunds/restores and subscription terms implemented if charging users.

The current code offers a finite trial and a configured adult testing exception;
it does not implement paid subscriptions or purchases. A personal API key is a
private development option, not a public payment system.
