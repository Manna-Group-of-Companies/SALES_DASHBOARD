# Shipping the Android app, and how it updates itself

Until 21 August 2026 a new build reached the reps as an APK on WhatsApp.
Somebody had to remember to build it, remember to send it, and every rep had to
remember to install it — and nothing anywhere recorded who was still on what.
The version gate in `app/lib/core/app_version.dart` could *refuse* an old
build, but it could not fix one: it told the rep to "ask the office for the new
app file", which was precisely the step that kept failing.

Now:

1. You push to `main`, touching anything under `app/`.
2. `.github/workflows/android-apk.yml` builds a **release-signed** APK and
   publishes it to a GitHub Release, with a small `version.json` beside it.
3. The rep opens the app. It reads `version.json`, sees a newer build number,
   and offers **Update now**.
4. They tap it. The APK downloads with a progress bar and Android's installer
   takes over.

Nothing is sent on WhatsApp, and nobody has to remember anything.

---

## Before the first run — the four secrets

**This is the one thing that will stop you, and it has to be done by hand.**

CI cannot sign the APK without the release key, and an APK signed with any
other key **will not install over what the reps already have**. Android would
make every rep uninstall first, which wipes their login and any unsent order
drafts. The workflow therefore fails loudly when the key is missing rather than
publishing something that cannot install.

The key lives in two gitignored files on the one machine that has ever built a
release:

```
app/android/app/manna-release.jks
app/android/key.properties
```

Add these under **Settings → Secrets and variables → Actions → New repository
secret**, in `Mannagoc/SALES_DASHBOARD`:

| Secret | What to put in it |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | the keystore, base64-encoded — see below |
| `ANDROID_KEYSTORE_PASSWORD` | `storePassword` from `key.properties` |
| `ANDROID_KEY_ALIAS` | `keyAlias` from `key.properties` |
| `ANDROID_KEY_PASSWORD` | `keyPassword` from `key.properties` |

To produce the first one, from the repository root in Git Bash:

```bash
base64 -w0 app/android/app/manna-release.jks > keystore.b64
```

Paste the contents of `keystore.b64` as the secret value, then **delete
`keystore.b64`** — it is the signing key in plain text.

> **Do not generate a new keystore.** A different key cannot install over the
> app already on the reps' phones. If this one is ever lost, every rep has to
> uninstall and reinstall, and there is no way around that.

GitHub secrets are encrypted and are never exposed to pull requests from forks,
which matters because this repository is public.

---

## What is public, and what is not

The repository is public, so **the APK on the release is downloadable by
anyone**. That is deliberate — it is what lets the phones fetch it with no
token baked into the app, which would be a far worse secret to ship.

The APK holds no credentials. Reps sign in to ERPNext themselves, and the app
carries only the site URL, which is public anyway.

---

## How the app decides there is an update

`app/lib/core/app_update.dart` holds the rule, with no network in it so it can
be tested; `app/lib/services/update_service.dart` does the fetching.

**The build number decides, not the version name.** `pubspec.yaml` has said
`1.1.0+2` since launch and nobody has ever bumped it, so it cannot be the
signal. CI passes `--build-number` from `github.run_number + 100`, which is
monotonic and never reused. The offset clears the handful of builds pushed by
hand from the machine that held the keystore.

You may still bump the `version:` line in `pubspec.yaml` when a release is
worth a human name. Nothing breaks if you never do.

**It fails silent.** No answer, malformed JSON, a missing URL, a version that
will not parse — all mean "no update", never a prompt. A rep in a shop is not
helped by a nag they cannot act on. It also never offers a **downgrade**.

`version.json` is read from
`https://github.com/Mannagoc/SALES_DASHBOARD/releases/latest/download/version.json`
— a plain file download, deliberately **not** the GitHub API. The API allows 60
unauthenticated requests an hour per IP, and a dozen reps in one office share
one.

---

## What the rep sees

- **Home screen**, once per launch: an "Update available" sheet with the
  version, the commit subject as release notes, **Update now** and **Later**.
  Dismissible — a rep in front of a customer should not be made to install
  anything mid-order.
- **Blocked by the version gate**: the same sheet with no "Later", offered
  straight from the update-required screen.

**Android asks once, per device, for permission to install app files.** That
prompt is unavoidable for anything not coming from the Play Store. It appears
the first time a rep taps Update; after that, updates are two taps.

---

## Checking it worked

After the first push:

1. **Actions** tab → the run should be green. If it failed at *Restore the
   signing key*, the secrets are missing or misnamed.
2. **Releases** → a release tagged `android-v1.1.0+<n>` with two assets,
   `manna-field-sales.apk` and `version.json`.
3. `https://github.com/Mannagoc/SALES_DASHBOARD/releases/latest/download/version.json`
   should return JSON in a browser.
4. On a phone carrying an **older** build, open the app — the sheet should
   appear. A phone already on the newest build correctly shows nothing.

The *Check it is release-signed* step fails the run if the APK came out
debug-signed, so a build that could not install over the field's copies is
never published.

---

## If you need to stop an update going out

Delete the release, or mark an older one as "latest" in the GitHub UI.
`releases/latest/download/` follows whichever release is flagged latest, so
demoting a bad build is enough — the app will read the older `version.json` and
stop offering it. There is no need to touch the phones.
