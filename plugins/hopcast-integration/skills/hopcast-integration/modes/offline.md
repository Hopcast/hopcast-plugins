# Offline mode — user-driven D2D sharing

The app drives everything: discover peers, pick some, send, accept incoming
transfers. Apart from the one-time `provision` and the automatic deferred
reports, nothing touches the network.

## Integration sequence (same on every platform)

```
requestPermissions ─▶ build(deviceId, serviceId) ─▶ isProvisioned? ──no──▶ provision(sdkKey, userId)
                                                          │yes                     │
                                                          ▼                        ▼
                                  attach neighbour + transfer listeners  ◀─────────┘
                                                          ▼
                                                   startSharing
                                                          ▼
                     send: resolve endpointIds fresh ─▶ sendFiles ─▶ progress … bulkFinished
                     receive: invitation ─▶ accept/reject ─▶ progress … fileCompleted(localPath)
                                                          ▼
                                          teardown: cancel listeners ─▶ stopSharing ─▶ release
```

Rules the integration must respect:
1. Attach the listeners **before** `startSharing`. Transfer events are not
   buffered.
2. Resolve `endpointId`s from the **latest** neighbour snapshot right before
   each send. Never store them.
3. Answer **every** invitation, with either accept or reject. An invitation left
   unanswered blocks the sender.
4. Move received files out of the SDK inbox: it is a cache.
   - iOS: `<Application Support>/hopcast_inbox/…`
   - Android: `filesDir/hopcast_inbox/…`
5. For large or many-recipient sends, send to one peer, wait for `bulkFinished`,
   then send to the next.
6. Before a large send, check Wi-Fi (`isWifiEnabled()` on Android) and ask the
   user to turn it on if it is off. On Android, a phone with its **mobile
   hotspot** on cannot use Wi-Fi Direct (much slower fallback): ask the user to
   turn it off.
7. **Repeated sends to the same peer** (e.g. a photographer sending photo after
   photo): do **not** disconnect after each transfer. On Android every new
   connection repays the Wi-Fi Direct upgrade (13–16 s when one phone is on
   4G). Connect once, keep the link (`setAutoDisconnectAfterTransfer(false)`
   natively, `build(autoDisconnectAfterTransfer: false)` in Flutter), send each
   file over the open link or batch files in one `sendFiles`, and disconnect
   when the session ends. iOS keeps its session open anyway.

---

## Flutter

Use `examples/flutter/hopcast_service.dart`. It is a complete, analyzer-clean
service class that implements every rule above. Typical wiring in the app:

```dart
import 'package:flutter/material.dart';
import 'package:hopcast_flutter/hopcast_flutter.dart';
import 'services/hopcast_service.dart';

class ShareScreen extends StatefulWidget {
  const ShareScreen({super.key, required this.userId, required this.deviceName});
  final String userId;
  final String deviceName; // persisted, stable
  @override
  State<ShareScreen> createState() => _ShareScreenState();
}

class _ShareScreenState extends State<ShareScreen> {
  late final HopcastService _hopcast = HopcastService(deviceName: widget.deviceName);
  HopcastStartResult? _status;

  @override
  void initState() {
    super.initState();
    _hopcast.receivedFiles.listen((path) {
      // move/copy `path` into app storage, refresh UI…
    });
    _hopcast.start(userId: widget.userId).then((r) {
      if (mounted) setState(() => _status = r);
    });
  }

  @override
  void dispose() {
    _hopcast.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    switch (_status) {
      case null:
        return const Center(child: CircularProgressIndicator());
      case HopcastStartResult.permissionDenied:
        return const Center(child: Text('Nearby permissions are required.'));
      case HopcastStartResult.notProvisioned:
        return const Center(child: Text('Connect to the internet once to enable sharing.'));
      case HopcastStartResult.ready:
        return StreamBuilder<List<HopcastNeighbor>>(
          stream: _hopcast.neighbors,
          initialData: _hopcast.currentNeighbors,
          builder: (context, snap) {
            final peers = snap.data ?? const [];
            if (peers.isEmpty) return const Center(child: Text('Looking for nearby devices…'));
            return ListView(
              children: [
                for (final p in peers)
                  ListTile(
                    title: Text(p.displayName),
                    onTap: () => _hopcast.send(
                      peerNames: [p.displayName],
                      filePaths: const ['/path/to/file'], // from a file picker
                    ),
                  ),
              ],
            );
          },
        );
    }
  }
}
```

