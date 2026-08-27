import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

nonisolated enum MainTab: String, Hashable {
  case recordings
  case settings
}

/// Recordings and Settings as tabs in one window. Settings briefly lived in its
/// own `Settings` scene, which is what makes Cmd+, work for free - so the
/// shortcut is wired by hand here instead, in `BlackboxApp`'s commands, and it
/// selects this tab rather than opening a second window.
struct MainWindowView: View {
  @Binding var selectedTab: MainTab

  var body: some View {
    TabView(selection: $selectedTab) {
      RecordingsView()
        .tabItem { Label("Recordings", systemImage: "waveform") }
        .tag(MainTab.recordings)
      SettingsView()
        .tabItem { Label("Settings", systemImage: "gearshape") }
        .tag(MainTab.settings)
    }
    .frame(minWidth: 700, minHeight: 450)
  }
}

// MARK: - Recordings

struct RecordingsView: View {
  @Environment(TranscriptionCoordinator.self) private var transcription
  @AppStorage(SettingsKeys.saveDirectoryPath) private var saveDirectoryPath =
    defaultSaveDirectoryPath
  @State private var recordings: [RecordingFile] = []
  @State private var selection: Set<String> = []
  @State private var actionError: ActionError?
  @State private var reloadTask: Task<Void, Never>?
  @State private var searchText = ""
  /// Filtering scans every transcript body, so it runs on the debounced value
  /// rather than on every keystroke.
  @State private var searchQuery = ""
  @State private var searchDebounce: Task<Void, Never>?
  @State private var pendingBulkDelete: Set<String>?
  @State private var pendingRetranscribe: URL?

