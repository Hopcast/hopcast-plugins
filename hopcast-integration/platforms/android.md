# Android (native) — `sdk-hopcast-android` setup

Supports **offline**, **online** and **hybrid** modes. On Android, online and
hybrid are **preview**: check with Hopcast before shipping them to production
(see `distribution.md`).

Requirements:
- `minSdk 21`; the SDK targets and compiles against API 34.
- A device with **Google Play Services** (discovery uses Nearby).
- **Physical devices** for testing: Nearby does not work on emulators.

## Step 1 — Dependency

Use the repository and version from `distribution.md`.

```kotlin
// settings.gradle.kts — dependencyResolutionManagement { repositories { … } }
maven { url = uri("<Maven repo URL from distribution.md>") }

// app/build.gradle.kts
dependencies {
    implementation("fr.hopcast:sdk-hopcast-android:<version from distribution.md>")
}
```

If the SDK was delivered as an `.aar` file, use the Maven route above if you can.
A bare `.aar` does not pull the SDK's transitive dependencies (Nearby, OkHttp,
coroutines…), so you would have to declare each one yourself.

The SDK ships minified, with its own consumer ProGuard rules. **The host needs no
keep rules.** Do not re-process the AAR.

## Step 2 — Host build configuration

```kotlin
android {
    defaultConfig { minSdk = 21 /* or higher */ }

    compileOptions {
        isCoreLibraryDesugaringEnabled = true   // SDK uses java.time / CompletableFuture
    }

    packaging {
        resources {
            excludes += setOf(
                "META-INF/INDEX.LIST",
                "META-INF/io.netty.versions.properties",
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE", "META-INF/LICENSE.txt", "META-INF/LICENSE.md",
                "META-INF/NOTICE", "META-INF/NOTICE.txt", "META-INF/NOTICE.md",
            )
            pickFirsts += setOf("META-INF/native-image/**")
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
```

Online and hybrid modes need extra configuration (Firebase). See
`modes/online.md`.

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

- `provision` requires `build()` first. Otherwise it fails with
  `IllegalStateException("HopcastSDK not built…")`.
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
- Toggle the online subsystem by calling `HopcastSDK.enableOnlineMode()` /
  `disableOnlineMode()` directly. **Do not use the `ServiceActions.ENABLE_ONLINE`
  or `DISABLE_ONLINE` intents**: they currently have no effect.

## API reference (public surface, `object HopcastSDK`)

Every call is synchronous. Only `provision` takes a callback.

**Identity**
```kotlin
fun provision(sdkKey: String, userId: String, callback: (Result<Unit>) -> Unit)   // callback on main thread
val isProvisioned: Boolean
val deviceUuid: String   // "unknown" until provisioned
```
There is **no `clearIdentity()` on Android yet**. To switch user, call
`provision(...)` again with the new `userId`: it replaces the stored identity.

**Setup**
```kotlin
HopcastSDK.Builder(deviceId: String, context: Context, lifecycleOwner: LifecycleOwner?, cacheDirectory: File)
HopcastSDK.Builder(deviceId: String, activity: Activity, lifecycleOwner: LifecycleOwner, cacheDirectory: File)
  .setMode(Mode)                                  // default OFFLINE_ONLY
  .setServiceId(String)                           // default = packageName; peers must match
  .setAutoAcceptConnections(Boolean)              // default false; true for online/hybrid
  .setIncomingTransferPolicy(IncomingTransferPolicy) // MANUAL (default) | AUTO_ACCEPT_ALL | AUTO_ACCEPT_TRUSTED
  .setTrustStore(TrustStore)                      // needed by AUTO_ACCEPT_TRUSTED (SharedPrefsTrustStore provided)
  .setAutoDisconnectAfterTransfer(Boolean)        // default false
  .setTransferWatchdog(stalledTimeoutMs: Long?)   // e.g. 30_000 → TransferFailed(STALLED)
  .setOnWifiStateChangedListener(OnWifiStateChangedListener)
  .setOnlineConfig(OnlineConfig)                  // REQUIRED for ONLINE_ONLY/HYBRID — use OnlineConfig()
  .build()
fun getRequiredPermissions(): List<String>
fun isWifiEnabled(): Boolean
val mode: Mode
fun release()
```
`lifecycleOwner` binds discovery to that lifecycle. Pass `null` to keep it running
until `release()`. `setAutoAcceptTransfers` is deprecated; use
`setIncomingTransferPolicy`.

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
```
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
```

## Android-specific behaviour
- Received files are written to `cacheDirectory/<transferId>/<fileName>`. Use
  `FileCompleted.localPath` and move the file out.
- After a transfer, release the connection, either with
  `setAutoDisconnectAfterTransfer(true)` or with `disconnect(endpointId)`. The
  next transfer then gets the full-speed Wi-Fi path.
- Discovery follows the `lifecycleOwner`: it runs in the foreground and stops in
  the background.
