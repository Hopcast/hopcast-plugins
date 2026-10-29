# Android (native) — `sdk-hopcast-android` setup

Supports **offline**, **online** and **hybrid** modes, at parity with iOS.
Current version: `fr.hopcast:sdk-hopcast-android:0.5.2`.

Requirements:
- `minSdk 21`; compileSdk 34 or higher recommended.
- A device with **Google Play Services** (discovery uses Nearby).
- **Physical devices** for testing: Nearby does not work on emulators.

## Step 1 — Dependency

Follow the **Android** section of `distribution.md`. It needs no credentials:
declare the Hopcast Maven repository in `settings.gradle(.kts)`
(`dependencyResolutionManagement`), or in `allprojects` for legacy projects, then:

```kotlin
// app/build.gradle.kts
dependencies {
    implementation("fr.hopcast:sdk-hopcast-android:0.5.2")
}
```

Use **0.5.2 or later**. The SDK ships minified, with its own consumer R8 rules.
Since 0.5.2 those rules are complete for R8 full mode (the AGP 8+ default) and
the device-to-device protocol uses no reflection, so **the host needs no
Hopcast rule** (step 2). Do not re-process the AAR. 0.5.1 is affected by known
online-mode and release-build bugs: always upgrade it (see `troubleshooting.md`).

## Step 2 — Host build configuration

```kotlin
android {
    defaultConfig { minSdk = 21 /* or higher */ }

    compileOptions {
        // MANDATORY, whatever the minSdk: the SDK uses java.time / CompletableFuture
        isCoreLibraryDesugaringEnabled = true
    }

    // MANDATORY: the MQTT client's transitive jars (netty…) ship duplicate META-INF files
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}
```

Groovy equivalent:

```groovy
android {
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
dependencies { coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.0.4' }
```

**Minified release builds (R8).** Nothing to add with 0.5.2+. The AAR's
consumer rules, applied automatically, cover the SDK's public API, services and
listeners, the MQTT stack (HiveMQ / Netty / JCTools, which resolve members by
name at runtime), and the `-dontwarn` entries for the optional classes those
libraries reference (OkHttp's Conscrypt / BouncyCastle / OpenJSSE providers,
Netty codecs, logging back-ends). A debug build and a release build of the app
exchange files normally.

- Do not add `-keep` / `-dontshrink` rules for the SDK, and remove any
  Hopcast-specific rule added as a 0.5.1 workaround (OkHttp `-dontwarn`,
  Netty / Gson keeps).
- Rules for the app's own code and for dependencies it adds itself (e.g.
  `firebase-messaging`, which ships its own) are still the app's business.
- To verify a release build, call `HopcastSDK.runProtocolSelfCheck()` (no
  `build()` or provisioning needed): `passed` must be `true`, and
  `fingerprint` must be identical in the debug and release variants.

```kotlin
val check = HopcastSDK.runProtocolSelfCheck()
if (!check.passed) Log.e("Hopcast", "Protocol self-check failed: ${check.failures}")
Log.i("Hopcast", "Protocol fingerprint: ${check.fingerprint}")
```

**Firebase.** The SDK declares `firebase-messaging` as `compileOnly`: it is not
pulled in. Offline-only apps do not need it. Online and hybrid apps add
`com.google.firebase:firebase-messaging` themselves (with the
`google-services` plugin and `google-services.json`) to get push wake-ups. See
`modes/online.md`. Without it, online mode still works while the app runs.

## Step 3 — Permissions

The SDK manifest declares every permission it needs, and they are merged into
the app. **Do not add `<uses-permission>` entries for them.** Request them at
runtime **before** building the SDK:

```kotlin
private val permissionLauncher =
    registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
        if (result.values.all { it }) startHopcast() else showPermissionRationale()
    }

fun ensurePermissionsThenStart() {
    val missing = HopcastManager.missingPermissions(this)   // wraps HopcastSDK.getRequiredPermissions()
    if (missing.isEmpty()) startHopcast() else permissionLauncher.launch(missing.toTypedArray())
}
```

`getRequiredPermissions()` returns a different set depending on the API level:

| API level | Permissions |
|---|---|
| 21–30 | `BLUETOOTH`, `BLUETOOTH_ADMIN` |
| ≤28 | `ACCESS_COARSE_LOCATION` |
| ≥29 | `ACCESS_FINE_LOCATION` |
| ≥31 | `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`, `BLUETOOTH_SCAN` |
| ≥33 | `NEARBY_WIFI_DEVICES`. Without it, transfers never switch to Wi-Fi and stay very slow. |

