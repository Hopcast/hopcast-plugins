// Reference integration of the Hopcast Android SDK (native) — all three modes.
//
// Copy into the host app (adapt the package) and the marked spots. One class
// owns the SDK: build, provisioning, listeners, offline (manual) flow and
// online inventory.
//
// Order that matters on Android:
//   runtime permissions  →  build  →  provision (once, online)  →  listeners  →  enable…Mode()
package com.example.app.hopcast

import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import fr.hopcast.sdk.HopcastIdentityException
import fr.hopcast.sdk.HopcastSDK
import fr.hopcast.sdk.enums.ConnectionState
import fr.hopcast.sdk.enums.IncomingTransferPolicy
import fr.hopcast.sdk.enums.InfraType
import fr.hopcast.sdk.enums.Mode
import fr.hopcast.sdk.enums.TransferEvent
import fr.hopcast.sdk.listeners.ConnectionListener
import fr.hopcast.sdk.listeners.DeviceDiscoveryListener
import fr.hopcast.sdk.listeners.OnlineEventListener
import fr.hopcast.sdk.listeners.TransferHandoffListener
import fr.hopcast.sdk.listeners.TransferListener
import fr.hopcast.sdk.model.BulkPeerOutcome
import fr.hopcast.sdk.model.Neighbor
import fr.hopcast.sdk.model.OnlineConfig
import fr.hopcast.sdk.model.TransferHandoff
import fr.hopcast.sdk.model.TransferInvitation
import java.io.File
import java.io.IOException

