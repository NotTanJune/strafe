# Security

strafe holds macOS Accessibility permission and installs a system-wide event
tap. That is a lot of trust to ask for, so this document states exactly what
strafe can and cannot do, and how to verify every claim yourself. Every claim
below points at a file and line you can read or a command you can run.

The whole program is about **1,120 lines** of Swift + C (`wc -l Sources/**`).
You can build it from source in about 30 seconds (`swift build`) and audit it
in an afternoon.

Source remains the canonical, auditable form of strafe. This fork also commits
an ad-hoc-signed arm64 convenience bundle at `artifacts/strafe.app`; it is not
an update channel or a substitute for reviewing and building the source.

---

## What strafe can do

strafe installs one active `CGEventTap` and holds Accessibility permission to
do so. The tap's event mask is defined in exactly one place, and it covers
**only gesture and dock-control events** — not keystrokes.

- **Tap mask definition:** `Sources/CStrafe/CStrafe.c`, function
  `strafe_tap_event_mask()` (near line 260):

  ```c
  uint64_t strafe_tap_event_mask(void) {
      return (1ULL << kCGSEventGesture) | (1ULL << kCGSEventDockControl);
  }
  ```

  That is `(1<<29) | (1<<30)` — the two private trackpad-gesture event types
  and nothing else. There is no `kCGEventKeyDown`/`kCGEventKeyUp` bit.

- **Why keys are excluded — determination comment:** immediately above that
  function in `Sources/CStrafe/CStrafe.c` (the `KEY-EVENTS-IN-MASK
  DETERMINATION` block, around lines 240–259) documents that an earlier
  revision masked key events, that they were never acted on, and that they were
  removed. The tap now wakes only on real space-swipe gestures.

- **The tap is installed here:** `Sources/strafe/SwipeInterceptor.swift`,
  `SwipeInterceptor.start()` (around line 39; the `tapCreate` call itself is at
  line 54), using
  `CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
  options: .defaultTap, eventsOfInterest: mask, ...)` where `mask` comes
  straight from `strafe_tap_event_mask()` above.

**Because keystrokes are not in the mask, strafe cannot observe what you type.**
A key event fails the `cgsType == dockControl || cgsType == gesture` guard
(`SwipeInterceptor.handle`, ~line 139) and is passed straight through, but in
practice a key event is never even delivered to the callback because it is not
in the tap's mask.

### Exactly what event data strafe touches

For the gesture events it does see, strafe reads a small fixed set of fields via
the wrappers in `Sources/CStrafe/CStrafe.c` (lines ~205–225):

- CGS event type (field 55) — `strafe_event_cgs_type`
- IOHID gesture type (field 110) — `strafe_event_hid_type`
- swipe motion axis (field 123) — `strafe_event_swipe_motion`
- gesture phase (field 132) — `strafe_event_gesture_phase`
- swipe progress (field 124) — `strafe_event_swipe_progress`
- swipe velocity X (field 129) — `strafe_event_swipe_velocity_x`
- source process id — `strafe_event_source_pid`

That is the entire surface of event data strafe inspects: enough to tell a real
horizontal 3-finger space swipe from anything else, and its direction. No
coordinates, no window contents, no clipboard, no key codes.

Beyond the swipe event itself, strafe also calls `CGWindowListCopyWindowInfo`
(reading window owner names and layer numbers, to detect whether Exposé/Mission
Control is open so it can pass real swipes through — `strafe_is_expose_active`,
`Sources/CStrafe/CStrafe.c` ~line 266) and reads the current cursor location to
pick which display to switch on (`copy_cursor_display_identifier`, same file
~line 96). Neither the window list nor the cursor position is stored or
transmitted; both are read, used for that one decision, and discarded.

---

## What strafe never does

Each of these is verifiable with a single grep over `Sources/`.

- **No remote network code.** strafe never opens a TCP or UDP socket, makes an
  HTTP request, or resolves a host. It does open one owner-only Unix domain
  socket at `/tmp/strafe.sock` for the local OpenLogi integration. The server
  accepts only `switch left` and `switch right`, and returns a short local
  response after the engine handles the request
  (`Sources/strafe/ControlServer.swift`).

  ```
  grep -rniE 'URLSession|NSURL|Network|CFSocket|curl|http://|https://' Sources/
  ```

  Zero hits. The expected local socket calls are isolated in
  `Sources/strafe/ControlServer.swift`.

