import ServiceManagement
import SwiftUI

struct SettingsView: View {
  @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
  @AppStorage("gracePeriod") private var gracePeriod: Double = 30
  @AppStorage("micEnabled") private var micEnabled = true
  @AppStorage("targetBundleIDs") private var targetBundleIDsData = defaultTargetBundleIDsJSON
  @AppStorage("meetingPatterns") private var meetingPatternsData = defaultMeetingPatternsJSON
  @AppStorage("saveDirectoryPath") private var saveDirectoryPath = defaultSaveDirectoryPath

  @State private var newBundleID = ""
  @State private var newPattern = ""

  var body: some View {
    Form {
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
      }

      Section("Target Applications") {
        ForEach(targetBundleIDs, id: \.self) { bundleID in
          HStack {
            Text(bundleID).font(.body.monospaced())
            Spacer()
            Button(role: .destructive) {
              removeBundleID(bundleID)
            } label: {
              Image(systemName: "trash")
            }.buttonStyle(.borderless)
          }
        }
        HStack {
          TextField("com.example.app", text: $newBundleID)
            .textFieldStyle(.roundedBorder)
            .onSubmit { addBundleID() }
          Button("Add") { addBundleID() }
            .disabled(newBundleID.isEmpty)
        }
      }

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
      }

      Section("Recordings") {
        HStack {
          Text(saveDirectoryPath)
            .lineLimit(1)
            .truncationMode(.head)
          Spacer()
          Button("Choose...") { pickFolder() }
        }

        HStack {
          Text("Grace period after meeting ends: \(Int(gracePeriod))s")
          Spacer()
          Slider(value: $gracePeriod, in: 5...60, step: 5)
            .frame(width: 200)
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 480)
    .onAppear {
      launchAtLogin = SMAppService.mainApp.status == .enabled
    }
  }

  // MARK: - Bundle IDs

  private var targetBundleIDs: [String] {
    (try? JSONDecoder().decode([String].self, from: Data(targetBundleIDsData.utf8))) ?? []
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
  #"["Meet -","meet.google.com","Zoom Meeting","Zoom","Voice Chat","Video Chat"]"#
let defaultSaveDirectoryPath = NSHomeDirectory() + "/Documents/Blackbox"
