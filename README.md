# Hopcast plugins for coding agents

The official Hopcast marketplace. It contains the **`hopcast-integration`**
skill, which integrates the Hopcast device-to-device file-sharing SDK into a
Flutter, native iOS or native Android app, in offline, online or hybrid mode.

## Install (Claude Code)

```
/plugin install hopcast-integration --marketplace Hopcast/hopcast-plugins
```

Before Claude Code 2.1.275, use two commands instead:

```
/plugin marketplace add Hopcast/hopcast-plugins
/plugin install hopcast-integration@hopcast
```

Then ask, for example: *"Integrate Hopcast into this app in offline mode"*.

All three modes (offline, online, hybrid) are covered on every platform. SDK
versions targeted by the current skill: `hopcast_flutter` 0.4.1, iOS
`HopcastKit` 0.4.1+, Android `fr.hopcast:sdk-hopcast-android` 0.5.2.

**Updates:** run `/plugin marketplace update hopcast`, or turn on auto-update for
the `hopcast` marketplace in `/plugin` → Marketplaces.

## Other agents (Cursor, Codex, Copilot, Gemini CLI…)

The skill follows the open [Agent Skills](https://agentskills.io) format. Copy
the folder `plugins/hopcast-integration/skills/hopcast-integration/` into your
agent's skills directory. Each release also attaches it as a zip.

## What you need from Hopcast

Only an **SDK key** (`pk_live_…`), from https://console.hopcast.io. The SDK
packages are public, but do nothing until a valid key provisions the device.

Support: contact@hopcast.io

---

## Maintainers

| Path | Role |
|---|---|
| `.claude-plugin/marketplace.json` | Marketplace catalog |
| `plugins/hopcast-integration/.claude-plugin/plugin.json` | Plugin manifest. **Bump `version` on every change**, otherwise installed copies are not updated. |
| `plugins/hopcast-integration/skills/hopcast-integration/` | The skill: `SKILL.md`, then `concepts`, `distribution`, `platforms/`, `modes/`, `examples/`, `troubleshooting` |

Release checklist:
1. `grep -rn "TODO(hopcast)" plugins/`. Every published channel must be filled in.
2. Bump `version` in `plugin.json`.
3. Run `claude plugin validate .`
4. Commit, tag `vX.Y.Z` and push.
5. Optionally, attach the zip to a GitHub release:
   ```bash
   (cd plugins/hopcast-integration/skills && zip -r ../../../hopcast-integration.zip hopcast-integration)
   ```

The `examples/` sources are compile-checked against the real SDKs (`flutter
analyze`, `xcodebuild`, Gradle). Re-check them after every SDK API change.
