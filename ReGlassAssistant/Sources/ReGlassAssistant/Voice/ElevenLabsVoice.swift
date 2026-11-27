import Foundation

/// An ElevenLabs voice (the one set in `VoiceSettings`, unless the init names one), in Eleven v4 Turbo, as 24 kHz mono
/// PCM. With no voice chosen (ElevenLabs not the owner's choice, or no voice ID) it goes straight to the fallback voice
/// (Apple's). `VoiceProvider.elevenLabs` registers it.
///
/// Routes, in order:
/// 1. **Text-to-Dialogue WebSocket** (`wss://api.elevenlabs.io/v1/text-to-dialogue/stream-input`, the only streaming
///    route for v4 models). One socket per reply, opened as soon as the reply starts so it's warm by the time Claude's
///    first sentence arrives. Messages: `{"voices": [id]}` first, then `{"inputs": [{"text", "voice_id"}]}` and
///    `{"flush": true}` per sentence (the server otherwise waits for about 40 characters and 8 words),
///    `{"keep_alive": true}` while waiting on Claude (the server closes after 20 s of silence), and
///    `{"close_socket": true}` at the end. The server answers with `{"audio": base64, "alignment": …}` chunks,
///    `{"is_final": true}`, or `{"error", "message", "code"}`.
/// 2. **REST streaming** per sentence (`POST /v1/text-to-speech/{voice}/stream?output_format=pcm_24000`), two at a
///    time, played in order. Used when the socket fails, and for the rest of the session if the socket was turned down
///    outright (an unsupported setting rather than a network blip).
/// 3. **The fallback voice** (Apple) for whatever is left, when ElevenLabs can't be reached at all (no key, quota,
///    network).
///
/// When a route fails part-way, the next one picks up at the first sentence the alignment data says wasn't finished.
public final class ElevenLabsVoice: Voice, @unchecked Sendable {
    public static let modelID = "eleven_v4_turbo"

    public let name = "ElevenLabs"
    /// The voice the init named, if any; otherwise `VoiceSettings.elevenLabsVoiceID` while ElevenLabs is the chosen
    /// voice, read as each reply starts. Empty: Apple's voice speaks.
    private let fixedVoiceID: String?
    private var voiceID: String {
        fixedVoiceID ?? (VoiceSettings.elevenLabsChosen ? VoiceSettings.elevenLabsVoiceID : "")
    }
    /// The voice to test: the ID set in the app even while another voice is chosen.
    private var testVoiceID: String { fixedVoiceID ?? VoiceSettings.elevenLabsVoiceID }
    private let modelID: String
    private let keyProvider: @Sendable () throws -> String?
    private let fallback: (any Voice)?
    private let session: URLSession

    private static let lock = NSLock()
    nonisolated(unsafe) private static var socketTurnedDownUntil: Date?

    public init(voiceID: String? = nil, modelID: String = ElevenLabsVoice.modelID,
                keys: KeyStore = .shared, fallback: (any Voice)? = AppleVoice()) {
        self.fixedVoiceID = voiceID
        self.modelID = modelID
        self.keyProvider = { try keys.read(.elevenLabs) }
        self.fallback = fallback
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 25
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
    }

