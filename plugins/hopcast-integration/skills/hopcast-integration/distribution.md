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
| Coordinates | `fr.hopcast:sdk-hopcast-android:0.5.1` |
| Repository | `https://raw.githubusercontent.com/Hopcast/hopcast-sdk-android/main/maven` (a static Maven repo served from the public GitHub repo `Hopcast/hopcast-sdk-android`) |
| Auth | none |

1. **Declare the repository** where the project resolves its dependencies.

   Modern projects (`settings.gradle.kts`, `dependencyResolutionManagement`):
   ```kotlin
   dependencyResolutionManagement {
       repositories {
           google()
           mavenCentral()
           maven("https://raw.githubusercontent.com/Hopcast/hopcast-sdk-android/main/maven")
       }
   }
   ```
   Groovy `settings.gradle`:
   ```groovy
   dependencyResolutionManagement {
       repositories {
           google()
           mavenCentral()
           maven { url 'https://raw.githubusercontent.com/Hopcast/hopcast-sdk-android/main/maven' }
       }
   }
   ```
   Legacy projects that declare repositories in the root `build.gradle` put the
   same `maven { url '…' }` line in `allprojects { repositories { … } }`.

2. **Add the dependency** (plus the mandatory host configuration described in
   `platforms/android.md`, step 2):
   ```kotlin
   // app/build.gradle.kts
   dependencies {
       implementation("fr.hopcast:sdk-hopcast-android:0.5.1")
       coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")   // mandatory
   }
   ```

The SDK's transitive dependencies (Nearby, OkHttp, the MQTT client,
coroutines…) resolve automatically from `google()` and `mavenCentral()`.
`com.google.firebase:firebase-messaging` is **not** pulled in: apps that use the
online or hybrid mode add it themselves (see `modes/online.md`).

Check the result with `./gradlew :app:dependencies --configuration releaseRuntimeClasspath`
or simply `./gradlew assembleDebug`.

---

## Flutter: `hopcast_flutter`

| | |
|---|---|
| Package | `hopcast_flutter` `0.4.0` |
| Source | git repository `https://github.com/Hopcast/hopcast-sdk-flutter`, tag `0.4.0` (**not** published on pub.dev) |
| Auth | none |

```yaml
# pubspec.yaml
dependencies:
  hopcast_flutter:
    git:
      url: https://github.com/Hopcast/hopcast-sdk-flutter
      ref: 0.4.0
```

Then run `flutter pub get`. Do **not** use `flutter pub add hopcast_flutter`
without the git options: the package is not on pub.dev.

The plugin **embeds** both native SDKs, so there is nothing to install natively:
- Android: the AAR `fr.hopcast:sdk-hopcast-android:0.5.1` ships inside the plugin
  as a local Maven repository, which the plugin's Gradle script adds to every
  project automatically. Do **not** add the Hopcast Maven URL or the Android
  dependency to the app yourself.
- iOS: the `HopcastSDKKit.xcframework` is vendored by the plugin's podspec. Do
  **not** add the `hopcast-sdk-ios` Swift package to the Runner.

The host app still needs the Gradle settings (desugaring, packaging excludes)
and the iOS settings (deployment target, Info.plist) from
`platforms/flutter.md`.

---

> **If installation fails** (repository unreachable, tag or version not found):
> do not guess other coordinates or versions. Tell the developer to contact
> contact@hopcast.io.
