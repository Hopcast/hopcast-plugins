# Hopcast — core concepts (all platforms)

Hopcast lets nearby phones exchange files **device to device (D2D)**, the way
AirDrop does. Discovery runs over Bluetooth and the file bytes travel over
Wi-Fi. The proprietary core ships as **hardened binaries**: the host app only
sees a thin, typed API.

## The three modes

| Mode | Who decides what is sent | Network needs | Platforms |
|---|---|---|---|
| **Offline** | The **app/user**: discover, pick peers, send, accept. | Online only for the one-time enrollment. Reports are uploaded later. | Flutter, iOS, Android |
| **Online** | The **Hopcast backend**: it tells devices what to fetch from which neighbour, and the SDK executes. | Persistent control connection to the Hopcast backend. Data still flows D2D. | iOS, Android (native only) |
| **Hybrid** | Both. The app turns either subsystem on or off at runtime (e.g. a user toggle). | As online, when online is enabled. | iOS, Android (native only) |

The mode is fixed when the SDK is built, through the Builder (native) or
implicitly (Flutter is always offline). In every mode, **file data never goes
through a server**: online mode adds a control plane, not a second data path.

## Concepts shared by every mode

### Provisioned identity (mandatory)
- `provision(sdkKey, userId)` enrolls the device once against the Hopcast
  backend. It needs connectivity, so call it typically **right after the app's
  login**.
- `sdkKey` (`pk_live_…`) is issued by Hopcast to the partner. `userId` is the
  **partner's own** user identifier.
- The identity is stored in the platform secure store (Keychain or Keystore). It
  survives restarts and stays valid **offline indefinitely**.
- **The SDK is inert until it is provisioned.** Every D2D call silently does
  nothing. This is the #1 cause of "nothing happens". Guard the call with
  `isProvisioned()`.
- To switch user or rotate the key, call `clearIdentity()` and then
  `provision(...)` again.
- The backend URL belongs to the SDK. **The app never configures it.**

### Exchange reporting (automatic)
Every transfer is recorded on the device and uploaded once connectivity is
available. Nothing to integrate.

### `serviceId`: discovery namespace
Only devices built with the **same** `serviceId` see each other. On iOS it must
match `NSBonjourServices` in `Info.plist` (`_<serviceId>._tcp`,
`_<serviceId>._udp`), otherwise discovery is blocked silently.

### `deviceId` / display name
The name peers see. Generate it **once and persist it**. Do not regenerate it on
every launch.

### `endpointId`: volatile
A peer's transport id is valid only for the current discovery session.
**Never persist it.** Resolve it from the latest neighbour snapshot right
before sending.

### Manual acceptance
Every incoming offline transfer arrives as an **invitation**. Nothing is received
until the app accepts it. Build the trust policy (allow list, block list, ask
the user) on top of that.

### Transport facts
- **No cross-platform interop.** iOS works with iOS, Android with Android, never
  iOS with Android (the transports differ). Mention this in the UX if users are
  mixed.
- **Wi-Fi must be on** for speed. With Wi-Fi off, transfers fall back to
  Bluetooth, about 100× slower.
- **One active transfer at a time** per device. Serialize large or
  many-recipient sends.
- Discovery runs **in the foreground**.
- Testing needs **two real devices**. Simulators and emulators build and link,
  but cannot discover peers.
