# Menu-Bar Status Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render aggregate runner status changes as one reliable `MenuBarExtra` image and stop the Working pulse when macOS Reduce Motion is enabled.

**Architecture:** Keep status aggregation in `AmpRunnerCore`. Replace the menu-bar label's custom layout with a direct `Image(nsImage:)` produced by `ImageRenderer`. An animation timeline supplies the pulse phase only while Working and Reduce Motion is disabled.

**Tech Stack:** Swift 5, SwiftUI, AppKit, XcodeGen, XCTest

---

### Task 1: Render the status label as one image

**Files:**
- Modify: `App/AmpRunnerApp.swift:35-108`
- Verify: `Tests/AmpRunnerCoreTests/RunnerStatusTests.swift`

- [ ] **Step 1: Replace the custom menu-bar label layout**

Change `MenuBarLabelView.body` to use an animation timeline whose content is a direct image:

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion

var body: some View {
    TimelineView(
        .animation(
            minimumInterval: 1.0 / 15.0,
            paused: aggregateStatus != .working || reduceMotion
        )
    ) { context in
        Image(nsImage: renderedIcon(at: context.date))
            .accessibilityLabel("Amp Runner: \(aggregateStatus.accessibilityDescription)")
    }
}
```

Remove `isWorkingPulseVisible`, `statusDot`, `mintColor`, and `updateWorkingPulse(for:)` from `MenuBarLabelView`. Retain `aggregateStatus` unchanged.

- [ ] **Step 2: Add the composite artwork view**

Add a private `MenuBarStatusArtwork` beside `MenuBarLabelView`. It owns the existing mark, dot shapes, dimensions, colors, and stopped opacity. Accept `status`, `colorScheme`, and `workingPulseOpacity` as immutable inputs. Give the artwork a fixed logical size so `ImageRenderer` produces a stable menu-bar image.

```swift
private struct MenuBarStatusArtwork: View {
    let status: RunnerAggregateStatus
    let colorScheme: ColorScheme
    let workingPulseOpacity: Double

    var body: some View {
        HStack(spacing: 3) {
            Image("MenubarTemplate")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(menuBarForegroundColor)
                .frame(width: 17, height: 17)
                .opacity(status == .stopped ? 0.45 : 1)
            statusDot
        }
        .frame(height: 18)
        .fixedSize()
    }

    @ViewBuilder
    private var statusDot: some View {
        switch status {
        case .stopped:
            EmptyView()
        case .starting:
            Circle().stroke(mintColor, lineWidth: 1.2).frame(width: 5, height: 5)
        case .online:
            Circle().fill(mintColor).frame(width: 5, height: 5)
        case .working:
            Circle()
                .fill(mintColor)
                .frame(width: 7, height: 7)
                .background {
                    Circle()
                        .fill(mintColor.opacity(workingPulseOpacity))
                        .frame(width: 12, height: 12)
                }
        case .error:
            Circle().fill(Color(nsColor: .systemRed)).frame(width: 5, height: 5)
        }
    }

    private var menuBarForegroundColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var mintColor: Color {
        colorScheme == .dark
            ? Color(red: 0.353, green: 0.820, blue: 0.659)
            : Color(red: 0.184, green: 0.561, blue: 0.427)
    }
}
```

- [ ] **Step 3: Render pulse frames and honor Reduce Motion**

Add these methods to `MenuBarLabelView`. The renderer creates a two-scale transparent `NSImage`; the pulse follows the original 1.4-second autoreversing cadence. Reduce Motion locks the halo at its quiet opacity.

```swift
private func renderedIcon(at date: Date) -> NSImage {
    let renderer = ImageRenderer(
        content: MenuBarStatusArtwork(
            status: aggregateStatus,
            colorScheme: colorScheme,
            workingPulseOpacity: workingPulseOpacity(at: date)
        )
    )
    renderer.scale = 2
    return renderer.nsImage ?? NSImage(size: NSSize(width: 17, height: 18))
}

private func workingPulseOpacity(at date: Date) -> Double {
    guard aggregateStatus == .working, !reduceMotion else { return 0.1 }
    let halfCycle = 1.4
    let elapsed = date.timeIntervalSinceReferenceDate
        .truncatingRemainder(dividingBy: halfCycle * 2)
    let progress = elapsed <= halfCycle
        ? elapsed / halfCycle
        : 2 - elapsed / halfCycle
    return 0.1 + (0.18 * progress)
}
```

- [ ] **Step 4: Generate the project and build the app**

Run:

```bash
PATH="/opt/homebrew/bin:$PATH" xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project AmpRunner.xcodeproj -scheme AmpRunner \
  -configuration Debug -derivedDataPath /tmp/AmpRunnerMenuBarFix \
  CODE_SIGNING_ALLOWED=NO build
```

Expected: XcodeGen completes and `xcodebuild` ends with `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run the core regression suite**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test
```

Expected: all 98 tests pass, including `testMenuBarAggregateStatusUsesBrandPrecedence`.

- [ ] **Step 6: Launch and inspect the generated app**

Run:

```bash
open /tmp/AmpRunnerMenuBarFix/Build/Products/Debug/AmpRunner.app
```

Confirm that the menu-bar mark changes for aggregate state transitions. Enable Reduce Motion in System Settings, then confirm Working keeps a static halo instead of pulsing. Quit the inspected build before continuing.

- [ ] **Step 7: Commit the implementation**

```bash
git add App/AmpRunnerApp.swift
git commit -m "fix(menu-bar): render aggregate status as one image" \
  -m "intent(menu-bar): make runner status changes visible and respect Reduce Motion" \
  -m "decision(menu-bar): rasterize the mark and status dot for MenuBarExtra instead of replacing it with NSStatusItem" \
  -m "constraint(accessibility): pause timeline updates and use a static Working halo when Reduce Motion is enabled"
```
