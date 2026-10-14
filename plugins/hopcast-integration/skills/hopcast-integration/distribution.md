# Getting the Hopcast SDK and the SDK key

## Access model: the key is the gate

The SDK packages can be **downloaded freely**, with no registry credentials and
no git access to request. What unlocks them is the **SDK key** (`pk_live_…`).

- Until `provision(sdkKey, userId)` has succeeded with a valid key, every SDK
  call is a silent no-op.
- Hopcast can revoke a key from the console at any time.

So the only credential to obtain is the key.

| Need | Where |
|---|---|
| SDK key (`pk_live_…`) | Create an account and a key at **https://console.hopcast.io**. If the developer has no access, they ask Hopcast (see Support). |
| Support | **contact@hopcast.io** |

**Never commit the key.** Inject it at build time (`--dart-define`, `xcconfig`,
`local.properties` / `BuildConfig`). The platform guides show how. If the key is
missing, stop and ask the developer for it. Never invent one.

---

## iOS (native): Swift Package Manager

| | |
|---|---|
| Package URL | `https://github.com/Hopcast/hopcast-sdk-ios` |
| Product / module | `HopcastKit` (`import HopcastKit`) |
| Version rule | `from: "0.4.1"`, which means "up to next major" |
| Auth | none |

The package is a binary XCFramework. SwiftPM downloads it and checks its
checksum. Nothing else is needed.

How to add it depends on the project type:

1. **`Package.swift` project**: add it to `dependencies`:
   ```swift
   .package(url: "https://github.com/Hopcast/hopcast-sdk-ios", from: "0.4.1")
   ```
   Then add it to the target:
   ```swift
   .product(name: "HopcastKit", package: "hopcast-sdk-ios")
   ```
2. **XcodeGen (`project.yml`) or Tuist (`Project.swift`)**: declare the package
   in the spec, then regenerate the project.
   ```yaml
   # XcodeGen
   packages:
     HopcastKit:
       url: https://github.com/Hopcast/hopcast-sdk-ios
       from: 0.4.1
   targets:
     App:
       dependencies:
         - package: HopcastKit
   ```
3. **Plain `.xcodeproj`**: ask the developer to do the GUI step, which takes
   about 30 seconds:
   1. **File → Add Package Dependencies…**
   2. Paste `https://github.com/Hopcast/hopcast-sdk-ios`.
   3. Choose "Up to Next Major" from `0.4.1`.
   4. Add `HopcastKit` to the app target.

   Wait for confirmation before continuing. Edit `project.pbxproj` by hand only
   if the developer explicitly asks for it.

Check the result with `xcodebuild -resolvePackageDependencies`, then build.

---

## Android (native): Maven

| | |
|---|---|
| Coordinates | `fr.hopcast:sdk-hopcast-android:TODO(hopcast)` |
| Repository | `TODO(hopcast)`: Maven Central, which needs no repository declaration |
| Auth | none |

```kotlin
// app/build.gradle.kts
dependencies {
    implementation("fr.hopcast:sdk-hopcast-android:<version>")
}
```

The SDK's transitive dependencies (Nearby, OkHttp, coroutines…) resolve
automatically from `google()` and `mavenCentral()`.

---

## Flutter: `hopcast_flutter`

| | |
|---|---|
| Package | `hopcast_flutter` |
| Source | `TODO(hopcast)`: pub.dev (`flutter pub add hopcast_flutter`) |
| Auth | none |

```bash
flutter pub add hopcast_flutter
```

The plugin pulls the native SDKs itself: the Android AAR from Maven, and
HopcastKit on iOS. There are no binaries to copy by hand.

---

> **If a value above is still `TODO(hopcast)`**: that channel is not published
> yet. Stop and tell the developer to ask contact@hopcast.io for the package.
> Do not guess coordinates.