  /// Carries its own title. One `String?` behind an alert hardcoded to "Export
  /// Failed" meant a failed trash and a failed echo-cancellation run both
  /// announced themselves as export failures.
  struct ActionError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
  }

  private var selectedRecording: RecordingFile? {
    guard selection.count == 1, let id = selection.first else { return nil }
    return recordings.first { $0.id == id }
  }

  var body: some View {
    NavigationSplitView {
      recordingsList
    } detail: {
      if let recording = selectedRecording {
        RecordingDetailView(
          recording: recording,
          onDelete: { deleteRecordings([recording.id]) },
          onTitleChanged: { scheduleReload() }
        )
        .id(recording.id)
      } else if selection.count > 1 {
        ContentUnavailableView(
          "\(selection.count) Recordings Selected",
          systemImage: "square.stack",
          description: Text("Use the context menu to export, reveal, or delete them together.")
        )
      } else {
        ContentUnavailableView(
          "Select a Recording",
          systemImage: "waveform",
          description: Text("Choose a recording to play or transcribe.")
        )
      }
    }
    .searchable(text: $searchText, prompt: "Search recordings and transcripts")
    .onChange(of: searchText) { _, text in
      searchDebounce?.cancel()
      searchDebounce = Task {
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled else { return }
        searchQuery = text
      }
    }
    .task { await loadRecordings() }
    // Every trigger goes through the same cancel-and-replace task. They used to
    // spawn untracked tasks that raced each other, so a rescan started before a
    // delete could land after it and put the deleted row back.
    .onChange(of: transcription.revision) { _, _ in scheduleReload() }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      scheduleReload(after: .milliseconds(500))
    }
    .alert(item: $actionError) { error in
      Alert(
        title: Text(error.title), message: Text(error.message), dismissButton: .default(Text("OK")))
    }
    .confirmationDialog(
      "Delete \(pendingBulkDelete?.count ?? 0) recordings?",
      isPresented: Binding(
        get: { pendingBulkDelete != nil },
        set: { if !$0 { pendingBulkDelete = nil } }
      ),
      titleVisibility: .visible
    ) {
      Button("Move to Trash", role: .destructive) {
        if let ids = pendingBulkDelete { deleteRecordings(ids) }
        pendingBulkDelete = nil
      }
      Button("Cancel", role: .cancel) { pendingBulkDelete = nil }
    } message: {
      Text("They move to the Trash, and any transcription still running for them is cancelled.")
    }
    .alert(
      "Transcribe Again?",
      isPresented: Binding(
        get: { pendingRetranscribe != nil },
        set: { if !$0 { pendingRetranscribe = nil } }
      )
    ) {
      Button("Transcribe Again") {
        if let url = pendingRetranscribe { transcription.transcribe(recordingDirectory: url) }
        pendingRetranscribe = nil
      }
      Button("Cancel", role: .cancel) { pendingRetranscribe = nil }
    } message: {
      Text(
        "This replaces the current transcript and uploads the audio to Soniox again, which is billed."
      )
    }
  }

  /// One recording goes straight to the Trash, like anywhere else on the Mac.
  /// More than one is worth a look first: the two paths that can do it act on
  /// the whole selection, which is not always what the click was aimed at.
  private func confirmDelete(_ ids: Set<String>) {
    guard !ids.isEmpty else { return }
    if ids.count == 1 {
      deleteRecordings(ids)
    } else {
      pendingBulkDelete = ids
    }
  }

  private func scheduleReload(after delay: Duration = .zero) {
    reloadTask?.cancel()
    reloadTask = Task {
      if delay > .zero { try? await Task.sleep(for: delay) }
      guard !Task.isCancelled else { return }
      await loadRecordings()
    }
  }

  // MARK: - Sidebar List

  private var recordingsList: some View {
    // Computed once per pass. It was read four times - the empty check, the
    // grouping, and twice inside `countSummary` - and each read scans every
    // transcript body in the library.
    let filtered = filteredRecordings
    return Group {
      if recordings.isEmpty {
        ContentUnavailableView(
          "No Recordings",
          systemImage: "waveform",
          description: Text("Recordings will appear here when Blackbox captures audio.")
        )
      } else if filtered.isEmpty {
        ContentUnavailableView.search(text: searchText)
      } else {
        List(selection: $selection) {
          // Grouped by day. A flat list of three hundred near-identical titles
          // is not something anyone can find last Thursday's call in.
          ForEach(Self.grouped(filtered), id: \.key) { group in
            Section(group.key) {
              ForEach(group.value) { recording in
                RecordingRow(
                  recording: recording,
                  onRename: { newTitle in
                    renameRecording(recording, to: newTitle)
                  }
                )
                .tag(recording.id)
                .contextMenu { contextMenu(for: recording) }
              }
            }
          }
        }
        // Scoped to what the search is actually showing: the selection
        // survives filtering, so Delete could otherwise take rows the user
        // cannot see.
        .onDeleteCommand { confirmDelete(visibleSelection(in: filtered)) }
      }
    }
    .frame(minWidth: 220)
    .navigationSplitViewColumnWidth(min: 220, ideal: 280)
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Text(Self.countSummary(for: filtered, of: recordings))
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func visibleSelection(in filtered: [RecordingFile]) -> Set<String> {
    let visible = Set(filtered.map(\.id))
    return selection.intersection(visible)
  }

  @ViewBuilder
  private func contextMenu(for recording: RecordingFile) -> some View {
    // Intersected with what the search is showing, for the same reason the
    // Delete key is: the selection survives filtering, so "Delete 12
    // Recordings" could otherwise include rows that are not on screen.
    let visible = visibleSelection(in: filteredRecordings)
    let targets = visible.contains(recording.id) ? visible : [recording.id]
    if targets.count == 1, recording.hasAudio, transcription.hasAPIKey,
      !transcription.status(for: recording.url).isActive
    {
      if recording.hasTranscript {
        // Replaces a transcript that already exists and pays for it again, so
        // it asks - the same rule as the detail view's button, which used to
        // confirm while this one did not.
        Button("Transcribe Again…") { pendingRetranscribe = recording.url }
      } else {
        Button("Transcribe") { transcription.transcribe(recordingDirectory: recording.url) }
      }
      Divider()
    }
    Button("Reveal in Finder") { revealInFinder(targets) }
    Button(targets.count > 1 ? "Export \(targets.count) Recordings…" : "Export Audio…") {
      exportRecordings(targets)
    }
    Divider()
    Button(targets.count > 1 ? "Delete \(targets.count) Recordings" : "Delete", role: .destructive)
    {
      confirmDelete(targets)
    }
  }

  /// Title match, plus transcript body so the archive is searchable by what was
  /// said rather than only by what it was called.
  private var filteredRecordings: [RecordingFile] {
    let query = searchQuery.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return recordings }
    return recordings.filter {
      $0.title.localizedCaseInsensitiveContains(query)
        || ($0.transcriptText?.localizedCaseInsensitiveContains(query) ?? false)
    }
  }

  private static func grouped(_ recordings: [RecordingFile])
    -> [(key: String, value: [RecordingFile])]
  {
    let calendar = Calendar.current
    // Hoisted: `sectionTitle` built two of these per recording.
    let now = Date()
    var order: [String] = []
    var groups: [String: [RecordingFile]] = [:]
    for recording in recordings {
      let key = sectionTitle(for: recording.date, calendar: calendar, now: now)
      if groups[key] == nil { order.append(key) }
      groups[key, default: []].append(recording)
    }
    return order.map { ($0, groups[$0] ?? []) }
  }

  private static func sectionTitle(for date: Date, calendar: Calendar, now: Date) -> String {
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), date > weekAgo {
      return date.formatted(.dateTime.weekday(.wide))
    }
    if calendar.isDate(date, equalTo: now, toGranularity: .year) {
      return date.formatted(.dateTime.month(.wide))
    }
    return date.formatted(.dateTime.month(.wide).year())
  }

  /// Says "3 of 326" while a search is narrowing the list. Reporting only the
  /// filtered count made the size of the library itself disappear the moment
  /// anything was typed.
  private static func countSummary(for shown: [RecordingFile], of all: [RecordingFile]) -> String {
    let total = ByteCountFormatter.string(
      fromByteCount: Int64(shown.reduce(0) { $0 + $1.size }), countStyle: .file)
    let noun = shown.count == 1 ? "recording" : "recordings"
    if shown.count == all.count {
      return "\(shown.count) \(noun), \(total)"
    }
    return "\(shown.count) of \(all.count) \(noun), \(total)"
  }

  // MARK: - Data

  // Directory enumeration + resourceValues is synchronous I/O that blocks MainActor.
  // With hundreds of recordings this freezes the UI on every window activation.
  private func loadRecordings() async {
    let dir = URL(fileURLWithPath: saveDirectoryPath)
    let loaded: [RecordingFile] = await Task.detached {
      var results: [RecordingFile] = []

      for url in RecordingStore.directories(in: dir) {
        // One stat per file: a successful `resourceValues` is itself the
        // existence check, so probing with `fileExists` first only doubled the
        // syscalls on a scan that runs for every recording.
        let originalURL = url.appendingPathComponent(RecordingStore.audioName)
        guard let originalValues = try? originalURL.resourceValues(forKeys: [.fileSizeKey])
        else { continue }
        // A zero-byte original is shown, not skipped. It means a call happened
        // and the capture produced nothing, which is information the user needs
        // - hiding it reads as "the recording never started", and leaves a
        // directory with no way to delete it from inside the app. The row marks
        // itself as failed and refuses to play or transcribe.
        let hasAudio = (originalValues.fileSize ?? 0) > 0
        let processedURL = url.appendingPathComponent(RecordingStore.processedAudioName)
        let processedValues = try? processedURL.resourceValues(forKeys: [.fileSizeKey])
        let hasProcessed = (processedValues?.fileSize ?? 0) > 0
        let metadata = RecordingMetadata.load(in: url)
        let originalSize = originalValues.fileSize ?? 0
        let processedSize = processedValues?.fileSize ?? 0
        let transcript = TranscriptDocument.load(for: url)
        results.append(
          RecordingFile(
            url: url,
            title: metadata?.title ?? url.deletingPathExtension().lastPathComponent,
            date: metadata?.createdAt
              ?? (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
              ).contentModificationDate) ?? .distantPast,
            size: originalSize + processedSize,
            hasAudio: hasAudio,
            hasProcessed: hasProcessed,
            // `load` already opened the sidecar one line up, so the extra
            // `fileExists` was a second syscall per recording per scan - and a
            // sidecar that exists but will not decode is better reported as no
            // transcript than as one the detail view cannot show.
            hasTranscript: transcript != nil,
            transcriptText: transcript.map { $0.segments.map(\.text).joined(separator: " ") }
          ))
      }

      return results.sorted { $0.date > $1.date }
    }.value
    recordings = loaded
  }

  // MARK: - Actions

  private func revealInFinder(_ ids: Set<String>) {
    let urls = recordings.filter { ids.contains($0.id) }.map(\.url)
    guard !urls.isEmpty else { return }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
  }

  private func exportRecordings(_ ids: Set<String>) {
    guard !ids.isEmpty else { return }
    // A recording with a zero-byte original has nothing to copy: `exportM4A`
    // throws on `loadTracks` and the user gets "Failed to export 1 of 1" from a
    // save panel they should never have been shown.
    let selected = recordings.filter { ids.contains($0.id) && $0.hasAudio }
    guard !selected.isEmpty else {
      actionError = ActionError(
        title: "Nothing to Export",
        message: ids.count == 1
          ? "That recording captured no audio."
          : "None of the selected recordings captured any audio.")
      return
    }

    if selected.count == 1, let recording = selected.first {
      let baseName = recording.title
      let panel = NSSavePanel()
      panel.nameFieldStringValue = "\(baseName).m4a"
      panel.allowedContentTypes = [.mpeg4Audio]
      guard panel.runModal() == .OK, let dest = panel.url else { return }
      Task {
        do {
          // The ORIGINAL, not `audioURL`, which prefers the echo-cancelled
          // copy. That copy is 16kHz mono - exporting it silently handed the
          // user a downgraded file believing it was their recording. Playback
          // offers an explicit choice; export had none.
          try await TranscriptionService.exportM4A(
            from: recording.url.appendingPathComponent(RecordingStore.audioName), to: dest)
        } catch {
          actionError = ActionError(
            title: "Export Failed", message: error.localizedDescription)
        }
      }
    } else {
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.canCreateDirectories = true
      panel.prompt = "Export"
      panel.message = "Choose a folder to export \(selected.count) recordings as M4A"
      guard panel.runModal() == .OK, let dest = panel.url else { return }
      Task {
        var failed = 0
        var overwritten = 0
        for recording in selected {
          // The title is user-editable, is not a filename, and is not unique -
          // three Zoom calls in one day share one. Joining it raw let a title
          // containing "../" walk out of the chosen folder, and `exportM4A`
          // unconditionally removes its destination, so exports silently
          // replaced each other. The recording's own directory name carries the
          // timestamp that makes it unique.
          let target = dest.appendingPathComponent(
            Self.exportFileName(for: recording.title, uniqueSuffix: recording.url.lastPathComponent)
          )
          if FileManager.default.fileExists(atPath: target.path) { overwritten += 1 }
          do {
            try await TranscriptionService.exportM4A(
              from: recording.url.appendingPathComponent(RecordingStore.audioName), to: target)
          } catch {
            failed += 1
          }
        }
        // Both are reported. A batch that overwrote *and* failed used to say
        // only that it failed, which is the half the user can see for
        // themselves.
        let overwriteNote =
          overwritten > 0
          ? " \(overwritten) replaced a file of the same name in that folder." : ""
        if failed > 0 {
          actionError = ActionError(
            title: "Export Failed",
            message: "Failed to export \(failed) of \(selected.count) recordings.\(overwriteNote)")
        } else if overwritten > 0 {
          actionError = ActionError(
            title: "Export Finished",
            message:
              "\(overwritten) of \(selected.count) recordings replaced a file of the same name in that folder."
          )
        }
      }
    }
  }

  /// A single path component, always, and unique across a batch. Sanitising
  /// keeps it inside the chosen folder; the suffix - the recording's directory
  /// name, which carries its timestamp - keeps two same-titled calls apart.
  static func exportFileName(for title: String, uniqueSuffix: String? = nil) -> String {
    let cleaned =
      title
      .components(separatedBy: CharacterSet(charactersIn: "/:"))
      .joined(separator: "-")
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "."))
      // Again, because the dot-trim can expose whitespace: ". ." trimmed once
      // is " ", which is not empty and names a file " .m4a".
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let base = cleaned.isEmpty ? "Recording" : cleaned
    guard let uniqueSuffix, !uniqueSuffix.isEmpty else { return "\(base).m4a" }
    return "\(base) \(uniqueSuffix).m4a"
  }

  private func deleteRecordings(_ ids: Set<String>) {
    var failed: [String] = []
    for recording in recordings where ids.contains(recording.id) {
      // Read before the move, used after it. Trashing first is what stops an
      // irreversible Soniox DELETE from firing for a recording that then fails
      // to trash - but the sidecar naming those remote artifacts goes to the
      // Trash with the directory, so the ids have to be captured here or the
      // cleanup has nothing to delete and the audio stays on Soniox forever.
      let job = TranscriptionJob.load(for: recording.url)
      do {
        try FileManager.default.trashItem(at: recording.url, resultingItemURL: nil)
        transcription.forgetDeletedRecording(recordingDirectory: recording.url, job: job)
      } catch {
        failed.append(recording.title)
        Log.error(
          Log.app, "delete",
          "could not trash \(recording.url.lastPathComponent): \(error.localizedDescription)")
      }
    }
    selection.subtract(ids)
    if !failed.isEmpty {
      actionError = ActionError(
        title: "Delete Failed",
        message: failed.count == 1
          ? "Could not move \"\(failed[0])\" to the Trash."
          : "Could not move \(failed.count) recordings to the Trash.")
    }
    scheduleReload()
  }

  private func renameRecording(_ recording: RecordingFile, to newTitle: String) {
    var metadata =
      RecordingMetadata.load(in: recording.url)
      ?? RecordingMetadata(
        title: recording.title,
        createdAt: recording.date,
        appName: recording.title,
        speakers: [:]
      )
    metadata.title = newTitle
    do {
      try metadata.save(in: recording.url)
    } catch {
      // Was `try?`. The list reloads from disk straight afterwards, so a failed
      // write showed the old title again with no explanation - and this is the
      // path that rebuilds the record from a failed load, so a silent failure
      // here is how a title is lost for good.
      actionError = ActionError(
        title: "Rename Failed", message: error.localizedDescription)
    }
    scheduleReload()
  }
}

