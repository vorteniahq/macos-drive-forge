import SwiftUI
import Foundation
import AppKit

// MARK: - Models

struct InstallerVersion: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let version: String
    let build: String

    var displayName: String { "\(title) \(version) (\(build))" }
}

struct USBDrive: Identifiable, Hashable {
    let id = UUID()
    let device: String
    let label: String
    let sizeDescription: String
    let sizeBytes: Int64
}

struct MultiVolumePlan: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var sizeGB: Int
    var installerVersion: InstallerVersion?
}

struct StashedInstaller: Identifiable {
    let id = UUID()
    let version: String
    let appPath: String
    let sizeDescription: String
    let sizeBytes: Int64

    /// Marketing OS name derived from the cached installer app, e.g. "macOS Sonoma".
    /// Falls back to the version number if the app name can't be read.
    var osName: String {
        var name = (appPath as NSString).lastPathComponent  // "Install macOS Sonoma.app"
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        if name.hasPrefix("Install ") { name = String(name.dropFirst("Install ".count)) }
        return name.isEmpty ? "macOS \(version)" : name
    }
}

// MARK: - Toast

enum ToastStyle {
    case success, error, info, warning

    var color: Color {
        switch self {
        case .success: return .green
        case .error: return .red
        case .info: return .blue
        case .warning: return .orange
        }
    }

    var icon: String {
        switch self {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
}

struct ToastMessage: Identifiable {
    let id = UUID()
    let message: String
    let style: ToastStyle
    let timestamp = Date()
}

// MARK: - Workflow Phase

enum WorkflowPhase: Int, CaseIterable {
    case selectInstaller = 0
    case chooseDrive = 1
    case prepare = 2
    case runCommand = 3

    var label: String {
        switch self {
        case .selectInstaller: return "Select Installer"
        case .chooseDrive: return "Choose Drive"
        case .prepare: return "Prepare"
        case .runCommand: return "Run Command"
        }
    }

    var icon: String {
        switch self {
        case .selectInstaller: return "arrow.down.app"
        case .chooseDrive: return "externaldrive"
        case .prepare: return "gearshape"
        case .runCommand: return "terminal"
        }
    }
}

// MARK: - AppModel

@MainActor
final class AppModel: ObservableObject {
    @Published var installers: [InstallerVersion] = []
    @Published var drives: [USBDrive] = []
    @Published var stashedInstallers: [StashedInstaller] = []
    @Published var selectedInstaller: InstallerVersion?
    @Published var selectedDrive: USBDrive?
    @Published var status: String = "Ready"
    @Published var logs: String = ""
    @Published var creating = false
    @Published var advancedMode = false
    @Published var pendingTerminalCommand: String = ""

    @Published var showDestructiveConfirm = false
    private var pendingDestructiveAction: (() async throws -> Void)?
    @Published var destructiveWarning: String = ""
    private var downloadWasCancelled = false

    // V2: feedback state
    @Published var isRefreshing = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var toasts: [ToastMessage] = []
    @Published var currentPhase: WorkflowPhase = .selectInstaller

    @Published var volumePlans: [MultiVolumePlan] = [
        MultiVolumePlan(name: "Sonoma", sizeGB: 32, installerVersion: nil),
        MultiVolumePlan(name: "Tahoe", sizeGB: 32, installerVersion: nil)
    ]

    var stashPath: String {
        get { UserDefaults.standard.string(forKey: "stashPath") ?? "\(NSHomeDirectory())/InstallerStash" }
        set { UserDefaults.standard.set(newValue, forKey: "stashPath"); objectWillChange.send() }
    }

    private let shell = Shell()

    // MARK: Phase tracking

    func updatePhase() {
        if !pendingTerminalCommand.isEmpty {
            currentPhase = .runCommand
        } else if creating {
            currentPhase = .prepare
        } else if selectedDrive != nil && selectedInstaller != nil {
            currentPhase = .prepare
        } else if selectedInstaller != nil {
            currentPhase = .chooseDrive
        } else {
            currentPhase = .selectInstaller
        }
    }

    // MARK: Toast

    func showToast(_ message: String, style: ToastStyle) {
        let toast = ToastMessage(message: message, style: style)
        withAnimation(.spring(response: 0.4)) {
            toasts.append(toast)
        }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation(.easeOut(duration: 0.3)) {
                toasts.removeAll { $0.id == toast.id }
            }
        }
    }

    // MARK: Refresh

    func refreshAll() {
        Task {
            isRefreshing = true
            await refreshInstallers()
            await refreshDrives()
            refreshStash()
            isRefreshing = false
            showToast("All data refreshed", style: .success)
        }
    }

    func refreshInstallers() async {
        appendLog("Querying Apple for available macOS full installers...")
        isRefreshing = true
        do {
            let output = try await shell.run("/usr/sbin/softwareupdate", ["--list-full-installers"])
            installers = parseInstallers(output.stdout + output.stderr)
            if selectedInstaller == nil { selectedInstaller = installers.first }
            appendLog(output.stdout.isEmpty ? output.stderr : output.stdout)
            status = "Found \(installers.count) installer version\(installers.count == 1 ? "" : "s")"
        } catch {
            status = "Failed to load installers"
            appendLog("ERROR: \(error.localizedDescription)")
            showToast("Failed to load installers", style: .error)
        }
        refreshStash()
        isRefreshing = false
        updatePhase()
    }

    func refreshDrives() async {
        status = "Scanning drives..."
        do {
            let output = try await shell.run("/usr/sbin/diskutil", ["list", "external", "physical"])
            let devices = parseExternalDevices(output.stdout)
            var result: [USBDrive] = []
            for device in devices {
                let info = await fetchDriveInfo(device: device)
                result.append(info)
            }
            drives = result
            if selectedDrive == nil { selectedDrive = drives.first }
            status = "Found \(drives.count) external drive\(drives.count == 1 ? "" : "s")"
        } catch {
            status = "Failed to scan drives"
            appendLog("ERROR: \(error.localizedDescription)")
        }
        updatePhase()
    }

    // MARK: Stash

    func refreshStash() {
        let stash = expandTilde(stashPath)
        guard let versionDirs = try? FileManager.default.contentsOfDirectory(atPath: stash) else {
            stashedInstallers = []
            return
        }

        var result: [StashedInstaller] = []
        for dir in versionDirs.sorted() {
            let versionPath = "\(stash)/\(dir)"
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: versionPath, isDirectory: &isDir), isDir.boolValue else { continue }
            if let appName = findInstallerAppName(in: versionPath) {
                let appPath = "\(versionPath)/\(appName)"
                let size = directorySize(at: appPath)
                result.append(StashedInstaller(version: dir, appPath: appPath, sizeDescription: formatBytes(size), sizeBytes: size))
            }
        }
        stashedInstallers = result
    }

