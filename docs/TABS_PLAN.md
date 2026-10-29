# Session tabs: research and plan

Status: phase 3 done on 2026-10-29 on branch `feature/session-tabs`. Decision: option B (our own tabs, one window holds many sessions). The phase 0 spike is in `git stash` on `spike/portal-two-surfaces`. Next: phase 4, the rest of the menus and keys.

## Phase 3 result (2026-10-29)

Branch `feature/session-tabs`, uncommitted on top of phase 2. The horizontal tab bar is in.

- New `Sources/SessionTabBar.swift`: one chip per session with favicon, name, a 6 pt status dot in `SessionStatusStyle` colors, an accent ring around the dot when a background tab has `needsInput`, and a close button (always on the active chip, on hover for the others, space kept either way). A `+` button runs `createNewTab`. The chip context menu has Rename…, Move Tab to New Window, Close Tab and Close Other Tabs. Chip style copies the doc tab bar's `TabChip`.
- New `Sources/WindowContentView.swift`: an AppKit container that holds two `NSHostingView`s, the bar on top and `WindowRootView` below, with the bar's height constraint at 0 or 32. See the finding below for why this is AppKit and not a SwiftUI `VStack`.
- `WindowRootView` is the session `ZStack` only.
- `WindowSessions.tabBarHidden` and `showsTabBar(withOneTab:)`; the `showTabBarWithOneTab` preference key (default off, no UI yet).
- `closeOtherSessions(in:keeping:)`, `promptRename(sessionId:)` for a chip's own session, and a right-click guard in `ClaudeTerminalWindow` so the bar's strip goes to the chips' context menus instead of the terminal background menu.
- `activateSession` polls for the new tab's Metal view before it sets the first responder. A fresh tab's view appears a few run-loop turns after its ContentView mounts, and one turn was not enough.

**Finding, now a hard rule.** The first version put the bar in a `VStack` above the session `ZStack`, inside one hosting view. Two things broke: the chip highlight went stale (the old tab drawn active after a switch), and when the bar disappeared on the way from two tabs to one, the window went blank, with the terminal's hosted view reporting hidden and no first responder. Both come from the known limit that CLAUDE.md records for the sidebar: SwiftUI does not reliably invalidate siblings of the Metal terminal view. Hosting the bar in its own `NSHostingView`, with the top/bottom split done by AppKit constraints, fixed both. The tree that holds the terminals must never restructure around them. CLAUDE.md and docs/ARCHITECTURE.md say so now.

Checked on a dev build:

| Check | Result |
|---|---|
| Two restored tabs | Bar shows both chips, active chip bold with fill and close button, full width above the sidebar. |
| Click a chip | Switches tab, title and focus. |
| Add a third tab | Third chip appended and active; highlight follows every later switch. |
| Click the active chip's close button | Tab closed, right neighbor active, surface freed. |
| Close down to one tab | Bar hides (height 0, hidden), the remaining terminal fills the window and keeps focus. |
| One tab at launch, then add one, then close one | Bar appears and disappears, terminal stays visible both times. |

Not checked by hand: the context menu (no right-click at the computer-use tier) and the attention ring (needs a real `needsInput`). Both are small view code.

## Phase 2 result (2026-10-29)

Branch `feature/session-tabs`, uncommitted on top of phase 1. A window now holds several sessions. There is no tab bar yet, so the only way to see the tabs is the window title and the keys.

