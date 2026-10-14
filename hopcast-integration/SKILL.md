---
name: hopcast-integration
description: Integrate the Hopcast device-to-device (D2D) file-sharing SDK into a Flutter, native iOS (Swift) or native Android (Kotlin) app, in offline (user-driven, AirDrop-like), online (cloud-orchestrated) or hybrid mode. Use when the user asks to add Hopcast, hopcast_flutter, HopcastKit or sdk-hopcast-android to an app, to wire nearby/peer-to-peer file sharing with Hopcast, or to debug a Hopcast integration (no devices discovered, transfers not arriving, provisioning errors).
---

# Hopcast SDK integration

You are integrating Hopcast into the developer's app. Hopcast moves files
**directly between nearby phones**. Discovery runs over Bluetooth and the data
over Wi-Fi. The core ships as hardened binaries, so only the public API described
in this skill exists. **Never invent APIs, URLs, versions or keys.** If something
is not covered here, say so and point the developer to Hopcast support
(`distribution.md`).

## Step 0 — Read the shared concepts

Read `concepts.md` first: modes, provisioning, `serviceId`, volatile
`endpointId`, platform limits. It is short and applies everywhere.

## Step 1 — Detect the platform

| Evidence in the project | Platform | Guide |
|---|---|---|
| `pubspec.yaml` with a `flutter:` section | **Flutter** | `platforms/flutter.md` |
| `*.xcodeproj` / `Package.swift`, Swift sources, no `pubspec.yaml` | **iOS native** | `platforms/ios.md` |
| `build.gradle(.kts)` with `com.android.application`, no `pubspec.yaml` | **Android native** | `platforms/android.md` |

If several platforms apply (e.g. a native app with both iOS and Android
targets), ask which ones to integrate.

## Step 2 — Pick the mode

| Mode | Use when | Flutter | iOS | Android |
|---|---|---|---|---|
| **offline** | Users choose what to send to whom (AirDrop-like). Works without internet after a one-time enrollment. | ✅ | ✅ | ✅ |
| **online** | The app distributes **its own content** (episodes, media, documents…) and wants Hopcast to deliver it automatically from nearby devices that already have it. | ❌ | ✅ | ⚠️ preview |
| **hybrid** | Both, with user-facing switches. | ❌ | ✅ | ⚠️ preview |

- If the developer did not say which mode, **ask**, and explain the difference in
  one sentence each.
- **Flutter is offline only.** If a Flutter app needs online or hybrid, stop and
  tell the developer to contact Hopcast. Do not try to reach the native SDKs
  through custom platform channels.
- For Android online or hybrid, warn the developer that it is a preview and must
  be validated with Hopcast before production.

Then read the mode guide: `modes/offline.md`, `modes/online.md` or
`modes/hybrid.md`. Online and hybrid also rely on the offline guide's
transfer-listener rules.

## Step 3 — Collect inputs (ask; never guess)

1. **Distribution source and version.** Get them from `distribution.md`. If a
   value is still `TODO(hopcast)`, ask the developer for it.
2. **`sdkKey`** (`pk_live_…`), issued by Hopcast. **Never write it into source
   files.** Inject it at build time; each platform guide shows how.
3. **`userId`**: the app's own logged-in user id. Find where login completes in
   the codebase: `provision` belongs right after it.
4. **`serviceId`**: short, lowercase, `a-z0-9`, unique to the app, e.g.
   `acmeshare`. Propose one from the app name and confirm it with the developer.
5. **Device display name**: generate it once and persist it, e.g. the user's
   first name plus a short random suffix.
6. Offline mode only: the **acceptance policy** for incoming transfers. Choose
   between accept all, ask the user every time, or allow/block lists.
7. Online mode only: the **content id scheme**, and where the app downloads its
   content.

## Step 4 — Implement

1. Apply the platform setup from the guide: dependency, Gradle / Podfile /
   Info.plist, permissions.
2. Copy the reference implementation into the app and adapt its `ADAPT` spots:

   | Platform | Reference file |
   |---|---|
   | Flutter | `examples/flutter/hopcast_service.dart` |
   | iOS | `examples/ios/HopcastManager.swift` |
   | Android | `examples/android/HopcastManager.kt` |

   These files compile against the real SDK. Keep their structure and their
   order of calls.
3. Hook it into the app:
   - start it after login and once permissions are granted;
   - expose neighbours, progress and received files to the UI;
   - tear it down on logout.
4. Match the existing code style, state management and DI of the host project.

## Step 5 — Verify

Go through this checklist and tell the developer the result:

- [ ] `provision` is called after login, guarded by `isProvisioned`, and its
      failure is handled without blocking the app.
- [ ] The `sdkKey` is injected at build time and not committed.
- [ ] iOS: the `serviceId` passed to the SDK matches `NSBonjourServices`
      (`_<id>._tcp`, `_<id>._udp`). The three Info.plist keys are present.
- [ ] Android: desugaring and packaging excludes are configured, and runtime
      permissions are requested before start. On API 33+ this includes
      `NEARBY_WIFI_DEVICES`.
- [ ] Listeners are attached **before** sharing starts (Flutter), or right after
      `build()` (native).
- [ ] `endpointId`s are resolved fresh before each send and never persisted.
- [ ] Every incoming invitation is answered, with accept or reject.
- [ ] Received files are moved out of the SDK cache.
- [ ] Online: inventory is (re)declared in `onCloudReady`. Content files live at
      `cacheDirectory/<contentId>`.
- [ ] Teardown calls `release()`.
- [ ] The project builds: `flutter analyze` / `flutter build`, `xcodebuild`, or
      `./gradlew assembleDebug`.

Then remind the developer:
- Testing needs **two physical devices on the same platform**. iOS and Android
  never see each other.
- Wi-Fi and Bluetooth must be on.

## When something does not work

Use `troubleshooting.md`, and the troubleshooting table in `modes/online.md` for
the online mode. The #1 cause is "not provisioned": the SDK silently ignores
every call until `provision` has succeeded once.

## Hard rules

- Do not call, override or mention backend, broker or API URLs. They belong to
  the SDK. Use `OnlineConfig()` with its default values.
- Do not strip, shrink, repackage or re-sign the shipped binaries.
- Do not add `<uses-permission>` entries on Android. The SDK merges its own.
- Do not use APIs that are not listed in the platform guides.
