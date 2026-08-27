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
  @AppStorage(SettingsKeys.saveDirectoryPath) private var saveDirectoryPath =
    defaultSaveDirectoryPath
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
            if transcription.hasAPIKey, !transcription.status(for: recording.url).isActive {
              Button(recording.hasTranscript ? "Transcribe Again" : "Transcribe") {
                transcription.transcribe(recordingDirectory: recording.url)
              }
              Divider()
            }
            Button("Reveal in Finder") { revealInFinder(Set([recording.id])) }
            Button("Export Audio…") { exportRecordings(Set([recording.id])) }
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
      var results: [RecordingFile] = []

      for url in RecordingStore.directories(in: dir) {
        // One stat per file: a successful `resourceValues` is itself the
        // existence check, so probing with `fileExists` first only doubled the
        // syscalls on a scan that runs for every recording.
        let originalURL = url.appendingPathComponent(RecordingStore.audioName)
        guard let originalValues = try? originalURL.resourceValues(forKeys: [.fileSizeKey])
        else { continue }
        // Prefer processed file for playback when available
        let processedURL = url.appendingPathComponent(RecordingStore.processedAudioName)
        let processedValues = try? processedURL.resourceValues(forKeys: [.fileSizeKey])
        let hasProcessed = processedValues != nil
        let audioURL = hasProcessed ? processedURL : originalURL
        let metadata = RecordingMetadata.load(in: url)
        let originalSize = originalValues.fileSize ?? 0
        let processedSize = processedValues?.fileSize ?? 0
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
      // Drop any queued transcription so it does not spend an upload on a
      // recording that is going away. Cancelling an already-running job is
      // asynchronous, so the job itself also re-checks that the directory still
      // exists before writing its transcript.
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
    case .waitingForRecording:
      Image(systemName: "clock")
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Waiting for recording to finish")
        .help("Starts when the current recording finishes")
    default:
      ProgressView()
        .controlSize(.small)
        .frame(width: 14, height: 14)
        .accessibilityLabel(Self.statusText(status))
        .help(Self.statusText(status))
    }
  }

  /// Shared with the detail view so a row and the pane it opens can never
  /// describe the same job differently.
  static func statusText(_ status: TranscriptionStatus) -> String {
    switch status {
    case .idle: "Not transcribed"
    case .waitingForRecording: "Starts when the current recording finishes"
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
  @State private var showRetranscribeConfirmation = false
  @State private var isProcessingAEC = false
  /// Set when the user scrolls the transcript themselves, so following the
  /// playhead never yanks the view out from under them. Cleared by the
  /// "Jump to current" button or by seeking.
  @State private var isFollowSuspended = false
  @State private var didCopyTranscript = false
  @AppStorage(SettingsKeys.playbackRate) private var playbackRate: Double = 1

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
      // Decoding a transcript is main-thread JSON work proportional to call
      // length, so only the recording that actually finished reloads - not
      // every open detail view every time any job anywhere completes.
      guard transcription.lastFinishedPath == recording.url.path else { return }
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
    .alert("Transcribe Again?", isPresented: $showRetranscribeConfirmation) {
      Button("Transcribe Again") { retranscribe() }
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
        Text(formatTime(currentTime))
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
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(Array(doc.segments.enumerated()), id: \.element.id) { index, segment in
            TranscriptSegmentView(
              segment: segment,
              speakerName: speakerName(for: segment.speaker),
              isActive: index == activeSegmentIndex,
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
        if isFollowSuspended, activeSegmentIndex != nil {
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

  /// Which segment the playhead is inside, or nil when it is past the end.
  /// Computed once per tick rather than per row: asking each row "am I active?"
  /// made highlighting quadratic in transcript length.
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

  private func startTranscription() {
    transcription.transcribe(recordingDirectory: recording.url)
  }

  /// The existing transcript is deliberately left on disk. A re-run that fails
  /// should leave the user where they started rather than costing them the
  /// transcript they already had; the new one overwrites it only on success.
  /// `transcriptArea` shows progress ahead of a stale transcript, so nothing
  /// here needs to clear the view.
  private func retranscribe() {
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
      "[\(formatTime(segment.time))] \(speakerName(for: segment.speaker)): \(segment.text)"
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
          Text(formatTimestamp(segment.time))
            .font(.caption2.monospacedDigit())
            // Was `.tertiary`, which is under 3:1 at this size - and this is a
            // functional control, not decoration.
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Play from \(formatTimestamp(segment.time))")
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

  private func formatTimestamp(_ time: Double) -> String {
    let total = max(0, Int(time))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    // Rolls to h:mm:ss past an hour. It used to emit "78:12" for a 78-minute
    // call while the transport above it read "1:18:12".
    return h > 0
      ? String(format: "%d:%02d:%02d", h, m, s)
      : String(format: "%d:%02d", m, s)
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
      .accessibilityValue(Self.timeDescription(progress * duration))
      .accessibilityAdjustableAction { direction in
        let step = 0.02
        let next = direction == .increment ? progress + step : progress - step
        onSeek(max(0, min(1, next)), true)
      }
    }
  }

  private static func timeDescription(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    let minutes = total / 60
    let secs = total % 60
    return "\(minutes) minutes \(secs) seconds"
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