    func deleteFromStash(_ stashed: StashedInstaller) {
        let versionDir = (stashed.appPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.removeItem(atPath: versionDir)
            appendLog("Deleted from stash: \(versionDir)")
            showToast("Removed \(stashed.osName) from stash", style: .info)
            refreshStash()
        } catch {
            appendLog("ERROR deleting stash entry: \(error.localizedDescription)")
            showToast("Failed to delete: \(error.localizedDescription)", style: .error)
        }
    }

    // MARK: Volume plans

    func addPlan() {
        volumePlans.append(MultiVolumePlan(
            name: "Installer\(volumePlans.count + 1)",
            sizeGB: 32,
            installerVersion: selectedInstaller
        ))
    }

    func removePlan(_ plan: MultiVolumePlan) {
        volumePlans.removeAll { $0.id == plan.id }
    }

    // MARK: USB creation

    func requestCreate() {
        guard let drive = selectedDrive else {
            showToast("Select a USB or external drive first", style: .warning)
            return
        }
        let warning: String
        if advancedMode {
            warning = "This will ERASE and re-partition \(drive.label) (\(drive.device)) with \(volumePlans.count) partition(s). All existing data will be destroyed."
        } else {
            warning = "This will ERASE \(drive.label) (\(drive.device)) and format it as a bootable macOS installer drive. All existing data will be destroyed."
        }
        destructiveWarning = warning
        pendingDestructiveAction = { [weak self] in
            try await self?.performCreate()
        }
        showDestructiveConfirm = true
    }

    func confirmCreate() {
        let action = pendingDestructiveAction
        pendingDestructiveAction = nil
        showDestructiveConfirm = false
        creating = true
        status = "Working..."
        updatePhase()

        Task {
            do {
                try await action?()
                status = "Prepared. Run the command shown in Terminal to complete the write."
                showToast("USB drive prepared successfully", style: .success)
            } catch {
                status = "Failed"
                appendLog("ERROR: \(error.localizedDescription)")
                showToast("Preparation failed: \(error.localizedDescription)", style: .error)
            }
            creating = false
            updatePhase()
        }
    }

    func cancelCreate() {
        pendingDestructiveAction = nil
        showDestructiveConfirm = false
        status = "Cancelled"
        showToast("Operation cancelled", style: .info)
    }

    private func performCreate() async throws {
        guard let drive = selectedDrive else {
            throw AppError("No drive selected")
        }
        let stash = expandTilde(stashPath)
        try FileManager.default.createDirectory(atPath: stash, withIntermediateDirectories: true)

        if advancedMode {
            try await buildMultiInstallerDrive(drive: drive, stash: stash)
        } else {
            guard let installer = selectedInstaller else {
                throw AppError("No installer selected")
            }
            try await buildSingleInstaller(drive: drive, installer: installer, stash: stash)
        }
    }

    private func buildSingleInstaller(drive: USBDrive, installer: InstallerVersion, stash: String) async throws {
        let appPath = try await ensureInstaller(version: installer, stash: stash)
        appendLog("Using installer: \(appPath)")

        let volumeName = "InstallUSB"
        appendLog("Erasing \(drive.device) as \(volumeName)...")
        _ = try await shell.run("/usr/sbin/diskutil", ["eraseDisk", "HFS+", volumeName, "GPT", drive.device], requireSudo: true)

        let createInstallMedia = "\(appPath)/Contents/Resources/createinstallmedia"
        pendingTerminalCommand = "sudo \"\(createInstallMedia)\" --volume \"/Volumes/\(volumeName)\" --nointeraction"
        appendLog("Drive prepared. Pending write command generated.")
        appendLog(pendingTerminalCommand)
        updatePhase()
    }

