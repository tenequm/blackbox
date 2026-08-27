import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

enum MainTab: Hashable {
  case recordings
  case settings
}

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
  @AppStorage("saveDirectoryPath") private var saveDirectoryPath = defaultSaveDirectoryPath
  @State private var recordings: [RecordingFile] = []
  @State private var selectedRecordingID: String?
  @State private var exportError: String?
  @State private var reloadTask: Task<Void, Never>?

  var body: some View {
    NavigationSplitView {
      recordingsList
    } detail: {
      if let id = selectedRecordingID,
        let recording = recordings.first(where: { $0.id == id })
      {
        RecordingDetailView(
          recording: recording,
          onDelete: { deleteRecordings(Set([id])) },
          onTitleChanged: { Task { await loadRecordings() } }
        )
        .id(id)
      } else {
        ContentUnavailableView(
          "Select a Recording",
          systemImage: "waveform",
          description: Text("Choose a recording to play or transcribe.")
        )
      }
    }
    .task { await loadRecordings() }
    .onChange(of: transcription.revision) { _, _ in
      Task { await loadRecordings() }
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      reloadTask?.cancel()
      reloadTask = Task {
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }
        await loadRecordings()
      }
    }
    .alert(
      "Export Failed",
      isPresented: Binding(
        get: { exportError != nil },
        set: { if !$0 { exportError = nil } }
      )
    ) {
      Button("OK") { exportError = nil }
    } message: {
      Text(exportError ?? "")
    }
  }

  // MARK: - Sidebar List

  private var recordingsList: some View {
    Group {
      if recordings.isEmpty {
        ContentUnavailableView(
          "No Recordings",
          systemImage: "waveform",
          description: Text("Recordings will appear here when Blackbox captures audio.")
        )
      } else {
        List(recordings, selection: $selectedRecordingID) { recording in
          RecordingRow(
            recording: recording,
            onRename: { newTitle in
              renameRecording(recording, to: newTitle)
            }
          )
          .contextMenu {
            Button("Reveal in Finder") { revealInFinder(Set([recording.id])) }
            Button("Export Audio...") { exportRecordings(Set([recording.id])) }
            Divider()
            Button("Delete", role: .destructive) {
              deleteRecordings(Set([recording.id]))
            }
          }
        }
      }
    }
    .frame(minWidth: 220)
    .navigationSplitViewColumnWidth(min: 220, ideal: 260)
    .toolbar {
      ToolbarItem(placement: .automatic) {
        Text("\(recordings.count) recordings, \(totalSizeFormatted)")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  // MARK: - Data

  private var totalSizeFormatted: String {
    let total = recordings.reduce(0) { $0 + $1.size }
    return ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)
  }

  // Directory enumeration + resourceValues is synchronous I/O that blocks MainActor.
  // With hundreds of recordings this freezes the UI on every window activation.
  private func loadRecordings() async {
    let dir = URL(fileURLWithPath: saveDirectoryPath)
    let loaded: [RecordingFile] = await Task.detached {
      // By name, not `contentsOfDirectory(at:)`: that variant resolves symlinks
      // in the base and yields a different spelling of the same path than the
      // recorder produces, which breaks transcription status lookups keyed by path.
      guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
      else { return [] }
      let files = names.map { dir.appendingPathComponent($0, isDirectory: true) }

      var results: [RecordingFile] = []

      for url in files
      where FileManager.default.fileExists(
        atPath: url.appendingPathComponent("audio.m4a").path)
      {
        let originalURL = url.appendingPathComponent("audio.m4a")
        guard FileManager.default.fileExists(atPath: originalURL.path) else { continue }
        // Prefer processed file for playback when available
        let processedURL = url.appendingPathComponent("audio-processed.m4a")
        let hasProcessed = FileManager.default.fileExists(atPath: processedURL.path)
        let audioURL = hasProcessed ? processedURL : originalURL
        let metadata = RecordingMetadata.load(in: url)
        let originalSize =
          (try? originalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let processedSize =
          hasProcessed
          ? ((try? processedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) : 0
        let sidecar = TranscriptDocument.sidecarURL(for: url)
        results.append(
          RecordingFile(
            url: url,
            audioURL: audioURL,
            title: metadata?.title ?? url.deletingPathExtension().lastPathComponent,
            date: metadata?.createdAt
              ?? (try? url.resourceValues(
                forKeys: [.contentModificationDateKey]
              ).contentModificationDate) ?? .distantPast,
            size: originalSize + processedSize,
            hasProcessed: hasProcessed,
            hasTranscript: FileManager.default.fileExists(atPath: sidecar.path)
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
    let selected = recordings.filter { ids.contains($0.id) }
    guard !selected.isEmpty else { return }

    if selected.count == 1, let recording = selected.first {
      let baseName =
        recording.audioURL.deletingLastPathComponent().deletingPathExtension().lastPathComponent
      let panel = NSSavePanel()
      panel.nameFieldStringValue = "\(baseName).m4a"
      panel.allowedContentTypes = [.mpeg4Audio]
      guard panel.runModal() == .OK, let dest = panel.url else { return }
      Task {
        do {
          try await TranscriptionService.exportM4A(from: recording.audioURL, to: dest)
        } catch {
          exportError = error.localizedDescription
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
        for recording in selected {
          let baseName =
            recording.audioURL.deletingLastPathComponent().deletingPathExtension()
            .lastPathComponent
          let target = dest.appendingPathComponent("\(baseName).m4a")
          do {
            try await TranscriptionService.exportM4A(from: recording.audioURL, to: target)
          } catch {
            failed += 1
          }
        }
        if failed > 0 {
          exportError = "Failed to export \(failed) of \(selected.count) recordings"
        }
      }
    }
  }

  private func deleteRecordings(_ ids: Set<String>) {
    for recording in recordings where ids.contains(recording.id) {
      // Drop any queued or in-flight transcription first, so it neither spends
      // an upload on a recording that is going away nor writes a transcript
      // into the Trash.
      transcription.cancel(recordingDirectory: recording.url)
      try? FileManager.default.trashItem(at: recording.url, resultingItemURL: nil)
    }
    if let selectedRecordingID, ids.contains(selectedRecordingID) {
      self.selectedRecordingID = nil
    }
    Task { await loadRecordings() }
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
    try? metadata.save(in: recording.url)
    Task { await loadRecordings() }
  }
}

// MARK: - Recording Row

private struct RecordingRow: View {
  let recording: RecordingFile
  var onRename: (String) -> Void

  @Environment(TranscriptionCoordinator.self) private var transcription
  @State private var isEditing = false
  @State private var editedTitle = ""

  @ViewBuilder private var transcriptionIndicator: some View {
    switch transcription.status(for: recording.url) {
    case .idle, .completed:
      EmptyView()
    case .error:
      Image(systemName: "exclamationmark.triangle")
        .font(.caption2)
        .foregroundStyle(.orange)
        .help("Transcription failed - open the recording to retry")
    case .uploading, .queued, .transcribing:
      ProgressView()
        .controlSize(.small)
        .scaleEffect(0.6)
        .frame(width: 12, height: 12)
        .help("Transcribing...")
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        if isEditing {
          TextField(
            "Title", text: $editedTitle,
            onCommit: {
              let trimmed = editedTitle.trimmingCharacters(in: .whitespaces)
              if !trimmed.isEmpty {
                onRename(trimmed)
              }
              isEditing = false
            }
          )
          .textFieldStyle(.plain)
          .lineLimit(1)
          .onExitCommand { isEditing = false }
        } else {
          Text(recording.title)
            .lineLimit(1)
            .truncationMode(.middle)
            .onTapGesture(count: 2) {
              editedTitle = recording.title
              isEditing = true
            }
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
        Text(recording.date, format: .dateTime.month().day().hour().minute())
        Spacer()
        Text(recording.sizeFormatted)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 2)
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
  @State private var isProcessingAEC = false

  // Metadata
  @State private var metadata: RecordingMetadata?
  @State private var isEditingTitle = false
  @State private var editedTitle = ""

  // Transcription
  @State private var transcript: TranscriptDocument?

  var body: some View {
    VStack(spacing: 0) {
      metadataHeader
      Divider()
      if let playerError {
        VStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle")
            .font(.title)
            .foregroundStyle(.secondary)
          Text("Could not load audio: \(playerError)")
            .font(.caption)
            .foregroundStyle(.secondary)
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
      setupPlayer()
      loadTranscript()
    }
    .onChange(of: transcription.revision) { _, _ in
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
          TextField(
            "Title", text: $editedTitle,
            onCommit: {
              let trimmed = editedTitle.trimmingCharacters(in: .whitespaces)
              if !trimmed.isEmpty {
                saveTitle(trimmed)
              }
              isEditingTitle = false
            }
          )
          .font(.headline)
          .textFieldStyle(.plain)
          .onExitCommand { isEditingTitle = false }
        } else {
          Text(recording.title)
            .font(.headline)
            .onTapGesture(count: 2) {
              editedTitle = recording.title
              isEditingTitle = true
            }
        }
        HStack(spacing: 8) {
          Text(recording.date.formatted(.dateTime.year().month().day().hour().minute()))
          Text(recording.sizeFormatted)
          if duration > 0 {
            Text(formatTime(duration))
          }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
      Spacer()
      HStack(spacing: 8) {
        if transcript != nil {
          Button {
            exportTranscript()
          } label: {
            Image(systemName: "doc.text")
          }
          .help("Export Transcript")
        }

        if !recording.hasProcessed {
          Button {
            runAEC()
          } label: {
            if isProcessingAEC {
              ProgressView()
                .controlSize(.small)
            } else {
              Image(systemName: "waveform.badge.magnifyingglass")
            }
          }
          .help("Remove echo from mic track")
          .disabled(isProcessingAEC)
        }

        Button {
          NSWorkspace.shared.activateFileViewerSelecting([recording.url])
        } label: {
          Image(systemName: "folder")
        }
        .help("Reveal in Finder")

        Button(role: .destructive) {
          showDeleteConfirmation = true
        } label: {
          Image(systemName: "trash")
        }
        .help("Delete")
      }
    }
    .padding()
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
        onSeek: { fraction in
          let time = fraction * duration
          seekTo(time)
        }
      )
      .frame(height: 48)

      HStack {
        Text(formatTime(currentTime))
          .font(.caption.monospacedDigit())
          .foregroundStyle(.secondary)
        Spacer()
        if recording.hasProcessed {
          Picker("", selection: $useProcessed) {
            Text("Original").tag(false)
            Text("Processed").tag(true)
          }
          .pickerStyle(.segmented)
          .frame(width: 150)
          .onChange(of: useProcessed) { _, _ in
            switchAudioSource()
          }
        }
        Picker("", selection: $trackSelection) {
          ForEach(availableTrackSelections) { t in
            Text(t.label).tag(t)
          }
        }
        .pickerStyle(.segmented)
        .frame(width: (metadata?.trackCount ?? 2) >= 3 ? 240 : 180)
        .onChange(of: trackSelection) { _, newValue in
          applyTrackSelection(newValue)
        }
        Spacer()
        Text("-\(formatTime(max(0, duration - currentTime)))")
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
        .buttonStyle(.plain)

        Button {
          togglePlayback()
        } label: {
          Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
            .font(.largeTitle)
        }
        .buttonStyle(.plain)

        Button {
          skip(by: 15)
        } label: {
          Image(systemName: "goforward.15")
            .font(.title3)
        }
        .buttonStyle(.plain)
      }
    }
    .padding()
  }

  private var activeAudioURL: URL {
    if useProcessed, recording.hasProcessed {
      return recording.url.appendingPathComponent("audio-processed.m4a")
    }
    return recording.url.appendingPathComponent("audio.m4a")
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

    // Periodic time observer (10x/sec)
    let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
    timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
      Task { @MainActor in
        if !isDragging {
          currentTime = time.seconds
        }
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
      player.play()
    }
    isPlaying = !isPlaying
  }

  private func seekTo(_ time: TimeInterval) {
    let cmTime = CMTime(seconds: time, preferredTimescale: 600)
    player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero)
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
      await AECProcessor.process(recordingDirectory: recording.url)
      isProcessingAEC = false
      // Reload recordings to pick up the new processed file
      onTitleChanged()
    }
  }

  // MARK: - Metadata

  private func loadMetadata() {
    metadata = RecordingMetadata.load(in: recording.url)
  }

  private func saveTitle(_ newTitle: String) {
    var meta =
      metadata
      ?? RecordingMetadata(
        title: recording.title,
        createdAt: recording.date,
        appName: recording.title,
        speakers: [:]
      )
    meta.title = newTitle
    try? meta.save(in: recording.url)
    metadata = meta
    onTitleChanged()
  }

  private func speakerName(for speakerID: Int) -> String {
    if let name = metadata?.speakers[String(speakerID)], !name.isEmpty {
      return name
    }
    return speakerID == -1 ? "You" : "Speaker \(speakerID + 1)"
  }

  private func saveSpeakerName(_ name: String, for speakerID: Int) {
    var meta =
      metadata
      ?? RecordingMetadata(
        title: recording.title,
        createdAt: recording.date,
        appName: recording.title,
        speakers: [:]
      )
    meta.speakers[String(speakerID)] = name
    try? meta.save(in: recording.url)
    metadata = meta
  }

  // MARK: - Transcript

  private var transcriptionStatus: TranscriptionStatus {
    transcription.status(for: recording.url)
  }

  private var transcriptArea: some View {
    Group {
      if let transcript, !transcript.segments.isEmpty {
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
      } else if transcriptionStatus != .idle {
        VStack(spacing: 12) {
          ProgressView()
          Text(transcriptionStatusText)
            .font(.caption)
            .foregroundStyle(.secondary)
          Button("Cancel") { cancelTranscription() }
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
    case .uploading: "Uploading audio..."
    case .queued: "Queued for transcription..."
    case .transcribing: "Transcribing..."
    default: ""
    }
  }

  private func transcriptView(_ doc: TranscriptDocument) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        ForEach(doc.segments) { segment in
          TranscriptSegmentView(
            segment: segment,
            speakerName: speakerName(for: segment.speaker),
            isActive: isSegmentActive(segment, in: doc),
            onTap: { jumpTo(time: segment.time) },
            onRenameSpeaker: { newName in
              saveSpeakerName(newName, for: segment.speaker)
            }
          )
        }
      }
      .padding()
    }
  }

  private func isSegmentActive(
    _ segment: TranscriptSegment, in doc: TranscriptDocument
  ) -> Bool {
    guard isPlaying else { return false }
    guard let idx = doc.segments.firstIndex(where: { $0.id == segment.id }) else {
      return false
    }
    let nextTime: Double =
      if idx + 1 < doc.segments.count {
        doc.segments[idx + 1].time
      } else {
        duration
      }
    return currentTime >= segment.time && currentTime < nextTime
  }

  private func jumpTo(time: Double) {
    seekTo(time)
    if !isPlaying { togglePlayback() }
  }

  // MARK: - Transcription Lifecycle

  private func loadTranscript() {
    transcript = TranscriptDocument.load(for: recording.url)
  }

  private func startTranscription() {
    transcription.transcribe(recordingDirectory: recording.url)
  }

  private func cancelTranscription() {
    transcription.cancel(recordingDirectory: recording.url)
  }

  // MARK: - Transcript Export

  private func exportTranscript() {
    guard let transcript, !transcript.segments.isEmpty else { return }

    let panel = NSSavePanel()
    panel.nameFieldStringValue = "\(recording.title).json"
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let dest = panel.url else { return }

    let segments = transcript.segments.map { segment in
      let m = Int(segment.time) / 60
      let s = Int(segment.time) % 60
      return ExportedSegment(
        speaker: speakerName(for: segment.speaker),
        time: String(format: "%d:%02d", m, s),
        text: segment.text
      )
    }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      let data = try encoder.encode(segments)
      try data.write(to: dest, options: .atomic)
    } catch {
      Log.error(
        Log.app, "export",
        "failed to export transcript: \(error.localizedDescription)")
    }
  }

  // MARK: - Formatting

  private func formatTime(_ time: TimeInterval) -> String {
    let total = max(0, Int(time))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0
      ? String(format: "%d:%02d:%02d", h, m, s)
      : String(format: "%d:%02d", m, s)
  }
}

// MARK: - Transcript Segment View

private struct TranscriptSegmentView: View {
  let segment: TranscriptSegment
  let speakerName: String
  let isActive: Bool
  let onTap: () -> Void
  let onRenameSpeaker: (String) -> Void

  @State private var showSpeakerPopover = false
  @State private var editedSpeakerName = ""

  private static let speakerColors: [Color] = [
    .blue, .green, .orange, .purple, .pink, .teal,
  ]

  private var isLocalUser: Bool { segment.speaker == -1 }

  private var speakerColor: Color {
    if isLocalUser { return .accentColor }
    return Self.speakerColors[segment.speaker % Self.speakerColors.count]
  }

  var body: some View {
    Button(action: onTap) {
      HStack(alignment: .top, spacing: 10) {
        VStack(alignment: .trailing, spacing: 2) {
          Text(speakerName)
            .font(.caption.bold())
            .foregroundStyle(speakerColor)
            .onTapGesture {
              editedSpeakerName = speakerName
              showSpeakerPopover = true
            }
            .popover(isPresented: $showSpeakerPopover) {
              VStack(spacing: 8) {
                Text("Speaker Name")
                  .font(.caption.bold())
                TextField(
                  "Name", text: $editedSpeakerName,
                  onCommit: {
                    let trimmed = editedSpeakerName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                      onRenameSpeaker(trimmed)
                    }
                    showSpeakerPopover = false
                  }
                )
                .textFieldStyle(.roundedBorder)
                .frame(width: 140)
              }
              .padding(12)
            }
          Text(formatTimestamp(segment.time))
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
        }
        .frame(width: 70, alignment: .trailing)

        Text(segment.text)
          .font(.body)
          .foregroundStyle(isActive ? .primary : .secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.vertical, 4)
      .padding(.horizontal, 8)
      .background(
        isActive ? speakerColor.opacity(0.08) : Color.clear,
        in: RoundedRectangle(cornerRadius: 6)
      )
    }
    .buttonStyle(.plain)
  }

  private func formatTimestamp(_ time: Double) -> String {
    let total = Int(time)
    let m = total / 60
    let s = total % 60
    return String(format: "%d:%02d", m, s)
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

// MARK: - Recording File

struct RecordingFile: Identifiable {
  var id: String { url.path }
  let url: URL  // recording directory
  let audioURL: URL  // audio.m4a inside the directory
  var title: String  // from metadata.title
  let date: Date  // from metadata.createdAt
  let size: Int
  let hasProcessed: Bool
  let hasTranscript: Bool

  var sizeFormatted: String {
    ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
  }
}

// MARK: - Waveform View

private struct WaveformView: View {
  let samples: [Float]
  let progress: Double
  let onSeek: (Double) -> Void

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
          let color: Color = fraction <= progress ? .accentColor : .secondary.opacity(0.3)

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
      }
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in
            let fraction = max(0, min(1, value.location.x / geo.size.width))
            onSeek(fraction)
          }
      )
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
