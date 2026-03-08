import AppKit
import SwiftUI

final class RecordingHUD {
  private var panel: NSPanel?
  private var hideTask: Task<Void, Never>?

  func show(appName: String, bundleID: String?) {
    hideTask?.cancel()
    panel?.close()

    let icon =
      bundleID
      .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
      .map { NSWorkspace.shared.icon(forFile: $0.path) }

    let content = HUDContentView(appName: appName, appIcon: icon)
    let hosting = NSHostingView(rootView: content)
    let size = hosting.fittingSize
    hosting.frame = NSRect(origin: .zero, size: size)

    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered, defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.hasShadow = true
    panel.contentView = hosting

    if let screen = NSScreen.main {
      let x = screen.frame.midX - size.width / 2
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
      userInfo: [.announcement: "Recording started for \(appName)"])

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
      MainActor.assumeIsolated {
        panel.close()
      }
    }
  }
}

private struct HUDContentView: View {
  let appName: String
  let appIcon: NSImage?

  var body: some View {
    HStack(spacing: 12) {
      if let icon = appIcon {
        Image(nsImage: icon)
          .resizable()
          .frame(width: 32, height: 32)
      } else {
        Image(systemName: "waveform.circle.fill")
          .font(.system(size: 28))
          .foregroundStyle(.red)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text("Recording Started")
          .font(.headline)
        Text(appName)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
  }
}