    private func buildMultiInstallerDrive(drive: USBDrive, stash: String) async throws {
        guard !volumePlans.isEmpty else {
            throw AppError("Add at least one volume plan")
        }

        let dupNames = Dictionary(grouping: volumePlans, by: { $0.name }).filter { $1.count > 1 }.keys
        if !dupNames.isEmpty {
            throw AppError("Duplicate volume names: \(dupNames.joined(separator: ", "))")
        }

        for plan in volumePlans where plan.installerVersion == nil {
            throw AppError("Volume '\(plan.name)' has no installer selected")
        }

        appendLog("Partitioning \(drive.device) with \(volumePlans.count) partition(s)...")
        let first = volumePlans[0]
        _ = try await shell.run(
            "/usr/sbin/diskutil",
            ["partitionDisk", drive.device, "\(volumePlans.count)", "GPT",
             "JHFS+", first.name, "\(first.sizeGB)G"] +
            volumePlans.dropFirst().flatMap { ["JHFS+", $0.name, "\($0.sizeGB)G"] },
            requireSudo: true
        )

        var commands: [String] = []
        for plan in volumePlans {
            guard let installer = plan.installerVersion else { continue }
            let appPath = try await ensureInstaller(version: installer, stash: stash)
            let createInstallMedia = "\(appPath)/Contents/Resources/createinstallmedia"
            commands.append("sudo \"\(createInstallMedia)\" --volume \"/Volumes/\(plan.name)\" --nointeraction")
            appendLog("Prepared write command: \(installer.displayName) -> /Volumes/\(plan.name)")
        }
        pendingTerminalCommand = commands.joined(separator: "\n")
        appendLog("All partitions ready. Run commands in Terminal top-to-bottom.")
        updatePhase()
    }

    private func ensureInstaller(version: InstallerVersion, stash: String) async throws -> String {
        let versionDir = "\(stash)/\(version.version)"
        try FileManager.default.createDirectory(atPath: versionDir, withIntermediateDirectories: true)

        if let name = findInstallerAppName(in: versionDir) {
            let path = "\(versionDir)/\(name)"
            appendLog("Stash hit: \(path)")
            return path
        }

        appendLog("Downloading \(version.displayName) from Apple (this may take several minutes)...")
        status = "Downloading \(version.version)..."
        isDownloading = true
        downloadProgress = 0
        showToast("Downloading \(version.version) from Apple...", style: .info)
        let versionStr = version.version
        _ = try await shell.runStreaming(
            "/usr/sbin/softwareupdate",
            ["--fetch-full-installer", "--full-installer-version", versionStr]
        ) { output in
            // Parse progress from softwareupdate output (e.g. "Installing: 45.0%")
            let lines = output.components(separatedBy: .newlines)
            for line in lines {
                if let range = line.range(of: #"(\d+\.?\d*)%"#, options: .regularExpression) {
                    let numStr = line[range].dropLast() // drop the %
                    if let pct = Double(numStr) {
                        DispatchQueue.main.async { [weak self] in
                            self?.downloadProgress = pct / 100.0
                            self?.status = "Downloading \(versionStr)... \(Int(pct))%"
                        }
                    }
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        self?.appendLog(trimmed)
                    }
                }
            }
        }
        isDownloading = false
        downloadProgress = 1.0

        guard let downloaded = findNewestInstallerInApplications() else {
            throw AppError("Downloaded installer not found in /Applications. Check System Settings > Software Update.")
        }