- New `Sources/AppDelegate+SessionLifecycle.swift`: `createWindow`, `openWindow`, `addSession`, `activateSession`, `focusTerminal`, `closeSession`, `closeSession(forTab:)` and `moveSessionToNewWindow`. `installWindow` is gone.
- New `Sources/WindowRootView.swift`: a `ZStack` of one `ContentView` per session, keyed by session id, with only the active one visible, hit-testable and on top. The switch crossfades over 150 ms.
- `activateSession` sets the title and, on the next run-loop turn, makes the session's `GhosttyNSView` the first responder. The Metal view, not the scroll view around it: the vendored `performKeyEquivalent` acts only when the first responder is inside `GhosttyNSView`.
- `closeSession` activates the neighbor to the right, or to the left at the end of the row, then drops the record one run-loop turn later so SwiftUI unmounts the view first. The last tab closes the window.
- `TabManager.closePanelAfterChildExited` closes one tab. A tab whose `claude` exits with status 0 closes itself and the window stays.
- `restoreWindow` reopens every session of a snapshot and activates `activeIndex`.
- `focusSession` (menu bar popover) activates the tab, then brings the window to the front.
- Pulled forward from phase 4, because the lifecycle needed entry points: File > New Tab (Cmd+T), Close Tab (Cmd+W), Close Window (Cmd+Shift+W); Window > Show Next Tab (Cmd+Shift+]), Show Previous Tab (Cmd+Shift+[), Move Tab to New Window. Cmd+1 to 9, Ctrl+Tab, Toggle Tab Bar and the window-list renumbering are still phase 4.
- New Tab rule: the picker starts at the active session's directory, and when the chosen directory is already open in a live session, `--continue` is dropped so two tabs never resume one conversation.
- New `Sources/AppDelegate+DevCommands.swift`: a dev-instance-only command file (`new-tab`, `close-tab`, `next`, `prev`, `activate`, `move-new-window`, `close-window`, `save`, `status`, `quit`) with a status report after each command. The computer-use tier for terminal apps allows no keyboard input, so this is how a dev build gets checked. Recipe in CONTRIBUTING.md.

Checked on a dev build, with the status report after each step:

| Check | Result |
|---|---|
| Restore a two-tab snapshot with `activeIndex` 1 | Pass. Title `tab-b`, focus inside its Metal view, `tab-a` mounted hidden. |
| Previous tab | Pass. `tab-a` active, title and focus follow. |
| New tab | Pass. Third tab appended and active. 3 sessions, 3 surfaces. |
| Close tab at the end of the row | Pass. Left neighbor active. 2 surfaces: the closed one is freed. |
| Tab whose `claude --version` exits at once | Pass. Only that tab closed; the window stayed with 2 tabs. |
| Move tab to new window | Pass. New window 40 pt offset, surface re-parented and rendering, focus inside it. The vendored code never calls `unbind`, so re-parenting is a plain `bind()` to the new host. |
| Close one of the two windows | Pass. Its session unregistered, 1 surface left. |
| Save with three tabs | Pass. Payload lists all three in order with `activeIndex` 0 and the sidebar settings. |

Found on the way: `resolveFrontWindow()` falls back to an arbitrary window when the app is not active, because `NSApp.keyWindow` and `NSApp.mainWindow` are both nil then. Menu commands cannot fire while the app is inactive, so this only matters for the URL-scheme and open-file paths, as it did before tabs.

## Phase 1 result (2026-10-29)

Branch `feature/session-tabs`, uncommitted. One session per window still, but every piece of session state now has a `sessionId` key.

- New `Sources/SessionTabs.swift`: `SessionConfig`, `WindowSnapshot` (format version 2, with a converter from the version 1 `WindowConfig`), `SessionRecord` and `WindowSessions`. `SessionRecord.makeSurface` holds the terminal setup that used to live in `ContentView.init`.
- New `Sources/SessionStatusStyle.swift`: the status colors and labels the popover used, now shared.
- `AppDelegate`: `sessions`, `sessionIdForTab`, `windowSessions`, `colorPanelSessionId`; `sessionMonitors`, `documentTabStates` and `windowConfigs` are gone. New helpers `windowId(forSession:)`, `window(forSession:)`, `activeSession(in:)`, `frontSession()`, `session(forTab:)`, `makeSessionRecord`, `registerSession`, `unregisterSession`.
- `ContentView` takes a `SessionRecord` and an `isActiveSession` flag. It no longer builds the surface.
- Terminal background code is keyed by session and finds the Metal view through the session's own hosted view, never "the first surface in this window".
- `tabManagerFor(window:)` returns the active session's manager.
- Persistence (planned as phase 7) came forward: Save & Quit writes `[WindowSnapshot]`, restore reads version 2 first and converts version 1. Checked both ways on a dev build: a hand-written version 1 payload restored with its name, sidebar width and doc tab; Save & Quit then wrote version 2 with `activeIndex`, `railWidth` and the session list, and that restored the same window.
- Closing the window runs `unregisterSession` for each session of that window. No crash.
- Dev-build affordance kept from the spike: `CLAUDE_TERMINAL_DEV_INSTANCE=1` skips the single-instance lock and the CLI symlink installer, so a build with its own bundle id can run next to the release app. Recipe in CONTRIBUTING.md.

Not done in phase 1, by design: `restoreWindow` reopens only the first session of a snapshot, and `TabManager.closePanelAfterChildExited` still closes the window. Both wait for `addSession` and `closeSession` in phase 2.

## Phase 0 result (2026-10-29)

Branch `spike/portal-two-surfaces`. Two sessions in one window in a `ZStack`, the inactive one at opacity 0 with hit testing off and `isActive` / `isVisibleInUI` false. Driven by a command file because the computer-use tier for terminal apps allows no keyboard input.

| Check | Result |
|---|---|
| Both terminals render | Pass. A and B each show their own Claude with the right sidebar. |
| Only the active one has focus | Pass with one fix, see below. |
| Resize while B hidden, then show B | Pass. B came back at the new size (615×468 for a 900×500 window). No stale frame, no garbage. |
| 20 switches, memory | Pass. RSS 152,432 KB before and after. |
| Close the window | Pass. `windows=0 surfaces=0` after close, process alive, no crash report. |
| Hidden sidebar does not take clicks | Pass. A click on B's Documents header position while A was in front left B's section open. |

Findings that change the plan:

1. **Focus does not move on its own.** After a switch, `window.firstResponder` fell to `ClaudeTerminalWindow`. The vendored coordinator drops focus from the hidden surface but does not give it to the new one. `activateSession` must call `window.makeFirstResponder(surface.hostedView)`. That call returned true and put the first responder inside the new surface every time. Phase 2 already lists this; it is now a must, not a check.
2. **Window title stayed on the first session's name** during the whole test. Expected. Phase 2 sets the title in `activateSession`.
3. **Stored `ContentView` values are safe.** The spike holds the two `ContentView`s as `let` properties of the root view, so their `init` ran once. Re-renders of the root did not create new surfaces. The real `ForEach` must get the same guarantee by moving the surface into `SessionRecord` (phase 1).
4. **A spike build can run next to the release app** with `PRODUCT_BUNDLE_IDENTIFIER=org.claire.claude-terminal.spike`, `CLAUDE_TERMINAL_SPIKE=1` to skip the single-instance lock, and `open --env` so the process gets a WindowServer connection. The CLI symlink installer must be skipped in that mode or it repoints `~/.local/bin/claude-terminal`. The branch has both guards. Keep them for phase 8 testing.

The fallback design is not needed.

## Goal

Add tabs so one window can hold many Claude sessions. A setting picks where the tab bar goes: along the top (horizontal) or on the left (vertical), as Warp does.

## Prior art

### Warp

- Open source: `github.com/warpdotdev/warp`. Rust. AGPL-3.0.
- Setting: `appearance.vertical_tabs.enabled` in `app/src/workspace/tab_settings.rs`. Other settings under `appearance.vertical_tabs.*`: `view_mode`, `display_granularity`, `tab_item_mode`, `primary_info`, `compact_subtitle`.
- Panel code: `app/src/workspace/view/vertical_tabs.rs` (about 286 KB).
- Persistence migration `2026-03-27-075600_add_vertical_tabs_panel_open_to_windows` saves whether the panel is open for each window.
- Features worth a look:
  - Compact and expanded modes. You choose the primary line: title, subtitle, or git branch.
  - Each row shows agent conversation status, including for Claude Code sessions. Rows with a known status sort first.
  - Tab groups with colors.
  - Drag tabs between windows. The horizontal and vertical bars share the drag code.
  - A detail panel opens on hover.
- Design specs live in `specs/APP-*/TECH.md` in that repo. Search them for `vertical_tabs`.

### iTerm2

- `github.com/gnachman/iTerm2`. Objective-C and Swift. GPL-2.0.
- The tab bar is a fork of PSMTabBarControl.
- Settings > Appearance: the tab bar can go at the top, the bottom, or the left. Left gives vertical tabs.
- Layout code: `sources/TerminalView/iTermLayoutCalculator.m` and `sources/TerminalView/iTermRootTerminalView.m`. Preference keys are in `sources/Settings/iTermPreferences.h`.

### License

Our repo is MIT. Warp is AGPL and iTerm2 is GPL. Read their code for design ideas only. Do not copy their code.

## Our code today

- Each `NSWindow` (`ClaudeTerminalWindow`) holds one Claude session.
- `AppDelegate.installWindow` (`Sources/AppDelegate.swift:219`) makes a new `windowId`, `tabId` and `sessionId` for each window. It stores state in dictionaries keyed by `windowId`: `windows`, `sessionMonitors`, `sidebarStates`, `documentTabStates`, `windowConfigs`, `customTerminalBackgrounds`. `tabManagers` is keyed by `tabId`.
- `ContentView` builds the `TerminalSurface` and the sidebar for one session.
- `TerminalTabBar.swift` and `DocumentTabState.swift` already exist. They hold document tabs (markdown and images) inside one session. The new session tabs need different names, for example `SessionTabBar` and `WindowSessionsState`.
- `AppDelegate.swift:58` sets `NSWindow.allowsAutomaticWindowTabbing = false`. Keep it off.
- Window restore is in `AppDelegate+WindowRestore.swift`. It saves one session for each window.
- Read `docs/ARCHITECTURE.md` before structural changes, mainly the portal system section.

## Why not native macOS window tabs (option A)

Native tabs are cheap: each session keeps its own window. But AppKit shows the tabs only along the top, so this option gives no vertical tabs.

## Facts that shape the plan

These come from reading the code. Each one changes a step below.

- **Key routing.** `GhosttyTerminalView.performKeyEquivalent` (vendored, line 6421) asks libghostty if a key matches a Ghostty binding. If it does, and the binding is of the "consumed" kind, it offers the key to `NSApp.mainMenu` first and only then lets Ghostty act. Ghostty's default bindings cover Cmd+T, Cmd+W, Cmd+Shift+W, Cmd+Shift+] and [, Ctrl+Tab, Ctrl+Shift+Tab and Cmd+1 to Cmd+9. So a menu item with the same key equivalent wins, and no change to the vendored file is needed. A key with no menu item falls through to Ghostty, which then emits a `new_tab` or `goto_tab` action that our host ignores. Every tab command must have a menu item.
- **Cmd+1 to Cmd+9 is taken.** `AppDelegate+NSMenuDelegate.swift` gives the first nine windows Cmd+1 to Cmd+9 in the Window menu. Tabs need those keys. Windows move to Cmd+Opt+1 to Cmd+Opt+9.
- **`ContentView.init` builds the `TerminalSurface` eagerly.** `ContentView.swift:65` creates the surface and then wraps it in `StateObject(wrappedValue:)`. Today `ContentView` is the window's root, so `init` runs once. Inside a `ForEach`, SwiftUI runs `init` on every parent re-render, and each run would make a new surface. The surface must move out of the view into a per-session object that `AppDelegate` creates once.
- **Four sites find "the surface in this window".** `AppDelegate+MainMenu.swift:116` (`findInDoc`) and three sites in `AppDelegate+TerminalBackground.swift` (lines 224, 254, 338) pick the first `TerminalSurface` whose `hostedView.window` is the window. With tabs there are several. `TerminalSurface` carries the `tabId` it was created with, so look up by `tabId`.
- **`TabManager.closePanelAfterChildExited` closes the window.** `Types.swift:303`. When Claude exits with status 0 the window closes. With tabs it must close one tab.
- **`tabManagerFor(window:)` returns the first `TabManager` in the window.** `AppDelegate+GhosttyStubs.swift:12`. It must return the active tab's.
- **Window title and frame autosave key come from the session name.** `AppDelegate.swift:252` and `:260`. With tabs the title follows the active tab. The autosave key must not change when the active tab changes.
- **The menu bar popover and `SessionListViewModel` use `windowId` as the session id.** `SessionEntry.id` is the `windowId`, and `handleTap` calls `focusWindow(windowId:)`. Both must switch to `sessionId`.
- **Window restore saves one `WindowConfig` for each window** under the `savedWindows` key. The new format must still read the old one.
- **`SessionState.needsInput`** exists already. The tab bar uses it for the attention marker.
- **Status colors** live in `MenuBarPopoverView.statusColor`. The tab bar needs the same colors, so they move to a shared place.
- **Per-directory stores stay as they are.** Danger flag, custom background hex and `sessionName-<dir>` are keyed by directory, not by window.

## Implementation plan

Eight phases. Phases 0 to 3 are one PR and deliver working horizontal tabs with keys. Phases 4 to 7 can each be their own PR. Do not start phase 1 until phase 0 passes.

### Phase 0: Portal spike

Goal: prove that one window can hold two Ghostty surfaces, with one visible, before any refactor.

1. On a scratch branch, in `installWindow`, build two `ContentView`s with two sessions and put them in a `ZStack`. Give each `.opacity(active ? 1 : 0)` and `.allowsHitTesting(active)`. Pass `isActive: active && activeDocTab == nil` and `isVisibleInUI:` the same into `GhosttyTerminalView`.
2. Add a temporary menu item on Cmd+Opt+T that flips the active one.
3. Check all of these:
   - Both terminals render. Neither window area is black.
   - Typing goes to the visible terminal and only to it.
   - Resize the window while tab B is hidden. Switch to B. B has the new size with no stale frame and no garbage.
   - Switch back and forth twenty times. No crash, no leak that grows with each switch (watch memory in Activity Monitor).
   - Close the window. Both surfaces tear down. No crash.
   - Sidebar for the hidden tab does not steal clicks.
4. Record the result at the top of this file.

How it should work: `TerminalWindowPortalRegistry.bind(hostedView:to:visibleInUI:...)` in `Types.swift:695` sets `hostedView.isHidden = !visibleInUI`. The vendored coordinator reads `desiredIsActive` and `desiredIsVisibleInUI` (line 12312) and stops rendering and drops focus for a hidden surface. Doc tabs already use this path with one surface, so the odds are good.

If it fails: the fallback is "one window per session, our own tab bar orders and shows the windows". Each tab stays an `NSWindow`; the tab bar in window A lists A and its siblings and brings the chosen one to the front at the same frame. This keeps the vertical bar option. It costs a window per tab and a frame-sync hack. Only take it if phase 0 fails.

### Phase 1: Models and state split

New file `Sources/SessionTabs.swift`:

```swift
/// Everything the app keeps for one Claude session. Created once by
/// AppDelegate.addSession and never rebuilt by SwiftUI.
final class SessionRecord {
    let sessionId: UUID
    let tabId: UUID            // Ghostty surface id, same as today
    let monitor: SessionMonitor
    let tabState: DocumentTabState
    let surface: TerminalSurface   // moved out of ContentView.init
    var config: SessionConfig
}

/// The ordered tabs of one window and which one is in front.
final class WindowSessions: ObservableObject {
    let windowId: UUID
    @Published var sessionIds: [UUID]
    @Published var activeSessionId: UUID
    @Published var railWidth: CGFloat   // vertical tab bar, per window
}
```

`AppDelegate` dictionaries after the split:

| Key | Dictionaries |
|---|---|
| `windowId` | `windows`, `sidebarStates`, `windowSessions: [UUID: WindowSessions]` |
| `sessionId` | `sessions: [UUID: SessionRecord]`, `customTerminalBackgrounds`, `terminalBackgroundObservations`, `terminalBackgroundApplyInProgress`, `terminalBackgroundReapplyTimestamps`, `terminalBackgroundReapplyTripped` |
| `tabId` | `tabManagers` (unchanged) plus `sessionIdForTab: [UUID: UUID]` |

`sessionMonitors`, `documentTabStates` and `windowConfigs` go away. `SessionRecord` holds those three. `colorPanelWindowId` becomes `colorPanelSessionId`.

Helpers on `AppDelegate`:

- `windowId(forSession:) -> UUID?`
- `activeSession(in windowId:) -> SessionRecord?`
- `frontSession() -> (windowId: UUID, record: SessionRecord)?`. This replaces `resolveFrontWindow()` at every call site that wants a session: `findInDoc`, `frontTabState`, `renameSession`, `handleOpenFile`, the two terminal background menu actions. `toggleSidebar` keeps `resolveFrontWindow()` because the sidebar is per window.
- `surface(forSession:) -> TerminalSurface?` for the four "surface in this window" sites.

`WindowConfig` splits in two. `SessionConfig` keeps `workingDirectory`, `claudeOptions`, `sessionName`, `openDocs`, `activeDocPath`, `customBackgroundHex`. `WindowSnapshot` holds `sessions: [SessionConfig]`, `activeIndex`, `sidebarVisible`, `sidebarWidth`, `railWidth`. Keep the old `WindowConfig` type, marked legacy, for decoding.

Move `statusColor` and `statusLabel` from `MenuBarPopoverView` into a new `SessionStatusStyle` enum in `SidebarFormatting.swift` or its own file. The tab bar and the popover both call it.

### Phase 2: Window and session lifecycle

Split `installWindow` into two functions.

`createWindow(sidebarVisible:sidebarWidth:railWidth:) -> UUID`:
- Builds the `ClaudeTerminalWindow`, `SidebarState` and `WindowSessions` with no sessions yet.
- Sets `contentView` to an `NSHostingView<WindowRootView>` with an explicit frame (phase 3).
- Does not call `setFrameAutosaveName` yet.

`addSession(to windowId: UUID, workingDirectory:claudeOptions:sessionName:storedConfig:) -> UUID`:
- Does what `installWindow` does today for one session: new `sessionId` and `tabId`, `SessionMonitor`, `DocumentTabState`, `TabManager`, the `TerminalSurface` (moved from `ContentView.init`, same config template code), and the per-directory background lookup.
- Appends to `windowSessions[windowId].sessionIds`, sets it active.
- On the first session of a window, calls `window.setFrameAutosaveName("claude-terminal-\(name)")` and centers if no saved frame. Later tabs do not touch it.
- Posts `.sessionListDidChange` and the existing print line.

`closeSession(_ sessionId: UUID)`:
- Stops the monitor, invalidates the background observation, removes all `sessionId` entries, removes the `tabManagers` entry and `sessionIdForTab`.
- Removes the id from `WindowSessions.sessionIds`. If it was active, activates the tab to its right, else the one to its left (Safari order).
- If the list is now empty, calls `window.close()`. `windowWillClose` then does only window-level cleanup, plus a sweep that closes any session still listed for that window, so the two paths cannot double-free.

`activateSession(_ sessionId: UUID)`:
- Sets `activeSessionId`, sets `window.title` to that session's name, makes the window key, and asks the surface for first responder (`window.makeFirstResponder(record.surface.hostedView)`; confirm the exact view in phase 0).

`moveSessionToNewWindow(_ sessionId: UUID)`:
- `createWindow` with the source window's sidebar settings, then re-parent the `SessionRecord`: remove the id from the old `WindowSessions`, append to the new one. The `TerminalSurface` is the same object, so the portal re-binds when the new `ContentView` mounts. Test that the portal survives re-parenting; if not, this item moves to "Later".

Other changes in this phase:
- `TabManager.closePanelAfterChildExited` calls `AppDelegate.shared?.closeSession(forTab: tabId)` instead of `window?.close()`. `TabManager` already stores `tabId`.
- `tabManagerFor(window:)` returns the active session's manager: `windowSessions` for that window, then `tabManagers[record.tabId]`.
- Window title: `activateSession` sets it. `ContentView.onChange(of: monitor.state.sessionName)` sets it only when its session is active.
- `renameSession` acts on `frontSession()` and updates the title the same way.
- `handleOpenFile` opens the doc in the front window's active session.
- `applicationShouldTerminate` counts sessions, not windows, in the alert text.

### Phase 3: Root view and horizontal tab bar

New `Sources/WindowRootView.swift`:

```swift
struct WindowRootView: View {
    @ObservedObject var sessions: WindowSessions
    @ObservedObject var sidebarState: SidebarState
    @AppStorage("tabBarPosition") var position = "top"   // "top" | "left"
    @AppStorage("showTabBarWithOneTab") var alwaysShowTabBar = false

    var body: some View {
        HStack(spacing: 0) {
            if position == "left" && showBar { SessionTabRail(sessions: sessions) ; RailDragHandle(...) }
            VStack(spacing: 0) {
                if position == "top" && showBar { SessionTabBar(sessions: sessions) }
                ZStack {
                    ForEach(sessions.sessionIds, id: \.self) { id in
                        if let record = AppDelegate.shared?.sessions[id] {
                            ContentView(record: record, sidebarState: sidebarState,
                                        isActiveSession: id == sessions.activeSessionId)
                                .opacity(id == sessions.activeSessionId ? 1 : 0)
                                .allowsHitTesting(id == sessions.activeSessionId)
                        }
                    }
                }
            }
        }
    }
    var showBar: Bool { alwaysShowTabBar || sessions.sessionIds.count > 1 }
}
```

- `ContentView` takes a `SessionRecord` and an `isActiveSession` flag. It no longer builds the surface. `GhosttyTerminalView` gets `isActive: isActiveSession && activeDocTab == nil` and the same for `isVisibleInUI`.
- The tab bar spans the full window width, above the sidebar too. It is window chrome, not session content.
- `ForEach` keyed by `sessionId` keeps each `ContentView`'s identity stable, so `SidebarHostView` scroll state and doc viewers survive a switch.
- Crossfade: wrap the opacity change in `withAnimation(.easeInOut(duration: 0.15))` inside `activateSession`. If the Metal layer flickers during the fade, move the animation to the sidebar only (an `isActiveSession`-driven opacity inside `ContentView` around `SidebarHostView`) and switch the terminal with no animation.
- `ClaudeTerminalWindow.isInsideSidebar` keeps working because `SidebarHostView` is unchanged. Add the same check for the tab bar so a right-click on a tab shows the tab context menu, not the terminal background menu.

New `Sources/SessionTabBar.swift` (horizontal):

- One chip per session: favicon from `FaviconLoader.favicon(for:size:)` at 14 pt, the name, a 6 pt status dot in `SessionStatusStyle` color, and a close button that appears on hover. When `needsInput == true` and the tab is not active, the dot becomes a filled ring in the accent color.
- A `+` button at the end calls the same action as Cmd+T.
- Chip style copies `TabChip` in `TerminalTabBar.swift` so the two bars look like one family. Do not share the type; the doc chip and the session chip will drift apart.
- Context menu on a chip: Rename…, Close Tab, Close Other Tabs, Move Tab to New Window.
- Height 32 pt, `VisualEffectBackground(material: .titlebar)`, 1 pt separator under it, same as the doc tab bar.
- Hidden when the window has one tab, unless the `showTabBarWithOneTab` preference is on. This resolves the open question: a single session looks the same as today.

### Phase 4: Menus and keybinds

All items are `NSMenuItem`s so the Ghostty key path hands them to us. Add `validateMenuItem` on `AppDelegate` to disable tab navigation when the front window has one tab.

| Key | Command | Menu | Notes |
|---|---|---|---|
| Cmd+T | New Tab | File | Runs the working-directory picker with the active session's directory as the start point. Same `--continue` and danger logic as a new window. This answers the open question: yes, the picker runs. A later preference can skip it. |
| Cmd+N | New Window | File | Unchanged. |
| Cmd+W | Close Tab | File | Closes the active tab. On the last tab it closes the window, same as today. Title changes to "Close Tab" when the window has more than one tab, else "Close Window". |
| Cmd+Shift+W | Close Window | File | Closes every tab in the window. New item. |
| Cmd+Shift+] | Show Next Tab | Window | Wraps around. |
| Cmd+Shift+[ | Show Previous Tab | Window | Wraps around. |
| Ctrl+Tab | Show Next Tab | Window | Second key equivalent on a hidden duplicate item. Key equivalent is `"\t"` with `.control`. |
| Ctrl+Shift+Tab | Show Previous Tab | Window | Same, with `[.control, .shift]`. |
| Cmd+1 to Cmd+8 | Select tab 1 to 8 | Window | Items are rebuilt in `menuNeedsUpdate` like the window list is today. |
| Cmd+9 | Select last tab | Window | Safari, Chrome and Ghostty all do this. |
| Cmd+Opt+1 to Cmd+Opt+9 | Select window 1 to 9 | Window | The window list moves here. Titles show the active tab's name and a tab count, for example "api (3 tabs)". |
| Cmd+Shift+R | Rename Session… | View | Exists. Acts on the active tab. The sidebar pencil icon posts `.renameSession` and lands here too. |
| Cmd+B | Toggle Sidebar | View | Exists. Per window. |
| Cmd+Shift+B | Toggle Tab Bar | View | Shows or hides the bar or rail for this window, on top of the position setting. State lives in `WindowSessions`. |
| none | Move Tab to New Window | Window | Context menu on the chip as well. |
| none | Tab Bar Position > Top / Left | View | Writes `tabBarPosition`. Every window follows at once through `@AppStorage`. |

Keys this plan does not take, and why:

- Cmd+Shift+T is "reopen closed tab" in every browser. Reserve it for that in "Later".
- Cmd+Opt+] and Cmd+Opt+[ stay free for doc-tab navigation inside a session, which has no keys today.
- Cmd+` is "Cycle Through Windows" in AppKit. Our Window menu is hand built, so this does not work today. Adding a standard "Cycle Through Windows" item is a small separate fix, not part of tabs.

Where each lives in code: `makeFileSubmenu` gets New Tab, Close Tab and Close Window. `makeViewSubmenu` gets Toggle Tab Bar and the Tab Bar Position submenu. `makeWindowSubmenu` and `menuNeedsUpdate` get the tab items and the renumbered window list. New `@objc` actions: `newTabFromMenu`, `closeTabFromMenu`, `closeWindowFromMenu`, `showNextTab`, `showPreviousTab`, `selectTab(_:)`, `selectLastTab`, `toggleTabBar`, `moveTabToNewWindow`, `setTabBarPosition(_:)`.

### Phase 5: Menu bar popover, session list, notifications

- `SessionEntry.id` becomes the `sessionId`. `activeSessionSnapshots()` returns `(sessionId, windowId, monitor)`.
- `focusWindow(windowId:)` becomes `focusSession(sessionId:)`: find the window, `activateSession`, make it key, activate the app.
- `SessionListViewModel.rebuildSessions` already excludes active ids from the past-session scan by `monitor.sessionId`, so that part needs no change once the entry id is the session id.
- The popover row can show which window a session is in only when there is more than one window. Skip this in the first version.
- `ActivityChartView`, `GitHubStatusMonitor`, `PreferencesView`, `SidebarDocumentsSection` and `SidebarView` mention `windows` once each. Check each. Most are `NSApp.windows`, not the dictionary.

### Phase 6: Vertical tab rail and preferences

New `Sources/SessionTabRail.swift`:

- A left panel, 180 to 320 pt, resizable by a drag handle. Width lives in `WindowSessions.railWidth` and is saved in the window snapshot. Default 220.
- Rows are compact: favicon, name, one subtitle line (abbreviated directory, the same `abbreviatePath` the sidebar uses), and the status dot on the right. No cost or context in the row. See "Vertical mode" below.
- The active row has the `controlBackgroundColor` fill and separator stroke that the chips use.
- Rows that need input can sort first. Make this a later toggle. Default is tab order, because keys 1 to 9 must match what the eye sees.
- A `+` row at the bottom.
- Same context menu as the chips.

Generalize `SidebarDragHandle` into a handle that takes a direction and a binding, so the rail and the sidebar share one implementation.

`PreferencesView` gets a "Tabs" section:

- Picker "Tab bar position": Top, Left. Key `tabBarPosition`.
- Toggle "Show tab bar with a single tab". Key `showTabBarWithOneTab`, default off.

### Phase 7: Persistence and migration

- `saveWindowConfigs` writes `[WindowSnapshot]` to the `savedWindows` key with a `"version": 2` field on each snapshot. One `SessionConfig` per tab, in tab order, plus `activeIndex`.
- `restoreSavedWindows` decodes `[WindowSnapshot]` first. On failure it decodes `[WindowConfig]` and maps each to a snapshot with one session and `activeIndex 0`. Both paths clear the key before returning, as today, so a crash on launch cannot loop.
- `restoreWindow(snapshot:)` calls `createWindow`, then `addSession` for each config with the `--continue` merge that `applicationDidFinishLaunching` does today, then `activateSession` for `activeIndex`. Doc tabs restore per session the same way as now.
- Nothing else changes. The per-directory stores are already keyed by directory.

### Phase 8: Checks, docs, release

Manual checklist before the first release with tabs:

1. Open two tabs in one window. Type in each. Output goes to the right one.
2. Resize the window on tab A. Switch to B. B fits the window.
3. Cmd+W on the last tab closes the window. Cmd+W with two tabs closes one and the neighbor becomes active.
4. Cmd+1, Cmd+9, Cmd+Shift+], Ctrl+Tab all switch tabs. Cmd+Opt+1 switches windows.
5. Rename on tab B updates the chip and the window title. Switch to A and the title is A's name.
6. Set a custom terminal background on tab B only. Tab A keeps its color. Quit and relaunch; B keeps it.
7. Let Claude exit with status 0 in tab B. Only tab B closes.
8. Save & Quit with two windows, three tabs total. Relaunch restores both windows, every tab, the active tab in each, and the open doc tabs.
9. Put a v1 `savedWindows` payload in UserDefaults and launch. One window per entry, one tab each.
10. Menu bar popover lists every tab. Clicking one brings its window forward and selects the tab.
11. Toggle sidebar on a two-tab window. Both tabs follow. Resize the sidebar. Both tabs follow.
12. Tab Bar Position set to Left. All open windows switch. Rail width survives Save & Quit.
13. Move Tab to New Window. The terminal keeps running and keeps its scrollback.
14. `needsInput` on a background tab shows the attention ring. Switching to it clears it.

Docs to update in the same PRs: `docs/ARCHITECTURE.md` (file map, the per-session dictionaries, a note under "Portal system" that one window now holds several surfaces, the key routing fact above), `README.md` (keyboard shortcuts), and `CLAUDE.md` if a new hard rule comes out of phase 0.

### Later

- Reopen Closed Tab, Cmd+Shift+T. Needs a per-window stack of closed `SessionConfig`s.
- Drag to reorder tabs. Drag tabs between windows.
- Expanded rail rows with cost and context, as a setting.
- Hover detail card on a tab.
- Tab groups and colors.
- A preference to skip the picker on Cmd+T and open the active session's directory with `--continue`.
- `claude-terminal://` URL parameter to open in a tab of the front window instead of a new window.

## Sidebar behavior when tabs switch

Question: when the user switches tabs, does the sidebar swap its content, and will that confuse people?

Decision: swap the content. Keep the sidebar as a single-session inspector. Put "what are the other tabs doing" in the tab bar.

### Why swap

- Every section in the sidebar is about one session: name, folder, Jira ticket, model, status, PR, subagents, tasks, documents, context, cost and network. Only the GitHub status badge is global. There is no mixed content to keep.
- Apple HIG (Panels) defines an inspector as a view that "displays the details of the currently selected item, automatically updating its contents when the item changes". Xcode, Finder and Keynote work this way. Users on macOS expect it.
- Terminal and agent apps do the same. iTerm2's toolbelt is per window and its tools follow the active session. VS Code's chat view shows the selected agent session and swaps when you pick another one.
- The other option, a global sidebar that stacks all sessions, fails on size. One session's sidebar can fill the window height on its own. In vertical-tab mode the window would also hold two session lists, one left and one right.

### Where the confusion would come from, and the fix for each

The swap itself is not the problem. These four things are.

1. **Layout jumps.** The sidebar is open in tab 1 and closed in tab 2, or the width differs. The terminal resizes on every switch and the eye loses its place.
   Fix: visibility, width and section collapse state are per window, not per tab. This matches today's code (`SidebarState` per window, `sidebarWidth` in UserDefaults, `documentsCollapsed` and `contextDetailsExpanded` in `@AppStorage`). Xcode keeps navigator and inspector visibility per window too. Chrome's tab-specific side panels, which hide and show per tab, are the counter-example, and that is the behavior to avoid. Cmd+Opt+S toggles the sidebar for the whole window.

2. **Change blindness.** The user switches tabs, the sidebar changes at the same instant as the terminal, and they read cost or context numbers that belong to the other session.
   Fix: a strong identity cue at the top and a short animated change. The sidebar header already shows the favicon and session name. The selected tab shows the same favicon and name, so the two match by eye. On a switch, crossfade the sidebar content over about 150 ms (`.transition(.opacity)`, no slide). NN/g's change-blindness guidance says the same: animate the change, keep it near the point of focus, and avoid a hard reload.

3. **Losing track of the other sessions.** The user wants to know if tab 3 is waiting for input without going there.
   Fix: that is the tab bar's job. Each tab gets a status dot with the same colors as the menu bar popover (`statusColor` in `MenuBarPopoverView`) and an attention marker for "needs input". Warp and VS Code both do this with a badge on the row and a dot for unread activity. In vertical mode the rows carry name, branch and status, like Warp's compact rows. Rows that need attention can sort first. The sidebar stays single-session.

4. **Lost per-session state.** Scroll position, an expanded tool detail, or the selected document in the sidebar reset on each switch.
   Fix: keep one `SidebarHostView` per session inside its `ContentView`, as today, and hide the inactive ones with the rest of the session's view. State then survives a switch with no extra code. All of them share the window's `SidebarState`.

### Vertical mode

The left panel answers "which session". The right sidebar answers "what is this session doing". They do not duplicate each other if the left rows stay compact: icon, name, subtitle and a status dot. Do not put cost or context in the rows by default. Three columns of text is too much. An expanded row mode can come later as a setting.

### Later

- A hover detail card on a tab, as Warp does. It shows status, branch, cost and context for a tab without switching to it. This covers most of the "what is that tab doing" cases.
- Per-tab sidebar visibility as an option. Not for the first version.

## Open questions

- Vertical tab style: Warp's rich status rows with a compact mode, or iTerm2's simple style with a title and an activity dot? Leaning compact rows with a status dot, see "Vertical mode" above.
- Should the horizontal bar hide when a window has only one tab?
- Should `--continue` and the working-directory picker run when you open a new tab, the same as for a new window?
- Should a tab's accent color, if tab colors come later, tint the sidebar header too? It would tie the two together with no text.
