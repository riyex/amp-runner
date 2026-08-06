# Menu-Bar Status Rendering Design

## Goal

Make the menu-bar icon visibly reflect the aggregate runner status while preserving the existing brand mark, status precedence, and accessibility description. Respect macOS Reduce Motion for the Working pulse.

## Design

`MenuBarExtra` will receive one `Image` label instead of an `HStack` containing custom shapes. `MenuBarLabelView` will render the brand mark and status indicator into one `NSImage` with SwiftUI's `ImageRenderer`. This keeps the status item on the image-label path that macOS renders reliably.

The composite image will preserve the current visual states:

- Stopped: dimmed mark with no dot.
- Starting: outlined mint dot.
- Online: solid mint dot.
- Working: solid mint dot with a pulsing halo.
- Error: solid red dot.

A lightweight timeline will update only the Working image's pulse phase. When `accessibilityReduceMotion` is enabled, the Working image will use one static pulse phase and will not request periodic updates. Other states remain static.

The implementation will remain within `MenuBarExtra`; it will not introduce an AppKit-owned `NSStatusItem` or change menu content and process supervision.

## Verification

The existing aggregate-status unit test will continue to verify status precedence. The rendering fix is AppKit integration behavior without an app UI-test target, so verification will consist of:

1. `swift test` for the core package.
2. XcodeGen project generation and a signing-disabled app build.
3. Launching the built app and checking that status changes update the menu-bar image.
4. Checking that Reduce Motion produces a static Working indicator.

The user approved this narrow exception to test-first development for the SwiftUI-to-AppKit rendering behavior.
