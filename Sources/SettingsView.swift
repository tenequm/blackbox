import AVFoundation
import CoreGraphics
import Security
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct SettingsView: View {
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @AppStorage(SettingsKeys.autoRecord) private var autoRecord = true
  @AppStorage(SettingsKeys.gracePeriod) private var gracePeriod: Double = 5
  @AppStorage(SettingsKeys.micEnabled) private var micEnabled = true
  @AppStorage(SettingsKeys.saveDirectoryPath) private var saveDirectoryPath =
    defaultSaveDirectoryPath
  @AppStorage(SettingsKeys.namePrefixTemplate) private var namePrefixTemplate = "YYMM-DD-"
  @AppStorage(SettingsKeys.notifyOnStart) private var notifyOnStart = true
  @AppStorage(SettingsKeys.notifyOnSaved) private var notifyOnSaved = true
  @AppStorage(SettingsKeys.notifyOnError) private var notifyOnError = true
  @AppStorage(SettingsKeys.excludedBundleIDs) private var excludedBundleIDsRaw = ""
  @Environment(TranscriptionCoordinator.self) private var transcription
  /// Loaded in `onAppear`, not here: a `@State` default expression is evaluated
  /// on every struct initialisation and thrown away after the first, so putting
  /// a synchronous Keychain round-trip in it pays `SecItemCopyMatching` every
  /// time the enclosing `TabView` body runs.
  @State private var sonioxAPIKey = ""
  @AppStorage(SettingsKeys.autoTranscribe) private var autoTranscribe = false
  @AppStorage(SettingsKeys.sonioxModel) private var sonioxModel = TranscriptionService.defaultModel
  @State private var keyCheck: APIKeyCheck = .untested

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
      // After the migration, which is what puts a legacy key in the Keychain.
      if sonioxAPIKey.isEmpty, let stored = KeychainHelper.string(forKey: SettingsKeys.sonioxAPIKey)
      {
        sonioxAPIKey = stored
      }
    }
    .onChange(of: sonioxAPIKey) { _, newValue in
      // The load above is a state write like any other, so it lands here too.
      // Without this guard every appear would delete-then-re-add the stored key
      // and throw away a "Key works" result the user had just obtained.
      guard newValue != (KeychainHelper.string(forKey: SettingsKeys.sonioxAPIKey) ?? "") else {
        return
      }
      KeychainHelper.setString(newValue, forKey: SettingsKeys.sonioxAPIKey)
      transcription.apiKeyChanged()
      keyCheck = .untested
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
      HStack(spacing: 8) {
        Button("Verify Key") { verifyAPIKey() }
          .disabled(sonioxAPIKey.isEmpty || keyCheck == .checking)
        keyCheckLabel
      }
      Text(
        "Get your API key at soniox.com. Audio is sent to Soniox servers for transcription, and Blackbox deletes it from Soniox once the transcript comes back."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      TextField("Model", text: $sonioxModel)
      Text(
        "Soniox model used for transcription. Leave as \(TranscriptionService.defaultModel) unless Soniox retires it."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Toggle("Transcribe recordings automatically", isOn: $autoTranscribe)
        .disabled(sonioxAPIKey.isEmpty)
      Text(
        "Every finished recording longer than three seconds is uploaded to Soniox as soon as it is saved, with no further prompt. Leave this off to transcribe one recording at a time from its detail view."
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
      var count = 0
      var totalBytes = 0

      for dir in RecordingStore.directories(in: url) {
        let audioURL = dir.appendingPathComponent(RecordingStore.audioName)
        if let size = try? audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
          count += 1
          totalBytes += size
        }
        let processedURL = dir.appendingPathComponent(RecordingStore.processedAudioName)
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

  // MARK: - API Key Verification

  private enum APIKeyCheck: Equatable {
    case untested
    case checking
    case valid
    case invalid(String)
  }

  @ViewBuilder private var keyCheckLabel: some View {
    switch keyCheck {
    case .untested:
      EmptyView()
    case .checking:
      ProgressView().controlSize(.small)
    case .valid:
      Label("Key works", systemImage: "checkmark.circle.fill")
        .font(.caption)
        .foregroundStyle(.green)
    case .invalid(let message):
      Label(message, systemImage: "exclamationmark.triangle.fill")
        .font(.caption)
        .foregroundStyle(.orange)
        .lineLimit(2)
    }
  }

  private func verifyAPIKey() {
    let key = sonioxAPIKey
    keyCheck = .checking
    Task {
      let result = await TranscriptionService.verifyAPIKey(key)
      guard key == sonioxAPIKey else { return }
      keyCheck = result.isValid ? .valid : .invalid(result.message ?? "Key rejected")
    }
  }

  // MARK: - Keychain Migration

  private func migrateAPIKeyToKeychain() {
    let defaults = UserDefaults.standard
    if let legacyKey = defaults.string(forKey: SettingsKeys.sonioxAPIKey), !legacyKey.isEmpty {
      KeychainHelper.setString(legacyKey, forKey: SettingsKeys.sonioxAPIKey)
      defaults.removeObject(forKey: SettingsKeys.sonioxAPIKey)
      sonioxAPIKey = legacyKey
      // Invalidated here rather than through `onChange`: the Keychain is written
      // first, so by the time the assignment above lands the guard there sees no
      // change and returns. Without this the coordinator keeps the "no key"
      // result it cached at launch until the next restart.
      transcription.apiKeyChanged()
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

/// UserDefaults and Keychain keys shared across the app. Spelled out in one
/// place because a typo in a key literal compiles and then reads back a
/// default: the feature it gates stops working with nothing in the log.
nonisolated enum SettingsKeys {
  static let autoRecord = "autoRecord"
  static let gracePeriod = "gracePeriod"
  static let micEnabled = "micEnabled"
  static let saveDirectoryPath = "saveDirectoryPath"
  static let namePrefixTemplate = "namePrefixTemplate"
  static let notifyOnStart = "notifyOnStart"
  static let notifyOnSaved = "notifyOnSaved"
  static let notifyOnError = "notifyOnError"
  static let excludedBundleIDs = "excludedBundleIDs"
  static let autoTranscribe = "autoTranscribe"
  static let sonioxModel = "sonioxModel"
  static let sonioxAPIKey = "sonioxAPIKey"
  static let playbackRate = "playbackRate"
}
