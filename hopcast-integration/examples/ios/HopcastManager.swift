// Reference integration of HopcastKit (native iOS) — all three modes.
//
// Copy into the host app and adapt the marked spots. One class owns the SDK:
// provisioning, build, listeners, offline (manual) flow and online inventory.
//
// Order that matters:
//   provision (once, online)  →  build  →  register listeners  →  enable…Mode()
// Building AFTER provisioning is required in online/hybrid modes (the advertised
// name is fixed at build time and must be the provisioned backend device id).
import Foundation
import Combine
import HopcastKit

final class HopcastManager: ObservableObject {

    // MARK: Configuration — ADAPT

    /// Discovery namespace. Must match NSBonjourServices (`_<id>._tcp` / `_<id>._udp`).
    /// Lowercase a-z, 0-9, '-', max 15 chars.
    static let serviceId = "acmeshare"

    /// .offlineOnly, .onlineOnly or .hybrid.
    let mode: Mode

    /// Where received files land. In online/hybrid it is ALSO where the SDK looks
    /// for content to serve: `cacheDirectory/<contentId>` (file name == content id).
    let cacheDirectory: URL

    // MARK: Published state

    @Published private(set) var isReady = false
    @Published private(set) var lastError: String?
    @Published private(set) var neighbors: [Neighbor] = []
    @Published private(set) var connected: Set<String> = []          // endpointIds
    @Published private(set) var progress: [String: Double] = [:]     // transferId → 0…1
    @Published private(set) var cloudReady = false

    /// Called on the main queue for every fully received file (move it out of the cache).
    var onFileReceived: ((URL, Neighbor) -> Void)?

    /// Content ids this device holds (online/hybrid). Re-declared on every cloud (re)connect.
    private(set) var inventory: Set<String> = []

    /// Files queued until the recipient is connected (offline flow).
    private var pendingSends: [String: [URL]] = [:]

    init(mode: Mode, cacheDirectory: URL) {
        self.mode = mode
        self.cacheDirectory = cacheDirectory
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: Startup

    /// Call after the app's login. `sdkKey` must be injected (xcconfig / Info.plist), never committed.
    func start(sdkKey: String, userId: String, deviceName: String) {
        if HopcastSDK.isProvisioned {
            buildAndActivate(deviceName: deviceName)
            return
        }
        HopcastSDK.provision(sdkKey: sdkKey, userId: userId) { [weak self] result in
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self?.buildAndActivate(deviceName: deviceName)
                case .failure(let error):
                    // SDK stays inert. Keep the app usable; retry on next launch / connectivity.
                    self?.lastError = "Hopcast enrollment failed: \(error)"
                }
            }
        }
    }

    private func buildAndActivate(deviceName: String) {
        let manualOffline = (mode == .offlineOnly)
        let builder = HopcastSDK
            .builder(deviceId: deviceName, cacheDirectory: cacheDirectory)
            .setMode(mode)
            .setServiceId(Self.serviceId)
            // Offline-only: ask before connecting. Online/hybrid: cloud-driven connections
            // must not wait for a prompt.
            .setAutoAcceptConnections(!manualOffline)
            .setAutoAcceptTransfers(false)   // offline invitations go through onTransferInvitation
        if mode != .offlineOnly {
            builder.setOnlineConfig(OnlineConfig())   // defaults only — the backend is SDK-owned
        }
        builder.build()

        // Listeners AFTER build() — before it they are silently dropped.
        HopcastSDK.setDeviceDiscoveryListener(self)
        HopcastSDK.setConnectionListener(self, tag: "app")
        HopcastSDK.setTransferListener(self, tag: "app")
        if mode != .offlineOnly {
            HopcastSDK.setOnlineEventListener(self, tag: "app")
        }

        // Nothing auto-starts, even in single modes.
        switch mode {
        case .offlineOnly: HopcastSDK.enableOfflineMode()
        case .onlineOnly:  HopcastSDK.enableOnlineMode()
        case .hybrid:      HopcastSDK.enableOfflineMode(); HopcastSDK.enableOnlineMode()
        }
        isReady = true
    }

    // MARK: Hybrid toggles (idempotent, safe any time after build)

    func setOfflineEnabled(_ on: Bool) { on ? HopcastSDK.enableOfflineMode() : HopcastSDK.disableOfflineMode() }
    func setOnlineEnabled(_ on: Bool) { on ? HopcastSDK.enableOnlineMode() : HopcastSDK.disableOnlineMode() }

    // MARK: Offline flow — connect, then send

    /// Sends `files` to `peer`: connects first if needed; files go out once connected.
    func send(_ files: [URL], to peer: Neighbor) {
        if connected.contains(peer.endpointId) {
            HopcastSDK.sendFiles(endpointIds: [peer.endpointId], files: files)
        } else {
            pendingSends[peer.endpointId, default: []] += files
            HopcastSDK.inviteNeighbors(endpointIds: [peer.endpointId])
        }
    }

    /// ADAPT: incoming connection policy (offline-only mode; auto-accepted otherwise).
    func shouldAcceptConnection(from neighbor: Neighbor) -> Bool { true }

    /// ADAPT: incoming transfer policy (allow/block list, user prompt…).
    func shouldAcceptTransfer(_ invitation: TransferInvitation) -> Bool { true }

    // MARK: Online flow — inventory & needs

    /// After the app downloaded `contentId` itself. The file must already be at
    /// `cacheDirectory/<contentId>`.
    func didDownload(contentId: String, via infra: InfraType) {
        inventory.insert(contentId)
        if cloudReady { HopcastSDK.reportDownloadedFile(infraType: infra, contentIds: [contentId]) }
        // else: declared in onCloudReady (publishes made while disconnected are dropped)
    }

    func didDelete(contentId: String) {
        inventory.remove(contentId)
        HopcastSDK.reportRemovedFile(contentIds: [contentId])
    }

    /// Asks nearby devices for `contentId`. Call once cloudReady is true.
    func request(contentId: String, ttlSeconds: Int = 300) -> String? {
        HopcastSDK.declareNeed(contentId: contentId, ttlSeconds: ttlSeconds)
    }

    func cancelRequest(needId: String) { HopcastSDK.cancelNeed(needId: needId) }

    // MARK: Teardown

    func stop() {
        HopcastSDK.removeConnectionListener(tag: "app")
        HopcastSDK.removeTransferListener(tag: "app")
        HopcastSDK.removeOnlineEventListener(tag: "app")
        HopcastSDK.setDeviceDiscoveryListener(nil)
        HopcastSDK.release()
        isReady = false
    }

    /// Account switch: drop the identity, then call start(...) again with the new user.
    func signOut() {
        stop()
        HopcastSDK.clearIdentity()
    }
}