        let appName = URL(fileURLWithPath: downloaded).lastPathComponent
        let dest = "\(versionDir)/\(appName)"
        if !FileManager.default.fileExists(atPath: dest) {
            appendLog("Copying installer to stash...")
            _ = try await shell.run("/bin/cp", ["-R", downloaded, dest])
        }
        appendLog("Saved to stash: \(dest)")
        showToast("Installer cached: \(version.version)", style: .success)
        refreshStash()
        return dest
    }

    // MARK: Download Only

    func downloadOnly() {
        guard let installer = selectedInstaller else {
            showToast("Select an installer first", style: .warning)
            return
        }
        if isCached(installer) {
            showToast("\(installer.version) is already in stash", style: .info)
            return
        }
        creating = true
        isDownloading = true
        status = "Downloading \(installer.version)..."

        Task {
            do {
                let stash = expandTilde(stashPath)
                try FileManager.default.createDirectory(atPath: stash, withIntermediateDirectories: true)
                _ = try await ensureInstaller(version: installer, stash: stash)
                status = "Downloaded \(installer.version)"
                showToast("Downloaded \(installer.displayName)", style: .success)
            } catch {
                if downloadWasCancelled {
                    status = "Download cancelled"
                    appendLog("Download cancelled by user")
                    showToast("Download cancelled", style: .warning)
                } else {
                    status = "Download failed"
                    appendLog("ERROR: \(error.localizedDescription)")
                    showToast("Download failed: \(error.localizedDescription)", style: .error)
                }
            }
            creating = false
            isDownloading = false
            downloadWasCancelled = false
        }
    }

    func cancelDownload() {
        guard isDownloading else { return }
        downloadWasCancelled = true
        status = "Cancelling..."
        appendLog("Cancelling download...")
        Task { await shell.cancelCurrent() }
    }

    // MARK: Actions

    func copyPendingCommand() {
        guard !pendingTerminalCommand.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pendingTerminalCommand, forType: .string)
        showToast("Command copied to clipboard", style: .success)
    }

    func runPendingInTerminal() {
        guard !pendingTerminalCommand.isEmpty else { return }
        let scriptDir = expandTilde(stashPath)
        let scriptPath = "\(scriptDir)/run-installerusb.sh"
        do {
            try "#!/bin/zsh\nset -e\n\(pendingTerminalCommand)\n".write(toFile: scriptPath, atomically: true, encoding: .utf8)
            _ = try? shellSync("/bin/chmod", ["+x", scriptPath])
            _ = try? shellSync("/usr/bin/open", ["-a", "Terminal", scriptPath])
            showToast("Opened script in Terminal", style: .success)
        } catch {
            appendLog("ERROR opening Terminal: \(error.localizedDescription)")
            showToast("Failed to open Terminal", style: .error)
        }
    }

    func installerLabel(_ installer: InstallerVersion) -> String {
        let cached = isCached(installer)
        let badge = cached ? "checkmark.circle.fill" : "arrow.down.circle"
        return "\(badge)|\(installer.displayName)"
    }

    func isCached(_ installer: InstallerVersion) -> Bool {
        let versionDir = "\(expandTilde(stashPath))/\(installer.version)"
        return findInstallerAppName(in: versionDir) != nil
    }

    // MARK: Parsing helpers

    private func parseInstallers(_ text: String) -> [InstallerVersion] {
        var result: [InstallerVersion] = []
        for line in text.split(separator: "\n") {
            let value = String(line)
            guard value.contains("Version:") else { continue }
            let title = capture(value, regex: "\\*?\\s*Title:\\s*([^,]+)") ?? "Install macOS"
            let version = capture(value, regex: "Version:\\s*([^,]+)") ?? "Unknown"
            let build = capture(value, regex: "Build:\\s*([^,\\s)]+)") ?? "Unknown"
            result.append(InstallerVersion(
                title: title.trimmingCharacters(in: .whitespaces),
                version: version.trimmingCharacters(in: .whitespaces),
                build: build.trimmingCharacters(in: .whitespaces)
            ))
        }
        return result
    }

    private func parseExternalDevices(_ text: String) -> [String] {
        var result: [String] = []
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("/dev/disk") {
                let device = line.split(separator: " ").first.map(String.init)?.replacingOccurrences(of: ":", with: "") ?? ""
                if !device.isEmpty && !result.contains(device) {
                    result.append(device)
                }
            }
        }
        return result
    }

    private func fetchDriveInfo(device: String) async -> USBDrive {
        if let info = await shell.runOptional("/usr/sbin/diskutil", ["info", device]) {
            let mediaName = capture(info, regex: "Device / Media Name:\\s*(.+)") ?? device
            let size = capture(info, regex: "Disk Size:\\s*([^(]+)") ?? "unknown size"
            let sizeBytes = parseSizeBytes(capture(info, regex: "Disk Size:.*\\(exactly (\\d+)") ?? "0")
            return USBDrive(
                device: device,
                label: mediaName.trimmingCharacters(in: .whitespaces),
                sizeDescription: size.trimmingCharacters(in: .whitespaces),
                sizeBytes: sizeBytes
            )
        }
        return USBDrive(device: device, label: device, sizeDescription: "unknown", sizeBytes: 0)
    }

    private func parseSizeBytes(_ blockCount: String) -> Int64 {
        guard let blocks = Int64(blockCount) else { return 0 }
        return blocks * 512
    }

    // MARK: Stash helpers

    private func findInstallerAppName(in directory: String) -> String? {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return nil }
        return items.first { $0.hasPrefix("Install macOS") && $0.hasSuffix(".app") }
    }

    private func findNewestInstallerInApplications() -> String? {
        let appsDir = "/Applications"
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: appsDir) else { return nil }
        return items
            .filter { $0.hasPrefix("Install macOS") && $0.hasSuffix(".app") }
            .map { "\(appsDir)/\($0)" }
            .sorted {
                let d1 = (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast
                let d2 = (try? FileManager.default.attributesOfItem(atPath: $1)[.modificationDate] as? Date) ?? .distantPast
                return d1 > d2
            }
            .first
    }

    private func directorySize(at path: String) -> Int64 {
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in enumerator {
                total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
            }
        }
        return total
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 { return String(format: "%.1f GB", Double(bytes) / 1e9) }
        if bytes >= 1_000_000 { return String(format: "%.0f MB", Double(bytes) / 1e6) }
        return "\(bytes) B"
    }

    private func appendLog(_ text: String) {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs += "\n[\(stamp)] \(text)"
    }

    private func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    private func capture(_ text: String, regex: String) -> String? {
        guard let exp = try? NSRegularExpression(pattern: regex) else { return nil }
        let ns = text as NSString
        guard let match = exp.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        let r = match.range(at: 1)
        guard r.location != NSNotFound else { return nil }
        return ns.substring(with: r)
    }

    private func shellSync(_ command: String, _ arguments: [String]) throws -> ShellOutput {
        let process = Process()
        let outPipe = Pipe(), errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ShellOutput(stdout: out, stderr: err, code: process.terminationStatus)
    }
}

// MARK: - Shell

struct ShellOutput {
    let stdout: String
    let stderr: String
    let code: Int32
}

final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _outData = Data()
    private var _errData = Data()

    func appendOut(_ data: Data) { lock.lock(); _outData.append(data); lock.unlock() }
    func appendErr(_ data: Data) { lock.lock(); _errData.append(data); lock.unlock() }
    var outString: String { lock.lock(); defer { lock.unlock() }; return String(data: _outData, encoding: .utf8) ?? "" }
    var errString: String { lock.lock(); defer { lock.unlock() }; return String(data: _errData, encoding: .utf8) ?? "" }
}

