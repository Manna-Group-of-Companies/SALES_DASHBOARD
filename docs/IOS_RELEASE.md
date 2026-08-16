# Releasing the iOS app without a Mac

The UAE reps are on iPhones. Until 16 August 2026 the only way to give them a
new build was Xcode on the one Mac in the business, and on the day the UAE
customer-sharing change was ready that Mac was not available — so a finished
change could not reach the people who needed it.

`.github/workflows/ios-testflight.yml` removes the machine from the critical
path. It builds on a **hosted macOS runner** and uploads to TestFlight.

Signing goes through the **App Store Connect API**, not through certificates
exported from somebody's keychain. That is the part that makes it work with no
Mac at all: `fetch-signing-files --create` will create the distribution
certificate and the provisioning profile if they do not exist yet, so there is
nothing to export from a machine you cannot open.

---

## Before the first run — the bundle identifier

**This is the one thing that will stop you, and it needs settling first.**

The repository still carries Flutter's placeholder:

```
PRODUCT_BUNDLE_IDENTIFIER = com.example.mannaFieldSales
```

Apple will not register anything under `com.example.` — it is a reserved
example domain. Android, by contrast, has been on the real identifier
(`com.mannagroup.fieldsales`) since the beginning.

So one of two things is true, and it is worth finding out which before spending
runner minutes:

- **The Mac has an uncommitted change.** Whoever set up TestFlight changed the
  bundle identifier in Xcode and never committed `ios/Runner.xcodeproj`. The
  same thing happened with `android/key.properties` and the release keystore,
  which existed only on one machine. If so, get that change committed — the
  workflow builds from the repository, not from anyone's laptop.
- **iOS was never set up for distribution** and the reps are running a build
  side-loaded from the Mac. Then the identifier has to be chosen, registered as
  an App ID in the Apple Developer portal, and an app record created in App
  Store Connect, before any of this works.

Either way, `BUNDLE_ID` at the top of the workflow must match what App Store
Connect knows about. It is currently set to `com.mannagroup.fieldsales` to
match Android.

## What you need

- An **Apple Developer Program** membership (the paid one). TestFlight is not
  available without it.
- The app registered in **App Store Connect** under the bundle identifier above.

## The four secrets

**Settings → Secrets and variables → Actions → New repository secret.**

GitHub never exposes these to pull requests from forks, which matters because
this repository is public.

| Secret | Where it comes from |
|---|---|
| `APP_STORE_CONNECT_ISSUER_ID` | App Store Connect → Users and Access → Integrations → App Store Connect API. The **Issuer ID** shown above the key table. |
| `APP_STORE_CONNECT_KEY_IDENTIFIER` | The **Key ID** of the API key, on the same page. |
| `APP_STORE_CONNECT_PRIVATE_KEY` | The contents of the `AuthKey_XXXXXXXX.p8` file downloaded when the key was created — the whole thing, `-----BEGIN PRIVATE KEY-----` line included. **Apple lets you download it once.** |
| `CERTIFICATE_PRIVATE_KEY` | An RSA private key the tooling uses to create the signing certificate. Generate one anywhere: `ssh-keygen -t rsa -b 2048 -m PEM -f cert_key -q -N ""` then paste the contents of `cert_key`. It is not Apple's — it is yours, and it must be kept, because a future certificate has to be created with the same one. |

Give the API key the **App Manager** role. Developer is not enough to upload a
build.

## Running it

**Actions → iOS → TestFlight → Run workflow.** Fill in what testers should be
told changed; it appears in TestFlight next to the build.

It is deliberately manual. A build costs about fifteen minutes of hosted-Mac
time and every upload is visible to every tester, so it happens when somebody
means it — not on every push.

## Build numbers

TestFlight refuses a build number it has already seen, and `pubspec.yaml` has
said `1.1.0+2` since the app was first released — the version has never been
bumped.

The workflow uses `github.run_number + 100` as the build number. It is
monotonic, never reused, and starts well clear of anything uploaded by hand.
The marketing version still comes from `pubspec.yaml`.

If somebody also uploads from the Mac, numbers could collide. Pick one route
and stay on it.

## What this does not cover

- **App Store review.** This puts builds in TestFlight for your own testers.
  Shipping to the public store is a separate submission.
- **Android.** That already builds on Windows —
  `flutter build apk --release` with `android/key.properties` and
  `android/app/manna-release.jks` in place. Both are gitignored and live only
  on the machine that built the last release. There are **two different
  keystores** in circulation; the one that matches what is installed on the
  reps' phones has certificate SHA-256 `f56c97c3…`. The other cannot update
  them and will fail with `INSTALL_FAILED_UPDATE_INCOMPATIBLE`.