    public func speak(_ sentences: AsyncStream<String>,
                      onRoute: @escaping @Sendable (VoiceRoute) -> Void) -> AsyncThrowingStream<[Int16], Error> {
        AsyncThrowingStream { continuation in
            let feed = SentenceFeed()
            let pump = Task {
                for await sentence in sentences { feed.append(sentence) }
                feed.finish()
            }
            let work = Task {
                do {
                    try await self.run(feed, onRoute: onRoute) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                pump.cancel()
                work.cancel()
            }
        }
    }

    /// The Keys screen's Test: a tiny synthesis ("Hello.", six characters of quota) through the REST route, in the
    /// voice set in the app.
    public func testKey(_ key: String) async -> KeyTestResult {
        let voice = testVoiceID
        guard !voice.isEmpty else { return .failed("Add an ElevenLabs voice ID in Voice and Speech to test the voice.") }
        switch await sample("Hello.", voice: voice, key: KeyStore.clean(key), label: "key test") {
        case .spoken(_, let firstAudio): return .works(String(format: "Works. The voice answered in %.1f s.", firstAudio))
        case .failed(let reason): return .failed(reason)
        }
    }

    /// The Voice and Speech screen's Test: `line` in the voice set in the app, through the REST route (so a test never
    /// turns the WebSocket route down for the replies), with its audio to play. Uses as many characters of quota as
    /// `line` has. The voice's name is looked up alongside, if the key may read voices; the test works without it.
    public func trial(_ line: String) async -> VoiceTrial {
        let voice = testVoiceID
        guard !voice.isEmpty else { return .failed("Add a voice ID first.") }
        let key: String?
        do {
            key = try keyProvider()
        } catch {
            return .failed("Unlock your iPhone once since it restarted, then try again.")
        }
        guard let key else { return .failed("Add your ElevenLabs key first.") }
        async let name = voiceName(voice, key: key)
        switch await sample(line, voice: voice, key: key, label: "voice test") {
        case .spoken(let samples, let firstAudio):
            let who = await name ?? "The voice"
            return .works(samples: samples, message: "Works. \(who) answered in \(String(format: "%.1f", firstAudio)) s.")
        case .failed(let reason):
            return .failed(reason)
        }
    }

    private enum Sample {
        case spoken([Int16], firstAudio: TimeInterval)
        case failed(String)
    }

    /// One REST synthesis of `text`, whole, with a plain sentence for whatever went wrong.
    private func sample(_ text: String, voice: String, key: String, label: String) async -> Sample {
        let watch = Stopwatch()
        do {
            var request = restRequest(text: text, key: key, voice: voice)
            request.timeoutInterval = 15
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                let error = await Self.restError(status: status, bytes: bytes)
                AssistantLog.add("ElevenLabs \(label): HTTP \(status) (\(error.logKind))")
                switch error {
                case .unauthorized: return .failed("ElevenLabs didn't accept this key, or it can't do text to speech.")
                case .quota: return .failed("The ElevenLabs character quota is used up.")
                case .paidPlanRequired: return .failed(error.reason)
                case .http(404): return .failed("That voice isn't in this ElevenLabs account.")
                default: return .failed("ElevenLabs answered with an error (\(status)).")
                }
            }
            var decoder = PCMByteDecoder()
            var data = Data()
            var firstByte: TimeInterval?
            for try await byte in bytes {
                if firstByte == nil { firstByte = watch.elapsed }
                data.append(byte)
            }
            let samples = decoder.decode(data)
            AssistantLog.add("ElevenLabs \(label): HTTP 200, \(data.count) bytes, first byte after \(firstByte?.seconds ?? "—")")
            guard !samples.isEmpty else { return .failed("ElevenLabs sent no audio.") }
            return .spoken(samples, firstAudio: firstByte ?? watch.elapsed)
        } catch {
            AssistantLog.add("ElevenLabs \(label) failed (\(type(of: error)))")
            return .failed("ReGlass couldn't reach ElevenLabs.")
        }
    }