class HopcastManager(
    private val context: Context,
    /** OFFLINE_ONLY, ONLINE_ONLY or HYBRID. */
    private val mode: Mode,
    /**
     * Where received files land. In online/hybrid it is ALSO where the SDK looks for
     * content to serve: `cacheDirectory/<contentId>` (file name == content id).
     */
    val cacheDirectory: File = File(context.filesDir, "hopcast"),
) : DeviceDiscoveryListener, ConnectionListener, TransferListener, OnlineEventListener,
    TransferHandoffListener {

    companion object {
        private const val TAG = "HopcastManager"
        private const val LISTENER_TAG = "app"

        /** ADAPT: discovery namespace — same value on every device of your app. */
        const val SERVICE_ID = "acmeshare"

        /** Runtime permissions still to request (pass to ActivityResultContracts.RequestMultiplePermissions). */
        fun missingPermissions(context: Context): List<String> =
            HopcastSDK.getRequiredPermissions().filter {
                ContextCompat.checkSelfPermission(context, it) != PackageManager.PERMISSION_GRANTED
            }
    }

    private val main = Handler(Looper.getMainLooper())

    /** Latest neighbour snapshot — the only valid source of endpointIds (volatile, never persist). */
    @Volatile var neighbors: List<Neighbor> = emptyList(); private set
    private val connected = mutableSetOf<String>()
    private val pendingSends = mutableMapOf<String, MutableList<File>>()

    /** Content ids this device holds (online/hybrid). Re-declared on every cloud (re)connect. */
    private val inventory = mutableSetOf<String>()
    @Volatile var cloudReady = false; private set

    /** UI hooks — invoked on the main thread. */
    var onNeighbors: ((List<Neighbor>) -> Unit)? = null
    var onFileReceived: ((File, Neighbor) -> Unit)? = null
    var onProgress: ((transferId: String, fraction: Float) -> Unit)? = null
    var onError: ((String) -> Unit)? = null

    // ---------------------------------------------------------------- startup

    /**
     * Call once runtime permissions are granted, after the app's login.
     * [sdkKey] must be injected (BuildConfig from local.properties / CI secret), never committed.
     * [lifecycleOwner]: discovery follows its lifecycle; null ⇒ runs until [stop].
     */
    fun start(sdkKey: String, userId: String, deviceName: String, lifecycleOwner: LifecycleOwner?) {
        cacheDirectory.mkdirs()
        val builder = HopcastSDK.Builder(deviceName, context.applicationContext, lifecycleOwner, cacheDirectory)
            .setMode(mode)
            .setServiceId(SERVICE_ID)
            // Offline-only: ask before connecting. Online/hybrid: cloud-driven connections
            // must not wait for a prompt.
            .setAutoAcceptConnections(mode != Mode.OFFLINE_ONLY)
            .setIncomingTransferPolicy(IncomingTransferPolicy.MANUAL)
        if (mode != Mode.OFFLINE_ONLY) {
            builder.setOnlineConfig(OnlineConfig())   // defaults only — the backend is SDK-owned
        }
        builder.build()                               // singleton; later builds are ignored until release()

        HopcastSDK.setDeviceDiscoveryListener(this)
        HopcastSDK.setConnectionListener(this, LISTENER_TAG)
        HopcastSDK.setTransferListener(this, LISTENER_TAG)
        if (mode != Mode.OFFLINE_ONLY) {
            HopcastSDK.setOnlineEventListener(this, LISTENER_TAG)
            HopcastSDK.setTransferHandoffListener(this, LISTENER_TAG)   // orchestrated transfers only
        }

        if (HopcastSDK.isProvisioned) {
            activate()
        } else {
            provisionThen(sdkKey, userId) { activate() }
        }
    }

    /**
     * One-time enrollment. Until it succeeds the SDK is INERT (calls silently no-op).
     * Idempotent: while an identity is stored it succeeds at once and ignores its arguments.
     */
    private fun provisionThen(sdkKey: String, userId: String, onSuccess: () -> Unit) {
        HopcastSDK.provision(sdkKey, userId) { result ->   // callback on the main thread
            result
                .onSuccess { onSuccess() }
                .onFailure { e ->
                    // Keep the app usable; call start(...) again later.
                    val why = when (e) {
                        is HopcastIdentityException.Server -> "HTTP ${e.statusCode} (check the SDK key)"
                        is HopcastIdentityException -> "unexpected backend response"
                        is IOException -> "no connectivity"
                        else -> e.message ?: e.toString()
                    }
                    onError?.invoke("Hopcast enrollment failed: $why")
                }
        }
    }

    /** Switch the enrolled user (logout → login as someone else). Call after [start]. */
    fun switchUser(sdkKey: String, newUserId: String) {
        HopcastSDK.clearIdentity()
        provisionThen(sdkKey, newUserId) { activate() }
    }

    private fun activate() {
        // Nothing auto-starts, even in single modes.
        when (mode) {
            Mode.OFFLINE_ONLY -> HopcastSDK.enableOfflineMode()
            Mode.ONLINE_ONLY -> HopcastSDK.enableOnlineMode()
            Mode.HYBRID -> { HopcastSDK.enableOfflineMode(); HopcastSDK.enableOnlineMode() }
        }
    }

    // ---------------------------------------------------------- hybrid toggles

    fun setOfflineEnabled(on: Boolean) = if (on) HopcastSDK.enableOfflineMode() else HopcastSDK.disableOfflineMode()
    fun setOnlineEnabled(on: Boolean) = if (on) HopcastSDK.enableOnlineMode() else HopcastSDK.disableOnlineMode()

    /** Wi-Fi off ⇒ ~100× slower Bluetooth fallback. Nudge the user before large sends. */
    fun isWifiEnabled(): Boolean = HopcastSDK.isWifiEnabled()

    // ---------------------------------------------- offline flow: connect, send

    /** Sends [files] to [peer]: connects first if needed; files go out once connected. */
    fun send(files: List<File>, peer: Neighbor) {
        if (peer.endpointId in connected) {
            HopcastSDK.sendFiles(listOf(peer.endpointId), files)
        } else {
            pendingSends.getOrPut(peer.endpointId) { mutableListOf() } += files
            HopcastSDK.inviteNeighbors(listOf(peer.endpointId))
        }
    }

    /** ADAPT: incoming connection policy (offline-only mode; auto-accepted otherwise). */
    fun shouldAcceptConnection(neighbor: Neighbor): Boolean = true

    /** ADAPT: incoming transfer policy (allow/block list, user prompt…). */
    fun shouldAcceptTransfer(invitation: TransferInvitation): Boolean = true

    // ------------------------------------------- online flow: inventory, needs

    /** After the app downloaded [contentId] itself; the file must be at `cacheDirectory/<contentId>`. */
    fun didDownload(contentId: String, via: InfraType) {
        inventory += contentId
        if (cloudReady) HopcastSDK.reportDownloadedFile(via, listOf(contentId))
        // else: declared in onCloudReady
    }

    fun didDelete(contentId: String) {
        inventory -= contentId
        HopcastSDK.reportRemovedFile(listOf(contentId))
    }

    /** Asks nearby devices for [contentId]. Returns the need id (or null if not possible). */
    fun request(contentId: String, ttlSeconds: Int = 300): String? =
        HopcastSDK.declareNeed(contentId, ttlSeconds)

    fun cancelRequest(needId: String) = HopcastSDK.cancelNeed(needId)

    // ---------------------------------------------------------------- teardown

    fun stop() {
        HopcastSDK.removeConnectionListener(LISTENER_TAG)
        HopcastSDK.removeTransferListener(LISTENER_TAG)
        HopcastSDK.removeOnlineEventListener(LISTENER_TAG)
        HopcastSDK.removeTransferHandoffListener(LISTENER_TAG)
        HopcastSDK.setDeviceDiscoveryListener(null)
        HopcastSDK.release()
        connected.clear()
        pendingSends.clear()
    }

    // ----------------------------------------------------------- listeners

    override fun onNeighborsChanged(neighbors: List<Neighbor>) {
        this.neighbors = neighbors
        main.post { onNeighbors?.invoke(neighbors) }
    }

    override fun onIncomingConnectionRequest(neighbor: Neighbor) {
        if (shouldAcceptConnection(neighbor)) HopcastSDK.acceptInvitation(neighbor.endpointId)
        else HopcastSDK.rejectInvitation(neighbor.endpointId)
    }

    override fun onConnectionStateChanged(state: ConnectionState, neighbor: Neighbor) {
        when (state) {
            ConnectionState.CONNECTION_ESTABLISHED -> {
                connected += neighbor.endpointId
                pendingSends.remove(neighbor.endpointId)?.let {
                    HopcastSDK.sendFiles(listOf(neighbor.endpointId), it)
                }
            }
            ConnectionState.CONNECTION_DISCONNECTED, ConnectionState.CONNECTION_REJECTED -> {
                connected -= neighbor.endpointId
                pendingSends.remove(neighbor.endpointId)
            }
            else -> Unit
        }
    }

    override fun onTransferInvitation(invitation: TransferInvitation) {
        // Offline flow only — online transfers are always auto-accepted.
        if (shouldAcceptTransfer(invitation)) HopcastSDK.acceptTransfer(invitation.transferId)
        else HopcastSDK.rejectTransfer(invitation.transferId)
    }

    override fun onTransferEvent(event: TransferEvent) {
        when (event) {
            is TransferEvent.TransferProgress -> if (event.totalBytes > 0) {
                val f = event.bytesTransferred.toFloat() / event.totalBytes
                main.post { onProgress?.invoke(event.transferId, f) }
            }
            is TransferEvent.FileCompleted -> {
                val path = event.localPath
                if (event.isReceiver && path != null) {
                    // Lands in cacheDirectory/<transferId>/<fileName> — move it out.
                    main.post { onFileReceived?.invoke(File(path), event.peer) }
                }
            }
            is TransferEvent.TransferFailed ->
                main.post { onError?.invoke("Transfer with ${event.peer.displayName} failed: ${event.reason}") }
            is TransferEvent.BulkSendFinished -> event.outcomes
                .filter { it.status == BulkPeerOutcome.Status.FAILED }
                .forEach { Log.w(TAG, "Send to ${it.peer.displayName} failed: ${it.errorReason}") }
            else -> Unit   // FileProgress, FileFailed, BulkSendStarted…
        }
    }

    override fun onCloudReady(deviceUuid: String) {
        cloudReady = true
        // Declare (again) after every (re)connect.
        if (inventory.isNotEmpty()) HopcastSDK.reportDownloadedFile(InfraType.STORED, inventory.toList())
    }

    override fun onCloudDisconnected() { cloudReady = false }   // the SDK reconnects by itself

    override fun onFilesToBeDownloaded(fileIds: List<String>) {
        // Heads-up: an orchestrated delivery is starting. Progress follows via onTransferEvent.
    }

    override fun onCloudError(reason: String) {
        main.post { onError?.invoke("Hopcast cloud: $reason") }
    }

    override fun onTransferHandoff(handoff: TransferHandoff) {
        // End of an orchestrated (online) transfer — for UI / analytics only;
        // the SDK acknowledges the instruction itself.
        Log.i(TAG, "Handoff ${handoff.instructionId}: ${handoff.status} (${handoff.bytesTotal} bytes)")
    }
}