actor Shell {
    private var currentProcess: Process?

    /// Terminates the currently-running streaming process (used to cancel a download).
    func cancelCurrent() {
        currentProcess?.terminate()
    }

    func run(_ command: String, _ arguments: [String], requireSudo: Bool = false) async throws -> ShellOutput {
        let process = Process()
        let outPipe = Pipe(), errPipe = Pipe()

        if requireSudo {
            let cmd = ([command] + arguments).map(shQuote).joined(separator: " ")
            let script = "do shell script \"\(escapeAppleScript(cmd))\" with administrator privileges"
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
        } else {
            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
        }

        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "shell", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: err.isEmpty ? "Command failed (exit \(process.terminationStatus))" : err
            ])
        }
        return ShellOutput(stdout: out, stderr: err, code: process.terminationStatus)
    }

    func runOptional(_ command: String, _ arguments: [String]) async -> String? {
        let process = Process()
        let outPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        return String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    func runStreaming(_ command: String, _ arguments: [String], onOutput: @Sendable @escaping (String) -> Void) async throws -> ShellOutput {
        let process = Process()
        let outPipe = Pipe(), errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collected = StreamCollector()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                collected.appendOut(data)
                if let str = String(data: data, encoding: .utf8) {
                    onOutput(str)
                }
            }
        }

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                collected.appendErr(data)
                if let str = String(data: data, encoding: .utf8) {
                    onOutput(str)
                }
            }
        }

        // Async wait (instead of blocking waitUntilExit) so the actor stays
        // responsive to cancelCurrent() while the download runs.
        currentProcess = process
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in cont.resume() }
            do { try process.run() } catch { cont.resume(throwing: error) }
        }
        currentProcess = nil

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil

        let out = collected.outString
        let err = collected.errString

        guard process.terminationStatus == 0 else {
            throw NSError(domain: "shell", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: err.isEmpty ? "Command failed (exit \(process.terminationStatus))" : err
            ])
        }
        return ShellOutput(stdout: out, stderr: err, code: process.terminationStatus)
    }

    private func shQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func escapeAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Error helper

struct AppError: LocalizedError {
    let msg: String
    init(_ msg: String) { self.msg = msg }
    var errorDescription: String? { msg }
}

// MARK: - Theme

enum FFTheme {
    // Vortenia brand palette (vortenia.com): electric lime on near-black, warm ink.
    static let accent = Color(red: 0.77, green: 0.94, blue: 0.0)          // #c4f000
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.77, green: 0.94, blue: 0.0),               // #c4f000
                 Color(red: 0.84, green: 1.0, blue: 0.17)],              // #d6ff2b
        startPoint: .leading, endPoint: .trailing
    )
    // Near-black Vortenia backdrop so panels read with depth instead of flat gray.
    static let windowBackground = LinearGradient(
        colors: [Color(red: 0.043, green: 0.043, blue: 0.043),           // #0b0b0b
                 Color(red: 0.078, green: 0.078, blue: 0.078)],          // #141414
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let headerGradient = LinearGradient(
        colors: [Color(red: 0.078, green: 0.078, blue: 0.078),           // #141414
                 Color(red: 0.043, green: 0.043, blue: 0.043)],          // #0b0b0b
        startPoint: .top, endPoint: .bottom
    )
    static let cardBg = Color(nsColor: NSColor.controlBackgroundColor).opacity(0.55)
    static let subtleBorder = Color(red: 0.149, green: 0.149, blue: 0.141) // #262624 rule
    static let dimText = Color(red: 0.60, green: 0.59, blue: 0.55)        // #9a968c ink-soft

    // Shared corner-radius scale for visual consistency.
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
}

// MARK: - Button styles

/// Solid lime call-to-action button. High contrast on the dark backdrop.
struct FFPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: FFTheme.controlRadius)
                    .fill(FFTheme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.35))
                    .shadow(color: FFTheme.accent.opacity(isEnabled ? 0.45 : 0), radius: 8)
            )
            .contentShape(Rectangle())
    }
}

/// Filled lime-tinted chip with a bright border — unmistakably a button on black.
struct FFSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = FFTheme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isEnabled ? tint : FFTheme.dimText)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: FFTheme.controlRadius)
                    .fill(tint.opacity(isEnabled ? (configuration.isPressed ? 0.32 : 0.20) : 0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: FFTheme.controlRadius)
                    .stroke(tint.opacity(isEnabled ? 0.9 : 0.25), lineWidth: 1.5)
            )
            .contentShape(Rectangle())
    }
}

