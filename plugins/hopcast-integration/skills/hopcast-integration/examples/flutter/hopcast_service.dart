// Reference integration of hopcast_flutter 0.4.0 — offline, online and hybrid.
//
// Copy this file into the host app (e.g. lib/services/hopcast_service.dart) and
// adapt the marked spots: the serviceId, the incoming-transfer policy, what to
// do with received files and (online) the content inventory. Depends only on
// `hopcast_flutter` and Flutter.
//
// Lifecycle:
//   start(userId)  →  permissions → build(mode) → provision (once, online)
//                  →  listen → startSharing (offline) / enableOnlineMode (online)
//   send(...)      →  offline: resolves fresh endpointIds, then sendFiles
//   didDownload / didDelete / request / cancelRequest  →  online inventory & needs
//   dispose()      →  cancels listeners, release()
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hopcast_flutter/hopcast_flutter.dart';

/// ADAPT (1): discovery namespace. Must match NSBonjourServices on iOS
/// (`_<serviceId>._tcp` / `_<serviceId>._udp`).
const String kHopcastServiceId = 'acmeshare';

/// Injected at build time: `flutter run --dart-define=HOPCAST_SDK_KEY=pk_live_…`.
/// Never hard-code or commit the key.
const String kHopcastSdkKey = String.fromEnvironment('HOPCAST_SDK_KEY');

/// Outcome of [HopcastService.start].
enum HopcastStartResult {
  /// The SDK is running in the requested mode.
  ready,

  /// Android runtime permissions were denied — explain and offer app settings.
  permissionDenied,

  /// Enrollment failed (offline or rejected key). The SDK stays inert; call
  /// [HopcastService.start] again later (next launch / connectivity regained).
  notProvisioned,
}

class HopcastService {
  HopcastService({
    required this.deviceName,
    this.mode = HopcastMode.offlineOnly,
  });

  /// Name shown to peers. Generate it once and persist it — don't regenerate
  /// it on every launch.
  final String deviceName;

  /// offlineOnly (user-driven), onlineOnly (cloud-orchestrated) or hybrid.
  final HopcastMode mode;

  bool get _hasOffline => mode != HopcastMode.onlineOnly;
  bool get _hasOnline => mode != HopcastMode.offlineOnly;

  final HopcastFlutter _hopcast = HopcastFlutter.instance;

  StreamSubscription<List<HopcastNeighbor>>? _neighborsSub;
  StreamSubscription<HopcastTransferEvent>? _eventsSub;
  StreamSubscription<HopcastOnlineEvent>? _onlineSub;
  StreamSubscription<HopcastTransferHandoff>? _handoffsSub;

  /// Latest neighbour snapshot — the only valid source of endpointIds.
  List<HopcastNeighbor> _neighbors = const [];

  /// Content ids this device holds (online/hybrid). Re-declared on every
  /// cloud (re)connection. ADAPT (4): seed it from disk at startup.
  final Set<String> _inventory = <String>{};
  bool _cloudReady = false;

  final _neighborsCtrl = StreamController<List<HopcastNeighbor>>.broadcast();
  final _receivedCtrl = StreamController<String>.broadcast();
  final _eventsCtrl = StreamController<HopcastTransferEvent>.broadcast();
  final _onlineCtrl = StreamController<HopcastOnlineEvent>.broadcast();

  /// Nearby devices (full snapshot on every change).
  Stream<List<HopcastNeighbor>> get neighbors => _neighborsCtrl.stream;
  List<HopcastNeighbor> get currentNeighbors => _neighbors;

  /// Absolute paths of fully received files (offline and online deliveries).
  Stream<String> get receivedFiles => _receivedCtrl.stream;

  /// Every transfer event, for progress UI.
  Stream<HopcastTransferEvent> get events => _eventsCtrl.stream;

  /// Online-mode events (cloud ready / disconnected / errors…).
  Stream<HopcastOnlineEvent> get onlineEvents => _onlineCtrl.stream;
  bool get cloudReady => _cloudReady;