    /// The voice's name in the owner's ElevenLabs account (`GET /v1/voices/{id}`), or nil when it can't be read (the
    /// key may lack the Voices permission, which nothing else needs).
    private func voiceName(_ voice: String, key: String) async -> String? {
        guard let url = URL(string: "https://api.elevenlabs.io/v1/voices/\(voice)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request) else { return nil }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            AssistantLog.add("ElevenLabs voice name: HTTP \(status)")
            return nil
        }
        let name = (try? JSONValue.parse(data))?["name"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return name?.isEmpty == false ? name : nil
    }

    // MARK: Routes

    private func run(_ feed: SentenceFeed, onRoute: @escaping @Sendable (VoiceRoute) -> Void,
                     emit: @escaping ([Int16]) -> Void) async throws {
        guard !voiceID.isEmpty else {
            // Apple's voice by choice: no ElevenLabs voice is set up.
            try Task.checkCancellation()
            guard let fallback else { throw VoiceError.notChosen }
            for try await chunk in fallback.speak(feed.texts(from: 0), onRoute: onRoute) { emit(chunk) }
            return
        }
        var fallbackReason = "ElevenLabs couldn't be reached."
        let key: String?
        do {
            key = try keyProvider()
        } catch {
            key = nil
            fallbackReason = "The iPhone hasn't been unlocked since it restarted."
            AssistantLog.add("ElevenLabs key locked until first unlock; using the fallback voice")
        }
        var resumeAt = 0
        var tryREST = true
        if let key {
            if Self.socketAllowed {
                do {
                    onRoute(.elevenLabsSocket)
                    try await speakOverSocket(feed, key: key, emit: emit)
                    return
                } catch let failure as RouteFailure {
                    resumeAt = failure.resumeAt
                    tryREST = failure.error.otherRouteMightWork
                    fallbackReason = failure.error.reason
                    if failure.turnedDown { Self.turnDownSocket() }
                    AssistantLog.add("ElevenLabs WebSocket failed (\(failure.error.logKind)); "
                                     + (tryREST ? "switching to REST" : "using the fallback voice")
                                     + " from sentence \(resumeAt + 1)")
                }
            }
            if tryREST {
                do {
                    onRoute(.elevenLabsREST)
                    try await speakOverREST(feed, from: resumeAt, key: key, emit: emit)
                    return
                } catch let failure as RouteFailure {
                    resumeAt = failure.resumeAt
                    fallbackReason = failure.error.reason
                    AssistantLog.add("ElevenLabs REST failed (\(failure.error.logKind)); using the fallback voice "
                                     + "from sentence \(resumeAt + 1)")
                }
            }
        } else {
            if fallbackReason == "ElevenLabs couldn't be reached." { fallbackReason = "There's no ElevenLabs key yet." }
            AssistantLog.add("No ElevenLabs key; using the fallback voice")
        }
        try Task.checkCancellation()
        guard let fallback else { throw VoiceError.noKey }
        let reason = fallbackReason
        for try await chunk in fallback.speak(feed.texts(from: resumeAt), onRoute: { _ in onRoute(.apple(reason: reason)) }) {
            emit(chunk)
        }
    }

    private struct RouteFailure: Error {
        let error: VoiceError
        let resumeAt: Int
        /// The route itself was refused (not a blip): skip it for a while.
        var turnedDown = false
    }

    // MARK: WebSocket

    private func speakOverSocket(_ feed: SentenceFeed, key: String, emit: @escaping ([Int16]) -> Void) async throws {
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/text-to-dialogue/stream-input")!
        components.queryItems = [
            URLQueryItem(name: "model_id", value: modelID),
            URLQueryItem(name: "output_format", value: "pcm_24000"),
            URLQueryItem(name: "sync_alignment", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        let socket = session.webSocketTask(with: request)
        socket.maximumMessageSize = 4 * 1024 * 1024
        socket.resume()
        let watch = Stopwatch()
        let progress = SocketProgress()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        func failure(_ error: VoiceError, turnedDown: Bool = false) -> RouteFailure {
            RouteFailure(error: error, resumeAt: progress.resumePoint(), turnedDown: turnedDown)
        }

        do {
            try await socket.send(.string(Self.json(["voices": [.string(voiceID)]])))
        } catch {
            let status = (socket.response as? HTTPURLResponse)?.statusCode
            if let status { AssistantLog.add("ElevenLabs WebSocket handshake HTTP \(status)") }
            throw failure(Self.socketError(status: status), turnedDown: status.map { (400..<500).contains($0) && $0 != 401 && $0 != 429 } ?? false)
        }

        // Sender: sentences as they arrive (each flushed), keep-alives while waiting, close at the end.
        let sender = Task { [voiceID] in
            let keepAlive = Task {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(2))
                    if progress.secondsSinceSend() > 8 {
                        try await socket.send(.string(Self.json(["keep_alive": true])))
                        progress.markSent()
                    }
                }
            }
            defer { keepAlive.cancel() }
            for await (index, text) in feed.stream(from: 0) {
                let spoken = text + " "
                try await socket.send(.string(Self.json([
                    "inputs": [["text": .string(spoken), "voice_id": .string(voiceID)]],
                ])))
                try await socket.send(.string(Self.json(["flush": true])))
                progress.sent(index: index, characters: spoken.count)
                if index == 0 { progress.firstSentAt = watch.elapsed }
            }
            try Task.checkCancellation()
            if progress.sentCount == 0 {
                // Nothing to say (Claude failed or declined before any text): don't wait for a final frame that an
                // empty session may never send.
                progress.finishedEmpty = true
                socket.cancel(with: .normalClosure, reason: nil)
                return
            }
            try await socket.send(.string(Self.json(["close_socket": true])))
            progress.markSent()
        }
        defer { sender.cancel() }

        // Receiver: audio until the final frame.
        var decoder = PCMByteDecoder()
        var samples = 0
        do {
            while true {
                try Task.checkCancellation()
                let message = try await socket.receive()
                let data: Data
                switch message {
                case .string(let text): data = Data(text.utf8)
                case .data(let bytes): data = bytes
                @unknown default: continue
                }
                guard let json = try? JSONValue.parse(data) else { continue }
                if let error = json["error"]?.string {
                    let classified = Self.classify(error)
                    let code = json["code"]?.int ?? 0
                    AssistantLog.add("ElevenLabs WebSocket error (\(classified.logKind), code \(code))")
                    throw failure(classified, turnedDown: Self.isTurnDown(error))
                }
                if let audio = json["audio"]?.string, let bytes = Data(base64Encoded: audio), !bytes.isEmpty {
                    let chunk = decoder.decode(bytes)
                    if samples == 0 {
                        let after = watch.elapsed - (progress.firstSentAt ?? 0)
                        AssistantLog.add("Voice: ElevenLabs WebSocket, first audio \(after.seconds) after the first sentence")
                    }
                    samples += chunk.count
                    progress.heardAudio()
                    if let characters = json["alignment"]?["chars"]?.array?.count { progress.spoke(characters) }
                    if !chunk.isEmpty { emit(chunk) }
                }
                if json["is_final"]?.bool == true { break }
            }
        } catch let routeFailure as RouteFailure {
            throw routeFailure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if progress.finishedEmpty { return }
            throw failure(.network)
        }
        // The socket said it was done; make sure every sentence was actually sent (the feed may still be open if
        // the server closed early).
        guard progress.sentCount == feed.count else { throw failure(.network) }
        AssistantLog.add("Voice: ElevenLabs WebSocket done, \(PCM.replySeconds(samples).seconds) of audio")
    }

    /// What the socket has sent and what the alignment says has been spoken, for resuming elsewhere.
    private final class SocketProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var ends: [Int] = []           // cumulative characters at the end of each sent sentence
        private var spokenCharacters = 0
        private var lastSend = Date()
        private var sawAlignment = false
        private var receivedAudio = false
        private var empty = false
        var firstSentAt: TimeInterval?

        /// The reply had no sentences, and the socket was closed without waiting for the server.
        var finishedEmpty: Bool {
            get { lock.withLock { empty } }
            set { lock.withLock { empty = newValue } }
        }

        func heardAudio() { lock.withLock { receivedAudio = true } }

        func sent(index: Int, characters: Int) {
            lock.withLock {
                ends.append((ends.last ?? 0) + characters)
                lastSend = Date()
            }
        }

        func markSent() { lock.withLock { lastSend = Date() } }

        func secondsSinceSend() -> TimeInterval { lock.withLock { Date().timeIntervalSince(lastSend) } }

        func spoke(_ characters: Int) {
            lock.withLock {
                sawAlignment = true
                spokenCharacters += characters
            }
        }

        var sentCount: Int { lock.withLock { ends.count } }

        /// The first sentence not fully spoken. Without alignment data, the first one not yet sent.
        func resumePoint() -> Int {
            lock.withLock {
                guard sawAlignment else { return receivedAudio ? ends.count : 0 }
                return ends.firstIndex(where: { $0 > spokenCharacters + 2 }) ?? ends.count
            }
        }
    }

