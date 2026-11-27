import Foundation

/// Which voice actually spoke, for the screens and the log.
public enum VoiceRoute: Sendable, Equatable {
    case elevenLabsSocket
    case elevenLabsREST
    /// Apple's voice, as the fallback (`reason` is a plain sentence) or by choice.
    case apple(reason: String?)
    /// Another provider's voice, by the name the screens show ("OpenAI voice"). For providers added later
    /// (`VoiceProvider`), so they need no case of their own here.
    case provider(String)

    public var label: String {
        switch self {
        case .elevenLabsSocket: return "ElevenLabs voice"
        case .elevenLabsREST: return "ElevenLabs voice (slower route)"
        case .apple: return "Apple's voice"
        case .provider(let name): return name
        }
    }
}

/// Something that turns sentences into speech. Every voice keeps this contract; `VoiceProvider` lists the ones the
/// owner can choose, and docs/VOICE.md walks through adding one.
///
/// - **Input:** the reply's sentences, in order, as Claude writes them (cut by `SentenceChunker`, cleaned for speaking
///   by `SpokenText`). The stream stays open while Claude is still writing, and can stay quiet for seconds (a web
///   search, a tool call). It can also end without a single sentence (Claude failed before any text).
/// - **Output:** 24 kHz mono signed 16-bit PCM (`PCM.replyRate`), as `[Int16]` chunks of any length, in order, as soon
///   as they're made. Resample anything else to it (`StreamingConverter`); little-endian bytes from the network become
///   samples with `PCMByteDecoder`. The same samples go to the glasses (ReGlassKit encodes them to Opus) or play on the
///   iPhone (`PCMPlayer`), so the voice never knows or cares which.
/// - **Streaming:** start on the first sentence; never wait for the whole reply. The glasses start playing once about
///   450 ms of audio is in, and end a reply whose audio stops coming for about 2.5 s once it has started (ReGlass fills
///   its own pauses, such as a web search, with silence). Fetching the next sentence while one plays keeps it smooth.
/// - **End:** finish the stream after the last sentence's audio, once `sentences` has ended.
/// - **Cancellation:** when the consumer stops (the wearer taps, a new wake word, the link drops), the returned stream
///   terminates: stop synthesis and every network call at once (`onTermination`), and emit nothing more.
/// - **Errors:** a voice that can't speak (no key, key turned down, quota, no network) should hand the sentences it
///   hasn't spoken to its fallback, Apple's voice on the iPhone, and report `onRoute(.apple(reason:))` with one plain
///   sentence, so the wearer still hears the answer. Throw (a `VoiceError` where one fits) only when there's no fallback:
///   the turn doesn't speak a failed reply again.
/// - **`onRoute`:** call it before the first audio with the route that speaks, and again whenever that changes.
/// - **Privacy:** never log the text, the key or the audio. Kinds, sizes and timings only (`AssistantLog`).
public protocol Voice: Sendable {
    /// Log-safe name ("ElevenLabs", "Apple").
    var name: String { get }

    /// Speaks `sentences` as they arrive, in order. The stream ends after the last sentence's audio. Cancelling the
    /// consumer stops synthesis. `onRoute` hears which voice is speaking, again whenever that changes.
    func speak(_ sentences: AsyncStream<String>,
               onRoute: @escaping @Sendable (VoiceRoute) -> Void) -> AsyncThrowingStream<[Int16], Error>
}

public extension Voice {
    func speak(_ sentences: AsyncStream<String>) -> AsyncThrowingStream<[Int16], Error> {
        speak(sentences, onRoute: { _ in })
    }

    func speak(_ text: String, onRoute: @escaping @Sendable (VoiceRoute) -> Void) -> AsyncThrowingStream<[Int16], Error> {
        let (sentences, continuation) = AsyncStream<String>.makeStream()
        continuation.yield(text)
        continuation.finish()
        return speak(sentences, onRoute: onRoute)
    }

    /// Speaks one piece of text.
    func speak(_ text: String) -> AsyncThrowingStream<[Int16], Error> {
        let (sentences, continuation) = AsyncStream<String>.makeStream()
        continuation.yield(text)
        continuation.finish()
        return speak(sentences)
    }

    /// The whole of `text` as one array of samples.
    func render(_ text: String) async throws -> [Int16] {
        var all: [Int16] = []
        for try await chunk in speak(text) { all += chunk }
        return all
    }
}

/// Which voice speaks the assistant's replies: the owner's choice (Settings → Assistant → Voice and speech), Apple's
/// on-device voice unless they chose another. ElevenLabs also needs a key in the Keychain and a voice ID from the
/// owner's own ElevenLabs voice library; until both are there, Apple's voice speaks.
public enum VoiceSettings {
    private static let voiceIDKey = "reglass.assistant.elevenLabsVoiceID"
    private static let providerKey = "reglass.assistant.voice"
    private static let lock = NSLock()

    /// The chosen voice. The first time it's read, a build from before the choice existed keeps what it did: ElevenLabs
    /// when a voice ID was set, else the iPhone. An ID no provider has any more (one removed) reads as the iPhone.
    public static var provider: VoiceProvider {
        get {
            lock.withLock {
                let defaults = UserDefaults.standard
                if let stored = defaults.string(forKey: providerKey) { return VoiceProvider.with(id: stored) ?? .iPhone }
                let migrated: VoiceProvider = clean(defaults.string(forKey: voiceIDKey) ?? "").isEmpty ? .iPhone : .elevenLabs
                defaults.set(migrated.id, forKey: providerKey)
                return migrated
            }
        }
        set {
            guard newValue != provider else { return }
            lock.withLock { UserDefaults.standard.set(newValue.id, forKey: providerKey) }
            AssistantLog.add("Voice: \(newValue.logName) chosen")
        }
    }

