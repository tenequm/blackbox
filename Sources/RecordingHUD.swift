import AppKit
import SwiftUI

/// The text of a HUD toast, retained after dismissal so smoke tests can assert
/// what was shown without racing the panel's display window.
struct HUDToast: Equatable, Sendable {
  static let startedTitle = "Recording Started"
  static let savedTitle = "Recording Saved"
  static let errorTitle = "Error"
  static let finalizingTitle = "Saving Recording…"

  var title: String
  var subtitle: String
}

final class RecordingHUD {
  private var panel: HUDPanel?
  private var hideTask: Task<Void, Never>?
  private(set) var lastToast: HUDToast?

  func showRecordingStarted(appName: String) {
    show(
      content: HUDContentView(
        title: HUDToast.startedTitle,
        subtitle: appName,
        icon: NSApplication.shared.applicationIconImage
      ))
  }

  static let openMainWindowNotification = Notification.Name("RecordingHUD.openMainWindow")

  func showRecordingSaved(appName: String) {
    show(
      content: HUDContentView(
        title: HUDToast.savedTitle,
        subtitle: appName,
        icon: NSApplication.shared.applicationIconImage
      ),
      duration: 10,
      onClick: {
        NotificationCenter.default.post(name: RecordingHUD.openMainWindowNotification, object: nil)
      }
    )
  }

  /// Shown while quit finalizes a recording. `LSUIElement` means there is no
  /// Dock icon to carry a "quitting" state and the menu has already closed, so
  /// without this the status item just sits there with a stale icon for up to
  /// eight seconds. The natural read is that the app has hung, and the natural
  /// response - Force Quit - is the one action that damages the file this code
  /// is busy saving.
  ///
  /// No auto-hide: it is dismissed by the process exiting.
  func showFinalizing() {
    show(
      content: HUDContentView(
        title: HUDToast.finalizingTitle,
        subtitle: "Blackbox will quit when the file is written",
        icon: NSApplication.shared.applicationIconImage
      ),
      duration: .infinity
    )
  }

  func showError(message: String) {
    show(
      content: HUDContentView(
        title: HUDToast.errorTitle,
        subtitle: message,
        icon: NSApplication.shared.applicationIconImage
      ),
      duration: 5
    )
  }

  private func show(
    content: HUDContentView, duration: Double = 2.5, onClick: (() -> Void)? = nil
  ) {
    hideTask?.cancel()
    panel?.close()

    let hosting = NSHostingView(rootView: content)
    let size = hosting.fittingSize
    hosting.frame = NSRect(origin: .zero, size: size)

    let panel = HUDPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.contentView = hosting
    panel.onClick = onClick
    // A toast with nothing to click must not swallow clicks. This panel sits in
    // the top-right corner for seconds at a time, over whatever the user is
    // doing - including a call app's own controls.
    panel.ignoresMouseEvents = onClick == nil

    // The screen under the pointer, not `NSScreen.main`: with no key window on
    // a multi-display setup, `main` is not reliably the one being looked at.
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    if let screen {
      let x = screen.visibleFrame.maxX - size.width - 16
      // Below the Notification Center banner zone, so the two do not stack on
      // top of each other.
      let y = screen.visibleFrame.maxY - size.height - 76
      panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = Self.fadeDuration
      panel.animator().alphaValue = 1
    }

    self.panel = panel
    lastToast = HUDToast(title: content.title, subtitle: content.subtitle)

    // Both strings, and at high priority. Announcing only the title meant an
    // error toast - whose whole message lives in the subtitle - said "Error"
    // and nothing else, and unprioritized announcements are the ones VoiceOver
    // drops first under load.
    let announcement =
      content.subtitle.isEmpty
      ? content.title : "\(content.title). \(content.subtitle)"
    NSAccessibility.post(
      element: NSApp as Any, notification: .announcementRequested,
      userInfo: [
        .announcement: announcement,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ])

    guard duration.isFinite else { return }
    hideTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(duration))
      guard !Task.isCancelled else { return }
      self?.dismiss()
    }
  }

  /// A cross-fade is the recommended Reduce Motion substitute, so this is a
  /// small thing - but the setting was consulted nowhere in the app.
  private static var fadeDuration: Double {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.25
  }

  private func dismiss() {
    guard let panel else { return }
    self.panel = nil
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = Self.fadeDuration
      panel.animator().alphaValue = 0
    } completionHandler: {
      Task { @MainActor in
        panel.close()
      }
    }
  }
}

// Intercepts clicks so the "Recording Saved" HUD can open the main window.
private final class HUDPanel: NSPanel {
  var onClick: (() -> Void)?

  override func sendEvent(_ event: NSEvent) {
    if event.type == .leftMouseUp, let action = onClick {
      self.onClick = nil
      action()
    }
    super.sendEvent(event)
  }
}

private struct HUDContentView: View {
  let title: String
  let subtitle: String
  let icon: NSImage

  var body: some View {
    HStack(spacing: 12) {
      Image(nsImage: icon)
        .resizable()
        .frame(width: 32, height: 32)
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .fixedSize()
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
  }
}
