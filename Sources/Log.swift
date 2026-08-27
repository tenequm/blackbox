import Foundation
import OSLog

// MARK: - Logger Instances

nonisolated enum Log {
  nonisolated static let app = Logger(subsystem: "com.tenequm.Blackbox", category: "app")
  nonisolated static let monitor = Logger(subsystem: "com.tenequm.Blackbox", category: "monitor")
  nonisolated static let recorder = Logger(subsystem: "com.tenequm.Blackbox", category: "recorder")
  nonisolated static let transcription = Logger(
    subsystem: "com.tenequm.Blackbox", category: "transcription")

  /// Log info to both os.Logger and file (for key lifecycle events).
  nonisolated static func info(_ logger: Logger, _ category: String, _ message: String) {
    logger.info("\(message, privacy: .public)")
    LogFile.write("INFO", category, message)
  }

  /// Log warning to both os.Logger and file.
  nonisolated static func warning(_ logger: Logger, _ category: String, _ message: String) {
    logger.warning("\(message, privacy: .public)")
    LogFile.write("WARNING", category, message)
  }

  /// Log error to both os.Logger and file.
  nonisolated static func error(_ logger: Logger, _ category: String, _ message: String) {
    logger.error("\(message, privacy: .public)")
    LogFile.write("ERROR", category, message)
  }
}

// MARK: - File Sink

/// Append-only log file at ~/Library/Logs/Blackbox/blackbox.log.
/// Thread-safe via serial queue. Only key events and errors are written to file.
nonisolated enum LogFile {
  private nonisolated static let queue = DispatchQueue(label: "com.tenequm.blackbox.logfile")
  private nonisolated static let maxSize = 1_048_576  // 1 MB

  // Precomputed paths (no computed properties to avoid MainActor issues in closures)
  nonisolated static let directory: URL =
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/Blackbox")
  nonisolated static let filePath: URL =
    directory.appendingPathComponent("blackbox.log")
  private nonisolated static let prevPath: URL =
    directory.appendingPathComponent("blackbox.prev.log")

  /// Call once at launch to rotate if the log is too large.
  nonisolated static func rotateIfNeeded() {
    queue.sync {
      let fm = FileManager.default
      try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
      guard let attrs = try? fm.attributesOfItem(atPath: filePath.path),
        let size = attrs[.size] as? Int, size > maxSize
      else { return }
      try? fm.removeItem(at: prevPath)
      try? fm.moveItem(at: filePath, to: prevPath)
    }
  }

  /// Append a line to the log file.
  nonisolated static func write(_ level: String, _ category: String, _ message: String) {
    let dir = directory
    let file = filePath
    let timestamp = Date().formatted(.iso8601)
    queue.async {
      let fm = FileManager.default
      try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
      let line = "\(timestamp) [\(level)] [\(category)] \(message)\n"
      guard let data = line.data(using: .utf8) else { return }
      if let handle = try? FileHandle(forWritingTo: file) {
        // `try?` on the throwing overload, not the non-throwing `write(_:)`.
        // That one raises an ObjC exception on ENOSPC, which nothing catches -
        // so a disk that filled mid-recording killed the process with SIGABRT
        // on the next log line.
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
      } else {
        fm.createFile(atPath: file.path, contents: data)
      }
    }
  }

  /// Collects debug info into a temp file and returns its URL.
  nonisolated static func export() -> URL {
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "blackbox-debug-\(ProcessInfo.processInfo.processIdentifier).log")

    var output = "=== Blackbox Debug Log ===\n"
    output += "Date: \(ISO8601DateFormatter().string(from: Date()))\n"
    output +=
      "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n"
    output += "App uptime: \(Int(ProcessInfo.processInfo.systemUptime))s\n"

    if let bundle = Bundle.main.infoDictionary {
      output += "Version: \(bundle["CFBundleShortVersionString"] ?? "?") "
      output += "(\(bundle["CFBundleVersion"] ?? "?"))\n"
    }

    // OSLogStore: last hour of entries
    output += "\n=== Recent OS Log (last 1h) ===\n"
    if let store = try? OSLogStore(scope: .currentProcessIdentifier) {
      let oneHourAgo = store.position(date: Date().addingTimeInterval(-3600))
      if let entries = try? store.getEntries(at: oneHourAgo) {
        for entry in entries {
          if let logEntry = entry as? OSLogEntryLog,
            logEntry.subsystem == "com.tenequm.Blackbox"
          {
            output += "\(logEntry.date) [\(logEntry.category)] \(logEntry.composedMessage)\n"
          }
        }
      }
    } else {
      output += "(unable to read OSLogStore)\n"
    }

    // File log contents - read under queue to serialize with writes
    queue.sync {
      output += "\n=== File Log ===\n"
      if let contents = try? String(contentsOf: filePath, encoding: .utf8) {
        output += contents
      } else {
        output += "(no file log)\n"
      }

      if let prev = try? String(contentsOf: prevPath, encoding: .utf8) {
        output += "\n=== Previous File Log ===\n"
        output += prev
      }
    }

    try? output.write(to: tempURL, atomically: true, encoding: .utf8)
    return tempURL
  }
}
