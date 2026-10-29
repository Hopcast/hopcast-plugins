# Online mode — cloud-orchestrated delivery (Flutter, iOS, Android)

In online mode, the app does not drive transfers. It tells Hopcast which content
each device **has** and which content it **needs**. The Hopcast backend then
matches nearby devices and instructs the SDKs, and the file moves device to
device without any user interaction. Transfers are always auto-accepted.

## Prerequisites for the host app

- **Content ids.** Every piece of content has a stable string id chosen by the
  app, e.g. `episode-1044`. Hopcast never sees file contents, only ids.
- **File layout contract.** A device can only serve a content if the file exists
  at **`cacheDirectory/<contentId>`**: the file name is exactly the content id,
  with no extension. After the app downloads a content, it writes it there.
  Native: `cacheDirectory` is the directory passed to the Builder. Flutter: it is
  `<getApplicationSupportDirectory()>/hopcast_inbox` (`path_provider`).
- **Both devices** need online mode enabled, the app in the foreground (unless
  push wake-ups are wired), and to be within D2D range.

## Sequence

```
provision ─▶ build(.onlineOnly | .hybrid, OnlineConfig(), autoAcceptConnections = true)
          ─▶ register OnlineEventListener + TransferListener
          ─▶ enableOnlineMode()                  ← nothing auto-starts
          ─▶ onCloudReady(deviceUuid)            ← connected to the orchestrator
               ├─ reportDownloadedFile(.stored, ids already on disk)
               ├─ reportDownloadedFile(.wifi/.cellular, id) after each app download
               ├─ declareNeed(contentId, ttlSeconds) → needId
               └─ (receiving side) onFilesToBeDownloaded → TransferListener progress → fileCompleted
```

Order per platform (see the platform guides):
- iOS native: `provision` **before** `build`.
- Android native: `build`, then `provision` (or `provision(context, …)` before
  `build`).
- Flutter: `build(mode:, onlineConfig:)`, then `provision`. If `provision` had to
  enroll the device (first launch), call `release()` + `build()` once, so iOS
  advertises the provisioned device id.

## Rules (important)

1. **Call `enableOnlineMode()` explicitly**, even in `onlineOnly` mode.
2. **Publish inventory and needs only while connected.** Calls made before
   `onCloudReady`, or between `onCloudDisconnected` and the next `onCloudReady`,
   can be lost. Keep the inventory in the app, and **re-declare it in every
   `onCloudReady`**. The reference examples do this.
3. `InfraType` describes how the device obtained the content:
   - `.wifi` / `WIFI`, `.cellular` / `CELLULAR`: the app downloaded it itself.
   - `.stored` / `STORED`: the content was already on disk, e.g. at app start.
   - `.d2d`: do **not** report it. Content received through Hopcast is declared
     automatically.
4. Call `reportRemovedFile(contentIds:)` whenever the app deletes content from
   `cacheDirectory`.
5. **Needs.** `declareNeed(contentId, ttlSeconds)` returns a `needId`, or `nil`
   / `null` if the SDK is not provisioned or the mode has no online flow. Call
   `cancelNeed(needId)` when the need is obsolete. While a need is valid, the
   cloud retries on its own.
6. **Received content.** The file arrives through the normal `TransferListener`
   events. Read the path from `fileCompleted.localPath`. To make the content
   servable again from this device, copy or move it to
   `cacheDirectory/<contentId>`.
7. Orchestrated transfers are serialized per peer: one with a busy peer waits
   in the SDK's queue and reuses the open link when it is free.
8. **Do not `declareNeed` while one of your own `sendFiles` to the peer that
   would serve it is still running.** Wait for the end of that transfer
   (Flutter: `bulkFinished`, or the last sender-side `fileCompleted` for an
   Android send over a kept link, as `examples/flutter/hopcast_service.dart`
   tracks; Android: `TRANSFER_FINISHED` / `BulkSendFinished`; iOS: `.finished`). Android 0.5.2 serializes and reuses the
   connection, but the overlap failed with 0.5.1 (`CONNECTION_REJECTED`,
   `PAYLOAD_FAILURE`, `PEER_DISCONNECTED`). Android native can check
   `HopcastSDK.isTransferInProgress(endpointId)` / `activeTransfers` first;
   these do not exist in Flutter or iOS.
9. `onCloudError(reason)` reports orchestration failures, for example
   `destination_unreachable`. These are informational: the cloud retries.
10. Never override the broker or backend URLs. Use `OnlineConfig()` /
   `const HopcastOnlineConfig()` without `brokerUrl`.
11. Optional: observe the end of each orchestrated transfer with a handoff
    listener (iOS / Android `TransferHandoffListener` under a tag, Flutter
    `transferHandoffs`). The SDK already acknowledges instructions itself: this
    is for UI and analytics only.

## Push wake-ups (optional, recommended)

These let Hopcast wake the app when a delivery is scheduled while the app is in
the background. They use **Firebase Cloud Messaging**. Without FCM, online mode
still works while the app is in the foreground.

### iOS
The host owns Firebase and its `MessagingDelegate`. **Forward every data message
unconditionally**: the SDK ignores the ones that are not Hopcast's. Do not filter
on keys yourself.

```swift
import FirebaseMessaging
import HopcastKit

extension AppDelegate: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        if let token = fcmToken { HopcastSDK.handleFcmToken(token) }
    }
}

// Silent / data pushes (enable "Remote notifications" background mode):
func application(_ application: UIApplication,
                 didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                 fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
    var data: [String: String] = [:]
    for (k, v) in userInfo { if let k = k as? String { data[k] = "\(v)" } }
    HopcastSDK.handleFcmMessage(data)
    completionHandler(.newData)
}
```