## Step 4 — Inject the `sdkKey`

Do not commit it. Read it from `local.properties` or a CI secret into `BuildConfig`:

```kotlin
// app/build.gradle.kts
val localProps = java.util.Properties().apply {
    rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { load(it) }
}
val hopcastSdkKey = (findProperty("HOPCAST_SDK_KEY") as String?)      // -PHOPCAST_SDK_KEY=… (CI)
    ?: localProps.getProperty("HOPCAST_SDK_KEY") ?: ""

android {
    buildFeatures { buildConfig = true }
    defaultConfig {
        buildConfigField("String", "HOPCAST_SDK_KEY", "\"$hopcastSdkKey\"")
    }
}
```

Read it in code as `BuildConfig.HOPCAST_SDK_KEY`.

## Step 5 — Wire the SDK

Copy `examples/android/HopcastManager.kt`. It compiles against the SDK and covers
all three modes. Then follow the mode guide in `modes/`.

Order on Android: **permissions → `build()` → `provision` → listeners →
`enable…Mode()`**.

- The two-argument `provision(sdkKey, userId, callback)` requires `build()`
  first. Otherwise it fails with `IllegalStateException("HopcastSDK not built…")`.
- To enroll **before** building (e.g. right after login, elsewhere in the app),
  use the overload `provision(context, sdkKey, userId, callback)`. It is also
  safe after `build()`.
- `build()` creates a process-wide singleton. Later builds return the same
  instance and ignore the new configuration until `HopcastSDK.release()`.
- Listener setters called before `build()` are silently ignored.

## Optional — foreground service

Use it to keep listening while the app is not in the foreground.

```xml
<!-- AndroidManifest.xml -->
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_DATA_SYNC" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
<application>
    <service android:name="fr.hopcast.sdk.service.HopcastService"
        android:exported="false"
        android:foregroundServiceType="dataSync|connectedDevice"
        android:stopWithTask="true" />
</application>
```

```kotlin
// Customize before starting:
NotificationParameters.notificationTitle = "Nearby sharing"
NotificationParameters.notificationText = "Listening for nearby devices"
NotificationParameters.smallIconRes = R.drawable.ic_share

ContextCompat.startForegroundService(this,
    Intent(this, HopcastService::class.java).setAction(ServiceActions.INIT))
```

- On API 33+, also request `POST_NOTIFICATIONS`. It is not in
  `getRequiredPermissions()`.
- Toggle a subsystem from the service by starting it with an intent whose
  action is `ServiceActions.ENABLE_ONLINE`, `DISABLE_ONLINE`, `ENABLE_OFFLINE` or
  `DISABLE_OFFLINE` (all handled since 0.5.2), or call
  `HopcastSDK.enable…Mode()` / `disable…Mode()` directly.

## API reference (public surface, `object HopcastSDK`)

Every call is synchronous. Only `provision` takes a callback.

**Identity**
```kotlin
fun provision(sdkKey: String, userId: String, callback: (Result<Unit>) -> Unit)   // after build(); callback on main thread
fun provision(context: Context, sdkKey: String, userId: String, callback: (Result<Unit>) -> Unit)   // usable before build()
val isProvisioned: Boolean
fun clearIdentity()
val deviceUuid: String   // "unknown" until provisioned
```
- `provision` is **idempotent**: while an identity is stored it succeeds
  immediately, without a network call, and **ignores** its arguments. To switch
  user or rotate the key, call `clearIdentity()` first, then `provision(...)`.
- Failures (in the `Result`): `HopcastIdentityException.Server(statusCode)`
  (HTTP error; 401/403 usually means a wrong key),
  `HopcastIdentityException.InvalidResponse`, a `java.io.IOException` (network),
  or `IllegalStateException` (called before `build()` without the `Context`
  overload). `HopcastIdentityException` is in package `fr.hopcast.sdk`.