Progress UI: listen to `_hopcast.events` and use `e.progressFraction`. On
`bulkFinished`, `e.outcomes` gives the result for each recipient.

Platform setup: `platforms/flutter.md`.

---

## iOS (native)

Use `examples/ios/HopcastManager.swift` with `mode: .offlineOnly`.

**Natively, you must connect before you send.** The Flutter plugin does this for
you. In native code it is two steps:

```swift
// 1. Connect: the peer gets onIncomingConnectionRequest (unless it auto-accepts connections)
HopcastSDK.inviteNeighbors(endpointIds: [peer.endpointId])

// 2. On ConnectionListener.onConnectionStateChanged(state: .established, neighbor: peer):
HopcastSDK.sendFiles(endpointIds: [peer.endpointId], files: [fileURL])
```

`sendFiles` returns `nil` when the recipient is not connected yet, the file
cannot be read, or the device is not provisioned. The example queues files until
the connection is `.established`, then sends them.

Builder for offline-only:

```swift
HopcastSDK.builder(deviceId: displayName, cacheDirectory: cacheDir)
    .setMode(.offlineOnly)
    .setServiceId("acmeshare")             // == NSBonjourServices
    .setAutoAcceptConnections(false)       // AirDrop-style: the receiver confirms
    .setAutoAcceptTransfers(false)         // invitations go through onTransferInvitation
    .build()
// then: listeners → HopcastSDK.enableOfflineMode()  (or startSharing(listener:))
```

Receiving side:
1. `onIncomingConnectionRequest`: call `acceptInvitation(endpointId:)` or
   `rejectInvitation(endpointId:)`.
2. `onTransferInvitation`: call `acceptTransfer(transferId:)` or
   `rejectTransfer(transferId:)`.
3. `onTransferEvent(.fileCompleted(…, localPath:, …))`: the file has arrived.

Platform setup: `platforms/ios.md`.

---

## Android (native)

Use `examples/android/HopcastManager.kt` with `Mode.OFFLINE_ONLY`.

It is the same two-step flow as on iOS. First connect with
`HopcastSDK.inviteNeighbors(listOf(endpointId))`. Then, on
`onConnectionStateChanged(CONNECTION_ESTABLISHED, peer)`, call
`HopcastSDK.sendFiles(listOf(endpointId), files)`. (Calling `sendFiles` for a
peer that is not connected yet also works on Android: the SDK queues a bulk send
and connects itself.)

Builder for offline-only:

```kotlin
HopcastSDK.Builder(displayName, applicationContext, lifecycleOwner, File(filesDir, "hopcast"))
    .setMode(Mode.OFFLINE_ONLY)
    .setServiceId("acmeshare")
    .setAutoAcceptConnections(false)
    .setIncomingTransferPolicy(IncomingTransferPolicy.MANUAL)
    .setAutoDisconnectAfterTransfer(false)   // keep the link across sends to the same peer
    .build()
// then: provision (if needed) → listeners → HopcastSDK.enableOfflineMode()
```

Android-only helpers:
- `IncomingTransferPolicy.AUTO_ACCEPT_TRUSTED` together with
  `setTrustStore(SharedPrefsTrustStore(context))` auto-accepts trusted senders.
- `setAutoDisconnectAfterTransfer(false)` keeps the link open, so repeated sends
  to the same peer skip the 13–16 s connection + Wi-Fi upgrade. End the session
  with `disconnect(endpointId)`, guarded by
  `!HopcastSDK.isTransferInProgress(endpointId)` (the example's
  `endSession`). Use `true` only when each send goes to a different peer.
- `HopcastSDK.connectedPeers`, `activeTransfers` and
  `isTransferInProgress(endpointId)` (0.5.2+) tell what is connected and
  running.
- `TransferEvent.BulkSendFinished` gives the result for each recipient.

Platform setup: `platforms/android.md`.