  Future<void> _build() => _hopcast.build(
        deviceId: deviceName,
        serviceId: kHopcastServiceId,
        mode: mode,
        // Defaults only — the backend and broker are SDK-owned.
        onlineConfig: _hasOnline ? const HopcastOnlineConfig() : null,
      );

  Future<HopcastStartResult> start({required String userId}) async {
    // 1. Permissions (Android runtime; best-effort true on iOS).
    if (!await _hopcast.requestPermissions()) {
      return HopcastStartResult.permissionDenied;
    }

    // 2. Build — idempotent, safe on every launch.
    await _build();

    // 3. One-time enrollment. Until it succeeds the SDK is INERT
    //    (every call silently no-ops).
    if (!await _hopcast.isProvisioned()) {
      assert(kHopcastSdkKey.isNotEmpty,
          'Missing --dart-define=HOPCAST_SDK_KEY=pk_live_…');
      try {
        await _hopcast.provision(sdkKey: kHopcastSdkKey, userId: userId);
      } on HopcastIdentityException catch (e) {
        // e.error: transport (offline) / server (+ statusCode) / notBuilt…
        debugPrint('Hopcast provision failed: ${e.error} ${e.statusCode ?? ''}');
        return HopcastStartResult.notProvisioned;
      }
      if (_hasOnline) {
        // iOS fixes the advertised name at build(); in online/hybrid it must
        // be the provisioned device id. Rebuild once after the first
        // enrollment (harmless on Android).
        await _hopcast.release();
        await _build();
      }
    }

    // 4. Subscribe BEFORE starting — transfer events are not buffered.
    _neighborsSub ??= _hopcast.neighbors.listen((peers) {
      _neighbors = peers;
      _neighborsCtrl.add(peers);
    });
    _eventsSub ??= _hopcast.transferEvents.listen(_onEvent);
    if (_hasOnline) {
      _onlineSub ??= _hopcast.onlineEvents.listen(_onOnlineEvent);
      _handoffsSub ??= _hopcast.transferHandoffs.listen((h) {
        if (!h.isSuccess) {
          debugPrint(
              'Orchestrated transfer ${h.instructionId} failed: ${h.reason}');
        }
      });
    }

    // 5. Nothing auto-starts: turn on the subsystems of this mode.
    if (_hasOffline) await _hopcast.startSharing();
    if (_hasOnline) await _hopcast.enableOnlineMode();
    return HopcastStartResult.ready;
  }

  // ------------------------------------------------------- hybrid toggles

  /// "Share with people nearby" switch. Persist the user's choice and re-apply
  /// it after every start().
  Future<void> setOfflineEnabled(bool on) =>
      on ? _hopcast.startSharing() : _hopcast.stopSharing();

  /// "Automatic delivery" switch.
  Future<void> setOnlineEnabled(bool on) =>
      on ? _hopcast.enableOnlineMode() : _hopcast.disableOnlineMode();

  // ----------------------------------------------------------- offline flow

  /// Sends [filePaths] to the peers whose display names are [peerNames].
  /// endpointIds are volatile: they are resolved from the latest snapshot here,
  /// right before sending. Returns the bulk id, or null if nothing was sent.
  Future<String?> send({
    required Iterable<String> peerNames,
    required List<String> filePaths,
    String? metadata,
  }) async {
    final wanted = peerNames.toSet();
    final ids = _neighbors
        .where((n) => wanted.contains(n.displayName))
        .map((n) => n.endpointId)
        .toList();
    if (ids.isEmpty || filePaths.isEmpty) return null;
    return _hopcast.sendFiles(
      endpointIds: ids,
      filePaths: filePaths,
      metadata: metadata,
    );
  }

  /// Whether Wi-Fi is on (Android). Off ⇒ ~100× slower Bluetooth fallback.
  Future<bool> isWifiEnabled() => _hopcast.isWifiEnabled();

  /// ADAPT (2): incoming-transfer policy (offline transfers only; online
  /// deliveries never raise an invitation). Nothing is received until
  /// accepted. Replace with allow/block lists or a user prompt.
  Future<bool> shouldAccept(HopcastTransferEvent invitation) async => true;