/// Compact icon button: a clearly filled, bordered lime circle so glyph actions read as tappable.
struct FFIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = FFTheme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isEnabled ? tint : FFTheme.dimText)
            .frame(width: 28, height: 28)
            .background(
                Circle().fill(tint.opacity(isEnabled ? (configuration.isPressed ? 0.32 : 0.20) : 0.08))
            )
            .overlay(Circle().stroke(tint.opacity(isEnabled ? 0.9 : 0.25), lineWidth: 1.5))
            .contentShape(Circle())
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var stashPathInput: String = ""

    var body: some View {
        ZStack(alignment: .topTrailing) {
            HSplitView {
                leftPanel
                    .frame(minWidth: 380, maxWidth: 460)
                rightPanel
                    .frame(minWidth: 500)
            }

            // Toast overlay
            VStack(spacing: 8) {
                ForEach(model.toasts) { toast in
                    ToastView(toast: toast)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }
            .padding(.top, 12)
            .padding(.trailing, 20)
            .animation(.spring(response: 0.4), value: model.toasts.count)
        }
        .background(FFTheme.windowBackground)
        .preferredColorScheme(.dark)
        .tint(FFTheme.accent)
        .frame(minWidth: 900, minHeight: 500, idealHeight: 700)
        .onAppear {
            stashPathInput = model.stashPath
            model.refreshAll()
        }
        .alert("Confirm Destructive Action", isPresented: $model.showDestructiveConfirm) {
            Button("Erase & Continue", role: .destructive) { model.confirmCreate() }
            Button("Cancel", role: .cancel) { model.cancelCreate() }
        } message: {
            Text(model.destructiveWarning)
        }
    }

    // MARK: Left panel

    var leftPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            headerBar

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Workflow indicator
                    WorkflowIndicator(currentPhase: model.currentPhase)
                        .padding(.top, 4)

                    // Stash
                    stashSection

                    // Mode toggle
                    modeToggle

                    // Installer / volume plans
                    if model.advancedMode {
                        volumePlansSection
                    } else {
                        installerSection
                    }

                    // Drive selection
                    driveSection
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)

            // Action bar
            actionBar
        }
    }

    var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .font(.title2)
                .foregroundStyle(FFTheme.accentGradient)

            VStack(alignment: .leading, spacing: 1) {
                Text("macOS Drive Forge")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text("USB & external drive installer builder")
                    .font(.system(size: 11))
                    .foregroundStyle(FFTheme.dimText)
            }

            Spacer()

            Button {
                model.refreshAll()
            } label: {
                Group {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .buttonStyle(FFIconButtonStyle())
            .help("Refresh all data")
            .disabled(model.isRefreshing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(FFTheme.headerGradient)
        .overlay(alignment: .bottom) {
            Rectangle().fill(FFTheme.subtleBorder).frame(height: 1)
        }
    }

    var stashSection: some View {
        CardView(title: "Installer Stash", icon: "archivebox") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .foregroundStyle(FFTheme.dimText)
                        .font(.caption)
                    TextField("~/InstallerStash", text: $stashPathInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit {
                            model.stashPath = stashPathInput
                            model.refreshStash()
                        }
                    Button {
                        model.stashPath = stashPathInput
                        model.refreshStash()
                    } label: {
                        Image(systemName: "checkmark.circle")
                    }
                    .buttonStyle(FFIconButtonStyle())
                    .help("Set stash path")
                }

                if model.stashedInstallers.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "tray")
                            .foregroundStyle(FFTheme.dimText)
                        Text("No cached installers")
                            .foregroundStyle(FFTheme.dimText)
                    }
                    .font(.caption)
                    .padding(.vertical, 4)
                } else {
                    ForEach(model.stashedInstallers) { stashed in
                        StashedInstallerRow(stashed: stashed, model: model)
                    }
                }
            }
        }
    }

    var modeToggle: some View {
        HStack(spacing: 8) {
            Image(systemName: model.advancedMode ? "square.stack.3d.up" : "externaldrive")
                .foregroundStyle(FFTheme.accentGradient)
                .font(.system(size: 14))
            Toggle(model.advancedMode ? "Multi-Volume Mode" : "Single Volume Mode", isOn: $model.advancedMode)
                .toggleStyle(.switch)
                .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(FFTheme.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: FFTheme.controlRadius))
        .overlay(RoundedRectangle(cornerRadius: FFTheme.controlRadius).stroke(FFTheme.subtleBorder))
    }

    var installerSection: some View {
        CardView(title: "Installer Version", icon: "arrow.down.app") {
            if model.installers.isEmpty {
                HStack(spacing: 6) {
                    if model.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text(model.isRefreshing ? "Loading installers..." : "No installers found. Click Refresh.")
                        .foregroundStyle(FFTheme.dimText)
                        .font(.caption)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("", selection: $model.selectedInstaller) {
                        Text("Select...").tag(Optional<InstallerVersion>.none)
                        ForEach(model.installers) { v in
                            InstallerPickerLabel(installer: v, isCached: model.isCached(v))
                                .tag(Optional(v))
                        }
                    }
                    .labelsHidden()
                    .onChange(of: model.selectedInstaller) { _, _ in model.updatePhase() }

                    HStack(spacing: 8) {
                        Button {
                            model.downloadOnly()
                        } label: {
                            HStack(spacing: 4) {
                                if model.isDownloading {
                                    ProgressView()
                                        .controlSize(.small)
                                        .scaleEffect(0.7)
                                } else {
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 11))
                                }
                                Text(model.isDownloading ? "Downloading..." : "Download Only")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .buttonStyle(FFSecondaryButtonStyle())
                        .disabled(model.creating)

                        if let sel = model.selectedInstaller, model.isCached(sel) {
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .font(.system(size: 11))
                                Text("In stash")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.green)
                            }
                        }
                    }

                    if model.isDownloading {
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: model.downloadProgress)
                                .progressViewStyle(.linear)
                                .tint(FFTheme.accent)
                            HStack(spacing: 6) {
                                Text(model.status)
                                    .font(.system(size: 11))
                                    .foregroundStyle(FFTheme.dimText)
                                Spacer()
                                Button {
                                    model.cancelDownload()
                                } label: {
                                    HStack(spacing: 3) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 10))
                                        Text("Cancel")
                                    }
                                }
                                .buttonStyle(FFSecondaryButtonStyle(tint: .red))
                                .help("Stop the download")
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            }
        }
    }

    var volumePlansSection: some View {
        CardView(title: "Volume Plans", icon: "square.stack.3d.up") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach($model.volumePlans) { $plan in
                    MultiVolumePlanRow(plan: $plan, installers: model.installers, model: model)
                }
                HStack(spacing: 8) {
                    Button {
                        model.addPlan()
                    } label: {
                        Label("Add Volume", systemImage: "plus.circle")
                    }
                    .buttonStyle(FFSecondaryButtonStyle())

                    if model.volumePlans.count > 1 {
                        Button {
                            if let last = model.volumePlans.last { model.removePlan(last) }
                        } label: {
                            Label("Remove Last", systemImage: "minus.circle")
                        }
                        .buttonStyle(FFSecondaryButtonStyle(tint: .red))
                    }
                }
            }
        }
    }

    var driveSection: some View {
        CardView(title: "USB Drive", icon: "externaldrive.fill") {
            VStack(alignment: .leading, spacing: 8) {
                if model.drives.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "externaldrive.badge.questionmark")
                            .foregroundStyle(.orange)
                        Text("No external drives found. Plug in a USB and Refresh.")
                            .foregroundStyle(FFTheme.dimText)
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    HStack(spacing: 8) {
                        Picker("", selection: $model.selectedDrive) {
                            Text("Select...").tag(Optional<USBDrive>.none)
                            ForEach(model.drives) { drive in
                                Text("\(drive.label) · \(drive.sizeDescription) (\(drive.device))")
                                    .tag(Optional(drive))
                            }
                        }
                        .labelsHidden()
                        .onChange(of: model.selectedDrive) { _, _ in model.updatePhase() }
                    }

                    if let drive = model.selectedDrive, drive.sizeBytes > 0 {
                        DriveCapacityBar(drive: drive)
                    }
                }

                Button {
                    Task { await model.refreshDrives() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                        Text("Rescan Drives")
                    }
                }
                .buttonStyle(FFSecondaryButtonStyle())
            }
        }
    }

    var actionBar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(FFTheme.subtleBorder).frame(height: 1)

            HStack(spacing: 10) {
                // Main action
                Button {
                    model.requestCreate()
                } label: {
                    HStack(spacing: 6) {
                        if model.creating {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .tint(.black)
                        } else {
                            Image(systemName: "hammer.fill")
                        }
                        Text(model.creating ? "Preparing..." : "Prepare Drive")
                    }
                }
                .disabled(model.creating)
                .buttonStyle(FFPrimaryButtonStyle())

                // Secondary actions
                Button {
                    model.copyPendingCommand()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(model.pendingTerminalCommand.isEmpty)
                .help("Copy command to clipboard")
                .buttonStyle(FFIconButtonStyle())

                Button {
                    model.runPendingInTerminal()
                } label: {
                    Image(systemName: "terminal")
                }
                .disabled(model.pendingTerminalCommand.isEmpty)
                .help("Run in Terminal")
                .buttonStyle(FFIconButtonStyle())
            }
            .padding(12)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: Right panel

    var rightPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Right header
            HStack {
                Image(systemName: "text.justify.left")
                    .foregroundStyle(FFTheme.dimText)
                Text("Output")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if !model.logs.isEmpty {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.logs, forType: .string)
                        model.showToast("Logs copied", style: .info)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(FFIconButtonStyle())
                    .help("Copy logs")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(FFTheme.headerGradient)
            .overlay(alignment: .bottom) {
                Rectangle().fill(FFTheme.subtleBorder).frame(height: 1)
            }

            // Terminal command
            if !model.pendingTerminalCommand.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal.fill")
                            .foregroundStyle(.green)
                        Text("Final Write Command")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text("Run in Terminal with sudo")
                            .font(.system(size: 10))
                            .foregroundStyle(FFTheme.dimText)
                    }

                    ScrollView {
                        Text(model.pendingTerminalCommand)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.green.opacity(0.9))
                            .padding(10)
                            .background(Color.black.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: FFTheme.controlRadius))
                    }
                    .frame(minHeight: 60, maxHeight: 140)
                }
                .padding(14)
                .background(FFTheme.cardBg)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(FFTheme.subtleBorder).frame(height: 1)
                }
            }

            // Log view
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if model.logs.isEmpty {
                            HStack(spacing: 8) {
                                Image(systemName: "text.justify.left")
                                    .foregroundStyle(FFTheme.dimText)
                                Text("No logs yet. Click Refresh to start.")
                                    .foregroundStyle(FFTheme.dimText)
                            }
                            .font(.system(size: 12))
                            .padding(20)
                        } else {
                            Text(model.logs)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .font(.system(size: 11, design: .monospaced))
                                .padding(12)
                        }

                        Color.clear.frame(height: 1).id("logBottom")
                    }
                }
                .scrollContentBackground(.hidden)
                .onChange(of: model.logs) { _, _ in
                    withAnimation {
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }
            .frame(maxHeight: .infinity)

            brandFooter
        }
    }

    // Vortenia brand strip at the foot of the output panel.
    var brandFooter: some View {
        HStack(spacing: 6) {
            Text("macOS Drive Forge")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(FFTheme.dimText)
            Spacer()
            Text("VORTENIA")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(FFTheme.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(FFTheme.headerGradient)
        .overlay(alignment: .top) {
            Rectangle().fill(FFTheme.subtleBorder).frame(height: 1)
        }
    }
}

// MARK: - Supporting Views

struct WorkflowIndicator: View {
    let currentPhase: WorkflowPhase

    var body: some View {
        HStack(spacing: 0) {
            ForEach(WorkflowPhase.allCases, id: \.rawValue) { phase in
                HStack(spacing: 4) {
                    ZStack {
                        Circle()
                            .fill(phase.rawValue <= currentPhase.rawValue ? FFTheme.accent : Color.gray.opacity(0.3))
                            .frame(width: 24, height: 24)

                        if phase.rawValue < currentPhase.rawValue {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Image(systemName: phase.icon)
                                .font(.system(size: 10))
                                .foregroundStyle(phase.rawValue <= currentPhase.rawValue ? .white : .gray)
                        }
                    }

                    Text(phase.label)
                        .font(.system(size: 10, weight: phase == currentPhase ? .semibold : .regular))
                        .foregroundStyle(phase.rawValue <= currentPhase.rawValue ? .primary : FFTheme.dimText)
                }

                if phase != WorkflowPhase.allCases.last {
                    Rectangle()
                        .fill(phase.rawValue < currentPhase.rawValue ? FFTheme.accent : Color.gray.opacity(0.3))
                        .frame(height: 2)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 4)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }
}

struct CardView<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(FFTheme.accentGradient)
                    .font(.system(size: 12))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FFTheme.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: FFTheme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: FFTheme.cardRadius).stroke(FFTheme.subtleBorder))
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
    }
}

