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
  @State private var revealAPIKey = false
  @State private var showTranscriptionConsent = false
  @State private var didCopyDiagnostics = false
  @AppStorage(SettingsKeys.acceptedTranscriptionTerms) private var hasAcceptedTranscriptionTerms =
    false

  @State private var audioRecordingGranted = false
  @State private var micPermissionGranted = false
  @State private var notificationPermissionGranted = false
  @State private var storageStats: (count: Int, sizeFormatted: String)?
  @State private var keyWriteTask: Task<Void, Never>?
  @State private var appNameCache: [String: String] = [:]
  @State private var pendingMove: (from: URL, to: URL)?

  var body: some View {
    Form {
      // Most-changed first. "Excluded Apps" is an advanced, potentially long
      // list and sat second, pushing the save location, transcription and
      // permissions below the fold at the default window height.
      generalSection
      recordingsSection
      transcriptionSection
      permissionsSection
      notificationsSection
      excludedAppsSection
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
      // Trimmed, because a pasted key routinely carries a trailing newline and
      // the resulting 401 says nothing a user can act on.
      let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
      // The load in `onAppear` is a state write like any other, so it lands
      // here too. Without this guard every appear would delete-then-re-add the
      // stored key and discard a "Key works" result just obtained.
      guard trimmed != (KeychainHelper.string(forKey: SettingsKeys.sonioxAPIKey) ?? "") else {
        return
      }
      // Debounced rather than written per keystroke. A partial prefix used to
      // be live in the Keychain the whole time the user was typing, so a job
      // finishing mid-typing authenticated with a truncated key and failed
      // terminally.
      keyCheck = .untested
      keyWriteTask?.cancel()
      keyWriteTask = Task {
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        KeychainHelper.setString(trimmed, forKey: SettingsKeys.sonioxAPIKey)
        transcription.apiKeyChanged()
        if trimmed.isEmpty {
          // A key that is gone cannot bill, and leaving the toggle on made the
          // app look like it was transcribing when nothing was happening.
          autoTranscribe = false
        }
      }
    }
    .confirmationDialog(
      "Move existing recordings?",
      isPresented: Binding(
        get: { pendingMove != nil },
        set: { if !$0 { pendingMove = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Move") {
        if let move = pendingMove { moveRecordings(from: move.from, to: move.to) }
        pendingMove = nil
      }
      Button("Leave Them", role: .cancel) { pendingMove = nil }
    } message: {
      Text(
        "Blackbox will only show recordings in the new folder. Recordings left behind stay on disk, and any transcription still in progress for them will not resume."
      )
    }
    .confirmationDialog(
      "Turn on automatic transcription?",
      isPresented: $showTranscriptionConsent,
      titleVisibility: .visible
    ) {
      Button("Turn On") {
        hasAcceptedTranscriptionTerms = true
        autoTranscribe = true
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "Every call you record from now on will be uploaded to Soniox, including the audio of everyone else on the call. Soniox is a paid service billed per hour of audio. Blackbox asks Soniox to delete each file once the transcript comes back, but that request can fail - for example if you remove your API key first."
      )
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      refreshPermissions()
    }
    .task(id: saveDirectoryPath) {
      // Keyed on the path: it used to be computed once, so after changing the
      // save folder the figure described a directory the user was no longer
      // using.
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

      // A picker, not a slider. This is a twelve-position choice that was
      // dragged across 200pt with no tick marks, and the value lived in a
      // sibling `Text` so the slider announced a nameless percentage to
      // VoiceOver. "Grace period" was jargon too.
      Picker("Keep recording for", selection: $gracePeriod) {
        Text("5 seconds").tag(5.0)
        Text("10 seconds").tag(10.0)
        Text("15 seconds").tag(15.0)
        Text("30 seconds").tag(30.0)
        Text("1 minute").tag(60.0)
      }
      Text("Keeps recording after the microphone stops, in case the call resumes")
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

  /// Cached. This is read from `body`, and an uncached version walked the
  /// filesystem once per excluded app on every body pass - so typing in the API
  /// key field a few sections up re-resolved every bundle on the main thread.
  private func appDisplayName(forBundleID bundleID: String) -> String {
    if let cached = appNameCache[bundleID] { return cached }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
      let bundle = Bundle(url: url)
    else { return bundleID }
    let name =
      (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
      ?? (bundle.infoDictionary?["CFBundleName"] as? String)
      ?? bundleID
    Task { @MainActor in appNameCache[bundleID] = name }
    return name
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
          .accessibilityLabel("Stop excluding \(appDisplayName(forBundleID: bundleID))")
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
        // Ask first where asking is possible. This always opened System
        // Settings, where a first-run user may not even be listed yet - so
        // there was nothing to toggle and no prompt had been shown.
        if !CGRequestScreenCaptureAccess() {
          NSWorkspace.shared.open(
            URL(
              string:
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
            )!)
        }
        refreshPermissions()
      }
      if !audioRecordingGranted {
        Text(
          "macOS applies this permission at launch, so Blackbox must be reopened after granting it."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
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
      // In words as well as colour. Red/green alone is invisible to a
      // colourblind reader, and VoiceOver read the row as a bare name with no
      // status at all.
      Text(granted ? "Granted" : "Not granted")
        .font(.caption)
        .foregroundStyle(.secondary)
      Spacer()
      if !granted {
        // "Fix" gave no hint that it opens another app, and three identical
        // "Fix" buttons are indistinguishable when navigating by control.
        Button("Open System Settings…", action: fixAction)
          .font(.caption)
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(name): \(granted ? "granted" : "not granted")")
  }

  // MARK: - Recordings

  private var recordingsSection: some View {
    Section("Recordings") {
      HStack {
        Text(saveDirectoryPath)
          .lineLimit(1)
          .truncationMode(.head)
        Spacer()
        Button("Choose…") { pickFolder() }
      }
      if let stats = storageStats {
        Text(
          "\(stats.count) \(stats.count == 1 ? "recording" : "recordings"), \(stats.sizeFormatted)"
        )
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
      HStack {
        // Was a bare `SecureField`. A pasted key with a trailing newline is
        // invisible in a masked field and fails with an opaque 401, so there
        // has to be a way to look at it.
        if revealAPIKey {
          TextField("Soniox API Key", text: $sonioxAPIKey)
        } else {
          SecureField("Soniox API Key", text: $sonioxAPIKey)
        }
        Button {
          revealAPIKey.toggle()
        } label: {
          Image(systemName: revealAPIKey ? "eye.slash" : "eye")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(revealAPIKey ? "Hide API key" : "Show API key")
      }
      HStack(spacing: 8) {
        Button("Verify Key") { verifyAPIKey() }
          .disabled(sonioxAPIKey.isEmpty || keyCheck == .checking)
        keyCheckLabel
        Spacer()
        Link("Get a key", destination: URL(string: "https://soniox.com")!)
          .font(.caption)
      }

      // Says what actually leaves the machine. "Audio is sent to Soniox" reads
      // as "my side is sent", and a user cannot tell from that they are making
      // a decision on the other participants' behalf.
      Text(
        "Transcription uploads both sides of the call - your microphone and the other participants' audio, mixed into one file - to Soniox, a paid third-party service billed per hour of audio. Blackbox asks Soniox to delete it once the transcript comes back."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Picker("Model", selection: $sonioxModel) {
        ForEach(TranscriptionService.knownModels, id: \.self) { model in
          Text(model).tag(model)
        }
        if !TranscriptionService.knownModels.contains(sonioxModel) {
          Text(sonioxModel).tag(sonioxModel)
        }
      }

      // The toggle spends money and sends someone else's voice to a third
      // party. It used to do both on one unconfirmed click, with the
      // explanation printed underneath in caption grey.
      Toggle("Transcribe recordings automatically", isOn: $autoTranscribe)
        .disabled(sonioxAPIKey.isEmpty)
        .onChange(of: autoTranscribe) { _, isOn in
          guard isOn, !hasAcceptedTranscriptionTerms else { return }
          autoTranscribe = false
          showTranscriptionConsent = true
        }
      if sonioxAPIKey.isEmpty {
        Text("Add an API key above to enable automatic transcription.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        Text(
          "Every finished recording longer than three seconds is uploaded shortly after it saves, with no further prompt. Leave this off to transcribe one recording at a time from its detail view."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Notifications

  /// Named for what it controls. These three gate the in-app floating panel,
  /// not system notifications - so a user who denied Notifications still got
  /// toasts over their screen and concluded the app ignored macOS privacy, and
  /// a user who turned all three off still got the one real system notification
  /// (permission revoked), which no toggle covers.
  private var notificationsSection: some View {
    Section("On-screen Alerts") {
      Toggle("When recording starts", isOn: $notifyOnStart)
      Toggle("When a recording is saved", isOn: $notifyOnSaved)
      Toggle("On errors", isOn: $notifyOnError)
      Text(
        "Brief panels in the corner of the screen. Separately, macOS notifies you if recording permission is revoked mid-call - that one follows your Notifications settings."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  // MARK: - Debug

  private var debugSection: some View {
    Section("Troubleshooting") {
      HStack {
        Button("Reveal Logs in Finder") {
          let fm = FileManager.default
          try? fm.createDirectory(at: LogFile.directory, withIntermediateDirectories: true)
          NSWorkspace.shared.open(LogFile.directory)
        }
        Button(didCopyDiagnostics ? "Copied" : "Copy Diagnostics") {
          let url = LogFile.export()
          if let contents = try? String(contentsOf: url, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(contents, forType: .string)
            didCopyDiagnostics = true
            Task {
              try? await Task.sleep(for: .seconds(2))
              didCopyDiagnostics = false
            }
          }
        }
      }
      // Said before it reaches the clipboard, not after it reaches a public
      // issue tracker.
      Text(
        "Diagnostics include the names of apps you were on calls with and when those calls happened, but never recording titles or transcript text."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      Button("Setup Assistant…") {
        (NSApplication.shared.delegate as? BlackboxApp.AppDelegate)?.showOnboarding()
      }

      LabeledContent("Version") {
        Text(Self.versionString).foregroundStyle(.secondary)
      }
    }
  }

  private static var versionString: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    // The build number is what Sparkle compares to decide whether an update
    // exists, so it is the number to quote in a bug report.
    let build = info?["CFBundleVersion"] as? String ?? "?"
    return "\(short) (\(build))"
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

  /// Offers to bring existing recordings along. Changing the folder used to
  /// write the new path and return, so the library looked emptied, and any
  /// in-flight transcription job in the old folder was never resumed - leaving
  /// its audio on Soniox.
  private func moveRecordings(from source: URL, to destination: URL) {
    Task.detached {
      for directory in RecordingStore.directories(in: source) {
        let target = destination.appendingPathComponent(directory.lastPathComponent)
        try? FileManager.default.moveItem(at: directory, to: target)
      }
    }
  }

  private func pickFolder() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let previous = URL(fileURLWithPath: saveDirectoryPath)
    saveDirectoryPath = url.path(percentEncoded: false)
    if !RecordingStore.directories(in: previous).isEmpty {
      pendingMove = (from: previous, to: url)
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
      ProgressView().controlSize(.small).accessibilityLabel("Checking key")
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
  static let acceptedTranscriptionTerms = "acceptedTranscriptionTerms"
}
