import AppKit
import SwiftUI

/// The text of a HUD toast, retained after dismissal so smoke tests can assert
/// what was shown without racing the panel's display window.
struct HUDToast: Equatable, Sendable {
  static let startedTitle = "Recording Started"
  static let savedTitle = "Recording Saved"
  static let errorTitle = "Error"

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

    if let screen = NSScreen.main {
      let x = screen.visibleFrame.maxX - size.width - 16
      let y = screen.visibleFrame.maxY - size.height - 16
      panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.25
      panel.animator().alphaValue = 1
    }

    self.panel = panel
    lastToast = HUDToast(title: content.title, subtitle: content.subtitle)

    NSAccessibility.post(
      element: panel as Any, notification: .announcementRequested,
      userInfo: [.announcement: content.title])

    hideTask = Task {
      try? await Task.sleep(for: .seconds(duration))
      guard !Task.isCancelled else { return }
      self.dismiss()
    }
  }

  private func dismiss() {
    guard let panel else { return }
    self.panel = nil
    NSAnimationContext.runAnimationGroup { ctx in
      ctx.duration = 0.25
      panel.animator().alphaValue = 0
    } completionHandler: {
      Task { @MainActor in
        panel.close()
      }
    }
  }
}

// Intercepts clicks so the "Recording Saved" HUD can reveal in Finder.
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
