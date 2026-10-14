# iOS (native) — HopcastKit setup

Supports **offline, online and hybrid** modes. iOS 14+, Xcode 15+, Swift 5.9.
Module: `import HopcastKit`. Every entry point is static on the `HopcastSDK` facade.

## Step 1 — Add the binary package

Follow the **iOS** section of `distribution.md`. It is public SwiftPM, with no
credentials. It covers three project types: `Package.swift`,
XcodeGen/Tuist, and a plain `.xcodeproj`.

```swift
.package(url: "https://github.com/Hopcast/hopcast-sdk-ios", from: "0.4.1")
// target dependency:
.product(name: "HopcastKit", package: "hopcast-sdk-ios")
```

The binary ships without doc comments. The API semantics are described in this
skill, so rely on it rather than on Xcode quick help.

## Step 2 — Info.plist

Replace `acmeshare` with the app's `serviceId`:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>$(PRODUCT_NAME) uses the local network to exchange content with nearby devices.</string>
<key>NSBluetoothAlwaysUsageDescription</key>
<string>$(PRODUCT_NAME) uses Bluetooth to discover nearby devices.</string>
<key>NSBonjourServices</key>
<array>
    <string>_acmeshare._tcp</string>
    <string>_acmeshare._udp</string>
</array>
```

- **Always call `.setServiceId(...)` explicitly.** The default comes from the
  bundle id and will not match the plist.
- The service id is normalized: lowercase, `a-z0-9-` only, at most 15
  characters. Choose a value that is already normalized, so the plist matches it
  exactly.
- There is no runtime permission API. iOS shows the Local Network prompt the
  first time the app advertises or browses.
- In debug, `HopcastSDK.requiredPermissions` lists the required plist keys.
- No entitlement and no background mode are required. The SDK pauses in the
  background and resumes when the app becomes active.
- Online push wake-ups optionally need the Push Notifications capability and
  Firebase. See `modes/online.md`.

## Step 3 — Inject the `sdkKey`

Do not commit it. One option:

1. Put `HOPCAST_SDK_KEY = pk_live_xxx` in an untracked `Secrets.xcconfig`.
2. Expose it in Info.plist: `<key>HopcastSdkKey</key><string>$(HOPCAST_SDK_KEY)</string>`.
3. Read it at runtime: `Bundle.main.object(forInfoDictionaryKey: "HopcastSdkKey") as? String`.

## Step 4 — Wire the SDK

Copy `examples/ios/HopcastManager.swift`. It compiles against the SDK and covers
all three modes. Then follow the mode guide in `modes/`.

Order on iOS: **`provision` → `build()` → register listeners →
`enable…Mode()`**.

- Building after provisioning is mandatory in online and hybrid modes, because
  the advertised name is fixed at build time and must be the provisioned device
  id. It is harmless in offline mode.
- Listeners registered **before** `build()` are silently dropped.
- `build()` runs only once. Later calls are ignored until `HopcastSDK.release()`.
- The `provision` completion thread is unspecified, so hop to the main queue.

## API reference (public surface)

**Identity**
```swift
static func provision(sdkKey: String, userId: String, completion: @escaping (Result<Void, Error>) -> Void)
static var isProvisioned: Bool
static func clearIdentity()
static var deviceUuid: String   // "unknown" until provisioned
```
Errors: `HopcastIdentityError.notProvisioned`, `.invalidResponse`,
`.server(statusCode:)`, or `URLSession` errors. Calling `provision` again when
already provisioned succeeds immediately.

**Setup**
```swift
static func builder(deviceId: String, cacheDirectory: URL) -> Builder
// Builder (all @discardableResult, chainable):
//   setMode(_ mode: Mode)                       default .offlineOnly
//   setServiceId(_ serviceId: String)           ALWAYS set it
//   setAutoAcceptConnections(_ enabled: Bool)   default false; set true for online/hybrid
//   setAutoAcceptTransfers(_ enabled: Bool)     default false (offline flow only)
//   setOnlineConfig(_ config: OnlineConfig)     REQUIRED for .onlineOnly/.hybrid — use OnlineConfig()
//   build()
static var mode: Mode
static var requiredPermissions: [String]
static func release()
```
Use `OnlineConfig()` with its default values. Do not override `brokerUrl`
unless Hopcast support explicitly asks for it.

**Mode toggles.** They are idempotent. The `enable` calls do nothing until the
device is provisioned.
```swift
static func enableOfflineMode();  static func disableOfflineMode()
static func enableOnlineMode();   static func disableOnlineMode()
```

**Offline (manual) flow**
```swift
static func startSharing(listener: DeviceDiscoveryListener? = nil)  // = set discovery listener + enableOfflineMode
static func stopSharing()
static func inviteNeighbors(endpointIds: [String])
static func acceptInvitation(endpointId: String)
static func rejectInvitation(endpointId: String)
@discardableResult static func sendFiles(endpointIds: [String], files: [URL], metadata: Data? = nil) -> String?
static func acceptTransfer(transferId: String)
static func rejectTransfer(transferId: String)
static func cancelTransfer(transferId: String)
```

**Online flow**
```swift
static func reportDownloadedFile(infraType: InfraType, contentIds: [String])
static func reportRemovedFile(contentIds: [String])
@discardableResult static func declareNeed(contentId: String, ttlSeconds: Int) -> String?
static func cancelNeed(needId: String)
static func handleFcmToken(_ token: String)
static func handleFcmMessage(_ data: [String: String])
```

**Listeners.** All callbacks arrive on the main queue, and every protocol is
`AnyObject`. The tagged registries accept several observers, one per tag.
```swift
static func setDeviceDiscoveryListener(_ l: DeviceDiscoveryListener?)          // single slot
static func setConnectionListener(_ l: ConnectionListener, tag: String);  static func removeConnectionListener(tag: String)
static func setTransferListener(_ l: TransferListener, tag: String);      static func removeTransferListener(tag: String)
static func setOnlineEventListener(_ l: OnlineEventListener, tag: String); static func removeOnlineEventListener(tag: String)