- **No third-party dependencies.** `Package.swift` declares no `dependencies`
  and no `.package(...)` entries — only Apple system frameworks
  (`ApplicationServices`, `CoreFoundation`, `CoreGraphics`, `IOKit`). Read the
  27-line `Package.swift` in full.

- **No analytics or telemetry.** strafe writes only to the process's own
  `stderr` (`grep -rn FileHandle.standardError Sources/`), `stdout` (the
  `strafe status` CLI readout in `Permissions.printStatus`, `Sources/strafe/Permissions.swift`
  ~line 28), and the fixed local control response described above. It never
  sends usage data to a network or analytics sink. Nothing batches, serializes,
  or transmits usage.

- **No auto-update.** strafe never downloads or executes anything. There is no
  updater, no Sparkle, no download URL (covered by the network grep above).

- **No dynamic loading.** strafe does not `dlopen`/`dlsym` anything. The private
  CGS symbols it uses are weak-imported at link time and guarded by an address
  check (`strafe_cgs_available`, `CStrafe.c` ~line 57):

  ```
  grep -rniE 'dlopen|dlsym' Sources/    # zero hits
  ```

- **No file-content access beyond its own bundle.** strafe does not read or
  write user files, preferences, caches, or databases. The only filesystem
  object it creates is the temporary owner-only Unix socket described above;
  request bytes are read from that socket and response bytes are written back
  to the connected local client.

- **No subprocess execution.** strafe spawns no processes. Unlike some prior
  art, it does **not** shell out to `tccutil` or anything else
  (`grep -rniE 'Process\(\)|/usr/bin|/bin/|tccutil' Sources/` — no spawns).

- **No persistence beyond the app itself.** strafe stores no preferences files,
  no databases, and no caches. Its temporary control socket is removed on
  normal termination and replaced on the next launch if macOS leaves a stale
  owner-matching socket (see README → Uninstall).

---

## Why strafe needs Accessibility

macOS only allows a process to create an **active** session-level event tap
(one that can suppress or modify events) if that process is trusted for
Accessibility. strafe's whole mechanism is to intercept your real 3-finger
space swipe, suppress the slow animated version, and post a synthetic
high-velocity dock swipe in its place — that requires an active tap, which
requires Accessibility. See `Sources/strafe/Permissions.swift` for the trust
check (`AXIsProcessTrusted` / `AXIsProcessTrustedWithOptions`), which is the
only permission strafe requests.

strafe does not request Input Monitoring, Full Disk Access, Screen Recording,
or any other permission.

---

## How to verify

```bash
git clone https://github.com/rileycx/strafe strafe && cd strafe

# 1. Build from source (~30s). No dependencies to resolve.
swift build

# 2. Count the codebase yourself.
wc -l Sources/strafe/*.swift Sources/CStrafe/CStrafe.c Sources/CStrafe/include/CStrafe.h

# 3. Confirm zero network / dynamic-loading / subprocess code.
grep -rniE 'URLSession|NSURL|Network|CFSocket|curl|http://|https://|dlopen|dlsym' Sources/
grep -rniE 'Process\(\)|tccutil|/usr/bin|/bin/' Sources/

# 4. Confirm the tap mask excludes keystrokes.
grep -n 'strafe_tap_event_mask' Sources/CStrafe/CStrafe.c
```

For the deep dive on exactly which private CGEvent fields are used and why, read
`docs/SPEC.md`. Caveat: `docs/SPEC.md` documents the upstream reference
implementation strafe was reimplemented from — the `tccutil` call, the second
event tap, and the key-event masking it describes are upstream-only and
intentionally absent from strafe.

---

## Reporting a vulnerability

Please report security issues through GitHub's private vulnerability reporting:
open the repository's **Security** tab and choose **Report a vulnerability**.
This keeps the report private until a fix is available. There is no email
contact for security reports.
