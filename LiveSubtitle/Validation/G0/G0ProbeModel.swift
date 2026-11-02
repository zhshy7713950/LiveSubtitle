#if DEBUG && !targetEnvironment(simulator)
import AVFoundation
import Observation
import Translation
import UIKit
import Darwin

@MainActor @Observable
final class G0ProbeModel {
    var status = "G0 临时验证 · 英文 → 简体中文"
    var ready = false
    var preparing = false
    var running = false
    var stopping = false
    var starting = false
    var rows: [G0Caption] = []
    var metricsText = "尚未开始"
    var translationConfiguration: TranslationSession.Configuration?
    var preparationID: UUID?
    var previewID = UUID()
    var pip = G0PiPProbe()
    var pipStarted = false
    private var identity: SessionIdentity?
    private let state = G0RunState()
    private let speech = G0SpeechProbe()
    private let inbox = G0AudioInbox()
    private var capture: G0CaptureProbe?
    private var preparationTask: Task<String, any Error>?
    private var startupTask: Task<Void, Never>?
    private var worker: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var startUptime = 0.0
    private var peakMemory: UInt64 = 0
    private var initialMemory: UInt64 = 0
    private var startMethod = ""
    private var pipEvents = ""
    private let clock = G0Clock()

    func beginPreparation() {
        guard !preparing, !running, !starting, !stopping else { return }
        preparing = true
        ready = false
        preparationID = UUID()
        status = "前台准备本地翻译和英文识别资源；请确认系统下载提示"
        translationConfiguration = TranslationSession.Configuration(source: G0TranslationProbe.source, target: G0TranslationProbe.target)
    }

    func finishPreparation(_ token: UUID?) async {
        guard token == preparationID, preparing else { return }
        do {
            let task = Task { try await speech.prepare() }
            preparationTask = task
            let method = try await task.value
            guard token == preparationID, preparing, !Task.isCancelled else { return }
            preparationTask = nil
            startMethod = method
            preparing = false
            ready = true
            status = "资源已就绪（\(method)）；可开始全屏共享"
        } catch {
            guard token == preparationID else { return }
            preparationTask = nil
            preparing = false
            ready = false
            status = "识别资源准备失败，请重试；未开始采集"
        }
    }

    func preparationFailed(_ token: UUID?) {
        guard token == preparationID else { return }
        preparing = false
        ready = false
        status = "本地翻译资源未就绪；未开始采集"
    }

    func start() {
        guard ready, !running, !starting, !stopping, identity == nil else { return }
        starting = true
        ready = false
        startupTask = Task { [weak self] in await self?.startRun() }
    }

