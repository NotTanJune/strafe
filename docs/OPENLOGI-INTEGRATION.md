# OpenLogi integration

This fork can share Strafe's live Transition Speed setting with the OpenLogi
gesture-button actions for moving to the previous or next macOS Space.

The integration is local and one-way:

```text
OpenLogi Agent -> /tmp/strafe.sock -> StrafeControlServer -> GestureSwitchEngine
```

OpenLogi sends `switch left` for `PreviousDesktop` and `switch right` for
`NextDesktop`. Strafe applies the speed currently selected in its menu-bar
menu, then returns `ok`. If Strafe is not running or rejects the request,
OpenLogi uses its existing native Space-switch implementation.

## Quick setup on another Mac

The repositories are:

```text
https://github.com/tanmay-nargas/strafe
https://github.com/tanmay-nargas/OpenLogi
```

Build and launch Strafe:

```sh
git clone https://github.com/tanmay-nargas/strafe
cd strafe
./Scripts/bundle.sh
open -n "$PWD/build/strafe.app"
```

The committed `artifacts/strafe.app` bundle is also available when a source
build is not needed. Grant Strafe **Accessibility** permission, open its
menu-bar item, and select the desired **Transition Speed**.

Build the OpenLogi agent from the integration branch:

```sh
git clone https://github.com/tanmay-nargas/OpenLogi
cd OpenLogi
git switch feature/gesture-button-flicks
DEVELOPER_DIR=/Library/Developer/CommandLineTools \
  cargo build -p openlogi-agent --release
```

Replace the nested agent in the OpenLogi app, sign the bundle, and launch it:

```sh
APP=/Applications/OpenLogi.app
AGENT="$APP/Contents/Library/LoginItems/OpenLogi Agent.app/Contents/MacOS/openlogi-agent"
cp target/release/openlogi-agent "$AGENT"
codesign --force --deep --sign - "$APP"
open -n "$APP"
```

The committed `artifacts/OpenLogi.app` in the OpenLogi fork already contains
the integration agent and can be copied to `/Applications` instead of
building the agent. A new ad-hoc signature has a new macOS TCC identity, so
grant **Input Monitoring** to **OpenLogi Agent** after installing or replacing
the agent. Restart OpenLogi after granting permission.

## Verify the connection

Strafe creates an owner-only Unix socket while its menu-bar app is running:

```sh
test -S /tmp/strafe.sock
stat -f '%N %Sp %Su:%Sg' /tmp/strafe.sock
```

The expected mode is `srw-------`. The endpoint accepts only these newline-
terminated commands:

```text
switch left
switch right
```

The response is `ok` after Strafe posts the synthetic gesture, or `error` when
the request is invalid, fails, or is at the edge of the Space list.

## Implementation locations

- Strafe server: `Sources/strafe/ControlServer.swift`
- Strafe lifecycle: `Sources/strafe/main.swift`
- OpenLogi client: `crates/openlogi-inject/src/inject/macos.rs`
- OpenLogi build and replacement details: `docs/MACOS-NO-XCODE-GESTURE-BUILD.md`

Neither app persists the selected Transition Speed. The setting remains live
only in the running Strafe process, so OpenLogi must connect to that process to
reuse it.
