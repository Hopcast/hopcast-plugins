# Flutter — `hopcast_flutter` setup

`hopcast_flutter` 0.4.0 supports the **offline, online and hybrid** modes on
both Android and iOS, through one Dart API.

Support matrix:

| | Android | iOS |
|---|---|---|
| Min version | API 21 (Android 5.0) | iOS 14.0 for the plugin; **use 15.0** in the app (Xcode 27 rejects deployment targets below 15) |
| Native core | AAR `fr.hopcast:sdk-hopcast-android:0.5.1`, embedded in the plugin | `HopcastSDKKit.xcframework`, embedded in the plugin |
| Registration | automatic (plugin loader) | automatic (plugin loader) |

Package constraints: Dart SDK `>=2.17.0 <4.0.0`, Flutter `>=3.0.0`.

---

## Step 1 — Add the dependency

Follow the **Flutter** section of `distribution.md`. **Do not invent a source or
a version.** The package is a git dependency, not a pub.dev package:

```yaml
# pubspec.yaml
dependencies:
  hopcast_flutter:
    git:
      url: https://github.com/Hopcast/hopcast-sdk-flutter
      ref: 0.4.0
```

Then `flutter pub get`. The plugin embeds both native SDKs: do **not** add the
Android Maven repository or dependency, nor the iOS Swift package. No wiring is
needed in `MainActivity` / `AppDelegate`: the plugin registers itself.

## Step 2 — Choose a `serviceId`

The `serviceId` is the discovery namespace: **only devices built with the same
`serviceId` see each other.** Use a short, lowercase ASCII string (letters and
digits only, no spaces) that is specific to the app, e.g. `acmeshare`. Put it in
one Dart constant: the iOS `Info.plist` (step 4) must repeat it exactly.

## Step 3 — Android host configuration

Edit `android/app/build.gradle.kts`. If the project uses `build.gradle` (Groovy),
translate the syntax and keep the same values.

```kotlin
android {
    defaultConfig {
        minSdk = maxOf(flutter.minSdkVersion, 21)
    }

    compileOptions {
        // REQUIRED: the SDK uses java.time / java.nio
        isCoreLibraryDesugaringEnabled = true
    }

    // REQUIRED: transitive jars ship duplicate META-INF entries
    packaging {
        resources {
            excludes += setOf(
                "META-INF/INDEX.LIST",
                "META-INF/io.netty.versions.properties",
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE", "META-INF/LICENSE.txt",
                "META-INF/NOTICE", "META-INF/NOTICE.txt",
            )
            pickFirsts += setOf("META-INF/native-image/**")
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
```

Groovy equivalent:

```groovy
android {
    defaultConfig { minSdkVersion Math.max(flutter.minSdkVersion, 21) }
    compileOptions { coreLibraryDesugaringEnabled true }
    packaging {
        resources {
            excludes += ['META-INF/INDEX.LIST', 'META-INF/io.netty.versions.properties',
                         'META-INF/DEPENDENCIES', 'META-INF/LICENSE', 'META-INF/LICENSE.txt',
                         'META-INF/NOTICE', 'META-INF/NOTICE.txt']
            pickFirsts += ['META-INF/native-image/**']
        }
    }
}
dependencies { coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4' }
```

- **Permissions**: the bundled AAR declares all the permissions it needs, and they
  are merged into the app automatically. **Do not add `<uses-permission>`
  entries.** They still have to be requested at runtime: call
  `requestPermissions()` from Dart.
- **`settings.gradle(.kts)`** must not force
  `RepositoriesMode.FAIL_ON_PROJECT_REPOS`: the plugin's Gradle script adds its
  embedded Maven repo to every project (`rootProject.allprojects { repositories
  { … } }`), which that mode rejects. Flutter's default template does not force
  it.
- **Release builds (R8)**: if `flutter build apk --release` fails with *"Missing
  class org.conscrypt…"*, add the three `-dontwarn` lines from
  `platforms/android.md` (step 2) to `android/app/proguard-rules.pro`.
- **Online / hybrid push**: the native SDK declares `firebase-messaging` as
  `compileOnly`. Apps that want push wake-ups add `firebase_messaging` (and the
  usual FlutterFire setup), which brings it. See `modes/online.md`.
- **Never strip, shrink or repackage the AAR.** It is already hardened, and
  re-processing it breaks the SDK or slows down transfers badly.

## Step 4 — iOS host configuration

`ios/Podfile`:

```ruby
platform :ios, '15.0'
```