    // MARK: REST

    private func speakOverREST(_ feed: SentenceFeed, from start: Int, key: String,
                               emit: @escaping ([Int16]) -> Void) async throws {
        let gate = Gate(permits: 2)
        let watch = Stopwatch()
        // Each sentence starts fetching as soon as it arrives (two at a time) and is played in order.
        let (queue, queueContinuation) = AsyncStream<(Int, AsyncThrowingStream<[Int16], Error>)>.makeStream()
        let producer = Task { [weak self] in
            for await (index, text) in feed.stream(from: start) {
                guard let self else { break }
                queueContinuation.yield((index, self.fetch(text, key: key, gate: gate)))
            }
            queueContinuation.finish()
        }
        defer { producer.cancel() }
        var samples = 0
        for await (index, audio) in queue {
            do {
                for try await chunk in audio {
                    if samples == 0 { AssistantLog.add("Voice: ElevenLabs REST, first audio after \(watch.elapsed.seconds)") }
                    samples += chunk.count
                    emit(chunk)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as VoiceError {
                throw RouteFailure(error: error, resumeAt: index)
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw RouteFailure(error: .network, resumeAt: index)
            }
        }
        try Task.checkCancellation()
        AssistantLog.add("Voice: ElevenLabs REST done, \(PCM.replySeconds(samples).seconds) of audio")
    }

    /// One sentence over REST, buffered so it can download while the previous one plays.
    private func fetch(_ text: String, key: String, gate: Gate) -> AsyncThrowingStream<[Int16], Error> {
        let (stream, continuation) = AsyncThrowingStream<[Int16], Error>.makeStream()
        let task = Task { [session] in
            await gate.acquire()
            defer { Task { await gate.release() } }
            do {
                let (bytes, response) = try await session.bytes(for: restRequest(text: text, key: key))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    let error = await Self.restError(status: status, bytes: bytes)
                    AssistantLog.add("ElevenLabs REST HTTP \(status) (\(error.logKind))")
                    throw error
                }
                var decoder = PCMByteDecoder()
                var pending = Data()
                pending.reserveCapacity(4800)
                for try await byte in bytes {
                    pending.append(byte)
                    if pending.count >= 4800 {   // 100 ms
                        continuation.yield(decoder.decode(pending))
                        pending.removeAll(keepingCapacity: true)
                    }
                }
                if !pending.isEmpty { continuation.yield(decoder.decode(pending)) }
                continuation.finish()
            } catch let error as VoiceError {
                continuation.finish(throwing: error)
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch let error as URLError {
                continuation.finish(throwing: error.code == .cancelled ? CancellationError()
                                    : (error.code == .timedOut ? VoiceError.timedOut : VoiceError.network))
            } catch {
                continuation.finish(throwing: VoiceError.network)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func restRequest(text: String, key: String, voice: String? = nil) -> URLRequest {
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice ?? voiceID)/stream")!
        components.queryItems = [URLQueryItem(name: "output_format", value: "pcm_24000")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try? JSONValue.object(["text": .string(text), "model_id": .string(modelID)]).encoded()
        return request
    }

    // MARK: Errors

    private static func restError(status: Int, bytes: URLSession.AsyncBytes) async -> VoiceError {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > 16_384 { break }
            }
        } catch {}
        let detail = (try? JSONValue.parse(data))?["detail"]
        let code = detail?["status"]?.string ?? detail?["code"]?.string ?? ""
        // ElevenLabs also answers 402 when the plan doesn't cover the request, such as a library voice on a free plan.
        if detail?["code"]?.string == "paid_plan_required" { return .paidPlanRequired }
        switch status {
        case 401, 403:
            return code.contains("quota") || code.contains("credit") ? .quota : .unauthorized
        case 402: return .quota
        case 429: return code.contains("quota") ? .quota : .rateLimited
        default:
            return code.contains("quota") ? .quota : .http(status)
        }
    }

    private static func socketError(status: Int?) -> VoiceError {
        switch status {
        case 401?, 403?: return .unauthorized
        case 402?: return .quota
        case 429?: return .rateLimited
        case let status?: return .http(status)
        case nil: return .network
        }
    }

    private static func classify(_ error: String) -> VoiceError {
        let lowered = error.lowercased()
        if lowered.contains("paid_plan_required") || lowered.contains("paid plan") { return .paidPlanRequired }
        if lowered.contains("quota") || lowered.contains("credit") || lowered.contains("payment") { return .quota }
        if lowered.contains("auth") || lowered.contains("api_key") || lowered.contains("permission") { return .unauthorized }
        if lowered.contains("rate") || lowered.contains("concurren") { return .rateLimited }
        if lowered.contains("timeout") { return .timedOut }
        return .http(400)
    }

    /// Errors that mean the socket route itself doesn't accept these settings (model, format, voice).
    private static func isTurnDown(_ error: String) -> Bool {
        let lowered = error.lowercased()
        return lowered.contains("invalid") || lowered.contains("unsupported") || lowered.contains("not_allowed")
            || lowered.contains("model") || lowered.contains("format")
    }

    private static var socketAllowed: Bool {
        lock.withLock {
            guard let until = socketTurnedDownUntil else { return true }
            return Date() >= until
        }
    }

    private static func turnDownSocket() {
        lock.withLock { socketTurnedDownUntil = Date().addingTimeInterval(30 * 60) }
        AssistantLog.add("ElevenLabs WebSocket turned down; using REST for the next 30 minutes")
    }

    private static func json(_ object: [String: JSONValue]) -> String {
        (try? JSONValue.object(object).encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

/// At most `permits` tasks at once.
private actor Gate {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) {
        self.permits = permits
    }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
