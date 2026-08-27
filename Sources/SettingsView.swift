import AVFoundation
import CoreGraphics
import Security
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @AppStorage("autoRecord") private var autoRecord = true
  @AppStorage("gracePeriod") private var gracePeriod: Double = 5
  @AppStorage("micEnabled") private var micEnabled = true
  @AppStorage("saveDirectoryPath") private var saveDirectoryPath = defaultSaveDirectoryPath
  @AppStorage("namePrefixTemplate") private var namePrefixTemplate = "YYMM-DD-"
  @AppStorage("notifyOnStart") private var notifyOnStart = true
  @AppStorage("notifyOnSaved") private var notifyOnSaved = true
  @AppStorage("notifyOnError") private var notifyOnError = true
  @AppStorage("excludedBundleIDs") private var excludedBundleIDsRaw = ""
  @State private var sonioxAPIKey = KeychainHelper.string(forKey: "sonioxAPIKey") ?? ""
  @AppStorage("autoTranscribe") private var autoTranscribe = false

  @State private var audioRecordingGranted = false
  @State private var micPermissionGranted = false
  @State private var notificationPermissionGranted = false
  @State private var storageStats: (count: Int, sizeFormatted: String)?

  var body: some View {
    Form {
      generalSection
      excludedAppsSection
      permissionsSection
      recordingsSection
      transcriptionSection
      notificationsSection
      debugSection
    }
    .formStyle(.grouped)
    .onAppear {
      launchAtLogin = SMAppService.mainApp.status == .enabled
      refreshPermissions()
      migrateAPIKeyToKeychain()
    }
    .onChange(of: sonioxAPIKey) { _, newValue in
      KeychainHelper.setString(newValue, forKey: "sonioxAPIKey")
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

      Toggle("Automatic Recording", isOn: $autoRecord)
      Text("Automatically records when your microphone becomes active, e.g. during calls")
        .font(.caption)
        .foregroundStyle(.secondary)

      Toggle("Record Microphone", isOn: $micEnabled)
      Text("Include your microphone in recordings")
        .font(.caption)
        .foregroundStyle(.secondary)

      HStack {
        Text("Grace period: \(Int(gracePeriod))s")
        Spacer()
        Slider(value: $gracePeriod, in: 5...60, step: 5)
          .frame(width: 200)
      }
      Text("Keeps recording briefly after the microphone stops, in case the call resumes")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Excluded Apps

  private var excludedBundleIDs: [String] {
    AudioMonitorSettings.parseBundleIDList(excludedBundleIDsRaw)
  }

  private func addExcludedApp(bundleID: String) {
    var ids = excludedBundleIDs
    guard !ids.contains(bundleID) else { return }
    ids.append(bundleID)
    excludedBundleIDsRaw = ids.joined(separator: ",")
  }

  private func removeExcludedApp(bundleID: String) {
    excludedBundleIDsRaw = excludedBundleIDs.filter { $0 != bundleID }.joined(separator: ",")
  }

  /// Covers apps the running-apps menu can't show: not currently running, or
  /// background-only (`activationPolicy == .prohibited`).
  private func addExcludedAppViaOpenPanel() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.applicationBundle]
    panel.allowsMultipleSelection = false
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.message = "Choose an app to exclude from automatic recording"
    guard panel.runModal() == .OK, let url = panel.url,
      let bundleID = Bundle(url: url)?.bundleIdentifier
    else { return }
    addExcludedApp(bundleID: bundleID)
  }

  private func appDisplayName(forBundleID bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
      let bundle = Bundle(url: url)
    else { return bundleID }
    return (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
      ?? (bundle.infoDictionary?["CFBundleName"] as? String)
      ?? bundleID
  }

  /// Currently-running apps (not already excluded) available to add. Includes
  /// menu-bar/accessory apps (e.g. dictation tools like TypeWhisper) alongside
  /// regular apps, since those are exactly what trigger false-positive call
  /// detection (mic + speaker briefly active together).
  private var addableRunningApps: [(name: String, bundleID: String)] {
    let excluded = Set(excludedBundleIDs)
    let myBundleID = Bundle.main.bundleIdentifier
    return
      NSWorkspace.shared.runningApplications
      .filter { $0.activationPolicy != .prohibited }
      .compactMap { app -> (name: String, bundleID: String)? in
        guard let bundleID = app.bundleIdentifier, bundleID != myBundleID,
          !excluded.contains(bundleID)
        else { return nil }
        return (name: app.localizedName ?? bundleID, bundleID: bundleID)
      }
      .sorted { $0.name < $1.name }
  }

  private var excludedAppsSection: some View {
    Section("Excluded Apps") {
      Text("Apps in this list never trigger automatic recording, even during a call.")
        .font(.caption)
        .foregroundStyle(.secondary)

      ForEach(excludedBundleIDs, id: \.self) { bundleID in
        HStack {
          Text(appDisplayName(forBundleID: bundleID))
          Text(bundleID)
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button {
            removeExcludedApp(bundleID: bundleID)
          } label: {
            Image(systemName: "minus.circle.fill")
              .foregroundStyle(.secondary)
          }
          .buttonStyle(.plain)
        }
      }

      Menu("Add App…") {
        let apps = addableRunningApps
        ForEach(apps, id: \.bundleID) { app in
          Button(app.name) {
            addExcludedApp(bundleID: app.bundleID)
          }
        }
        if !apps.isEmpty {
          Divider()
        }
        Button("Other…") {
          addExcludedAppViaOpenPanel()
        }
      }
    }
  }

  // MARK: - Permissions

  private var permissionsSection: some View {
    Section("Permissions") {
      permissionRow(
        "Screen & System Audio Recording",
        granted: audioRecordingGranted
      ) {
        NSWorkspace.shared.open(
          URL(
            string:
              "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
          )!)
      }
      permissionRow(
        "Microphone",
        granted: micPermissionGranted
      ) {
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
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone"
            )!)
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

      TextField("Name prefix", text: $namePrefixTemplate)
      Text(
        "Prepended to new recording names, e.g. \"\(formatNamePrefix(template: namePrefixTemplate, date: Date()))Zoom\". Tokens: YYYY, YY, MM, DD. Leave empty for no prefix."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  // MARK: - Transcription

  private var transcriptionSection: some View {
    Section("Transcription") {
      SecureField("Soniox API Key", text: $sonioxAPIKey)
      Text(
        "Get your API key at soniox.com. Audio is sent to Soniox servers for transcription."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Toggle("Transcribe recordings automatically", isOn: $autoTranscribe)
        .disabled(sonioxAPIKey.isEmpty)
      Text(
        "Every finished recording is uploaded to Soniox as soon as it is saved, with no further prompt. Leave this off to transcribe one recording at a time from its detail view."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
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

  // MARK: - Permissions Refresh

  private func refreshPermissions() {
    audioRecordingGranted = CGPreflightScreenCaptureAccess()
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

      var count = 0
      var totalBytes = 0

      for dir in files
      where FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("audio.m4a").path)
      {
        let audioURL = dir.appendingPathComponent("audio.m4a")
        if let size = try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
          count += 1
          totalBytes += size
        }
        let processedURL = dir.appendingPathComponent("audio-processed.m4a")
        if let size = try? processedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
          totalBytes += size
        }
      }

      return (
        count: count,
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

  // MARK: - Keychain Migration

  private func migrateAPIKeyToKeychain() {
    let defaults = UserDefaults.standard
    if let legacyKey = defaults.string(forKey: "sonioxAPIKey"), !legacyKey.isEmpty {
      KeychainHelper.setString(legacyKey, forKey: "sonioxAPIKey")
      defaults.removeObject(forKey: "sonioxAPIKey")
      sonioxAPIKey = legacyKey
    }
  }
}

// MARK: - Keychain Helper

enum KeychainHelper {
  private static let service = "com.tenequm.Blackbox"

  static func string(forKey key: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
    ]
    var result: AnyObject?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func setString(_ value: String, forKey key: String) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    SecItemDelete(query as CFDictionary)
    if !value.isEmpty {
      var attrs = query
      attrs[kSecValueData as String] = Data(value.utf8)
      SecItemAdd(attrs as CFDictionary, nil)
    }
  }
}

let defaultSaveDirectoryPath =
  NSHomeDirectory() + "/Library/Application Support/Blackbox/Recordings"