    private func startRun() async {
        guard !Task.isCancelled, !stopping else { return }
        let token = await state.begin()
        guard !Task.isCancelled, !stopping else { return }
        identity = token
        inbox.activate(token)
        pip = G0PiPProbe()
        previewID = UUID()
        pipEvents = ""
        startUptime = 0
        initialMemory = 0
        peakMemory = 0
        pipStarted = false
        rows = []
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try audio.setActive(true) // No microphone or silent-audio keepalive.
            try pip.prepare(sessionID: token.sessionID)
            pip.onEvent = { [weak self] id, event in
                guard let self, self.identity?.sessionID == id else { return }
                self.pipEvents = String((self.pipEvents + "," + event).suffix(200))
                self.pipStarted = self.pip.isActive
                if ["closed", "startFailed", "renderFailed"].contains(event) {
                    self.requestStop("PiP: \(event)")
                } else if event == "restored" {
                    self.status = "已恢复 App；离开前请重新开启字幕小窗"
                }
            }
            try await speech.start(identity: token, inbox: inbox, onTranscript: { [weak self] result in
                await self?.receive(result)
            }, onFailure: { [weak self] token, code in
                await self?.failed(token, code: code)
            })
            guard identity == token else { return }
            let capture = G0CaptureProbe(inbox: inbox, identity: token)
            self.capture = capture
            capture.onStarted = { [weak self] in self?.captureStarted(token) }
            capture.onCancelled = { [weak self] in self?.requestStop("用户取消系统共享") }
            capture.onFailure = { [weak self] code in self?.failed(token, code: code) }
            status = "请在系统界面确认共享整个屏幕"
            try capture.present()
        } catch {
            failed(token, code: (error as? FailureCode) ?? .unavailable)
        }
    }

    private func captureStarted(_ token: SessionIdentity) {
        guard identity == token else { return }
        starting = false
        running = true
        startUptime = ProcessInfo.processInfo.systemUptime
        initialMemory = Self.memoryBytes()
        peakMemory = initialMemory
        status = "采集已开始：点“开启字幕小窗”，再切 Chrome 播放英文视频"
        worker = Task { [weak self] in await self?.translateLoop(token) }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.identity == token else { return }
                await self.refreshMetrics(token)
                if UIApplication.shared.applicationState == .background, !self.pip.isActive {
                    self.requestStop("后台没有可用字幕 PiP")
                    return
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func startPiP() {
        guard identity != nil, running else { return }
        do { try pip.start() } catch { status = "PiP 尚未就绪，请稍后再点开启；离开前须看到小窗" }
    }

    private func receive(_ result: G0Transcript) async {
        guard identity == result.identity, !stopping else { return }
        let accepted = await state.receive(result)
        guard identity == result.identity else { return }
        if !accepted { requestStop("G0 失败：翻译队列积压"); return }
        let snapshot = await state.snapshot()
        guard identity == result.identity else { return }
        rows = snapshot.rows
        updatePiP()
    }

    private func translateLoop(_ token: SessionIdentity) async {
        while !Task.isCancelled, identity == token {
            guard let job = await state.next(token) else {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                continue
            }
            if await state.expired(job) { failed(token, code: .deadlineExceeded); return }
            let translation = Task { try await G0TranslationProbe.translate(job.text) }
            let timeout = Task { [weak self] in
                guard let self else { return }
                do { try await clock.sleep(until: job.deadline) } catch { return }
                if await state.expired(job), identity == token { failed(token, code: .deadlineExceeded) }
                translation.cancel()
            }
            do {
                let translated = try await withTaskCancellationHandler {
                    try await translation.value
                } onCancel: {
                    translation.cancel()
                }
                timeout.cancel()
                guard identity == token, !Task.isCancelled else { return }
                if await state.expired(job) { failed(token, code: .deadlineExceeded); return }
                let application = await state.apply(translated, to: job)
                if application == .expired { failed(token, code: .deadlineExceeded); return }
                let snapshot = await state.snapshot()
                guard identity == token else { return }
                rows = snapshot.rows
                updatePiP()
            } catch {
                timeout.cancel()
                guard identity == token, !Task.isCancelled else { return }
                if let code = await state.failureCode(for: job) { failed(token, code: code); return }
                await state.finish(job)
            }
        }
    }

    private func updatePiP() {
        let visible = rows.suffix(RuntimePolicy.defaultDisplayCount)
        pip.update(visible.isEmpty ? "等待声音" : visible.map { ($0.translation.isEmpty ? "本地翻译中…" : $0.translation) + "\n" + $0.source }.joined(separator: "\n\n"))
    }

    private func failed(_ token: SessionIdentity, code: FailureCode) {
        guard identity == token, !stopping else { return }
        requestStop("G0 失败：\(code.rawValue)")
    }

    func requestStop(_ reason: String = "用户停止") {
        guard !stopping else { return }
        stopping = true
        stopTask = Task { [weak self] in await self?.stop(reason) }
    }

    private func stop(_ reason: String) async {
        let old = identity
        identity = nil
        preparationID = nil
        translationConfiguration = nil
        ready = false
        preparing = false
        running = false
        starting = false
        preparationTask?.cancel()
        startupTask?.cancel()
        worker?.cancel()
        monitor?.cancel()
        if let old { await refreshMetrics(old, ending: true) }
        await state.invalidate()
        inbox.invalidate()
        _ = try? await preparationTask?.value
        await startupTask?.value
        preparationTask = nil
        startupTask = nil
        await capture?.stop()
        await speech.release()
        await pip.stop()
        await worker?.value
        await monitor?.value
        worker = nil; monitor = nil; capture = nil
        rows = []
        pipStarted = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        status = "已停止并清空内容：\(reason)"
        metricsText += "\n停止原因：\(reason)"
        stopping = false
        stopTask = nil
    }

    func backgrounded() {
        if starting { requestStop("启动期间离开 App"); return }
        guard running else { return }
        let token = identity
        Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard let self, self.identity == token, self.running else { return }
            if !self.pip.isActive { self.requestStop("离开 App 时没有可用字幕 PiP") }
        }
    }

    private func refreshMetrics(_ token: SessionIdentity, ending: Bool = false) async {
        let audio = inbox.snapshot()
        let speech = await speech.snapshot()
        let scheduling = await state.snapshot()
        guard ending || identity == token else { return }
        let memory = Self.memoryBytes()
        peakMemory = max(peakMemory, memory)
        let elapsed = startUptime > 0 ? ProcessInfo.processInfo.systemUptime - startUptime : 0
        metricsText = String(format: "时长 %.0f s · 音频 %d / 非静音 %d\n输入 %.0f Hz × %d → 识别 %.0f Hz\n原文事件 %d · 译文 %d · 视频帧 %d\n音频队列 %.3f s / 峰值 %.3f s\n音频溢出 %d · 输入丢弃 %d · 无效 %d · 断流 %d\n翻译排队 %d / 峰值 %d · 旧结果 %d\n内存起始 %.1f / 当前 %.1f / 采样峰值 %.1f MiB\n热状态 %d · %@\nPiP: %@", elapsed, audio.buffers, speech.nonSilent,
                             speech.inputRate, speech.channels, speech.analyzerRate, speech.results,
                             scheduling.translations, pip.frames, audio.queuedSeconds, audio.maximumQueuedSeconds,
                             audio.overflowCount, speech.inputDrops, audio.invalidCount, speech.discontinuities,
                             scheduling.pending, scheduling.maximumPending, scheduling.stale,
                             Double(initialMemory) / 1_048_576, Double(memory) / 1_048_576, Double(peakMemory) / 1_048_576,
                             ProcessInfo.processInfo.thermalState.rawValue, startMethod, pipEvents)
    }

    private static func memoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
}
#endif
