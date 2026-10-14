# Troubleshooting

Check the items in order. Most "nothing happens" reports come from the first
three.

## Nothing happens / no device discovered
1. **Not provisioned.** The SDK is inert until `provision` has succeeded once.
   Check `isProvisioned()`. The native logs show a warning on every ignored call.
2. **`serviceId` mismatch.** Both devices must use the same value. On iOS,
   `NSBonjourServices` must contain `_<serviceId>._tcp` and `_<serviceId>._udp`
   exactly.
3. **iOS with Android.** These never discover each other. Test iOS with iOS, or
   Android with Android.
4. **`startSharing()` not called**, or the app is in the background. Discovery
   only runs in the foreground.
5. **Android permissions denied.** Check `requestPermissions()` /
   `getRequiredPermissions()`. If the user chose "Don't ask again", send them to
   the app settings. On some OEM builds, location must be turned on system-wide.
6. **iOS Local Network denied.** Settings → the app → Local Network.
7. **Radios off.** Bluetooth must be on (both devices) and Wi-Fi should be on.
8. **Simulator or emulator.** Use real devices.
9. Wait a few seconds, or call `startSharing()` again: it is safe and refreshes
   discovery.

## The receiver never gets the file
- The invitation was never accepted. Is the transfer-event listener attached
  **before** `startSharing()`? Events are not buffered.
- iOS: the first send to a new peer waits up to about 25 s while the connection
  is set up. Move the devices closer and retry.
- Look at the `bulkFinished` outcomes for `FAILED` and read the `reason`.

## `sendFiles` returns null
No readable, non-empty file, or no recipient. Check the paths and resolve
`endpointIds` fresh from the latest neighbour snapshot.

## Transfers are extremely slow
- Wi-Fi is off on one side, so the transfer fell back to Bluetooth.
- Android 13+: `NEARBY_WIFI_DEVICES` was not granted, so the transfer cannot
  switch to Wi-Fi.
- Sends are fired in a tight loop. Serialize them: wait for `bulkFinished`
  before the next send.
- Android: the AAR was shrunk or re-processed. Integrate it as is.

## Build errors
| Error | Fix |
|---|---|
| Android: *"Dependency 'fr.hopcast:sdk-hopcast-android:…' requires core library desugaring to be enabled"* | Mandatory whatever the minSdk: set `isCoreLibraryDesugaringEnabled = true` and add `coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:…")` (see the platform guide). Flutter: in `android/app/build.gradle(.kts)`. |
| Android: *"N files found with path 'META-INF/INDEX.LIST'"* (or `io.netty.versions.properties`, `DEPENDENCIES`, `LICENSE`, `NOTICE`…) | Duplicates from the MQTT client's netty jars. Add the packaging `excludes` / `pickFirsts` block from the platform guide. |
| Android release / R8: *"Missing class org.conscrypt…"* (or `org.bouncycastle.jsse…`, `org.openjsse…`) | Optional OkHttp TLS providers. Add `-dontwarn org.bouncycastle.jsse.**`, `-dontwarn org.conscrypt.**`, `-dontwarn org.openjsse.**` to `proguard-rules.pro`. Do not add keep rules or shrink the AAR. |
| Android native: cannot resolve `fr.hopcast:sdk-hopcast-android` | Declare `maven("https://raw.githubusercontent.com/Hopcast/hopcast-sdk-android/main/maven")` where the project resolves dependencies: `dependencyResolutionManagement` in `settings.gradle(.kts)`, or `allprojects` in legacy projects. Declaring it only in `app/build.gradle` fails under `FAIL_ON_PROJECT_REPOS`. |
| Flutter Android: cannot resolve `fr.hopcast:sdk-hopcast-android` | The plugin embeds the AAR and adds its repo to every project. `settings.gradle(.kts)` must not force `RepositoriesMode.FAIL_ON_PROJECT_REPOS`. Do not add the Maven URL yourself. |
| Android online / hybrid: unresolved `FirebaseMessagingService` / `RemoteMessage`, `ClassNotFoundException` on `HopcastFirebaseMessagingService`, or no push wake-ups | The SDK declares `firebase-messaging` as `compileOnly`. Add `com.google.firebase:firebase-messaging` (Flutter: `firebase_messaging`) plus the `google-services` setup. Offline-only apps do not need it. |
| iOS: *"requires a higher minimum iOS deployment version"*, or Xcode refuses a deployment target below 15.0 | Set the deployment target to 15.0: `platform :ios, '15.0'` in the Podfile (Flutter) and `IPHONEOS_DEPLOYMENT_TARGET = 15.0` on the Runner / app target, then `pod install`. |

## `provision` fails
- Flutter: `HopcastIdentityException`. `error == transport`: offline, retry
  later. `error == server` with `statusCode` 401/403: the key was rejected.
  `error == notBuilt`: `provision` was called before `build`.
- Android: `HopcastIdentityException.Server(statusCode)`, `.InvalidResponse`, an
  `IOException` (offline), or `IllegalStateException` (called before `build()`;
  use `provision(context, …)` to enroll earlier).
- iOS: `HopcastIdentityError.server(statusCode:)`, `.invalidResponse`, or a
  `URLSession` error.
- Keep the app usable and retry on the next launch or when connectivity
  returns.
- Key rejected repeatedly: check the `sdkKey` with Hopcast (see
  `distribution.md`).

## The user changed but the device is still enrolled for the old one
`provision` is idempotent and ignores its arguments while an identity exists.
Call `clearIdentity()` first, then `provision(...)` with the new user.

## Online transfers fail on the first launch only (Flutter, iOS)
In online / hybrid mode, peers are addressed by the provisioned device id, and
iOS fixes the advertised name at `build()`. If the SDK was built before the
first `provision`, it advertises a per-install id instead. Call `release()` then
`build()` once right after the first successful `provision` (the reference
service does it).