Also set the Runner target's iOS Deployment Target to 15.0 (Xcode → Runner →
General, or `IPHONEOS_DEPLOYMENT_TARGET = 15.0`). The plugin itself needs 14.0,
but recent Xcode versions (Xcode 27) reject deployment targets below 15.0. Then
run `cd ios && pod install`.

`ios/Runner/Info.plist`: replace `acmeshare` with the `serviceId` from step 2.
The two Bonjour entries must use **exactly** the same value.

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Used to discover and share files with nearby devices.</string>
<key>NSBonjourServices</key>
<array>
    <string>_acmeshare._tcp</string>
    <string>_acmeshare._udp</string>
</array>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Used to discover nearby devices for file sharing.</string>
```

If `NSBonjourServices` does not match the `serviceId`, iOS **silently** blocks
discovery: no error and no permission prompt.

The XCFramework is vendored by the plugin's podspec, so there is nothing more to
declare.

## Step 5 — Inject the `sdkKey` without committing it

```bash
flutter run --dart-define=HOPCAST_SDK_KEY=pk_live_xxx
```

```dart
const String kHopcastSdkKey = String.fromEnvironment('HOPCAST_SDK_KEY');
// Fail loudly in debug if it is missing:
assert(kHopcastSdkKey.isNotEmpty, 'Pass --dart-define=HOPCAST_SDK_KEY=…');
```

## Step 6 — Wire the SDK

Follow the mode guide (`modes/offline.md`, `modes/online.md`,
`modes/hybrid.md`, Flutter sections). A complete reference service covering the
three modes lives in `examples/flutter/hopcast_service.dart`: copy it and adapt
it.

Order in Flutter: **`requestPermissions` → `build(mode:)` → `provision` (if
needed) → subscribe to streams → `startSharing()` / `enableOnlineMode()`**.

- `provision` requires `build` first (otherwise `HopcastIdentityException` with
  `error == notBuilt`).
- Online / hybrid on iOS: the name advertised to peers is fixed at `build()` and
  must be the provisioned device id. If the device was **not** provisioned when
  `build()` ran, call `release()` then `build()` again once, right after the
  first successful `provision`. The reference service does this. It is harmless
  on Android.

## Flutter API at a glance

Everything goes through the singleton `HopcastFlutter.instance`
(`import 'package:hopcast_flutter/hopcast_flutter.dart';`).

| Method | Notes |
|---|---|
| `Future<bool> requestPermissions()` | Android runtime permissions. Always returns `true` on iOS: the system shows the Local Network prompt on the first discovery. |
| `Future<List<String>> getRequiredPermissions()` | Exact permission list for this API level. Empty on iOS. |
| `Future<void> build({required String deviceId, String serviceId = 'hopcast', HopcastMode mode = HopcastMode.offlineOnly, HopcastOnlineConfig? onlineConfig})` | Idempotent: one native instance per process until `release()` (later calls ignore their arguments). Always pass `serviceId`. Online / hybrid: pass `onlineConfig: const HopcastOnlineConfig()`. |
| `Future<void> provision({required String sdkKey, required String userId})` | One-time online enrollment, called after `build`. Idempotent: succeeds without network, ignoring its arguments, while an identity is stored. Throws `HopcastIdentityException` (a `PlatformException`, code `PROVISION_FAILED` or `NOT_BUILT`), or `PlatformException` `BAD_ARGS`. |
| `Future<bool> isProvisioned()` | `false` means the SDK is **inert** and every D2D call is a silent no-op. |
| `Future<void> clearIdentity()` | Removes the stored identity. Call it, then `provision(...)` again, to switch user or rotate the key. |
| `Future<String> deviceUuid()` | Backend device id; `"unknown"` until provisioned. |
| `Future<HopcastMode> mode()` | The mode the SDK was built with. |
| `Future<void> startSharing()` / `stopSharing()` | The **offline** subsystem toggle (advertising, discovery, user-driven transfers). Calling `startSharing()` again is safe and refreshes discovery. No-op in `onlineOnly`. |
| `Future<void> enableOnlineMode()` / `disableOnlineMode()` | The **online** subsystem toggle. Idempotent. No-op in `offlineOnly` or while unprovisioned (replayed after a successful `provision`). |
| `Future<void> reportDownloadedFile({required HopcastInfraType infraType, required List<String> contentIds})` | Online inventory: this device now holds these contents. |
| `Future<void> reportRemovedFile(List<String> contentIds)` | Online inventory: contents deleted locally. |
| `Future<String?> declareNeed({required String contentId, required int ttlSeconds})` | Online: ask for a content. Returns a `needId`, or `null`. |
| `Future<void> cancelNeed(String needId)` | Online: drop a need. |
| `Future<void> handleFcmMessage(Map<String, dynamic> data)` / `handleFcmToken(String token)` | Forward FCM data messages and tokens (from `firebase_messaging`). |
| `Future<bool> isWifiEnabled()` | Always returns `true` on iOS. |
| `Future<String?> sendFiles({required List<String> endpointIds, required List<String> filePaths, String? metadata})` | Returns a bulk id, or `null` if there is no readable file or no recipient. |
| `Future<void> acceptTransfer(String transferId)` / `rejectTransfer(String transferId)` | Answer an `invitation` event. |
| `Future<void> release()` | Frees the native resources. Call `build` again to reuse the SDK. |

| Stream | Emits |
|---|---|
| `Stream<List<HopcastNeighbor>> neighbors` | A **full snapshot** on every change. An empty list means nobody is in range. Late subscribers get the last snapshot. |
| `Stream<HopcastTransferEvent> transferEvents` | Typed transfer lifecycle events. **Not buffered**: subscribe before `startSharing()`. |
| `Stream<Map> transfers` | The raw maps behind `transferEvents`. |
| `Stream<HopcastOnlineEvent> onlineEvents` | Online events: `type` (`HopcastOnlineEventType.filesToBeDownloaded` with `fileIds`, `cloudReady` with `deviceUuid`, `cloudDisconnected`, `cloudError` with `reason`, `unknown`). |
| `Stream<HopcastTransferHandoff> transferHandoffs` | One summary per **orchestrated** (online) transfer: `instructionId`, `status` (`HopcastHandoffStatus.success/failure`), `reason`, `bytesTotal`, `files` (`HopcastHandoffFile { fileId, bytes, direction }`), `isSuccess`. |

Online types: `HopcastMode { offlineOnly, onlineOnly, hybrid }`;
`HopcastOnlineConfig({String? brokerUrl, bool isSecondaryFcm = true, bool runAsService = false})`:
always use `const HopcastOnlineConfig()` and never set `brokerUrl`;
`HopcastInfraType { d2d, wifi, cellular, stored }`.

Errors: `HopcastIdentityException` (extends `PlatformException`) with
`error` (`HopcastIdentityError.server` + `statusCode`, `invalidResponse`,
`transport`, `notProvisioned`, `notBuilt`, `unknown`) and `statusCode`.

`HopcastNeighbor`: `endpointId` (volatile, **never persist it**), `displayName`.

`HopcastTransferEvent` fields: `type`, `isReceiver`, `transferId`, `peerName`,
`fileName`, `localPath`, `reason`, `bytesTransferred`, `totalBytes`,
`fileIndex`, `fileTotal`, `totalPeers`, `totalFiles`, `senderName`,
`fileCount`, `meta`, `outcomes`. Getters: `isInvitation`, `isFileCompleted`,
`isBulkFinished`, `isFailed`, `progressFraction`, `anyOutcomeSuccess`,
`wasRejected`.

| `HopcastTransferType` | Side | Extra fields |
|---|---|---|
| `invitation` | receiver | `senderName`, `fileCount`, `totalBytes`, `meta`. Answer it with accept or reject. |
| `bulkStarted` | sender | `totalPeers`, `totalFiles` |
| `transferProgress` | both | `bytesTransferred`, `totalBytes`, `peerName` |
| `fileProgress` | both | `fileName`, `bytesTransferred`, `totalBytes`, `peerName` |
| `fileCompleted` | both | `fileName`, `localPath` (receiver: absolute path in the SDK inbox), `fileIndex`, `fileTotal`, `peerName` |
| `fileFailed` | both | `fileName`, `reason`, `peerName` |
| `transferFailed` | both | `reason`, `peerName` |
| `bulkFinished` | sender | `outcomes`: a list of `HopcastTransferOutcome { peerName, status (SUCCESS/FAILED), reason?, isSuccess }` |
| `unknown` | — | Ignore it. Always keep a `default:` branch. |

Content layout (online / hybrid): the SDK's `cacheDirectory` is
`<getApplicationSupportDirectory()>/hopcast_inbox` (`path_provider`; it is
`filesDir/hopcast_inbox` on Android and `Application Support/hopcast_inbox` on
iOS). A content can be served only if its file exists at
`<that directory>/<contentId>`.

`reason` and `status` hold opaque native enum names, such as `PEERDISCONNECTED`
or `INVITATIONREJECTED`. Treat them as strings and never match them exhaustively.