**Setup**
```kotlin
HopcastSDK.Builder(deviceId: String, context: Context, lifecycleOwner: LifecycleOwner?, cacheDirectory: File)
HopcastSDK.Builder(deviceId: String, activity: Activity, lifecycleOwner: LifecycleOwner, cacheDirectory: File)
  .setMode(Mode)                                  // default OFFLINE_ONLY
  .setServiceId(String)                           // default = packageName; peers must match
  .setAutoAcceptConnections(Boolean)              // default false; true for online/hybrid
  .setIncomingTransferPolicy(IncomingTransferPolicy) // MANUAL (default) | AUTO_ACCEPT_ALL | AUTO_ACCEPT_TRUSTED
  .setTrustStore(TrustStore)                      // needed by AUTO_ACCEPT_TRUSTED (SharedPrefsTrustStore provided)
  .setAutoDisconnectAfterTransfer(Boolean)        // see "Connection reuse" below; false for repeated sends
  .setTransferWatchdog(stalledTimeoutMs: Long?)   // e.g. 30_000 → TransferFailed(STALLED)
  .setOnWifiStateChangedListener(OnWifiStateChangedListener)
  .setOnlineConfig(OnlineConfig)                  // REQUIRED for ONLINE_ONLY/HYBRID — OnlineConfig() or OnlineConfig(isSecondaryFcm = true)
  .build()
fun getRequiredPermissions(): List<String>
fun isWifiEnabled(): Boolean
val mode: Mode
fun release()
fun runProtocolSelfCheck(): ProtocolSelfCheckResult   // (passed, failures, fingerprint); works before build()
```
`lifecycleOwner` binds discovery to that lifecycle. Pass `null` to keep it running
until `release()`. `setAutoAcceptTransfers` is deprecated; use
`setIncomingTransferPolicy`.

`OnlineConfig(brokerUrl, isSecondaryFcm = false, runAsService = false)`
(`fr.hopcast.sdk.model`): never pass `brokerUrl` (keep the SDK default).
`isSecondaryFcm = true` when the app has its own `FirebaseMessagingService`
(see `modes/online.md`). `runAsService = true` signals that the host keeps the
optional foreground service running.

**Mode toggles.** They are idempotent. The `enable` calls do nothing until the
device is provisioned.
```kotlin
fun enableOfflineMode(); fun disableOfflineMode()
fun enableOnlineMode();  fun disableOnlineMode()
```

**Offline (manual) flow**
```kotlin
fun startSharing(listener: DeviceDiscoveryListener? = null); fun stopSharing()
fun inviteNeighbors(endpointIds: List<String>)
fun acceptInvitation(endpointId: String); fun rejectInvitation(endpointId: String)
fun disconnect(endpointId: String)
fun sendFiles(endpointIds: List<String>, files: List<File>, metadata: ByteArray? = null): String?
fun sendFiles(endpointIds: List<String>, files: List<File>, metadata: ByteArray?, disconnectAfterTransfer: Boolean): String?
fun acceptTransfer(transferId: String); fun rejectTransfer(transferId: String); fun cancelTransfer(transferId: String)
fun sendBytes(endpointIds: List<String>, bytes: ByteArray): Boolean   // small app messages (≤ ~24 KB) to connected peers
```
`sendFiles` to a single, already-connected peer starts at once and returns the
transfer id. To several peers, or to a peer that is not connected yet, it queues
a **bulk send**: the SDK connects to each peer in turn and reports
`BulkSendStarted` / `BulkSendFinished`; the call returns the bulk id. It returns
`null` only when no file is readable, there is no recipient, or the SDK is not
provisioned.

**Read-only state (Android only, since 0.5.2).** Snapshots; use the listeners
to react to changes.
```kotlin
val connectedPeers: List<Neighbor>                    // established links
val activeTransfers: List<ActiveTransfer>             // running + queued orchestrated transfers
fun isTransferInProgress(endpointId: String): Boolean // anything running / queued / being set up with that peer
data class ActiveTransfer(val transferId: String, val isReceiver: Boolean,
                          val peer: Neighbor, val isQueued: Boolean)   // fr.hopcast.sdk.model
```

**Online flow**
```kotlin
fun reportDownloadedFile(infraType: InfraType, contentIds: List<String>)
fun reportRemovedFile(contentIds: List<String>)
fun declareNeed(contentId: String, ttlSeconds: Int): String?
fun cancelNeed(needId: String)
fun handleFcmMessage(data: Map<String, String>)   // only when OnlineConfig(isSecondaryFcm = true)
fun handleFcmToken(token: String)                 // idem
```