  // ------------------------------------------------------------ online flow

  /// After the app downloaded [contentId] itself. The file must already be at
  /// `<getApplicationSupportDirectory()>/hopcast_inbox/<contentId>`.
  Future<void> didDownload(String contentId,
      {HopcastInfraType via = HopcastInfraType.wifi}) async {
    _inventory.add(contentId);
    if (_cloudReady) {
      await _hopcast.reportDownloadedFile(
          infraType: via, contentIds: [contentId]);
    } // else: declared on the next cloudReady
  }

  Future<void> didDelete(String contentId) async {
    _inventory.remove(contentId);
    await _hopcast.reportRemovedFile([contentId]);
  }

  /// Asks nearby devices for [contentId]. Returns the need id, or null.
  Future<String?> request(String contentId, {int ttlSeconds = 300}) =>
      _hopcast.declareNeed(contentId: contentId, ttlSeconds: ttlSeconds);

  Future<void> cancelRequest(String needId) => _hopcast.cancelNeed(needId);

  // -------------------------------------------------------------- listeners

  Future<void> _onEvent(HopcastTransferEvent e) async {
    _eventsCtrl.add(e);
    switch (e.type) {
      case HopcastTransferType.invitation:
        final id = e.transferId;
        if (id == null) return;
        if (await shouldAccept(e)) {
          await _hopcast.acceptTransfer(id);
        } else {
          await _hopcast.rejectTransfer(id);
        }
        break;
      case HopcastTransferType.fileCompleted:
        // ADAPT (3): offline files — move/copy them out of the SDK inbox (it
        // is a cache). Online contents — keep them at hopcast_inbox/<contentId>
        // so this device can serve them again.
        if (e.isReceiver && e.localPath != null) {
          _receivedCtrl.add(e.localPath!);
        }
        break;
      case HopcastTransferType.bulkFinished:
        for (final o in e.outcomes ?? const <HopcastTransferOutcome>[]) {
          if (!o.isSuccess) {
            debugPrint('Send to ${o.peerName} failed: ${o.reason}');
          }
        }
        break;
      default:
        // Progress / failures / unknown types — forwarded via [events].
        break;
    }
  }

  Future<void> _onOnlineEvent(HopcastOnlineEvent e) async {
    _onlineCtrl.add(e);
    switch (e.type) {
      case HopcastOnlineEventType.cloudReady:
        _cloudReady = true;
        // Declare (again) after every (re)connect.
        if (_inventory.isNotEmpty) {
          await _hopcast.reportDownloadedFile(
              infraType: HopcastInfraType.stored,
              contentIds: _inventory.toList());
        }
        break;
      case HopcastOnlineEventType.cloudDisconnected:
        _cloudReady = false; // the SDK reconnects by itself
        break;
      case HopcastOnlineEventType.cloudError:
        debugPrint('Hopcast cloud: ${e.reason}'); // informational, cloud retries
        break;
      default:
        // filesToBeDownloaded: a delivery is starting; progress follows on
        // transferEvents.
        break;
    }
  }

  // --------------------------------------------------------------- identity

  /// Switch the enrolled user (logout → login as someone else). provision is
  /// idempotent, so the old identity must be cleared first.
  Future<void> switchUser(String newUserId) async {
    await _hopcast.clearIdentity();
    await _hopcast.provision(sdkKey: kHopcastSdkKey, userId: newUserId);
  }

  // --------------------------------------------------------------- teardown

  Future<void> dispose() async {
    await _neighborsSub?.cancel();
    await _eventsSub?.cancel();
    await _onlineSub?.cancel();
    await _handoffsSub?.cancel();
    _neighborsSub = null;
    _eventsSub = null;
    _onlineSub = null;
    _handoffsSub = null;
    if (_hasOnline) await _hopcast.disableOnlineMode();
    if (_hasOffline) await _hopcast.stopSharing();
    await _hopcast.release();
    await _neighborsCtrl.close();
    await _receivedCtrl.close();
    await _eventsCtrl.close();
    await _onlineCtrl.close();
  }
}
