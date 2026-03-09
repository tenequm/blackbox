import AVFoundation
import ServiceManagement
import SwiftUI
import UserNotifications

struct SettingsView: View {
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @AppStorage("gracePeriod") private var gracePeriod: Double = 30
  @AppStorage("micEnabled") private var micEnabled = true
  @AppStorage("targetBundleIDs") private var targetBundleIDsData = defaultTargetBundleIDsJSON
  @AppStorage("meetingPatterns") private var meetingPatternsData = defaultMeetingPatternsJSON
  @AppStorage("saveDirectoryPath") private var saveDirectoryPath = defaultSaveDirectoryPath
  @AppStorage("notifyOnStart") private var notifyOnStart = true
  @AppStorage("notifyOnSaved") private var notifyOnSaved = true
  @AppStorage("notifyOnError") private var notifyOnError = true

  @State private var newBundleID = ""
  @State private var newPattern = ""
  @State private var showBundleIDField = false
  @State private var screenRecordingGranted = false
  @State private var micPermissionGranted = false
  @State private var notificationPermissionGranted = false
  @State private var storageStats: (count: Int, sizeFormatted: String)?

  var body: some View {
    Form {
      generalSection
      permissionsSection
      targetAppsSection
      meetingDetectionSection
      recordingsSection
      notificationsSection
      debugSection
    }
    .formStyle(.grouped)
    .frame(minWidth: 420, idealWidth: 480, maxWidth: 640)
    .onAppear {
      launchAtLogin = SMAppService.mainApp.status == .enabled
      refreshPermissions()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      refreshPermissions()
    }
    .task {
      await computeStorageStats()
    }
  }

  // MARK: - General