struct ToastView: View {
    let toast: ToastMessage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.style.icon)
                .foregroundStyle(toast.style.color)
            Text(toast.message)
                .font(.system(size: 12, weight: .medium))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: FFTheme.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: FFTheme.cardRadius)
                .stroke(toast.style.color.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
        .frame(maxWidth: 320)
    }
}

struct StashedInstallerRow: View {
    let stashed: StashedInstaller
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text(stashed.osName)
                    .font(.system(size: 12, weight: .semibold))
                Text("\(stashed.version) · \(stashed.sizeDescription)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(FFTheme.dimText)
            }

            Spacer()

            Button {
                model.deleteFromStash(stashed)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(FFIconButtonStyle(tint: .red))
            .help("Delete \(stashed.osName) from stash")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Color.green.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: FFTheme.controlRadius))
    }
}

struct InstallerPickerLabel: View {
    let installer: InstallerVersion
    let isCached: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isCached ? "checkmark.circle.fill" : "arrow.down.circle")
                .foregroundStyle(isCached ? Color.green : FFTheme.accent)
            Text(installer.displayName)
        }
    }
}

struct DriveCapacityBar: View {
    let drive: USBDrive

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(FFTheme.dimText)
                Text(drive.label)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(drive.sizeDescription)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(FFTheme.dimText)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))

                    RoundedRectangle(cornerRadius: 3)
                        .fill(FFTheme.accentGradient)
                        .frame(width: geo.size.width * capacityFraction)
                }
            }
            .frame(height: 6)
        }
        .padding(8)
        .background(FFTheme.cardBg)
        .clipShape(RoundedRectangle(cornerRadius: FFTheme.controlRadius))
    }

    var capacityFraction: CGFloat {
        let gb = Double(drive.sizeBytes) / 1e9
        // Show proportion relative to 256GB max for visual scale
        return min(CGFloat(gb / 256.0), 1.0)
    }
}