`handleFcmMessage` is ignored while online mode is disabled.

### Android

Add Firebase. The SDK declares `firebase-messaging` as `compileOnly`: it does
not bundle it, and the app must add it itself.

```kotlin
// root build.gradle.kts
plugins { id("com.google.gms.google-services") version "4.4.0" apply false }
// app/build.gradle.kts
plugins { id("com.google.gms.google-services") }
dependencies { implementation("com.google.firebase:firebase-messaging:23.4.1") }
// + app/google-services.json
```

Then pick **one** of the two setups.

**A. The app has no FCM service of its own.** Let the SDK own FCM: keep
`OnlineConfig()` (`isSecondaryFcm = false`) and declare the SDK's service.

```xml
<service android:name="fr.hopcast.sdk.internal.online.firebase.HopcastFirebaseMessagingService"
    android:exported="false">
    <intent-filter><action android:name="com.google.firebase.MESSAGING_EVENT" /></intent-filter>
</service>
```

**B. The app already has a `FirebaseMessagingService`.** Use
`OnlineConfig(isSecondaryFcm = true)` and forward everything to the SDK:

```kotlin
class AppMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        HopcastSDK.handleFcmMessage(message.data)   // ignores non-Hopcast payloads
        // … the app's own handling
    }
    override fun onNewToken(token: String) {
        HopcastSDK.handleFcmToken(token)
        // … the app's own handling
    }
}
```

### Flutter

The app owns FCM through `firebase_messaging` (plus the usual FlutterFire
setup). Keep `const HopcastOnlineConfig()` (`isSecondaryFcm` defaults to `true`
in Dart) and forward everything; the SDK ignores the messages that are not
Hopcast's:

```dart
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:hopcast_flutter/hopcast_flutter.dart';

Future<void> wireHopcastPush() async {
  final hopcast = HopcastFlutter.instance;
  FirebaseMessaging.onMessage.listen((m) => hopcast.handleFcmMessage(m.data));
  FirebaseMessaging.instance.onTokenRefresh.listen(hopcast.handleFcmToken);
  final token = await FirebaseMessaging.instance.getToken();
  if (token != null) await hopcast.handleFcmToken(token);
}
```

On Android, `firebase_messaging` brings the `firebase-messaging` library the SDK
needs. Do not declare `HopcastFirebaseMessagingService` in a Flutter app.

## Flutter wiring

`examples/flutter/hopcast_service.dart` with `mode: HopcastMode.onlineOnly`
implements this flow. The core of it:

```dart
await hopcast.build(
  deviceId: deviceName,
  serviceId: 'acmeshare',
  mode: HopcastMode.onlineOnly,
  onlineConfig: const HopcastOnlineConfig(),
);
// provision if needed (see above), then:
hopcast.onlineEvents.listen((e) {
  switch (e.type) {
    case HopcastOnlineEventType.cloudReady:
      // Re-declare the whole inventory on every (re)connection.
      hopcast.reportDownloadedFile(
          infraType: HopcastInfraType.stored, contentIds: inventory.toList());
      break;
    case HopcastOnlineEventType.filesToBeDownloaded:
      // A delivery is starting; progress follows on transferEvents.
      break;
    default:
      break;
  }
});
await hopcast.enableOnlineMode();

// After the app downloaded a content itself (file at <cache>/<contentId>):
await hopcast.reportDownloadedFile(
    infraType: HopcastInfraType.wifi, contentIds: ['episode-1044']);
// Ask nearby devices for a content:
final needId = await hopcast.declareNeed(contentId: 'episode-1045', ttlSeconds: 300);
```

Online deliveries arrive on `transferEvents` as `fileCompleted` with
`isReceiver == true`; they never raise an `invitation`.

## Reference code

The online part of `examples/ios/HopcastManager.swift`,
`examples/android/HopcastManager.kt` and `examples/flutter/hopcast_service.dart`
covers this flow: `didDownload`, `didDelete`, `request`, `cancelRequest`, and
the re-declaration on cloud ready. Instantiate them with `.onlineOnly` /
`Mode.ONLINE_ONLY` / `HopcastMode.onlineOnly`.

## Troubleshooting

| Symptom | Check |
|---|---|
| `declareNeed` returns nil/null | The device is not provisioned, the mode is `offlineOnly`, or `OnlineConfig` is missing from the Builder. Flutter: the first `build()` of the process wins; `release()` before building in another mode. |
| `onCloudReady` never fires | `enableOnlineMode()` was not called, the device is not provisioned, there is no connectivity, or `OnlineConfig` is missing. Android: SDK 0.5.1 (or Flutter plugin 0.4.0) missed `io.netty:netty-codec-http`, so the WebSocket connection failed: upgrade to 0.5.2 (Flutter 0.4.1), where it is transitive; if upgrading is impossible, add `implementation("io.netty:netty-codec-http:4.1.99.Final")`. |
| Need and direct send to the same peer both fail (`CONNECTION_REJECTED`, `PAYLOAD_FAILURE`, `PEER_DISCONNECTED`) | Android 0.5.1 overlap bug: upgrade to 0.5.2, and do not `declareNeed` while your own `sendFiles` to that peer is running (rule 8). |
| Transfers never start | Check that: both devices have online mode on and the app in the foreground; they are within D2D range; the serving device declared the content **after** `onCloudReady`; and the file exists at `cacheDirectory/<contentId>`. |
| Background wake-ups missing | FCM token not forwarded; data messages filtered before forwarding; iOS "Remote notifications" background mode missing. |