// MARK: - Recording Row

private struct RecordingRow: View {
  let recording: RecordingFile
  var onRename: (String) -> Void

  @Environment(TranscriptionCoordinator.self) private var transcription
  @State private var isEditing = false
  @State private var editedTitle = ""
  @FocusState private var titleFieldFocused: Bool

  /// Focus has to be requested explicitly. Swapping in a `TextField` does not
  /// make it first responder, so renaming used to present a caret-less field
  /// that swallowed the first thing you typed.
  private func beginRename() {
    editedTitle = recording.title
    isEditing = true
    titleFieldFocused = true
  }

  /// Each stage gets its own glyph rather than one shared spinner: in this row
  /// the indicator is the only signal a recording is being transcribed at all,
  /// and "waiting on a recording" and "stalled offline" are things the user can
  /// act on, while "transcribing" is not.
  @ViewBuilder private var transcriptionIndicator: some View {
    let status = transcription.status(for: recording.url)
    switch status {
    case .idle, .completed:
      EmptyView()
    case .error:
      Image(systemName: "exclamationmark.triangle")
        .font(.caption2)
        .foregroundStyle(.orange)
        .accessibilityLabel("Transcription failed")
        .help("Transcription failed - open the recording to retry")
    case .offline:
      Image(systemName: "wifi.slash")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Waiting for a network connection")
        .help("Offline - Blackbox will keep trying")
    default:
      ProgressView()
        .controlSize(.small)
        .frame(width: 14, height: 14)
        .accessibilityLabel(Self.statusText(status))
        .help(Self.statusText(status))
    }
  }

  /// One utterance per row rather than four loose elements, and it carries the
  /// transcription state, which was otherwise conveyed only by a spinner.
  private var accessibilityDescription: String {
    var parts = [recording.title, recording.date.formatted(date: .abbreviated, time: .shortened)]
    if recording.hasTranscript { parts.append("transcribed") }
    if recording.hasProcessed { parts.append("echo removed") }
    let status = transcription.status(for: recording.url)
    if status.isActive { parts.append(Self.statusText(status)) }
    return parts.joined(separator: ", ")
  }

  private static func rowDateFormat(for date: Date) -> Date.FormatStyle {
    Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
      ? .dateTime.month().day().hour().minute()
      : .dateTime.year().month().day().hour().minute()
  }

  /// Shared with the detail view so a row and the pane it opens can never
  /// describe the same job differently.
  static func statusText(_ status: TranscriptionStatus) -> String {
    switch status {
    case .idle: "Not transcribed"
    case .queued: "Waiting in line"
    case .mixing: "Preparing audio"
    case .uploading: "Uploading"
    case .transcribing: "Transcribing"
    case .offline: "No connection - Blackbox will keep trying"
    case .retrying(let attempt, let total): "Retrying (attempt \(attempt) of \(total))"
    case .cancelling: "Cancelling"
    case .completed: "Transcribed"
    case .error(let message): message
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        if isEditing {
          TextField("Title", text: $editedTitle)
            .onSubmit {
              let trimmed = editedTitle.trimmingCharacters(in: .whitespaces)
              if !trimmed.isEmpty {
                onRename(trimmed)
              }
              isEditing = false
            }
            .focused($titleFieldFocused)
            .textFieldStyle(.plain)
            .lineLimit(1)
            .onExitCommand { isEditing = false }
        } else {
          Text(recording.title)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(recording.title)
            .onTapGesture(count: 2) { beginRename() }
        }
        if !recording.hasAudio {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
            .help("This recording captured no audio")
            .accessibilityLabel("Recording failed - no audio was captured")
        }
        if recording.hasProcessed {
          Image(systemName: "waveform.badge.magnifyingglass")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .help("Echo cancellation applied")
        }
        if recording.hasTranscript {
          Image(systemName: "text.quote")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        transcriptionIndicator
      }
      HStack {
        // Relative for recent items and year-qualified beyond this one: a call
        // from last March was indistinguishable from one this March.
        Text(recording.date, format: Self.rowDateFormat(for: recording.date))
        Spacer()
        Text(recording.sizeFormatted)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityDescription)
  }
}

// MARK: - Recording Detail View

struct RecordingDetailView: View {
  let recording: RecordingFile
  var onDelete: () -> Void
  var onTitleChanged: () -> Void

