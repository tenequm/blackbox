import Foundation

nonisolated enum BlackboxTestMode {
  private static let enabledFlag = "--ui-test-mode"
  private static let runIDFlag = "--test-run-id"
  private static let saveDirectoryFlag = "--test-save-directory"

  static let isEnabled = CommandLine.arguments.contains(enabledFlag)

  static let runID: String? = value(for: runIDFlag)

  static let saveDirectoryOverride: URL? = {
    guard let path = value(for: saveDirectoryFlag), !path.isEmpty else { return nil }
    return URL(fileURLWithPath: path)
  }()

  static let controlDirectory: URL? = saveDirectoryOverride?.appending(
    path: ".blackbox-test-control")

  private static func value(for flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag) else { return nil }
    let valueIndex = CommandLine.arguments.index(after: index)
    guard valueIndex < CommandLine.arguments.endIndex else { return nil }
    return CommandLine.arguments[valueIndex]
  }
}

nonisolated enum BlackboxTestCommand: String, Codable, Sendable {
  case queryState
  case startManualRecording
  case stopManualRecording
  case terminateApp
}

nonisolated struct BlackboxTestRequest: Codable, Sendable {
  var requestID: String
  var command: BlackboxTestCommand
}

nonisolated struct BlackboxTestSnapshot: Codable, Sendable {
  var isRecording: Bool
  var isManualRecording: Bool
  var isSaving: Bool
  var currentAppName: String?
  var errorMessage: String?
  var permissionNeeded: Bool
  var micPermissionNeeded: Bool
  var lastSavedRecordingPath: String?
  var hudTitle: String?
  var hudSubtitle: String?
}

nonisolated struct BlackboxTestResponse: Codable, Sendable {
  var requestID: String
  var command: BlackboxTestCommand
  var snapshot: BlackboxTestSnapshot
}
