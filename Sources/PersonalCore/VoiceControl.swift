import AppKit
import AVFoundation
import Foundation

public final class VoiceControl {
    private struct Recording: Codable {
        var id: String, owner: String, title: String, status: String
    }
    private let root: URL
    private let lock = NSRecursiveLock()
    private var player: AVAudioPlayer?
    private var playerOwner: String?
    private var recording: Recording?
    private var startProcess: Process?
    public init(root: URL) {
        self.root = root
        if let data = try? Data(contentsOf: root.appendingPathComponent("recording-session.json")), var item = try? JSONDecoder().decode(Recording.self, from: data) {
            if ["starting", "recording", "awaiting_title_verification", "stopping"].contains(item.status) { item.status = "unknown_after_restart" }
            recording = item; try? save()
        }
    }
    public static let tools: [ToolDefinition] = {
        let f = ToolDefinition.field
        return [
            ToolDefinition("voicememos_play", "Play the specified original locally with native confirmation", ["id": f("string", "Recording ID")], required: ["id"], readOnly: false),
            ToolDefinition("voicememos_stop_playback", "Stop only playback owned by this Agent", readOnly: false),
            ToolDefinition("voicememos_recording_status", "Read this Agent's recording session and public shortcut configuration"),
            ToolDefinition("voicememos_recording_start", "Start a named recording through the owner's configured public shortcut, after native confirmation", readOnly: false),
            ToolDefinition("voicememos_recording_stop", "Stop an owned session only after a human checks the active recording's exact title", ["session_id": f("string", "This Agent's active session UUID")], required: ["session_id"], readOnly: false),
            ToolDefinition("voicememos_recording_forget", "Forget this Agent's unknown session after native confirmation; never stops or deletes audio", ["session_id": f("string", "Unknown session UUID")], required: ["session_id"], readOnly: false),
        ]
    }()
    public static func configure(root: URL, start: String, stop: String) throws {
        guard let startID = UUID(uuidString: start), let stopID = UUID(uuidString: stop), startID != stopID else { throw ServiceError("invalid_arguments", "Two distinct official shortcut UUIDs are required") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let path = root.appendingPathComponent("recording-shortcuts.json")
        try PrivateFile.writeJSON(JSON.object(["start": .string(startID.uuidString), "stop": .string(stopID.uuidString)]), to: path)
    }
    private func shortcuts() throws -> (String, String) {
        let config = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: root.appendingPathComponent("recording-shortcuts.json")))
        guard let start = config["start"].string.flatMap(UUID.init(uuidString:)), let stop = config["stop"].string.flatMap(UUID.init(uuidString:)), start != stop else { throw ServiceError("recording_not_configured", "Owner must configure two public Voice Memos shortcuts in the App") }
        return (start.uuidString, stop.uuidString)
    }
    private func save() throws {
        let url = root.appendingPathComponent("recording-session.json")
        try PrivateFile.writeJSON(recording, to: url)
    }
    private func view(owner: String) -> JSON {
        var fields: [String: JSON] = ["shortcuts_configured": .bool((try? shortcuts()) != nil), "playback_owned": .bool(playerOwner == owner && player?.isPlaying == true)]
        if let item = recording, item.owner == owner {
            fields["session_id"] = .string(item.id); fields["title"] = .string(item.title); fields["status"] = .string(item.status)
        } else { fields["status"] = .string(recording == nil ? "idle" : "another_agent_session") }
        return .object(fields)
    }
    private func process(_ shortcut: String, input: URL? = nil) -> Process {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", shortcut] + (input.map { ["--input-path", $0.path] } ?? [])
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        return process
    }
    public func call(_ name: String, owner: AgentRecord, values: [String: JSON], module: () throws -> VoiceMemosModule, authorize: () throws -> Void) throws -> JSON {
        lock.lock(); defer { lock.unlock() }
        try authorize()
        let a = Arguments(values)
        switch name {
        case "voicememos_recording_status": return view(owner: owner.id)
        case "voicememos_play":
            guard playerOwner == nil || playerOwner == owner.id || player?.isPlaying != true else { throw ServiceError("playback_busy", "Another Agent owns the current playback") }
            let reader = try module(); let id = try a.requiredString("id")
            let metadata = try reader.call("voicememos_get", ["id": .string(id)])
            let source = try reader.localAudio(id: id)
            let candidate = try AVAudioPlayer(contentsOf: source)
            guard NativeConfirmation.ask("在本机播放录音？", "Agent: \(owner.name)\n\(metadata["title"].string ?? "")\nRecording ID: \(id)\nDuration: \(Int(candidate.duration)) seconds\n将通过当前音频输出设备播放。") else { return .object(["status": .string("cancelled")]) }
            try authorize(); guard candidate.play() else { throw ServiceError("playback_failed", "Native player did not start") }
            player?.stop(); player = candidate; playerOwner = owner.id
            return .object(["status": .string("playing")])
        case "voicememos_stop_playback":
            guard playerOwner == owner.id else { throw ServiceError("not_found", "This Agent does not own playback") }
            player?.stop(); player = nil; playerOwner = nil; return .object(["status": .string("stopped")])
        case "voicememos_recording_start":
            guard recording == nil else { throw ServiceError("recording_busy", "An existing session must be resolved before starting another") }
            let (start, _) = try shortcuts(); let id = UUID().uuidString
            let title = "APM Recording \(id)"
            guard NativeConfirmation.ask("开始麦克风录音？", "Agent: \(owner.name)\n标题：\(title)\n将运行专用的语音备忘录公开快捷指令。请先确认当前没有其他录音；系统可能另行请求麦克风权限。停止录音也需要本机确认。") else { return .object(["status": .string("cancelled")]) }
            try authorize()
            let input = root.appendingPathComponent("recording-input.txt")
            try PrivateFile.write(Data(title.utf8), to: input)
            recording = Recording(id: id, owner: owner.id, title: title, status: "starting"); try save()
            let startTask = process(start, input: input)
            startTask.terminationHandler = { [weak self] task in
                guard let self else { return }; self.lock.lock(); defer { self.lock.unlock() }
                if self.recording?.id == id, self.recording?.status == "starting" {
                    self.recording?.status = task.terminationStatus == 0 ? "awaiting_title_verification" : "unknown_start_result"; try? self.save()
                }
                try? FileManager.default.removeItem(at: input)
                self.startProcess = nil
            }
            startProcess = startTask
            do { try startTask.run() } catch { recording?.status = "unknown_start_result"; try? save(); throw error }
            return view(owner: owner.id)
        case "voicememos_recording_stop", "voicememos_recording_forget":
            guard let item = recording, item.owner == owner.id, item.id == (try a.string("session_id", required: true)) else { throw ServiceError("not_found", "This Agent does not own that session") }
            if name == "voicememos_recording_forget" {
                guard item.status.hasPrefix("unknown") else { throw ServiceError("invalid_state", "Only unknown sessions may be forgotten") }
                guard NativeConfirmation.ask("忘记未知录音会话？", "Agent: \(owner.name)\n\(item.title)\n请先在语音备忘录中自行确认并处理当前录音。此操作只清除本服务会话，不停止或删除任何录音。") else { return .object(["status": .string("cancelled")]) }
                try authorize(); recording = nil; try save(); return view(owner: owner.id)
            }
            guard ["starting", "recording", "awaiting_title_verification"].contains(item.status) else { throw ServiceError("recording_ownership_unknown", "Resolve unknown state manually in Voice Memos; never stop an unverified recording") }
            let (_, stop) = try shortcuts()
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/VoiceMemos.app"))
            guard NativeConfirmation.ask("核对当前录音后停止？", "Agent: \(owner.name)\n请在语音备忘录中核对当前正在录制的标题必须为：\n\(item.title)\n只有标题完全一致才点确认；看不到或不一致请取消。公开停止动作没有录音ID参数，需要你核对归属。") else { return .object(["status": .string("cancelled")]) }
            try authorize(); recording?.status = "stopping"; try save()
            let stopTask = process(stop); let done = DispatchSemaphore(value: 0)
            stopTask.terminationHandler = { _ in done.signal() }
            do { try stopTask.run() } catch { recording?.status = "unknown_stop_result"; try? save(); throw error }
            guard done.wait(timeout: .now() + 20) == .success, stopTask.terminationStatus == 0 else {
                recording?.status = "unknown_stop_result"; try save(); throw ServiceError("effect_unknown", "Inspect Voice Memos manually; stopping is never retried automatically")
            }
            recording = nil; try save(); return .object(["status": .string("stopped"), "recording_title": .string(item.title), "lookup": .string("Search exact title after the recording synchronizes; no latest recording is guessed")])
        default: throw ServiceError("unknown_tool", name)
        }
    }
}
