# Flutter — `hopcast_flutter` setup

**Flutter supports the OFFLINE mode only.** Online and hybrid modes exist only in
the native iOS / Android SDKs. If the developer needs them from Flutter, stop
and tell them to contact Hopcast.

Support matrix:

| | Android | iOS |
|---|---|---|
| Min version | API 21 (Android 5.0) | iOS 14.0 |
| Native core | AAR `fr.hopcast:sdk-hopcast-android` (bundled) | `HopcastSDKKit.xcframework` (bundled) |
| Registration | automatic (plugin loader) | automatic (plugin loader) |

Dart SDK `>=2.17.0`, Flutter `>=3.0.0`.

---

## Step 1 — Add the dependency

Follow the **Flutter** section of `distribution.md`. **Do not invent a source or
a version.**

```bash
flutter pub add hopcast_flutter
```

The plugin pulls the native SDKs itself. No wiring is needed in `MainActivity` /
`AppDelegate`: the plugin registers itself.

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
- **`settings.gradle`** must not force `RepositoriesMode.FAIL_ON_PROJECT_REPOS`,
  because the plugin injects its own bundled Maven repo. Flutter's default
  template does not force it.
- **Never strip, shrink or repackage the AAR.** It is already hardened, and
  re-processing it breaks the SDK or slows down transfers badly.

## Step 4 — iOS host configuration

`ios/Podfile`:

```ruby
platform :ios, '14.0'
```

Also set the Runner target's iOS Deployment Target to 14.0 or higher. Then run
`cd ios && pod install`.

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

Follow `modes/offline.md` (Flutter section). A complete reference service lives
in `examples/flutter/hopcast_service.dart`: copy it and adapt it.

## Flutter API at a glance

Everything goes through the singleton `HopcastFlutter.instance`
(`import 'package:hopcast_flutter/hopcast_flutter.dart';`).

| Method | Notes |
|---|---|
| `Future<bool> requestPermissions()` | Android runtime permissions. Always returns `true` on iOS: the system shows the Local Network prompt on the first discovery. |
| `Future<List<String>> getRequiredPermissions()` | Exact permission list for this API level. Empty on iOS. |
| `Future<void> build({required String deviceId, String serviceId = 'hopcast'})` | Idempotent: one native instance per process until `release()`. Always pass `serviceId`. |
| `Future<void> provision({required String sdkKey, required String userId})` | One-time online enrollment, called after `build`. Throws `PlatformException` with code `PROVISION_FAILED`, `NOT_BUILT` or `BAD_ARGS`. |
| `Future<bool> isProvisioned()` | `false` means the SDK is **inert** and every D2D call is a silent no-op. |
| `Future<void> clearIdentity()` | Removes the stored identity. Call it, then `provision(...)` again, to switch user or rotate the key. |
| `Future<void> startSharing()` / `stopSharing()` | Advertising and discovery. Calling `startSharing()` again is safe and refreshes discovery. |
| `Future<bool> isWifiEnabled()` | Always returns `true` on iOS. |
| `Future<String?> sendFiles({required List<String> endpointIds, required List<String> filePaths, String? metadata})` | Returns a bulk id, or `null` if there is no readable file or no recipient. |
| `Future<void> acceptTransfer(String transferId)` / `rejectTransfer(String transferId)` | Answer an `invitation` event. |
| `Future<void> release()` | Frees the native resources. Call `build` again to reuse the SDK. |

| Stream | Emits |
|---|---|
| `Stream<List<HopcastNeighbor>> neighbors` | A **full snapshot** on every change. An empty list means nobody is in range. Late subscribers get the last snapshot. |
| `Stream<HopcastTransferEvent> transferEvents` | Typed transfer lifecycle events. **Not buffered**: subscribe before `startSharing()`. |
| `Stream<Map> transfers` | The raw maps behind `transferEvents`. |

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

`reason` and `status` hold opaque native enum names, such as `PEERDISCONNECTED`
or `INVITATIONREJECTED`. Treat them as strings and never match them exhaustively.
