import AVFoundation
import Foundation
import Speech

/// One expensive media task at a time; state survives clients and service restarts.
public final class VoiceJobs: @unchecked Sendable {
    private struct Job: Codable {
        var id: String, owner: String, kind: String, recordingID: String, status: String
        var locale: String, downloadModels: Bool, created: Date
        var error: String?, result: JSON?
        var inputExtension: String?
    }
    private struct Pending {
        let id: String
        let authorize: () throws -> Void
    }
    private let root: URL
    private let lock = NSRecursiveLock()
    private var jobs: [String: Job] = [:]
    private var pending: [Pending] = []
    private var running: String?
    private var task: Task<Void, Never>?
    public init(root: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for url in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where url.pathExtension == "json" {
            var job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: url))
            guard UUID(uuidString: job.id) != nil else { continue }
            if ["queued", "running"].contains(job.status) {
                job.status = "interrupted"; job.error = "service_restarted; no automatic retry"
                try persist(job)
            }
            if !["queued", "running"].contains(job.status) {
                try? FileManager.default.removeItem(at: inputURL(job))
                try? FileManager.default.removeItem(at: directory(job).appendingPathComponent("converted.m4a"))
            }
            jobs[job.id] = job
        }
    }
    public static let tools: [ToolDefinition] = {
        let f = ToolDefinition.field
        let job = ["job_id": f("string", "This Agent's job UUID")]
        return [
            ToolDefinition("voicememos_transcribe", "Start local SpeechAnalyzer transcription; returns immediately, never replaces Apple's transcript", ["id": f("string", "Recording ID"), "locale": f("string", "Required supported language, e.g. zh-CN or en-US"), "download_models": f("boolean", "Allow Apple's language model download when absent, default false")], required: ["id", "locale"], readOnly: false),
            ToolDefinition("voicememos_convert", "Convert a private snapshot to m4a in a background job; original media is retained", ["id": f("string", "Recording ID")], required: ["id"], readOnly: false),
            ToolDefinition("voicememos_jobs_list", "List only this Agent's background jobs"),
            ToolDefinition("voicememos_job_get", "Read job state and complete generated text through pages", job.merging(["body_offset": f("integer", "Unicode scalar offset"), "max_chars": f("integer", "1...16000")]) { a, _ in a }, required: ["job_id"]),
            ToolDefinition("voicememos_job_cancel", "Cancel a queued/running task; original recording is retained", job, required: ["job_id"], readOnly: false),
        ]
    }()
    private func directory(_ job: Job) -> URL { root.appendingPathComponent(job.id, isDirectory: true) }
    private func inputURL(_ job: Job) -> URL { directory(job).appendingPathComponent(job.inputExtension.map { "input." + $0 } ?? "input") }
    private func persist(_ job: Job) throws {
        let url = root.appendingPathComponent(job.id + ".json")
        try PrivateFile.writeJSON(job, to: url)
    }
    private func view(_ job: Job) -> JSON {
        .object(["job_id": .string(job.id), "kind": .string(job.kind), "recording_id": .string(job.recordingID), "status": .string(job.status), "locale": .string(job.locale), "created_at": .string(ISO8601DateFormatter().string(from: job.created)), "error": job.error.map(JSON.string) ?? .null, "result": job.result ?? .null, "continues_after_disconnect": .bool(true)])
    }
    public func start(owner: String, kind: String, recordingID: String, source: URL, locale: String, downloadModels: Bool, authorize: @escaping () throws -> Void) throws -> JSON {
        lock.lock(); defer { lock.unlock() }
        guard jobs.values.filter({ $0.owner == owner && ["queued", "running"].contains($0.status) }).count < 4, pending.count < 16 else { throw ServiceError("server_busy", "Media job queue is full") }
        try authorize()
        let job = Job(id: UUID().uuidString, owner: owner, kind: kind, recordingID: recordingID, status: "queued", locale: locale, downloadModels: downloadModels, created: Date(), inputExtension: source.pathExtension)
        let folder = directory(job)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let before = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            try FileManager.default.copyItem(at: source, to: inputURL(job))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: inputURL(job).path)
            let after = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { throw ServiceError("source_changed", "Recording changed during snapshot") }
            try authorize(); try persist(job); jobs[job.id] = job
            pending.append(Pending(id: job.id, authorize: authorize)); pump()
            return view(job)
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    private func pump() {
        guard running == nil, !pending.isEmpty else { return }
        let next = pending.removeFirst(); running = next.id
        task = Task { await self.run(next) }
    }
    private func run(_ pending: Pending) async {
        var job = snapshot(pending.id)!
        let authorizationMonitor = Task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)); try pending.authorize() }
                catch is CancellationError { return }
                catch { self.stopUnauthorized(pending.id, error); return }
            }
        }
        defer { authorizationMonitor.cancel() }
        do {
            try Task.checkCancellation(); try pending.authorize()
            job.status = "running"; try update(job)
            let input = inputURL(job)
            let assets = AssetStore(root: root.deletingLastPathComponent().appendingPathComponent("Agents/\(job.owner)/voice_memos/Exports"), application: "voice_memos")
            if job.kind == "transcription" {
                let result = try await transcribe(input, locale: job.locale, downloadModels: job.downloadModels, authorize: pending.authorize)
                try Task.checkCancellation(); try pending.authorize()
                try PrivateFile.writeJSON(result, to: directory(job).appendingPathComponent("transcript.json"))
                let text = result["text"].string ?? ""
                job.result = .object(["transcript_source": .string("speech_analyzer_generated"), "total_scalars": .int(text.unicodeScalars.count), "text_asset": try assets.save(Data(text.utf8), filename: "generated-transcript.txt", mimeType: "text/plain; charset=utf-8"), "segments_asset": try assets.save(result.data(), filename: "generated-transcript.json", mimeType: "application/json")])
            } else {
                let output = directory(job).appendingPathComponent("converted.m4a")
                guard let export = AVAssetExportSession(asset: AVURLAsset(url: input), presetName: AVAssetExportPresetAppleM4A) else { throw ServiceError("unsupported_media", "No native m4a exporter for this media") }
                // The async export API propagates Task.cancel() to the native exporter.
                try await export.export(to: output, as: .m4a)
                try Task.checkCancellation(); try pending.authorize()
                job.result = try assets.saveFile(output, filename: "converted.m4a", mimeType: "audio/mp4")
            }
            try Task.checkCancellation(); try pending.authorize(); job.status = "succeeded"
        } catch {
            job.status = Task.isCancelled || error is CancellationError ? "cancelled" : "failed"
            let native = error as NSError
            let underlying = native.userInfo[NSUnderlyingErrorKey] as? NSError
            job.error = (error as? ServiceError)?.code ?? "native_media_failed: \(native.domain):\(native.code)" + (underlying.map { "; \($0.domain):\($0.code)" } ?? "")
        }
        try? FileManager.default.removeItem(at: inputURL(job))
        try? FileManager.default.removeItem(at: directory(job).appendingPathComponent("converted.m4a"))
        finish(job)
    }
    private func finish(_ completed: Job) {
        var job = completed
        lock.lock(); defer { lock.unlock() }
        // Cancellation wins even if a native operation completed at the same moment.
        if jobs[job.id]?.status == "cancelled" { job.status = "cancelled"; job.result = nil }
        if jobs[job.id]?.status == "failed" { job.status = "failed"; job.error = jobs[job.id]?.error; job.result = nil }
        do { try persist(job); jobs[job.id] = job } catch { jobs[job.id]?.status = "interrupted" }
        running = nil; task = nil; pump()
    }
    private func stopUnauthorized(_ id: String, _ error: Error) {
        lock.lock(); defer { lock.unlock() }
        guard running == id, var job = jobs[id], job.status == "running" else { return }
        job.status = "failed"; job.error = (error as? ServiceError)?.code ?? "permission_denied"
        jobs[id] = job; try? persist(job); task?.cancel()
    }
    private func snapshot(_ id: String) -> Job? { lock.lock(); defer { lock.unlock() }; return jobs[id] }
    private func update(_ job: Job) throws { lock.lock(); defer { lock.unlock() }; try persist(job); jobs[job.id] = job }
    private func transcribe(_ url: URL, locale: String, downloadModels: Bool, authorize: @escaping () throws -> Void) async throws -> JSON {
        guard SpeechTranscriber.isAvailable, let language = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: locale)) else { throw ServiceError("unsupported_locale", "SpeechAnalyzer does not support this language on this Mac") }
        let transcriber = SpeechTranscriber(locale: language, preset: .transcription)
        let alreadyReserved = await AssetInventory.reservedLocales.contains(language)
        if !alreadyReserved { _ = try await AssetInventory.reserve(locale: language) }
        let status = await AssetInventory.status(forModules: [transcriber])
        guard status != .unsupported else { throw ServiceError("unsupported_locale", "Language model is unsupported") }
        if status != .installed && !downloadModels {
            if !alreadyReserved { _ = await AssetInventory.release(reservedLocale: language) }
            throw ServiceError("model_download_required", "Retry with download_models=true to download Apple's language model; audio stays local")
        }
        try authorize(); try Task.checkCancellation()
        if status != .installed, let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) { try await request.downloadAndInstall() }
        try authorize(); try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let resultTask = Task { () throws -> JSON in
            var segments: [JSON] = []; var full = ""
            for try await result in transcriber.results {
                try Task.checkCancellation(); try authorize()
                let text = String(result.text.characters); full += text
                segments.append(.object(["text": .string(text), "start_seconds": .number(result.range.start.seconds), "duration_seconds": .number(result.range.duration.seconds)]))
            }
            return .object(["text": .string(full), "segments": .array(segments), "locale": .string(language.identifier), "transcript_source": .string("speech_analyzer_generated")])
        }
        let output = try await withTaskCancellationHandler {
            do {
                try await analyzer.start(inputAudioFile: AVAudioFile(forReading: url), finishAfterFile: true)
                return try await resultTask.value
            } catch { resultTask.cancel(); await analyzer.cancelAndFinishNow(); throw error }
        } onCancel: { resultTask.cancel(); Task { await analyzer.cancelAndFinishNow() } }
        return output
    }
    public func call(_ name: String, owner: String, arguments: [String: JSON]) throws -> JSON {
        lock.lock(); defer { lock.unlock() }
        if name == "voicememos_jobs_list" { return .object(["jobs": .array(jobs.values.filter { $0.owner == owner }.sorted { $0.created > $1.created }.map(view))]) }
        let a = Arguments(arguments); let id = try a.requiredString("job_id")
        guard var job = jobs[id], job.owner == owner else { throw ServiceError("not_found", "Job not found for this Agent") }
        if name == "voicememos_job_cancel", ["queued", "running"].contains(job.status) {
            job.status = "cancelled"; try persist(job); jobs[id] = job
            pending.removeAll { $0.id == id }
            if running == id { task?.cancel() } else { try? FileManager.default.removeItem(at: directory(job)) }
        }
        var fields = view(job).object!
        if name == "voicememos_job_get", job.status == "succeeded", job.kind == "transcription" {
            let result = try JSONDecoder().decode(JSON.self, from: Data(contentsOf: directory(job).appendingPathComponent("transcript.json")))
            fields["body"] = try BodyPaging.page(result["text"].string ?? "", arguments: a)
            fields["transcript_source"] = .string("speech_analyzer_generated")
        }
        return .object(fields)
    }
}