  @Environment(TranscriptionCoordinator.self) private var transcription

  // Playback
  @State private var player: AVPlayer?
  @State private var isPlaying = false
  @State private var duration: TimeInterval = 0
  @State private var currentTime: TimeInterval = 0
  @State private var timeObserver: Any?
  @State private var isDragging = false
  @State private var playerError: String?
  @State private var waveformSamples: [Float] = []
  @State private var trackSelection: TrackSelection = .all
  @State private var useProcessed: Bool = true

  // UI
  @State private var showDeleteConfirmation = false
  @State private var showRetranscribeConfirmation = false
  @State private var isProcessingAEC = false
  /// Set when the user scrolls the transcript themselves, so following the
  /// playhead never yanks the view out from under them. Cleared by the
  /// "Jump to current" button or by seeking.
  @State private var isFollowSuspended = false
  @State private var didCopyTranscript = false
  @State private var actionError: RecordingsView.ActionError?
  @AppStorage(SettingsKeys.playbackRate) private var playbackRate: Double = 1

  // Metadata
  @State private var metadata: RecordingMetadata?
  @State private var isEditingTitle = false
  @FocusState private var titleFieldFocused: Bool
  @State private var editedTitle = ""

  // Transcription
  @State private var transcript: TranscriptDocument?

  var body: some View {
    VStack(spacing: 0) {
      metadataHeader
      Divider()
      if !recording.hasAudio {
        // Shown rather than hidden from the list: the user needs to know a call
        // produced nothing, and needs to be able to delete it.
        VStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle")
            .font(.title)
            .foregroundStyle(.orange)
          Text("This recording captured no audio")
            .font(.headline)
          Text(
            "The capture produced an empty file. There is nothing to play, transcribe or export - you can delete it with the button above."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let playerError {
        VStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle")
            .font(.title)
            .foregroundStyle(.secondary)
          Text("Could not load audio: \(playerError)")
            .font(.caption)
            .foregroundStyle(.secondary)
          // The source picker normally lives inside `playbackControls`, which
          // this branch replaces - so when the echo-cancelled copy was the file
          // that would not open, the one control that switches back to the
          // intact original disappeared with it.
          if recording.hasProcessed {
            Picker("Audio", selection: $useProcessed) {
              Text("Original").tag(false)
              Text("Echo removed").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: useProcessed) { _, _ in switchAudioSource() }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        playbackControls
        Divider()
        transcriptArea
      }
    }
    .onAppear {
      loadMetadata()
      // No player for a capture that produced nothing: `AVPlayer` on an empty
      // file only produces an error to show underneath a message that already
      // says the same thing.
      if recording.hasAudio { setupPlayer() }
      loadTranscript()
    }
    // The cached metadata is the source for every write below, and `.id` is the
    // directory path, which a rename does not change - so renaming in the
    // sidebar left this view holding the old title, and the next speaker rename
    // wrote it back over the new one.
    .onChange(of: recording.title) { _, _ in loadMetadata() }
    .onChange(of: transcription.finishCount(for: recording.url)) { _, _ in
      // Decoding a transcript is main-thread JSON work proportional to call
      // length, so only the recording that actually finished reloads - not
      // every open detail view every time any job anywhere completes.
      loadTranscript()
    }
    .onDisappear {
      teardownPlayer()
    }
    .focusable()
    .onKeyPress(.space) {
      togglePlayback()
      return .handled
    }
    .onKeyPress(.leftArrow) {
      skip(by: -15)
      return .handled
    }
    .onKeyPress(.rightArrow) {
      skip(by: 15)
      return .handled
    }
  }

  // MARK: - Header

  private var metadataHeader: some View {
    HStack {
      VStack(alignment: .leading, spacing: 4) {
        if isEditingTitle {
          TextField("Title", text: $editedTitle)
            .onSubmit {
              let trimmed = editedTitle.trimmingCharacters(in: .whitespaces)
              if !trimmed.isEmpty {
                saveTitle(trimmed)
              }
              isEditingTitle = false
            }
            .focused($titleFieldFocused)
            .font(.headline)
            .textFieldStyle(.plain)
            .onExitCommand { isEditingTitle = false }
        } else {
          Text(recording.title)
            .font(.headline)
            .onTapGesture(count: 2) { beginRename() }
            .help("Double-click to rename")
        }
        HStack(spacing: 8) {
          Text(recording.date.formatted(.dateTime.year().month().day().hour().minute()))
          Text(recording.sizeFormatted)
          if duration > 0 {
            Text(formatHMS(duration))
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      HStack(spacing: 8) {
        if transcript != nil {
          Button {
            copyTranscript()
          } label: {
            Image(systemName: didCopyTranscript ? "checkmark" : "doc.on.doc")
          }
          .accessibilityLabel("Copy Transcript")
          .help("Copy the whole transcript")

          Button {
            exportTranscript()
          } label: {
            Image(systemName: "square.and.arrow.down")
          }
          .accessibilityLabel("Export Transcript")
          .help("Export Transcript")

          // Without this a bad transcript was permanent: the transcript area
          // only offers Retry on the error path, so a transcript that arrived
          // garbled, in the wrong language, or from the wrong model could only
          // be replaced by deleting the sidecar in Finder.
          Button {
            showRetranscribeConfirmation = true
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .accessibilityLabel("Transcribe Again")
          .help("Transcribe again - replaces the current transcript")
          .disabled(transcriptionStatus.isActive)
        }

        // A recording that captured nothing has no mic track to clean, so the
        // button could only ever fail - under a headline that already says
        // there is nothing to do with this recording.
        if !recording.hasProcessed, recording.hasAudio {
          Button {
            runAEC()
          } label: {
            if isProcessingAEC {
              ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            } else {
              Image(systemName: "waveform.badge.magnifyingglass")
            }
          }
          .accessibilityLabel(
            isProcessingAEC ? "Removing echo" : "Remove Echo from Microphone Track"
          )
          .help("Remove echo from mic track")
          .disabled(isProcessingAEC)
        }

        Button {
          NSWorkspace.shared.activateFileViewerSelecting([recording.url])
        } label: {
          Image(systemName: "folder")
        }
        .accessibilityLabel("Reveal in Finder")
        .help("Reveal in Finder")

        Button(role: .destructive) {
          showDeleteConfirmation = true
        } label: {
          Image(systemName: "trash")
        }
        .accessibilityLabel("Delete Recording")
        .help("Delete")
      }
    }
    .padding()
    .alert(item: $actionError) { error in
      Alert(
        title: Text(error.title), message: Text(error.message),
        dismissButton: .default(Text("OK")))
    }
    .alert("Transcribe Again?", isPresented: $showRetranscribeConfirmation) {
      Button("Transcribe Again") { startTranscription() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "This replaces the current transcript and uploads the audio to Soniox again, which is billed."
      )
    }
    .alert("Delete Recording?", isPresented: $showDeleteConfirmation) {
      Button("Delete", role: .destructive, action: onDelete)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will move \"\(recording.title)\" to the Trash.")
    }
  }

  // MARK: - Playback

  private var playbackControls: some View {
    VStack(spacing: 8) {
      WaveformView(
        samples: waveformSamples,
        progress: duration > 0 ? currentTime / duration : 0,
        duration: duration,
        onSeek: { fraction, isFinal in
          // `isDragging` gates the 10 Hz time observer. It was declared and
          // read but never assigned, so every observer tick overwrote the drag
          // and the playhead snapped backwards under the cursor.
          isDragging = !isFinal
          seekTo(fraction * duration, exact: isFinal)
          if isFinal { isFollowSuspended = false }
        }
      )
      .frame(height: 48)

      HStack {
        Text(formatHMS(currentTime))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        if recording.hasProcessed {
          // Real titles rather than `Picker("")`: an empty label is not a
          // hidden label, it is no accessibility name at all.
          Picker("Audio", selection: $useProcessed) {
            Text("Original").tag(false)
            Text("Echo removed").tag(true)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
          .onChange(of: useProcessed) { _, _ in
            switchAudioSource()
          }
        }
        Picker("Voices", selection: $trackSelection) {
          ForEach(availableTrackSelections) { t in
            Text(t.label).tag(t)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .onChange(of: trackSelection) { _, newValue in
          applyTrackSelection(newValue)
        }
        Spacer()
        Text("-\(formatHMS(max(0, duration - currentTime)))")
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
      }

      HStack(spacing: 20) {
        Button {
          skip(by: -15)
        } label: {
          Image(systemName: "gobackward.15")
            .font(.title3)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Skip Back 15 Seconds")
        .help("Skip back 15 seconds")

        Button {
          togglePlayback()
        } label: {
          Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
            .font(.largeTitle)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isPlaying ? "Pause" : "Play")
        .accessibilityValue(isPlaying ? "Playing" : "Paused")
        .help(isPlaying ? "Pause" : "Play")

        Button {
          skip(by: 15)
        } label: {
          Image(systemName: "goforward.15")
            .font(.title3)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Skip Forward 15 Seconds")
        .help("Skip forward 15 seconds")

        // Reviewing an hour-long call at 1x is the difference between a tool
        // people use and one they abandon.
        Menu {
          Picker("Speed", selection: $playbackRate) {
            ForEach(Self.playbackRates, id: \.self) { rate in
              Text(Self.rateLabel(rate)).tag(rate)
            }
          }
          .pickerStyle(.inline)
          .labelsHidden()
        } label: {
          Text(Self.rateLabel(playbackRate))
            .font(.caption.monospacedDigit())
            .frame(minWidth: 34)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Playback Speed")
        .accessibilityValue(Self.rateLabel(playbackRate))
        .help("Playback speed")
        .onChange(of: playbackRate) { _, newValue in
          // Only while playing: setting a non-zero rate on a paused player
          // starts it.
          if isPlaying { player?.rate = Float(newValue) }
        }
      }
    }
    .padding()
  }

  private static let playbackRates: [Double] = [0.75, 1, 1.25, 1.5, 1.75, 2]

  private static func rateLabel(_ rate: Double) -> String {
    rate == rate.rounded() ? "\(Int(rate))x" : "\(rate)x"
  }

  private var activeAudioURL: URL {
    if useProcessed, recording.hasProcessed {
      return recording.url.appendingPathComponent(RecordingStore.processedAudioName)
    }
    return recording.url.appendingPathComponent(RecordingStore.audioName)
  }

  private func switchAudioSource() {
    let wasPlaying = isPlaying
    let savedTime = currentTime
    teardownPlayer()
    setupPlayer()
    if savedTime > 0, savedTime < duration {
      seekTo(savedTime)
    }
    if wasPlaying {
      player?.play()
      isPlaying = true
    }
    trackSelection = .all
  }

  private func setupPlayer() {
    let asset = AVURLAsset(url: activeAudioURL)
    let item = AVPlayerItem(asset: asset)
    let p = AVPlayer(playerItem: item)
    player = p
    playerError = nil
    currentTime = 0

    // Get duration + waveform once asset is loaded
    Task {
      do {
        let dur = try await asset.load(.duration)
        duration = dur.seconds.isFinite ? dur.seconds : 0
        let samples = await WaveformExtractor.extract(from: activeAudioURL)
        waveformSamples = samples
      } catch {
        playerError = error.localizedDescription
        Log.error(
          Log.app, "playback",
          "failed to load asset: \(error.localizedDescription)")
      }
    }

    // The interval is in the *item's* timeline, so at 2x this fires ~20x/sec.
    // Every tick invalidates the whole detail view, so the value is deliberately
    // not written when it has not changed at this resolution.
    let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
    timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
      // Already on the main queue; the `Task` hop only cost an extra turn.
      //
      // No change-detection threshold here. One was added to cut re-renders and
      // it quantised the playhead into visible steps - the transport is the one
      // thing in this view that has to look continuous.
      MainActor.assumeIsolated {
        guard !isDragging, time.seconds.isFinite else { return }
        currentTime = time.seconds
      }
    }

    // End-of-track notification
    endObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime,
      object: item,
      queue: .main
    ) { _ in
      Task { @MainActor in
        isPlaying = false
        currentTime = 0
        p.seek(to: .zero)
      }
    }
  }

  @State private var endObserver: (any NSObjectProtocol)?

  private func teardownPlayer() {
    if let observer = timeObserver {
      player?.removeTimeObserver(observer)
      timeObserver = nil
    }
    if let observer = endObserver {
      NotificationCenter.default.removeObserver(observer)
      endObserver = nil
    }
    player?.pause()
    player = nil
    isPlaying = false
    currentTime = 0
  }

  private func togglePlayback() {
    guard let player else { return }
    if isPlaying {
      player.pause()
    } else {
      // `rate` rather than `play()`, so resuming honours the chosen speed
      // instead of silently snapping back to 1x.
      player.rate = Float(playbackRate)
    }
    isPlaying = !isPlaying
  }

  /// `exact` is false during a drag. A zero-tolerance seek per drag tick makes
  /// the audio judder; one exact seek when the finger lifts is what the user
  /// actually asked for.
  private func seekTo(_ time: TimeInterval, exact: Bool = true) {
    let cmTime = CMTime(seconds: time, preferredTimescale: 600)
    if exact {
      player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
    } else {
      player?.seek(to: cmTime)
    }
    currentTime = time
  }

  private var availableTrackSelections: [TrackSelection] {
    let count = metadata?.trackCount ?? 2
    if count >= 3 {
      return [.all, .system, .perApp, .mic]
    } else {
      return [.all, .system, .mic]
    }
  }

  private func applyTrackSelection(_ selection: TrackSelection) {
    guard let tracks = player?.currentItem?.tracks else { return }
    let audioTracks = tracks.filter { $0.assetTrack?.mediaType == .audio }
    let trackCount = audioTracks.count
    for (i, track) in audioTracks.enumerated() {
      let isLast = (i == trackCount - 1)
      switch selection {
      case .all: track.isEnabled = true
      case .system: track.isEnabled = (i == 0)
      case .perApp: track.isEnabled = (trackCount >= 3 && i == 1)
      case .mic: track.isEnabled = isLast
      }
    }
  }

  private func skip(by seconds: TimeInterval) {
    let newTime = max(0, min(duration, currentTime + seconds))
    seekTo(newTime)
  }

  // MARK: - Echo Cancellation

  private func runAEC() {
    isProcessingAEC = true
    Task {
      do {
        // Every non-outcome is reported. The most reachable one is a recording
        // made with the microphone off, where the button is offered on a file
        // that has no mic track to clean and used to do nothing at all.
        switch try await AECProcessor.process(recordingDirectory: recording.url) {
        case .processed, .alreadyRunning:
          break
        case .alreadyProcessed:
          actionError = RecordingsView.ActionError(
            title: "Already Processed",
            message: "This recording already has an echo-cancelled copy.")
        case .nothingToProcess:
          actionError = RecordingsView.ActionError(
            title: "Nothing to Process",
            message:
              "This recording has no separate microphone track, so there is no echo to remove.")
        }
      } catch {
        // Was fire-and-forget: the spinner simply stopped, the button stayed,
        // and the user had no way to tell whether it had run.
        actionError = RecordingsView.ActionError(
          title: "Echo Cancellation Failed", message: error.localizedDescription)
      }
      isProcessingAEC = false
      // Through the list's own reload, like every other trigger.
      onTitleChanged()
    }
  }

  // MARK: - Metadata

  private func loadMetadata() {
    metadata = RecordingMetadata.load(in: recording.url)
  }

  private func beginRename() {
    editedTitle = recording.title
    isEditingTitle = true
    titleFieldFocused = true
  }

  /// The one place that rebuilds a record from a failed load and writes it
  /// back. `appName` genuinely has no better source here - it is not on
  /// `RecordingFile` - so a reconstruction loses it, which is why the write
  /// failing silently was worth surfacing.
  private func writeMetadata(_ mutate: (inout RecordingMetadata) -> Void) {
    var meta =
      metadata
      ?? RecordingMetadata(
        title: recording.title,
        createdAt: recording.date,
        appName: recording.title,
        speakers: [:]
      )
    mutate(&meta)
    do {
      try meta.save(in: recording.url)
      metadata = meta
    } catch {
      // Was `try?` in all three rename paths, and two of them then assigned the
      // in-memory copy anyway - so the UI showed a rename that never reached
      // disk and reverted at the next scan.
      actionError = RecordingsView.ActionError(
        title: "Could Not Save", message: error.localizedDescription)
    }
  }

  private func saveTitle(_ newTitle: String) {
    writeMetadata { $0.title = newTitle }
    onTitleChanged()
  }

  private func speakerName(for speakerID: Int) -> String {
    if let name = metadata?.speakers[String(speakerID)], !name.isEmpty {
      return name
    }
    // `+ 1` on `Int.max` traps, and this value comes off disk.
    return speakerID == -1 ? "You" : "Speaker \(speakerID &+ 1)"
  }

  private func saveSpeakerName(_ name: String, for speakerID: Int) {
    writeMetadata { $0.speakers[String(speakerID)] = name }
  }

  // MARK: - Transcript

  private var transcriptionStatus: TranscriptionStatus {
    transcription.status(for: recording.url)
  }

  private var transcriptArea: some View {
    Group {
      // Order matters here, and it is not the obvious one.
      //
      // A running job wins over an existing transcript, because re-transcribing
      // otherwise looked like nothing happened - the old text stayed on screen
      // with no progress and no way to tell the request had registered.
      //
      // An existing transcript then wins over an error, because a failed
      // re-transcribe must not cost the user the transcript they already had.
      // The row's indicator still shows the failure.
      if transcriptionStatus.isActive {
        VStack(spacing: 12) {
          // Determinate wherever the stage can actually report itself. Mixing
          // and uploading a long call are minutes each, and an indeterminate
          // spinner through that is indistinguishable from a stall.
          if let fraction = transcriptionStatus.fraction {
            ProgressView(value: fraction)
              .progressViewStyle(.linear)
              .frame(maxWidth: 220)
              .accessibilityLabel(RecordingRow.statusText(transcriptionStatus))
              .accessibilityValue("\(Int(fraction * 100)) percent")
          } else {
            ProgressView()
              .accessibilityLabel(RecordingRow.statusText(transcriptionStatus))
          }
          Text(transcriptionStatusText)
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("Cancel") { cancelTranscription() }
            .buttonStyle(.bordered)
            .disabled(transcriptionStatus == .cancelling)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let transcript, !transcript.segments.isEmpty {
        transcriptView(transcript)
      } else if case .error(let msg) = transcriptionStatus {
        VStack(spacing: 12) {
          Image(systemName: "exclamationmark.triangle")
            .font(.title)
            .foregroundStyle(.secondary)
          Text(msg)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          Button("Retry") { startTranscription() }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        VStack(spacing: 12) {
          if !transcription.hasAPIKey {
            Text("Add your Soniox API key in Settings to enable transcription")
              .font(.caption)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          } else {
            Button("Transcribe") { startTranscription() }
              .buttonStyle(.borderedProminent)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
  }

  private var transcriptionStatusText: String {
    switch transcriptionStatus {
    case .mixing: "Preparing audio for transcription"
    case .uploading(let fraction): "Uploading - \(Int(fraction * 100))%"
    default: RecordingRow.statusText(transcriptionStatus)
    }
  }

  private func transcriptView(_ doc: TranscriptDocument) -> some View {
    // Hoisted so it is computed once per pass rather than once per rendered
    // row, which is what the property's own comment already claimed.
    let active = activeSegmentIndex
    return ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(Array(doc.segments.enumerated()), id: \.element.id) { index, segment in
            TranscriptSegmentView(
              segment: segment,
              speakerName: speakerName(for: segment.speaker),
              isActive: index == active,
              onSeek: { jumpTo(time: segment.time) },
              onRenameSpeaker: { newName in
                saveSpeakerName(newName, for: segment.speaker)
              }
            )
            .id(segment.id)
          }
        }
        .padding()
        // Long-form reading, not a data table: past roughly 700pt a line runs
        // far enough that the eye loses its place returning to the next one.
        .frame(maxWidth: 720, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
      }
      // Scrolling by hand stops the follow. Without this, reading back through
      // a transcript while it plays is a fight with the scroll position.
      .onScrollPhaseChange { _, phase in
        if phase == .interacting { isFollowSuspended = true }
      }
      .overlay(alignment: .bottomTrailing) {
        if isFollowSuspended, active != nil {
          Button {
            isFollowSuspended = false
            scrollToActiveSegment(in: doc, proxy: proxy)
          } label: {
            Label("Jump to current", systemImage: "arrow.down.circle.fill")
              .font(.caption)
          }
          .buttonStyle(.borderedProminent)
          .padding()
        }
      }
      .onChange(of: activeSegmentIndex) { _, _ in
        guard !isFollowSuspended else { return }
        scrollToActiveSegment(in: doc, proxy: proxy)
      }
    }
  }

  /// Which segment the playhead is inside, or nil before the first one.
  /// Callers hoist it out of the row loop, so it runs once per pass.
  ///
  /// Deliberately not gated on `isPlaying`. Pausing used to clear the highlight
  /// entirely, which is precisely when the user wants to see where they are.
  private var activeSegmentIndex: Int? {
    guard let segments = transcript?.segments, !segments.isEmpty else { return nil }
    // The playhead is normally inside or just past the previous match, so a
    // linear scan from the start is wasteful but bounded; a binary search is
    // the right shape and is what this is.
    var low = 0
    var high = segments.count - 1
    var found: Int?
    while low <= high {
      let mid = (low + high) / 2
      if segments[mid].time <= currentTime {
        found = mid
        low = mid + 1
      } else {
        high = mid - 1
      }
    }
    return found
  }

  private func scrollToActiveSegment(in doc: TranscriptDocument, proxy: ScrollViewProxy) {
    guard let index = activeSegmentIndex, doc.segments.indices.contains(index) else { return }
    withAnimation(.easeInOut(duration: 0.25)) {
      proxy.scrollTo(doc.segments[index].id, anchor: .center)
    }
  }

  private func jumpTo(time: Double) {
    seekTo(time)
    // Clicking a timestamp is an explicit "take me here", so it re-engages
    // following even if the user had scrolled away.
    isFollowSuspended = false
    if !isPlaying { togglePlayback() }
  }

  // MARK: - Transcription Lifecycle

  private func loadTranscript() {
    transcript = TranscriptDocument.load(for: recording.url)
  }

  /// Covers the first transcription, Retry, and Transcribe Again - they were
  /// three call sites of two byte-identical functions. The existing transcript
  /// is deliberately left on disk: a re-run that fails should leave the user
  /// where they started, and the new one overwrites it only on success.
  /// `transcriptArea` shows progress ahead of a stale transcript, so nothing
  /// here needs to clear the view.
  private func startTranscription() {
    transcription.transcribe(recordingDirectory: recording.url)
  }

  private func cancelTranscription() {
    transcription.cancel(recordingDirectory: recording.url)
  }

  // MARK: - Transcript Export

  /// Plain text with speaker and timestamp, because that is what someone pastes
  /// into a message or a doc. The JSON export stays for anything programmatic.
  private func copyTranscript() {
    guard let transcript, !transcript.segments.isEmpty else { return }
    let body = transcript.segments.map { segment in
      "[\(formatHMS(segment.time))] \(speakerName(for: segment.speaker)): \(segment.text)"
    }.joined(separator: "\n")
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(body, forType: .string)

    didCopyTranscript = true
    Task {
      try? await Task.sleep(for: .seconds(2))
      didCopyTranscript = false
    }
  }

  private func exportTranscript() {
    guard let transcript, !transcript.segments.isEmpty else { return }

    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(recording.title).txt"
    panel.allowedContentTypes = [.plainText, .json]
    // Both formats are offered in the panel itself. Plain text is the default
    // because that is what a transcript is usually pasted into, but JSON was
    // reachable only by typing the extension, which is not a choice anyone
    // finds.
    panel.accessoryView = NSHostingView(
      rootView: Text("Choose .txt for readable text, or .json for structured data.")
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(8)
    )
    guard panel.runModal() == .OK, let dest = panel.url else { return }

    let segments = transcript.segments.map { segment in
      ExportedSegment(
        speaker: speakerName(for: segment.speaker),
        time: formatHMS(segment.time),
        text: segment.text
      )
    }

    do {
      let data: Data
      if dest.pathExtension.lowercased() == "json" {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        data = try encoder.encode(segments)
      } else {
        // Plain text is the default now. Nobody outside this repo wants
        // `[{"speaker":…}]` when they meant to paste a transcript into a doc.
        let body = segments.map { "[\($0.time)] \($0.speaker): \($0.text)" }
          .joined(separator: "\n")
        data = Data(body.utf8)
      }
      try data.write(to: dest, options: .atomic)
    } catch {
      // Was logged and swallowed: the user picked a location, pressed Save, and
      // got no file and no error.
      actionError = RecordingsView.ActionError(
        title: "Export Failed", message: error.localizedDescription)
      Log.error(
        Log.app, "export",
        "failed to export transcript: \(error.localizedDescription)")
    }
  }

  // MARK: - Formatting

}

// MARK: - Transcript Segment View

/// The row is deliberately NOT a `Button`. Wrapping it made the whole segment
/// one tap target, which meant the transcript could not be selected or copied -
/// the words were pixels. Seeking now lives on the timestamp, which is a
/// discrete control, and the body text is ordinary selectable text.
private struct TranscriptSegmentView: View {
  let segment: TranscriptSegment
  let speakerName: String
  let isActive: Bool
  let onSeek: () -> Void
  let onRenameSpeaker: (String) -> Void

  @Environment(\.colorSchemeContrast) private var contrast
  @State private var showSpeakerPopover = false
  @State private var editedSpeakerName = ""
  @FocusState private var speakerFieldFocused: Bool
  @ScaledMetric(relativeTo: .caption) private var gutterWidth: CGFloat = 74

  private static let speakerColors: [Color] = [
    .blue, .green, .orange, .purple, .pink, .teal,
  ]

  private var isLocalUser: Bool { segment.speaker == -1 }

  private var speakerColor: Color {
    if isLocalUser { return .accentColor }
    // `%` keeps the sign in Swift, so a negative speaker id from a hand-edited
    // or corrupted sidecar indexed out of bounds and crashed the app.
    let index = abs(segment.speaker) % Self.speakerColors.count
    return Self.speakerColors[index]
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      VStack(alignment: .trailing, spacing: 2) {
        Button {
          editedSpeakerName = speakerName
          showSpeakerPopover = true
          speakerFieldFocused = true
        } label: {
          Text(speakerName)
            .font(.caption.bold())
            .foregroundStyle(speakerColor)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rename speaker \(speakerName)")
        .help("Rename this speaker")
        .popover(isPresented: $showSpeakerPopover) {
          VStack(spacing: 8) {
            Text("Speaker Name")
              .font(.caption.bold())
            TextField("Name", text: $editedSpeakerName)
              .textFieldStyle(.roundedBorder)
              .frame(width: 140)
              .focused($speakerFieldFocused)
              .onSubmit {
                let trimmed = editedSpeakerName.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { onRenameSpeaker(trimmed) }
                showSpeakerPopover = false
              }
          }
          .padding(12)
        }

        Button(action: onSeek) {
          Text(formatHMS(segment.time))
            .font(.caption2.monospacedDigit())
            // Was `.tertiary`, which is under 3:1 at this size - and this is a
            // functional control, not decoration.
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play from \(formatHMS(segment.time))")
        .help("Play from here")
      }
      .frame(width: gutterWidth, alignment: .trailing)

      Text(segment.text)
        .font(.body)
        // Always full contrast. This was `.secondary` for every inactive
        // segment, and since "active" required playback to be running, a paused
        // transcript - the normal reading state - was entirely grey.
        .foregroundStyle(.primary)
        .fontWeight(isActive ? .medium : .regular)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(.vertical, 4)
    .padding(.horizontal, 8)
    // Clicking anywhere on the row seeks, as it did before the transcript
    // became selectable. Making the whole row a `Button` is what selection
    // replaced, and a plain `onTapGesture` loses to the text's own click
    // handling - `simultaneousGesture` runs alongside it, so a click still
    // seeks and a drag still selects.
    .contentShape(Rectangle())
    .simultaneousGesture(TapGesture().onEnded { onSeek() })
    .background(
      isActive ? speakerColor.opacity(contrast == .increased ? 0.22 : 0.10) : Color.clear,
      in: RoundedRectangle(cornerRadius: 6)
    )
    .overlay(alignment: .leading) {
      // A non-colour cue for the active row: the tint alone is invisible under
      // Increase Contrast and to a colourblind reader.
      if isActive {
        RoundedRectangle(cornerRadius: 2)
          .fill(speakerColor)
          .frame(width: 3)
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(isActive ? [.isSelected] : [])
    .contextMenu {
      Button("Copy") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(segment.text, forType: .string)
      }
      Button("Play From Here", action: onSeek)
    }
  }

}

// MARK: - Track Selection

enum TrackSelection: String, Identifiable {
  case all, system, perApp, mic
  var id: String { rawValue }
  var label: String {
    switch self {
    case .all: "All"
    case .system: "System"
    case .perApp: "App"
    case .mic: "Mic"
    }
  }
}

// MARK: - Time Formatting

/// One formatter for every timestamp the app shows. There were four, and each
/// was fixed for the past-an-hour case separately: the transport and the
/// transcript rows got the hour component, the transcript *export* and the
/// scrubber's VoiceOver value did not - so a 78-minute call read "1:18:12" on
/// screen and "78:12" in the exported file.
nonisolated func formatHMS(_ seconds: TimeInterval) -> String {
  let total = seconds.isFinite ? max(0, Int(min(seconds, 24 * 60 * 60))) : 0
  let h = total / 3600
  let m = (total % 3600) / 60
  let s = total % 60
  return h > 0
    ? String(format: "%d:%02d:%02d", h, m, s)
    : String(format: "%d:%02d", m, s)
}

/// Spoken form of the same value, for `accessibilityValue`.
nonisolated func spokenDuration(_ seconds: TimeInterval) -> String {
  let total = seconds.isFinite ? max(0, Int(min(seconds, 24 * 60 * 60))) : 0
  let h = total / 3600
  let m = (total % 3600) / 60
  let s = total % 60
  var parts: [String] = []
  if h > 0 { parts.append("\(h) hour\(h == 1 ? "" : "s")") }
  if m > 0 { parts.append("\(m) minute\(m == 1 ? "" : "s")") }
  parts.append("\(s) second\(s == 1 ? "" : "s")")
  return parts.joined(separator: " ")
}

// MARK: - Recording File

struct RecordingFile: Identifiable {
  var id: String { url.path }
  let url: URL  // recording directory
  var title: String  // from metadata.title
  let date: Date  // from metadata.createdAt
  let size: Int
  /// False when `audio.m4a` is present but empty - a capture that produced
  /// nothing. The row still appears so it can be seen and deleted.
  let hasAudio: Bool
  let hasProcessed: Bool
  let hasTranscript: Bool
  /// Loaded during the off-main scan so search can match on what was said, not
  /// just the title. Nil when there is no transcript.
  let transcriptText: String?

  var sizeFormatted: String {
    ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
  }
}

// MARK: - Waveform View

private struct WaveformView: View {
  let samples: [Float]
  let progress: Double
  let duration: TimeInterval
  let onSeek: (Double, _ isFinal: Bool) -> Void

  @Environment(\.colorSchemeContrast) private var contrast

  private var unplayedOpacity: Double { contrast == .increased ? 0.55 : 0.3 }

  var body: some View {
    GeometryReader { geo in
      Canvas { context, size in
        guard !samples.isEmpty else { return }
        let barWidth: CGFloat = 2
        let gap: CGFloat = 1.5
        let step = barWidth + gap
        let barCount = Int(size.width / step)
        guard barCount > 0 else { return }

        let midY = size.height / 2
        let maxAmp = size.height / 2 - 1

        for i in 0..<barCount {
          let sampleIdx = i * samples.count / barCount
          let amp = CGFloat(samples[min(sampleIdx, samples.count - 1)])
          let barHeight = max(2, amp * maxAmp)
          let x = CGFloat(i) * step
          let fraction = Double(i) / Double(barCount)
          let color: Color =
            fraction <= progress ? .accentColor : .secondary.opacity(unplayedOpacity)

          let rect = CGRect(
            x: x,
            y: midY - barHeight,
            width: barWidth,
            height: barHeight * 2
          )
          context.fill(
            Path(roundedRect: rect, cornerRadius: 1),
            with: .color(color)
          )
        }

        // An explicit playhead, so the played/unplayed boundary does not rest
        // on colour alone.
        let headX = size.width * progress
        context.fill(
          Path(CGRect(x: max(0, headX - 0.5), y: 0, width: 1.5, height: size.height)),
          with: .color(.primary))
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            let fraction = max(0, min(1, value.location.x / geo.size.width))
            onSeek(fraction, false)
          }
          .onEnded { value in
            let fraction = max(0, min(1, value.location.x / geo.size.width))
            onSeek(fraction, true)
          }
      )
      // A `Canvas` is invisible to VoiceOver and its only affordance was a drag,
      // so scrubbing was mouse-only. As an adjustable element it is reachable
      // with the arrow keys and announces where it is.
      .accessibilityElement()
      .accessibilityLabel("Playback Position")
      .accessibilityValue(spokenDuration(progress * duration))
      .accessibilityAdjustableAction { direction in
        let step = 0.02
        let next = direction == .increment ? progress + step : progress - step
        onSeek(max(0, min(1, next)), true)
      }
    }
  }

}

// MARK: - Waveform Extractor

enum WaveformExtractor {
  nonisolated static let bucketCount = 300

  static func extract(from url: URL) async -> [Float] {
    let asset = AVURLAsset(url: url)
    guard
      let tracks = try? await asset.loadTracks(withMediaType: .audio),
      !tracks.isEmpty,
      let reader = try? AVAssetReader(asset: asset)
    else { return [] }
    return await Task.detached {
      extractSync(tracks: tracks, reader: reader)
    }.value
  }

  nonisolated private static func extractSync(tracks: [AVAssetTrack], reader: AVAssetReader)
    -> [Float]
  {
    let outputSettings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    // AudioMixOutput combines all tracks into a single mixed stream
    let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: outputSettings)
    output.alwaysCopiesSampleData = false
    reader.add(output)
    guard reader.startReading() else { return [] }

    // First pass: collect all samples into a flat buffer
    var allSamples: [Int16] = []
    allSamples.reserveCapacity(48000 * 60 * 5)  // ~5 min at 48kHz pre-alloc

    while let buffer = output.copyNextSampleBuffer() {
      guard let blockBuffer = CMSampleBufferGetDataBuffer(buffer) else { continue }
      let length = CMBlockBufferGetDataLength(blockBuffer)
      let sampleCount = length / MemoryLayout<Int16>.size
      let startIndex = allSamples.count
      allSamples.append(contentsOf: repeatElement(0, count: sampleCount))
      allSamples.withUnsafeMutableBufferPointer { ptr in
        guard let base = ptr.baseAddress else { return }
        _ = CMBlockBufferCopyDataBytes(
          blockBuffer, atOffset: 0, dataLength: length,
          destination: base.advanced(by: startIndex))
      }
    }

    guard !allSamples.isEmpty else { return [] }

    // Second pass: downsample into buckets
    let samplesPerBucket = max(1, allSamples.count / bucketCount)
    var result = [Float](repeating: 0, count: bucketCount)

    for i in 0..<bucketCount {
      let start = i * samplesPerBucket
      let end = min(start + samplesPerBucket, allSamples.count)
      guard start < end else { continue }
      var sum: Float = 0
      for j in start..<end {
        let s = Float(allSamples[j]) / 32768.0
        sum += s * s
      }
      result[i] = (sum / Float(end - start)).squareRoot()
    }

    // Normalize to 0...1
    let peak = result.max() ?? 1
    if peak > 0 {
      for i in 0..<result.count {
        result[i] /= peak
      }
    }

    return result
  }
}
