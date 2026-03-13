import AppKit
import Darwin

// MARK: - Parse & validate PID

guard CommandLine.arguments.count > 1,
  let pid = pid_t(CommandLine.arguments[1]),
  kill(pid, 0) == 0
else {
  exit(1)
}

// MARK: - Derive app bundle path

// Executable is at Contents/MacOS/BlackboxWatchdog → 3 levels up = .app bundle
let bundlePath = URL(fileURLWithPath: CommandLine.arguments[0]).standardized
  .deletingLastPathComponent()  // Contents/MacOS
  .deletingLastPathComponent()  // Contents
  .deletingLastPathComponent()  // .app
  .path

// MARK: - Setup NSApplication (accessory = no Dock icon)

NSApplication.shared.setActivationPolicy(.accessory)

// MARK: - Signal classification

enum Crash {
  static let signals: Set<Int32> = [SIGTRAP, SIGABRT, SIGBUS, SIGSEGV, SIGILL, SIGFPE]

  static func name(of sig: Int32) -> String {
    switch sig {
    case SIGTRAP: "SIGTRAP"
    case SIGABRT: "SIGABRT"
    case SIGBUS: "SIGBUS"
    case SIGSEGV: "SIGSEGV"
    case SIGILL: "SIGILL"
    case SIGFPE: "SIGFPE"
    default: "signal \(sig)"
    }
  }
}

// MARK: - Monitor process via kqueue

DispatchQueue.global(qos: .utility).async {
  let kq = kqueue()
  guard kq >= 0 else { exit(1) }

  var event = kevent(
    ident: UInt(pid),
    filter: Int16(EVFILT_PROC),
    flags: UInt16(EV_ADD | EV_ONESHOT),
    fflags: UInt32(NOTE_EXIT),
    data: 0,
    udata: nil
  )

  var output = kevent()
  let result = kevent(kq, &event, 1, &output, 1, nil)
  close(kq)

  guard result > 0 else { exit(1) }

  let status = Int32(output.data)

  // Check if process was signaled
  if status & 0x7F != 0 {
    let sig = status & 0x7F
    if Crash.signals.contains(sig) {
      let signalName = Crash.name(of: sig)
      let path = bundlePath
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          // Switch to regular so the alert is focusable and visible
          NSApplication.shared.setActivationPolicy(.regular)
          NSApplication.shared.activate(ignoringOtherApps: true)

          let alert = NSAlert()
          alert.alertStyle = .critical
          alert.messageText = "Blackbox crashed unexpectedly"
          alert.informativeText =
            "The app terminated due to \(signalName). Any in-progress recording may have been partially saved."
          alert.addButton(withTitle: "Reopen Blackbox")
          alert.addButton(withTitle: "Dismiss")

          let response = alert.runModal()
          if response == .alertFirstButtonReturn {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = [path]
            try? task.run()
            task.waitUntilExit()
          }
          exit(0)
        }
      }
      return
    }
  }

  // Clean exit or intentional kill - exit silently
  exit(0)
}

// MARK: - Run loop

NSApplication.shared.run()
