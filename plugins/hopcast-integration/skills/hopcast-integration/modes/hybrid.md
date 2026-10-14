# Hybrid mode — offline and online side by side (Flutter, iOS, Android)

Hybrid mode is the union of `modes/offline.md` and `modes/online.md`. Both
subsystems share one identity, one `cacheDirectory` and one set of listeners.
**Read both mode guides first.** This file only covers what changes.

## Builder

- iOS: `.setMode(.hybrid)`. Android: `.setMode(Mode.HYBRID)`. Flutter:
  `build(…, mode: HopcastMode.hybrid, onlineConfig: const HopcastOnlineConfig())`.
- Native: `setOnlineConfig(OnlineConfig())` is **required**. Without it, the
  online subsystem never starts and only a warning is logged.
- `setAutoAcceptConnections(true)`: cloud-driven connections must not wait for a
  prompt. The **user's** control over offline transfers moves to the transfer
  invitation (`onTransferInvitation`), which still goes through the app's policy
  (`setAutoAcceptTransfers(false)` on iOS, `IncomingTransferPolicy.MANUAL` on
  Android). Flutter configures this itself: offline transfers raise an
  `invitation` event, online ones never do.

## Runtime toggles

Each subsystem can be on or off independently: either one, both, or neither.
The four calls are idempotent and safe at any time after `build()`.

```swift
// iOS
HopcastSDK.enableOfflineMode();  HopcastSDK.disableOfflineMode()
HopcastSDK.enableOnlineMode();   HopcastSDK.disableOnlineMode()
```
```kotlin
// Android
HopcastSDK.enableOfflineMode();  HopcastSDK.disableOfflineMode()
HopcastSDK.enableOnlineMode();   HopcastSDK.disableOnlineMode()
```
```dart
// Flutter: startSharing/stopSharing are the offline toggle
await hopcast.startSharing();      await hopcast.stopSharing();
await hopcast.enableOnlineMode();  await hopcast.disableOnlineMode();
```

The usual UX gives the user two switches: "Share with people nearby" (offline)
and "Automatic delivery" (online). **Persist** the user's choice and re-apply it
after every `build()`. Nothing auto-starts.

## How the two flows interact

- **Transfers in both flows** go through the same `TransferListener`, keyed by
  `transferId`.
  - Offline transfers raise `onTransferInvitation`; online transfers never do.
  - Online deliveries are announced by `onFilesToBeDownloaded`.
- **Received files**, offline or online, arrive at `fileCompleted.localPath`.
  - For online content, move or copy the file to `cacheDirectory/<contentId>` so
    the device can serve it again.
  - For offline content, move it to the app's storage.
- A device runs **one active transfer at a time**. An offline send and an online
  delivery queue behind each other.
- Exchange reports record which flow produced each exchange. Nothing to do.

## Reference code

Instantiate `examples/ios/HopcastManager.swift` with `.hybrid`,
`examples/android/HopcastManager.kt` with `Mode.HYBRID`, or
`examples/flutter/hopcast_service.dart` with `HopcastMode.hybrid`. Wire their
`setOfflineEnabled` and `setOnlineEnabled` methods to the two switches.