    /// The ElevenLabs voice to speak with, as set in the app; empty when none is set (then Apple's voice speaks).
    /// Voice IDs are letters and digits only, so anything else pasted with one is dropped.
    public static var elevenLabsVoiceID: String {
        get { clean(UserDefaults.standard.string(forKey: voiceIDKey) ?? "") }
        set {
            let cleaned = clean(newValue)
            guard cleaned != elevenLabsVoiceID else { return }
            if cleaned.isEmpty {
                UserDefaults.standard.removeObject(forKey: voiceIDKey)
            } else {
                UserDefaults.standard.set(cleaned, forKey: voiceIDKey)
            }
            AssistantLog.add("Voice: ElevenLabs voice \(cleaned.isEmpty ? "cleared; Apple's voice speaks" : "set")")
        }
    }

    /// ElevenLabs is the chosen voice and a voice ID is set. Whether its key is there is checked as each reply starts.
    public static var elevenLabsChosen: Bool { provider == .elevenLabs && !elevenLabsVoiceID.isEmpty }

    private static func clean(_ value: String) -> String {
        String(value.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) })
    }
}

public enum VoiceError: Error, Equatable, Sendable {
    /// No ElevenLabs voice is chosen (no voice ID set).
    case notChosen
    case noKey
    case keyLocked
    /// The key was turned down (or lacks text-to-speech permission).
    case unauthorized
    /// The character quota or credits ran out.
    case quota
    /// The voice needs a paid plan (`paid_plan_required`): a free account can't use library voices via the API.
    case paidPlanRequired
    case rateLimited
    case http(Int)
    case network
    case synthesis
    case timedOut

    var logKind: String {
        switch self {
        case .notChosen: return "no ElevenLabs voice chosen"
        case .noKey: return "no key"
        case .keyLocked: return "key locked until first unlock"
        case .unauthorized: return "key not accepted"
        case .quota: return "quota used up"
        case .paidPlanRequired: return "voice needs a paid plan"
        case .rateLimited: return "rate limited"
        case .http(let status): return "HTTP \(status)"
        case .network: return "network error"
        case .synthesis: return "synthesis failed"
        case .timedOut: return "timed out"
        }
    }

    /// One plain sentence for the screens.
    var reason: String {
        switch self {
        case .notChosen: return "No ElevenLabs voice is set up."
        case .noKey: return "There's no ElevenLabs key yet."
        case .keyLocked: return "The iPhone hasn't been unlocked since it restarted."
        case .unauthorized: return "ElevenLabs didn't accept the key."
        case .quota: return "The ElevenLabs character quota is used up."
        case .paidPlanRequired: return "This ElevenLabs voice needs a paid plan. Choose one of ElevenLabs' default voices."
        case .rateLimited: return "ElevenLabs asked ReGlass to slow down."
        case .http, .synthesis: return "ElevenLabs had a problem."
        case .network, .timedOut: return "ElevenLabs couldn't be reached."
        }
    }

    /// Whether another ElevenLabs route could still work (only network trouble and server errors).
    var otherRouteMightWork: Bool {
        switch self {
        case .network, .timedOut, .rateLimited: return true
        case .http(let status): return status >= 500 || status == 400 || status == 404 || status == 422
        default: return false
        }
    }
}

/// The sentences of one reply, replayable from any index: a voice that fails part-way hands the rest (including
/// sentences still to come) to the next route without losing any.
final class SentenceFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    private var finished = false
    private var subscribers: [UUID: AsyncStream<(Int, String)>.Continuation] = [:]

    func append(_ sentence: String) {
        let (index, targets): (Int, [AsyncStream<(Int, String)>.Continuation]) = lock.withLock {
            items.append(sentence)
            return (items.count - 1, Array(subscribers.values))
        }
        for target in targets { target.yield((index, sentence)) }
    }

    func finish() {
        let targets: [AsyncStream<(Int, String)>.Continuation] = lock.withLock {
            finished = true
            defer { subscribers.removeAll() }
            return Array(subscribers.values)
        }
        for target in targets { target.finish() }
    }

    var count: Int { lock.withLock { items.count } }

    func text(at index: Int) -> String? {
        lock.withLock { index < items.count ? items[index] : nil }
    }

    /// The sentences from `index` on, with their indexes: those already here, then the rest as they arrive.
    func stream(from index: Int) -> AsyncStream<(Int, String)> {
        let (stream, continuation) = AsyncStream<(Int, String)>.makeStream()
        let id = UUID()
        lock.withLock {
            for i in index..<max(index, items.count) { continuation.yield((i, items[i])) }
            if finished {
                continuation.finish()
            } else {
                subscribers[id] = continuation
            }
        }
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            _ = self.lock.withLock { self.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    /// Just the text, for handing to another voice.
    func texts(from index: Int) -> AsyncStream<String> {
        let source = stream(from: index)
        return AsyncStream { continuation in
            let task = Task {
                for await (_, text) in source { continuation.yield(text) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
