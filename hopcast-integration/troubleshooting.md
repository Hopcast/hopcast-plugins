# Troubleshooting

Check the items in order. Most "nothing happens" reports come from the first
three.

## Nothing happens / no device discovered
1. **Not provisioned.** The SDK is inert until `provision` has succeeded once.
   Check `isProvisioned()`. The native logs show a warning on every ignored call.
2. **`serviceId` mismatch.** Both devices must use the same value. On iOS,
   `NSBonjourServices` must contain `_<serviceId>._tcp` and `_<serviceId>._udp`
   exactly.
3. **iOS with Android.** These never discover each other. Test iOS with iOS, or
   Android with Android.
4. **`startSharing()` not called**, or the app is in the background. Discovery
   only runs in the foreground.
5. **Android permissions denied.** Check `requestPermissions()` /
   `getRequiredPermissions()`. If the user chose "Don't ask again", send them to
   the app settings. On some OEM builds, location must be turned on system-wide.
6. **iOS Local Network denied.** Settings → the app → Local Network.
7. **Radios off.** Bluetooth must be on (both devices) and Wi-Fi should be on.
8. **Simulator or emulator.** Use real devices.
9. Wait a few seconds, or call `startSharing()` again: it is safe and refreshes
   discovery.

## The receiver never gets the file
- The invitation was never accepted. Is the transfer-event listener attached
  **before** `startSharing()`? Events are not buffered.
- iOS: the first send to a new peer waits up to about 25 s while the connection
  is set up. Move the devices closer and retry.
- Look at the `bulkFinished` outcomes for `FAILED` and read the `reason`.

## `sendFiles` returns null
No readable, non-empty file, or no recipient. Check the paths and resolve
`endpointIds` fresh from the latest neighbour snapshot.

## Transfers are extremely slow
- Wi-Fi is off on one side, so the transfer fell back to Bluetooth.
- Android 13+: `NEARBY_WIFI_DEVICES` was not granted, so the transfer cannot
  switch to Wi-Fi.
- Sends are fired in a tight loop. Serialize them: wait for `bulkFinished`
  before the next send.
- Android: the AAR was shrunk or re-processed. Integrate it as is.

## Build errors
| Error | Fix |
|---|---|
| Android: *"requires core library desugaring to be enabled"* | Enable `isCoreLibraryDesugaringEnabled` and add `desugar_jdk_libs` (see the platform guide). |
| Android: duplicate `META-INF/...` | Add the packaging `excludes` / `pickFirsts` block. |
| Android: cannot resolve `fr.hopcast:sdk-hopcast-android` | Check the repository setup. Flutter: `settings.gradle` must not force `FAIL_ON_PROJECT_REPOS`. |
| iOS: *"requires a higher minimum iOS deployment version"* | Set `platform :ios, '14.0'` and a Runner deployment target of 14.0 or higher, then `pod install`. |

## `provision` fails
- `PROVISION_FAILED` (Flutter) or a thrown error (native): the device is offline,
  or the key was rejected. Keep the app usable and retry on the next launch or
  when connectivity returns.
- `NOT_BUILT` (Flutter): `provision` was called before `build`.
- Key rejected repeatedly: check the `sdkKey` with Hopcast (see
  `distribution.md`).