protocol DeviceDiscoveryListener { func onNeighborsChanged(_ neighbors: [Neighbor]) }   // full snapshot
protocol ConnectionListener {      // default empty impls
    func onIncomingConnectionRequest(neighbor: Neighbor)
    func onConnectionStateChanged(state: ConnectionState, neighbor: Neighbor)
}
protocol TransferListener {        // default empty impls
    func onTransferInvitation(_ invitation: TransferInvitation)
    func onTransferStateChanged(transferId: String, isReceiver: Bool, state: TransferState, peer: Neighbor)
    func onTransferEvent(_ event: TransferEvent)
}
protocol OnlineEventListener {     // default empty impls
    func onFilesToBeDownloaded(fileIds: [String])
    func onCloudReady(deviceUuid: String)
    func onCloudDisconnected()
    func onCloudError(reason: String)
}
```

**Types**
```swift
enum Mode { case offlineOnly, onlineOnly, hybrid }
enum InfraType: String { case d2d, wifi, cellular, stored }
enum ConnectionState { case discovering, initiated, onHold, established, rejected, disconnected }
enum TransferState { case idle, invited, accepted, inProgress, finished, cancelled, failed }
enum TransferErrorReason { case peerDisconnected, invitationRejected, sourceUnreadable, storageFailure,
                                payloadFailure, cancelled, backendError, controlChannelError, unknown }
enum TransferEvent {
    case transferProgress(transferId: String, isReceiver: Bool, bytesTransferred: Int64, totalBytes: Int64, peer: Neighbor)
    case fileProgress(transferId: String, isReceiver: Bool, file: TransferFileInfo, bytesTransferred: Int64, totalBytes: Int64, peer: Neighbor)
    case fileCompleted(transferId: String, isReceiver: Bool, file: TransferFileInfo, localPath: String?, fileIndex: Int, fileTotal: Int, peer: Neighbor)
    case fileFailed(transferId: String, isReceiver: Bool, file: TransferFileInfo, reason: TransferErrorReason, peer: Neighbor)
    case transferFailed(transferId: String, isReceiver: Bool, reason: TransferErrorReason, peer: Neighbor)
}   // completion = TransferState.finished (there is no "completed" event case)
struct Neighbor { let endpointId: String; let displayName: String }
struct TransferFileInfo { let id: String; let name: String; let size: Int64; let mimeType: String? }
struct TransferInvitation { let transferId: String; let sender: Neighbor; let files: [TransferFileInfo];
                            let totalBytes: Int64; let customMetadata: Data? }
```

## iOS-specific behaviour
- Received files are written to `cacheDirectory/<transferId>/<fileName>`. Use
  `fileCompleted.localPath` and move the file out.
- In offline mode, a multi-recipient send uses one stream per peer, so the
  bandwidth needed grows with the number of recipients.
- Logs use the subsystem `fr.hopcast.sdk`:
  `log stream --predicate 'subsystem == "fr.hopcast.sdk"'`.
- Testing needs **two physical iPhones**.