  private var generalSection: some View {
    Section("General") {
      Toggle("Launch at Login", isOn: $launchAtLogin)
        .onChange(of: launchAtLogin) { _, enabled in
          do {
            if enabled {
              try SMAppService.mainApp.register()
            } else {
              try SMAppService.mainApp.unregister()
            }
          } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
          }
        }

      Toggle("Record Microphone", isOn: $micEnabled)
      Text("Captures your microphone as a separate audio track alongside app audio")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Permissions

  private var permissionsSection: some View {
    Section("Permissions") {
      permissionRow(
        "Screen Recording",
        granted: screenRecordingGranted
      ) {
        NSWorkspace.shared.open(
          URL(
            string:
              "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
      }
      permissionRow(
        "Microphone",
        granted: micPermissionGranted
      ) {
        // If never asked, trigger system prompt. If denied, open Settings.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
          Task {
            await AVCaptureDevice.requestAccess(for: .audio)
            refreshPermissions()
          }
        } else {
          NSWorkspace.shared.open(
            URL(
              string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
      }
      permissionRow(
        "Notifications",
        granted: notificationPermissionGranted
      ) {
        let settings = UNUserNotificationCenter.current()
        Task {
          let status = await settings.notificationSettings()
          if status.authorizationStatus == .notDetermined {
            let _ = try? await settings.requestAuthorization(options: [.alert, .sound])
            refreshPermissions()
          } else {
            NSWorkspace.shared.open(
              URL(
                string:
                  "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
          }
        }
      }
    }
  }

  private func permissionRow(
    _ name: String, granted: Bool, fixAction: @escaping () -> Void
  ) -> some View {
    HStack {
      Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
        .foregroundStyle(granted ? .green : .red)
      Text(name)
      Spacer()
      if !granted {
        Button("Fix", action: fixAction)
          .font(.caption)
      }
    }
  }

  // MARK: - Target Applications

  private var targetAppsSection: some View {
    Section("Target Applications") {
      Text("Blackbox monitors these apps and records when meetings are detected.")
        .font(.caption)
        .foregroundStyle(.secondary)

      ForEach(targetBundleIDs, id: \.self) { bundleID in
        HStack(spacing: 8) {
          if let icon = appIcon(for: bundleID) {
            Image(nsImage: icon)
              .resizable()
              .frame(width: 16, height: 16)
          }
          Text(appDisplayName(for: bundleID))
          Text(bundleID)
            .font(.caption)
            .foregroundStyle(.tertiary)
          Spacer()
          Button(role: .destructive) {
            removeBundleID(bundleID)
          } label: {
            Image(systemName: "trash")
          }.buttonStyle(.borderless)
        }
      }

      Menu("Add Application...") {
        ForEach(availableApps, id: \.processIdentifier) { app in
          Button(app.localizedName ?? "Unknown") {
            if let bid = app.bundleIdentifier { addBundleIDDirect(bid) }
          }
        }
        Divider()
        Button("Add by Bundle ID...") { showBundleIDField = true }
      }

      if showBundleIDField {
        HStack {
          TextField("com.example.app", text: $newBundleID)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
              addBundleID()
              showBundleIDField = false
            }
          Button("Add") {
            addBundleID()
            showBundleIDField = false
          }
          .disabled(newBundleID.isEmpty)
        }
      }

      Button("Reset to Defaults") {
        targetBundleIDsData = defaultTargetBundleIDsJSON
      }
      .font(.caption)
    }
  }

  // MARK: - Meeting Detection

  private var meetingDetectionSection: some View {
    Section("Meeting Detection") {
      Text("Recording starts when a target app has a window title matching any pattern below.")
        .font(.caption)
        .foregroundStyle(.secondary)

      ForEach(currentMeetingPatterns, id: \.self) { pattern in
        HStack {
          Text(pattern)
          Spacer()
          Button(role: .destructive) {
            removePattern(pattern)
          } label: {
            Image(systemName: "trash")
          }.buttonStyle(.borderless)
        }
      }
      HStack {
        TextField("e.g. Google Meet", text: $newPattern)
          .textFieldStyle(.roundedBorder)
          .onSubmit { addPattern() }
        Button("Add") { addPattern() }
          .disabled(newPattern.isEmpty)
      }

      Button("Reset to Defaults") {
        meetingPatternsData = defaultMeetingPatternsJSON
      }
      .font(.caption)

      HStack {
        Text("Grace period: \(Int(gracePeriod))s")
        Spacer()
        Slider(value: $gracePeriod, in: 5...60, step: 5)
          .frame(width: 200)
      }
      Text(
        "Keeps recording briefly after the meeting window closes, in case it reappears (e.g., switching tabs)"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  // MARK: - Recordings

  private var recordingsSection: some View {
    Section("Recordings") {
      HStack {
        Text(saveDirectoryPath)
          .lineLimit(1)
          .truncationMode(.head)
        Spacer()
        Button("Choose...") { pickFolder() }
      }
      if let stats = storageStats {
        Text("\(stats.count) recordings, \(stats.sizeFormatted)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Notifications

  private var notificationsSection: some View {
    Section("Notifications") {
      Toggle("Recording started", isOn: $notifyOnStart)
      Toggle("Recording saved", isOn: $notifyOnSaved)
      Toggle("Errors", isOn: $notifyOnError)
    }
  }

  // MARK: - Debug

  private var debugSection: some View {
    Section("Debug") {
      HStack {
        Button("Open Log File") {
          let fm = FileManager.default
          try? fm.createDirectory(at: LogFile.directory, withIntermediateDirectories: true)
          NSWorkspace.shared.open(LogFile.directory)
        }
        Button("Copy Debug Log") {
          let url = LogFile.export()
          if let contents = try? String(contentsOf: url, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(contents, forType: .string)
          }
        }
      }
    }
  }

  // MARK: - Bundle IDs

  private var targetBundleIDs: [String] {
    (try? JSONDecoder().decode([String].self, from: Data(targetBundleIDsData.utf8))) ?? []
  }

  private var availableApps: [NSRunningApplication] {
    NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
      .filter { app in app.bundleIdentifier.map { !targetBundleIDs.contains($0) } ?? false }
      .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
  }

  private func appIcon(for bundleID: String) -> NSImage? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
      .map { NSWorkspace.shared.icon(forFile: $0.path) }
  }

  private func appDisplayName(for bundleID: String) -> String {
    NSWorkspace.shared.runningApplications
      .first { $0.bundleIdentifier == bundleID }?
      .localizedName ?? bundleID.components(separatedBy: ".").last ?? bundleID
  }

  private func addBundleIDDirect(_ id: String) {
    var ids = targetBundleIDs
    guard !ids.contains(id) else { return }
    ids.append(id)
    targetBundleIDsData = (try? String(data: JSONEncoder().encode(ids), encoding: .utf8)) ?? "[]"
  }

  private func removeBundleID(_ id: String) {
    var ids = targetBundleIDs
    ids.removeAll { $0 == id }
    targetBundleIDsData = (try? String(data: JSONEncoder().encode(ids), encoding: .utf8)) ?? "[]"
  }

  private func addBundleID() {
    let id = newBundleID.trimmingCharacters(in: .whitespaces)
    guard !id.isEmpty else { return }
    var ids = targetBundleIDs
    guard !ids.contains(id) else {
      newBundleID = ""
      return
    }
    ids.append(id)
    targetBundleIDsData = (try? String(data: JSONEncoder().encode(ids), encoding: .utf8)) ?? "[]"
    newBundleID = ""
  }

  // MARK: - Meeting Patterns

  private var currentMeetingPatterns: [String] {
    (try? JSONDecoder().decode([String].self, from: Data(meetingPatternsData.utf8))) ?? []
  }

  private func removePattern(_ pattern: String) {
    var patterns = currentMeetingPatterns
    patterns.removeAll { $0 == pattern }
    meetingPatternsData =
      (try? String(data: JSONEncoder().encode(patterns), encoding: .utf8)) ?? "[]"
  }

  private func addPattern() {
    let p = newPattern.trimmingCharacters(in: .whitespaces)
    guard !p.isEmpty else { return }
    var patterns = currentMeetingPatterns
    guard !patterns.contains(p) else {
      newPattern = ""
      return
    }
    patterns.append(p)
    meetingPatternsData =
      (try? String(data: JSONEncoder().encode(patterns), encoding: .utf8)) ?? "[]"
    newPattern = ""
  }

  // MARK: - Permissions Refresh

  private func refreshPermissions() {
    screenRecordingGranted = CGPreflightScreenCaptureAccess()
    micPermissionGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    Task {
      let settings = await UNUserNotificationCenter.current().notificationSettings()
      notificationPermissionGranted = settings.authorizationStatus == .authorized
    }
  }

  // MARK: - Storage Stats

  private func computeStorageStats() async {
    let path = saveDirectoryPath
    let result: (count: Int, sizeFormatted: String)? = await Task.detached {
      let url = URL(fileURLWithPath: path)
      guard
        let files = try? FileManager.default.contentsOfDirectory(
          at: url, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)
      else { return nil }
      let m4as = files.filter { $0.pathExtension == "m4a" }
      let totalBytes = m4as.compactMap {
        try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
      }.reduce(0, +)
      return (
        count: m4as.count,
        sizeFormatted: ByteCountFormatter.string(
          fromByteCount: Int64(totalBytes), countStyle: .file)
      )
    }.value
    storageStats = result
  }

  // MARK: - Folder Picker

  private func pickFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    if panel.runModal() == .OK, let url = panel.url {
      saveDirectoryPath = url.path(percentEncoded: false)
    }
  }
}

let defaultTargetBundleIDsJSON =
  #"["com.google.Chrome","us.zoom.xos","ru.keepcoder.Telegram","org.telegram.desktop"]"#
let defaultMeetingPatternsJSON =
  #"["Meet -","meet.google.com","Zoom Meeting","Voice Chat","Video Chat"]"#
let defaultSaveDirectoryPath =
  NSHomeDirectory() + "/Library/Application Support/Blackbox/Recordings"
