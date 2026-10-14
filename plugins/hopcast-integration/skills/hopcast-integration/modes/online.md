# Online mode — cloud-orchestrated delivery (native iOS / Android only)

**Not available in Flutter.** Android support is in **preview**: confirm with
Hopcast before shipping it.

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

On iOS, call `provision` **before** `build`. On Android, call `build` first, then
`provision`. See the platform guides.

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
7. The SDK processes one orchestrated transfer at a time and queues the others.
8. `onCloudError(reason)` reports orchestration failures, for example
   `destination_unreachable`. These are informational: the cloud retries.
9. Never override the broker or backend URLs. Use `OnlineConfig()` with its
   default values.

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

Add Firebase. The SDK does not bundle it.

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

## Reference code

The online part of `examples/ios/HopcastManager.swift` and
`examples/android/HopcastManager.kt` covers this flow: `didDownload`,
`didDelete`, `request`, `cancelRequest`, and the `onCloudReady` re-declaration.
Instantiate them with `.onlineOnly` / `Mode.ONLINE_ONLY`.

## Troubleshooting

| Symptom | Check |
|---|---|
| `declareNeed` returns nil/null | The device is not provisioned, the mode is `offlineOnly`, or `OnlineConfig` is missing from the Builder. |
| `onCloudReady` never fires | `enableOnlineMode()` was not called, the device is not provisioned, there is no connectivity, or `OnlineConfig` is missing. |
| Transfers never start | Check that: both devices have online mode on and the app in the foreground; they are within D2D range; the serving device declared the content **after** `onCloudReady`; and the file exists at `cacheDirectory/<contentId>`. |
| Background wake-ups missing | FCM token not forwarded; data messages filtered before forwarding; iOS "Remote notifications" background mode missing. |
