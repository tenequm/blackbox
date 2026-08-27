import AppKit
import Foundation

@MainActor
final class BlackboxTestController {
  private let monitor: AudioMonitor
  private var pollTimer: Timer?
  private let commandURL: URL
  private let stateURL: URL

  init(monitor: AudioMonitor) {
    self.monitor = monitor
    let controlDirectory =
      BlackboxTestMode.controlDirectory
      ?? FileManager.default.temporaryDirectory.appending(path: ".blackbox-test-control")
    try? FileManager.default.createDirectory(
      at: controlDirectory, withIntermediateDirectories: true)
    self.commandURL = controlDirectory.appending(path: "command.json")
    self.stateURL = controlDirectory.appending(path: "state.json")
  }

  func start() {
    guard BlackboxTestMode.isEnabled else { return }
    writeState()
    pollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.poll()
      }
    }
    Log.info(Log.app, "test", "test control started (runID=\(BlackboxTestMode.runID ?? "nil"))")
  }

  func stop() {
    pollTimer?.invalidate()
    pollTimer = nil
  }

  private func poll() {
    if let data = try? Data(contentsOf: commandURL),
      let request = try? JSONDecoder().decode(BlackboxTestRequest.self, from: data)
    {
      try? FileManager.default.removeItem(at: commandURL)
      Log.info(Log.app, "test", "handling test command: \(request.command.rawValue)")
      handle(request)
    }
    writeState()
  }

  private func handle(_ request: BlackboxTestRequest) {
    switch request.command {
    case .queryState:
      writeState()
    case .startManualRecording:
      monitor.startManualRecording()
    case .stopManualRecording:
      monitor.stopManualRecording()
    case .terminateApp:
      // Via the run loop: this handler runs from a main-queue block the timer
      // callback schedules, and terminating from inside a main-queue block
      // starves the main queue for the nested run loop `.terminateLater` spins
      // up, so the reply that ends termination never gets to run.
      RunLoop.main.perform {
        MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
      }
    }
  }

  private func writeState() {
    let response = BlackboxTestResponse(
      requestID: UUID().uuidString,
      command: .queryState,
      snapshot: monitor.testSnapshot()
    )
    guard let data = try? JSONEncoder().encode(response) else { return }
    try? data.write(to: stateURL, options: .atomic)
  }
}
