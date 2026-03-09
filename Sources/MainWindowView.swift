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
    .frame(minWidth: 600, minHeight: 400)
  }
}

// MARK: - Recordings

struct RecordingsView: View {
  @AppStorage("saveDirectoryPath") private var saveDirectoryPath = defaultSaveDirectoryPath
  @State private var recordings: [RecordingFile] = []
  @State private var selectedIDs: Set<String> = []
  @State private var exportError: String?

  var body: some View {
    VStack(spacing: 0) {
      if recordings.isEmpty {
        ContentUnavailableView(
          "No Recordings",
          systemImage: "waveform",
          description: Text("Recordings will appear here when Blackbox captures audio.")
        )
      } else {
        Table(recordings, selection: $selectedIDs) {
          TableColumn("Name") { recording in
            Label(recording.name, systemImage: "waveform.circle.fill")
          }
          .width(min: 150, ideal: 250)

          TableColumn("Date") { recording in
            Text(recording.date, format: .dateTime.month().day().hour().minute())
          }
          .width(min: 120, ideal: 160)

          TableColumn("Size") { recording in
            Text(recording.sizeFormatted)
          }
          .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: RecordingFile.ID.self) { ids in
          if !ids.isEmpty {
            Button("Reveal in Finder") { revealInFinder(ids) }
            Button("Export...") { exportRecordings(ids) }
            Divider()
            Button("Delete", role: .destructive) { deleteRecordings(ids) }
          }
        } primaryAction: { ids in
          revealInFinder(ids)
        }
      }

      Divider()

      HStack {
        Text("\(recordings.count) recordings, \(totalSizeFormatted)")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Reveal in Finder") { revealInFinder(selectedIDs) }
          .disabled(selectedIDs.isEmpty)
        Button("Export...") { exportRecordings(selectedIDs) }
          .disabled(selectedIDs.isEmpty)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
    }
    .task { await loadRecordings() }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      Task { await loadRecordings() }
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
      guard
        let files = try? FileManager.default.contentsOfDirectory(
          at: dir,
          includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
          options: .skipsHiddenFiles)
      else { return [] }
      return
        files
        .filter { $0.pathExtension == "m4a" }
        .compactMap { url -> RecordingFile? in
          let values = try? url.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey])
          return RecordingFile(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            date: values?.contentModificationDate ?? .distantPast,
            size: values?.fileSize ?? 0
          )
        }
        .sorted { $0.date > $1.date }
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
    let urls = recordings.filter { ids.contains($0.id) }.map(\.url)
    guard !urls.isEmpty else { return }

    if urls.count == 1, let source = urls.first {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = source.lastPathComponent
      panel.allowedContentTypes = [.mpeg4Audio]
      guard panel.runModal() == .OK, let dest = panel.url else { return }
      do {
        try FileManager.default.copyItem(at: source, to: dest)
      } catch {
        exportError = error.localizedDescription
      }
    } else {
      let panel = NSOpenPanel()
      panel.canChooseFiles = false
      panel.canChooseDirectories = true
      panel.canCreateDirectories = true
      panel.prompt = "Export"
      panel.message = "Choose a folder to export \(urls.count) recordings"
      guard panel.runModal() == .OK, let dest = panel.url else { return }
      var failed = 0
      for source in urls {
        let target = dest.appendingPathComponent(source.lastPathComponent)
        do {
          try FileManager.default.copyItem(at: source, to: target)
        } catch {
          failed += 1
        }
      }
      if failed > 0 {
        exportError = "Failed to export \(failed) of \(urls.count) recordings"
      }
    }
  }

  private func deleteRecordings(_ ids: Set<String>) {
    for recording in recordings where ids.contains(recording.id) {
      try? FileManager.default.trashItem(at: recording.url, resultingItemURL: nil)
    }
    selectedIDs.subtract(ids)
    Task { await loadRecordings() }
  }
}

// MARK: - Recording File

struct RecordingFile: Identifiable {
  var id: String { url.path }
  let url: URL
  let name: String
  let date: Date
  let size: Int

  var sizeFormatted: String {
    ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
  }
}
