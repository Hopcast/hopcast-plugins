// Reference integration of hopcast_flutter (OFFLINE mode).
//
// Copy this file into the host app (e.g. lib/services/hopcast_service.dart) and
// adapt the three marked spots: the serviceId, the incoming-transfer policy and
// what to do with received files. Depends only on `hopcast_flutter` and Flutter.
//
// Lifecycle:
//   start(userId)  →  permissions → build → provision (once, online) → listen → startSharing
//   send(...)      →  resolves fresh endpointIds, then sendFiles
//   dispose()      →  cancels listeners, release()
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:hopcast_flutter/hopcast_flutter.dart';

/// ADAPT (1): discovery namespace. Must match NSBonjourServices on iOS
/// (`_<serviceId>._tcp` / `_<serviceId>._udp`).
const String kHopcastServiceId = 'acmeshare';

/// Injected at build time: `flutter run --dart-define=HOPCAST_SDK_KEY=pk_live_…`.
/// Never hard-code or commit the key.
const String kHopcastSdkKey = String.fromEnvironment('HOPCAST_SDK_KEY');

/// Outcome of [HopcastService.start].
enum HopcastStartResult {
  /// Sharing is running.
  ready,

  /// Android runtime permissions were denied — explain and offer app settings.
  permissionDenied,

  /// Enrollment failed (offline or rejected key). The SDK stays inert; call
  /// [HopcastService.start] again later (next launch / connectivity regained).
  notProvisioned,
}

class HopcastService {
  HopcastService({required this.deviceName});

  /// Name shown to peers. Generate it once and persist it — don't regenerate
  /// it on every launch.
  final String deviceName;

  final HopcastFlutter _hopcast = HopcastFlutter.instance;

  StreamSubscription<List<HopcastNeighbor>>? _neighborsSub;
  StreamSubscription<HopcastTransferEvent>? _eventsSub;

  /// Latest neighbour snapshot — the only valid source of endpointIds.
  List<HopcastNeighbor> _neighbors = const [];

  final _neighborsCtrl = StreamController<List<HopcastNeighbor>>.broadcast();
  final _receivedCtrl = StreamController<String>.broadcast();
  final _eventsCtrl = StreamController<HopcastTransferEvent>.broadcast();

  /// Nearby devices (full snapshot on every change).
  Stream<List<HopcastNeighbor>> get neighbors => _neighborsCtrl.stream;
  List<HopcastNeighbor> get currentNeighbors => _neighbors;

  /// Absolute paths of fully received files (in the SDK inbox — move them out).
  Stream<String> get receivedFiles => _receivedCtrl.stream;

  /// Every transfer event, for progress UI.
  Stream<HopcastTransferEvent> get events => _eventsCtrl.stream;

  Future<HopcastStartResult> start({required String userId}) async {
    // 1. Permissions (Android runtime; best-effort true on iOS).
    if (!await _hopcast.requestPermissions()) {
      return HopcastStartResult.permissionDenied;
    }

    // 2. Build — idempotent, safe on every launch.
    await _hopcast.build(deviceId: deviceName, serviceId: kHopcastServiceId);

    // 3. One-time enrollment. Until it succeeds the SDK is INERT
    //    (every D2D call silently no-ops).
    if (!await _hopcast.isProvisioned()) {
      assert(kHopcastSdkKey.isNotEmpty,
          'Missing --dart-define=HOPCAST_SDK_KEY=pk_live_…');
      try {
        await _hopcast.provision(sdkKey: kHopcastSdkKey, userId: userId);
      } on PlatformException catch (e) {
        debugPrint('Hopcast provision failed: ${e.code} ${e.message}');
        return HopcastStartResult.notProvisioned;
      }
    }

    // 4. Subscribe BEFORE startSharing — transfer events are not buffered.
    _neighborsSub ??= _hopcast.neighbors.listen((peers) {
      _neighbors = peers;
      _neighborsCtrl.add(peers);
    });
    _eventsSub ??= _hopcast.transferEvents.listen(_onEvent);

    // 5. Advertise + discover. Calling it again later is safe (refreshes).
    await _hopcast.startSharing();
    return HopcastStartResult.ready;
  }

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

  /// ADAPT (2): incoming-transfer policy. Nothing is received until accepted.
  /// Replace with allow/block lists or a user prompt.
  Future<bool> shouldAccept(HopcastTransferEvent invitation) async => true;

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
        // ADAPT (3): move/copy the file out of the SDK inbox (it is a cache).
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

  /// Switch the enrolled user (logout → login as someone else).
  Future<void> switchUser(String newUserId) async {
    await _hopcast.clearIdentity();
    await _hopcast.provision(sdkKey: kHopcastSdkKey, userId: newUserId);
  }

  Future<void> dispose() async {
    await _neighborsSub?.cancel();
    await _eventsSub?.cancel();
    _neighborsSub = null;
    _eventsSub = null;
    await _hopcast.stopSharing();
    await _hopcast.release();
    await _neighborsCtrl.close();
    await _receivedCtrl.close();
    await _eventsCtrl.close();
  }
}