**Listeners.** `ConnectionListener`, `TransferListener` and
`OnlineEventListener` methods have default empty bodies.
```kotlin
fun setDeviceDiscoveryListener(l: DeviceDiscoveryListener?)
fun setConnectionListener(l: ConnectionListener, tag: String);   fun removeConnectionListener(tag: String)
fun setTransferListener(l: TransferListener, tag: String);       fun removeTransferListener(tag: String)
fun setOnlineEventListener(l: OnlineEventListener, tag: String); fun removeOnlineEventListener(tag: String)
fun setNeighborArrivalListener(l: NeighborArrivalListener, tag: String)
fun setOnAppBytesReceivedListener(l: OnAppBytesReceivedListener, tag: String)
fun setTransferHandoffListener(l: TransferHandoffListener, tag: String); fun removeTransferHandoffListener(tag: String)

interface DeviceDiscoveryListener { fun onNeighborsChanged(neighbors: List<Neighbor>) }
interface ConnectionListener {
    fun onIncomingConnectionRequest(neighbor: Neighbor) {}
    fun onConnectionStateChanged(state: ConnectionState, neighbor: Neighbor) {}
}
interface TransferListener {
    fun onTransferInvitation(invitation: TransferInvitation) {}
    fun onTransferStateChanged(transferId: String, isReceiver: Boolean, state: TransferState, peer: Neighbor) {}
    fun onTransferEvent(event: TransferEvent) {}
}
interface OnlineEventListener {   // main thread
    fun onFilesToBeDownloaded(fileIds: List<String>) {}
    fun onCloudReady(deviceUuid: String) {}
    fun onCloudDisconnected() {}
    fun onCloudError(reason: String) {}
}
fun interface TransferHandoffListener {   // main thread; orchestrated (online) transfers only
    fun onTransferHandoff(handoff: TransferHandoff)
}
```
The single-argument `setTransferHandoffListener(listener)` is deprecated (it also
reports user-driven transfers); use the tagged variant.
Do not assume which thread discovery, connection and transfer callbacks run on.
Post to the main thread before touching the UI, as the example does.

**Types** (packages `fr.hopcast.sdk.enums` and `fr.hopcast.sdk.model`)
```kotlin
enum class Mode { OFFLINE_ONLY, ONLINE_ONLY, HYBRID }
enum class InfraType { D2D, WIFI, CELLULAR, STORED }
enum class IncomingTransferPolicy { AUTO_ACCEPT_ALL, AUTO_ACCEPT_TRUSTED, MANUAL }
enum class ConnectionState { CONNECTION_DISCOVERING, CONNECTION_INITIATED, CONNECTION_ON_HOLD,
                             CONNECTION_ESTABLISHED, CONNECTION_REJECTED, CONNECTION_DISCONNECTED }
enum class TransferState { TRANSFER_IDLE, TRANSFER_INVITED, TRANSFER_ACCEPTED, TRANSFER_IN_PROGRESS,
                           TRANSFER_FINISHED, TRANSFER_CANCELLED, TRANSFER_FAILED }
enum class TransferErrorReason { PEER_DISCONNECTED, INVITATION_REJECTED, SOURCE_UNREADABLE, STORAGE_FAILURE,
    PAYLOAD_FAILURE, CANCELLED, STALLED, BACKEND_ERROR, CONTROL_CHANNEL_ERROR, CONNECTION_TIMEOUT, UNKNOWN }
sealed interface TransferEvent {   // all have transferId + isReceiver
    TransferProgress(bytesTransferred, totalBytes, peer)
    FileProgress(file, bytesTransferred, totalBytes, peer)
    FileCompleted(file, localPath: String?, fileIndex, fileTotal, peer)
    FileFailed(file, reason, peer)
    TransferFailed(reason, peer)
    BulkSendStarted(totalPeers, totalFiles)
    BulkSendFinished(outcomes: List<BulkPeerOutcome>)
}   // always keep an `else ->` branch; completion = TransferState.TRANSFER_FINISHED
data class Neighbor(val endpointId: String, val displayName: String)
data class TransferFileInfo(val id: String, val name: String, val size: Long, val mimeType: String?)
data class TransferInvitation(val transferId: String, val sender: Neighbor, val files: List<TransferFileInfo>,
                              val totalBytes: Long, val customMetadata: ByteArray?)
data class BulkPeerOutcome(val peer: Neighbor, val perPeerTransferId: String?, val status: Status,
                           val errorReason: TransferErrorReason?)   // Status { SUCCESS, FAILED }
data class OnlineConfig(val brokerUrl: String = DEFAULT_BROKER_URL, val isSecondaryFcm: Boolean = false,
                        val runAsService: Boolean = false)
data class TransferHandoff(val instructionId: String?, val sessionId: String, val status: HandoffStatus,
                           val reason: String?, val bytesTotal: Long, val files: List<HandoffFile>,
                           val peerDeviceId: String, val startedAt: String, val completedAt: String)
data class HandoffFile(val fileId: String, val bytes: Long, val direction: TransferDirection)
data class ProtocolSelfCheckResult(val passed: Boolean, val failures: List<String>, val fingerprint: String)
enum class HandoffStatus { SUCCESS, FAILURE }          // fr.hopcast.sdk.enums
enum class TransferDirection { UPLOAD, DOWNLOAD }      // fr.hopcast.sdk.enums
sealed class HopcastIdentityException : Exception {   // fr.hopcast.sdk
    class NotProvisioned; class InvalidResponse; class Server(val statusCode: Int)
}
```

