# Hopcast partner skill

A Claude Code skill (Agent Skill) that integrates the Hopcast SDK into a partner
app. It covers Flutter, iOS and Android, in offline, online and hybrid modes.

## Before sending it to a partner (Hopcast)

1. Fill in every `TODO(hopcast)` in `hopcast-integration/distribution.md`
   (`grep -rn "TODO(hopcast)" hopcast-integration`).
2. Optional: if the partner only uses one platform or one mode, you can delete
   the files that don't apply. `SKILL.md` already tells the agent to stop when a
   mode is not available on a platform.
3. Zip the folder: `zip -r hopcast-integration.zip hopcast-integration`.

## Installing it (partner)

Unzip the folder into the app repository:

```
<app-repo>/.claude/skills/hopcast-integration/SKILL.md
```

To make it available in every project, use `~/.claude/skills/hopcast-integration/`
instead. Then, in Claude Code, ask for example *"Integrate Hopcast into this app
in offline mode"*. The skill loads automatically, or you can invoke it with
`/hopcast-integration`.

## Contents

| File | Role |
|---|---|
| `SKILL.md` | Entry point: platform detection, mode choice, inputs, checklist |
| `concepts.md` | Concepts shared by all platforms and modes |
| `distribution.md` | Where to get the SDK and the key (**to fill in**) |
| `platforms/{flutter,ios,android}.md` | Installation, configuration, public API reference |
| `modes/{offline,online,hybrid}.md` | Integration flow for each mode |
| `examples/flutter/hopcast_service.dart` | Flutter reference service (offline), checked with `flutter analyze` |
| `examples/ios/HopcastManager.swift` | iOS reference manager (3 modes), compiled against the SDK |
| `examples/android/HopcastManager.kt` | Android reference manager (3 modes), compiled against the SDK |
| `troubleshooting.md` | Diagnostics |
