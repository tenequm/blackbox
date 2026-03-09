import AppKit
import SwiftUI

final class RecordingHUD {
  private var panel: HUDPanel?
  private var hideTask: Task<Void, Never>?

  func showRecordingStarted(appName: String, bundleID: String?) {
    show(
      content: HUDContentView(
        title: "Recording Started",
        subtitle: appName,
        icon: NSApplication.shared.applicationIconImage
      ))
  }

  func showRecordingSaved(appName: String, fileName: String, fileURL: URL) {
    show(
      content: HUDContentView(
        title: "Recording Saved",
        subtitle: "\(appName) - \(fileName)",
        icon: NSApplication.shared.applicationIconImage
      ),
      onClick: { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
    )
  }

  private func show(content: HUDContentView, onClick: (() -> Void)? = nil) {
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

    NSAccessibility.post(
      element: panel as Any, notification: .announcementRequested,
      userInfo: [.announcement: content.title])

    hideTask = Task {
      try? await Task.sleep(for: .seconds(2.5))
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
    if event.type == .leftMouseUp, let onClick {
      onClick()
      Task { @MainActor [weak self] in
        self?.onClick = nil  // fire once
      }
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
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
  }
}