struct MultiVolumePlanRow: View {
    @Binding var plan: MultiVolumePlan
    let installers: [InstallerVersion]
    let model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.slash")
                .foregroundStyle(FFTheme.dimText)
                .font(.system(size: 12))

            TextField("Name", text: $plan.name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)

            Stepper("\(plan.sizeGB) GB", value: $plan.sizeGB, in: 16...256, step: 8)
                .font(.system(size: 12))

            Picker("", selection: $plan.installerVersion) {
                Text("Select...").tag(Optional<InstallerVersion>.none)
                ForEach(installers) { v in
                    InstallerPickerLabel(installer: v, isCached: model.isCached(v))
                        .tag(Optional(v))
                }
            }
            .labelsHidden()
            .frame(minWidth: 120)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(FFTheme.cardBg.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: FFTheme.controlRadius))
    }
}

// MARK: - App entry

@main
struct FlashForgeApp: App {
    private static let homeURL = "https://vortenia.com"

    var body: some Scene {
        WindowGroup("macOS Drive Forge") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
        .commands {
            // Custom About panel (replaces the bare default).
            CommandGroup(replacing: .appInfo) {
                Button("About macOS Drive Forge") { Self.showAboutPanel() }
            }
            // The default Help menu has no help book ("No help available").
            // Point it at the Vortenia site instead.
            CommandGroup(replacing: .help) {
                Button("macOS Drive Forge Help") {
                    if let url = URL(string: Self.homeURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .keyboardShortcut("?", modifiers: .command)
            }
        }
    }

    private static func showAboutPanel() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
        let credits = NSAttributedString(
            string: "Put multiple macOS installers on one USB or external drive.\n\nMIT License · vortenia.com",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "macOS Drive Forge",
            .applicationVersion: version,
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Vortenia"
        ])
    }
}
