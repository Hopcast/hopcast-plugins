# Getting the Hopcast SDK — distribution channels

> **Hopcast fills this file in before handing the skill to a partner.**
> Every `TODO(hopcast)` below is a placeholder. If you are an agent and a value
> you need is still a `TODO(hopcast)`, **stop and ask the developer** for it.
> Never guess a URL, a version or a key.

| Platform | Artifact | Version | How to get it |
|---|---|---|---|
| Flutter | `hopcast_flutter` package (bundles the Android AAR and the iOS XCFramework) | `TODO(hopcast)` (latest: `0.3.3`) | `TODO(hopcast): private git URL + tag, or a zip to vendor with a path: dependency` |
| iOS (native) | Swift package `HopcastKit` (binary XCFramework) | `TODO(hopcast)` (latest: `0.4.1`) | `TODO(hopcast): SPM URL (e.g. https://github.com/Hopcast/hopcast-sdk-ios) + access procedure if private` |
| Android (native) | `fr.hopcast:sdk-hopcast-android` (AAR) | `TODO(hopcast)` (latest: `0.4.0`) | `TODO(hopcast): private Maven repo URL + credentials procedure` |

## Credentials provided by Hopcast

| Value | Format | Used for | Where it comes from |
|---|---|---|---|
| `sdkKey` | `pk_live_…` | One-time device enrollment (`provision`), in every mode | `TODO(hopcast): e.g. the Hopcast console (https://console.hopcast.io)` |

The `sdkKey` can be embedded in the app binary and can be revoked by Hopcast, but
**do not commit it to source control**. Inject it at build time
(`--dart-define`, `xcconfig`, `local.properties` / `BuildConfig`). The platform
guides show how.

## Support

`TODO(hopcast): support contact (e.g. contact@hopcast.io)`