// MARK: - Listeners (all callbacks arrive on the main queue)

extension HopcastManager: DeviceDiscoveryListener {
    func onNeighborsChanged(_ neighbors: [Neighbor]) {
        self.neighbors = neighbors   // full snapshot; endpointIds are volatile — never persist them
    }
}

extension HopcastManager: ConnectionListener {
    func onIncomingConnectionRequest(neighbor: Neighbor) {
        if shouldAcceptConnection(from: neighbor) {
            HopcastSDK.acceptInvitation(endpointId: neighbor.endpointId)
        } else {
            HopcastSDK.rejectInvitation(endpointId: neighbor.endpointId)
        }
    }

    func onConnectionStateChanged(state: ConnectionState, neighbor: Neighbor) {
        switch state {
        case .established:
            connected.insert(neighbor.endpointId)
            if let files = pendingSends.removeValue(forKey: neighbor.endpointId) {
                HopcastSDK.sendFiles(endpointIds: [neighbor.endpointId], files: files)
            }
        case .disconnected, .rejected:
            connected.remove(neighbor.endpointId)
            pendingSends.removeValue(forKey: neighbor.endpointId)
        default:
            break
        }
    }
}

extension HopcastManager: TransferListener {
    func onTransferInvitation(_ invitation: TransferInvitation) {
        // Offline flow only — online transfers are always auto-accepted.
        if shouldAcceptTransfer(invitation) {
            HopcastSDK.acceptTransfer(transferId: invitation.transferId)
        } else {
            HopcastSDK.rejectTransfer(transferId: invitation.transferId)
        }
    }

    func onTransferStateChanged(transferId: String, isReceiver: Bool, state: TransferState, peer: Neighbor) {
        switch state {
        case .finished, .failed, .cancelled: progress[transferId] = nil
        default: break
        }
    }

    func onTransferEvent(_ event: TransferEvent) {
        switch event {
        case let .transferProgress(transferId, _, bytes, total, _):
            progress[transferId] = total > 0 ? Double(bytes) / Double(total) : nil
        case let .fileCompleted(_, isReceiver, _, localPath, _, _, peer):
            if isReceiver, let path = localPath {
                onFileReceived?(URL(fileURLWithPath: path), peer)
            }
        case let .transferFailed(_, _, reason, peer):
            lastError = "Transfer with \(peer.displayName) failed: \(reason)"
        default:
            break   // fileProgress, fileFailed…
        }
    }
}

extension HopcastManager: OnlineEventListener {
    func onCloudReady(deviceUuid: String) {
        cloudReady = true
        // Declare (again) after every (re)connect: publishes made while disconnected are lost.
        if !inventory.isEmpty {
            HopcastSDK.reportDownloadedFile(infraType: .stored, contentIds: Array(inventory))
        }
    }

    func onCloudDisconnected() { cloudReady = false }   // the SDK reconnects by itself

    func onFilesToBeDownloaded(fileIds: [String]) {
        // Heads-up: an orchestrated delivery is starting. Progress follows via TransferListener.
    }

    func onCloudError(reason: String) {
        lastError = "Hopcast cloud: \(reason)"   // the cloud retries while the need is valid
    }
}