## Android-specific behaviour
- Received files are written to `cacheDirectory/<transferId>/<fileName>`. Use
  `FileCompleted.localPath` and move the file out.
- Discovery follows the `lifecycleOwner`: it runs in the foreground and stops in
  the background.

## Connection reuse (repeated sends to the same peer)

Every **new** connection pays the Nearby handshake plus the upgrade from
Bluetooth to a Wi-Fi Direct / Wi-Fi Aware link: **13–16 s** between devices on
different networks (e.g. one phone on 4G). Disconnecting after each transfer
makes an app that sends photo after photo pay it on every send. Instead:

1. Build with `.setAutoDisconnectAfterTransfer(false)`: the link stays open after
   each send (both the connected-peer path and the bulk path, since 0.5.2).
2. Connect once (`inviteNeighbors`, or let the first `sendFiles` connect).
3. Send each new file over the open link (`sendFiles(listOf(endpointId), listOf(file))`),
   or batch several files in **one** `sendFiles` call: one transfer, one
   connection.
4. When the session with that peer ends, call `disconnect(endpointId)`, after
   checking `isTransferInProgress(endpointId)`: `disconnect` cuts the link at once,
   including transfers running on it.

```kotlin
HopcastSDK.inviteNeighbors(listOf(endpointId))   // once
// on CONNECTION_ESTABLISHED (or endpointId in HopcastSDK.connectedPeers.map { it.endpointId }):
photos.forEach { HopcastSDK.sendFiles(listOf(endpointId), listOf(it)) }   // reuses the link
// session over:
if (!HopcastSDK.isTransferInProgress(endpointId)) HopcastSDK.disconnect(endpointId)
```

- Without the call, a send to an already-connected peer keeps the link, but a
  bulk send drops it. `true` drops it after every send. The per-call
  `sendFiles(…, metadata, disconnectAfterTransfer)` overload overrides it once.
- A device holds **one** D2D link at a time: while it keeps a link to A, a
  device B cannot connect to it. The SDK frees the link itself when the app
  sends to another peer (after the running transfers finish).
- **Mobile hotspot.** A phone with Wi-Fi tethering on cannot create the Wi-Fi
  Direct / Aware link (Nearby: `WIFI_HOTSPOT_ENABLED`). Transfers still work on
  a slower fallback medium and take much longer to start (about 38 s observed).
  This is an OS limitation no SDK can fix: ask users to turn the hotspot off.

## Concurrency (since 0.5.2)

The app, the online orchestrator and auto-sync can target the same peer at the
same time. The SDK arbitrates: duplicate connection requests are ignored
(“already connected” counts as success), cloud-orchestrated sends are
serialized per peer on the open link, and the SDK never tears down a link that
another transfer, or a queued send, still uses. The app's own `sendFiles` calls
to a connected peer are not delayed and may run in parallel.

Still, **do not call `declareNeed` for content that the same peer would serve
while your own `sendFiles` to that peer is running**: wait for the transfer to
finish (`TRANSFER_FINISHED` / `BulkSendFinished`), or check
`HopcastSDK.isTransferInProgress(endpointId)` / `activeTransfers` first. With
0.5.1 this overlap failed on both sides (`CONNECTION_REJECTED`,
`PAYLOAD_FAILURE`, `PEER_DISCONNECTED`).
