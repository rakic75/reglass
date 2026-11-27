# Voice and speech

ReGlass listens to you, asks Claude, and speaks the answer. Three parts do that:

- **Speech recognition** writes down what you say.
- **Claude** writes the answer. It needs your Anthropic key.
- **The voice** speaks the answer.

Out of the box, recognition and the voice both run on the iPhone. You can switch either one to ElevenLabs, which is
optional. You choose in **Settings → Assistant → Voice and speech**. A change applies from your next request.

## The defaults

**Voice: iPhone (on-device).** Apple's voice, made on the iPhone. ReGlass picks the best English voice installed on
it: a premium voice, then an enhanced one, then the standard one. You can download better voices in the iPhone's
accessibility settings. Nothing goes over the network.

**Speech recognition: iPhone (on-device).** Apple's speech recognizer (`SpeechTranscriber`), on the iPhone. The first
time, iOS downloads its English model. Until that's done, ReGlass uses Apple's older recognizer, which also runs on
the iPhone. The audio doesn't leave it.

## How a reply is made

1. **You speak.** You say "Hey Meta" or touch and hold the touchpad. The glasses send their microphone to the iPhone
   as Opus over Bluetooth. `ReGlassKit` decodes it to 16 kHz mono PCM.
2. **Recognition.** `Transcriber` feeds the audio to the chosen recognizer as it arrives. ReGlass decides by itself
   when you've finished: about 1 s of silence, or 1.6 s when your words sound unfinished ("tell me about…"). It drops
   the wake phrase from the text.
3. **Claude.** `TurnRunner` sends the text to Claude (`ClaudeClient`) and streams the answer back. Claude may call
   tools on the way, such as a timer, a note or the weather.
4. **Sentences.** `SentenceChunker` cuts the streamed answer into sentences as soon as each one is complete. The first
   one goes out at once, so the voice can start while Claude is still writing. `SpokenText` takes out what shouldn't
   be read aloud: markdown, links, emoji.
5. **The voice.** `ChosenVoice` hands the sentences to the chosen voice. Every voice returns 24 kHz mono 16-bit PCM,
   sentence by sentence, as it's made.
6. **Out.** Usually to the glasses: `ReGlassKit` encodes the PCM to Opus in 20 ms packets and sends it in real time.
   The glasses start to play once about half a second is in. The reply plays on the iPhone instead (`PCMPlayer`) when
   the iPhone's audio goes to another Bluetooth device, such as a car, and for requests typed in Talk to ReGlass.

If the chosen voice fails part-way, Apple's voice speaks the rest. If Claude fails, a short apology plays in Apple's
voice.

The ElevenLabs voice tries three routes, in order: a WebSocket that streams the whole reply, then one request per
sentence, then Apple's voice. Each one picks up at the first sentence the last one didn't finish.

ElevenLabs Scribe streams your audio over a WebSocket while you speak. If it can't connect within 1.5 s, or fails
before the end, the iPhone's recognizer takes over with everything heard so far. If ElevenLabs turns the key away,
ReGlass stays on the iPhone's recognizer until the key changes or a check passes.

## Setting up ElevenLabs

You need an ElevenLabs account. The voice and recognition use the same key.

### 1. Make an API key

In ElevenLabs, open the developer settings and create an API key. You can limit what a key may do. Give ReGlass's
key only these permissions:

| Permission | Why |
| --- | --- |
| Text to Speech | The voice. |
| Speech to Text | ElevenLabs Scribe. |
| Voices: read | Reading your voice: the Test shows its name. |

Leave the rest off. If you use only the voice, or only recognition, you can leave the other one off too. ElevenLabs
also lets you set a credit limit for a key.

### 2. Add the key

Open **Settings → Assistant → Keys** and add it under ElevenLabs. You can also add it right in Voice and speech: when
you choose ElevenLabs without a key, the key's row appears there. The key stays in the iPhone's Keychain, on this
iPhone only. It's never synced, backed up or logged.

Test on the Keys screen makes one small call. With a voice ID set, it asks ElevenLabs to say "Hello.", six
characters, without playing it. Without one, it checks speech to text, which costs nothing.

### 3. Choose a voice

1. In ElevenLabs, open your voices and pick one. A voice from the Voice Library has to be added to your voices first.
   On a free plan, ElevenLabs lets apps use only its default voices, not Voice Library voices. With a library voice,
   Test says the voice needs a paid plan.
2. Copy its voice ID: a code of about 20 letters and digits, in the voice's details.
3. In Voice and speech, choose **ElevenLabs** under Voice and paste the ID.
4. Tap **Test**. ReGlass says a short line in that voice.

The voice uses ElevenLabs' Eleven v4 Turbo model (`ElevenLabsVoice.modelID`).

### 4. Choose ElevenLabs Scribe

Under Speech recognition, choose **ElevenLabs Scribe**. ReGlass checks the key straight away, without sending any
audio. The first time, ElevenLabs may ask you to accept its speech to text terms once, on its website. ReGlass
tells you when that's the case.

Scribe hears accents, names and local places better than the iPhone. To help it spell them, ReGlass sends the names
of towns near you with each request.

## Privacy

| What | Where it goes |
| --- | --- |
| Your voice, with the iPhone recognizer | Nowhere. It's written down on the iPhone. |
| Your voice, with ElevenLabs Scribe | ElevenLabs, from the wake word to the end of each request, with the names of towns near you. |
| The words of your request | Anthropic, for Claude. Never the audio. |
| The reply, with the iPhone voice | Nowhere. It's spoken on the iPhone. |
| The reply, with the ElevenLabs voice | ElevenLabs, sentence by sentence. |
| The live interpreter | It needs ElevenLabs Scribe. While it runs, it streams the microphone to ElevenLabs. |

Each company keeps what it gets as its own privacy policy says. ElevenLabs offers zero retention only on enterprise
plans, so ReGlass doesn't ask for it. ReGlass's own activity log has no words in it: only kinds, sizes and timings.
Keys are never logged.

## Costs

Apple's voice and recognizer are free. Anthropic charges for Claude by the amount of text. ElevenLabs charges for the
voice by the characters spoken and for Scribe by the length of the audio, out of your plan's credits. Check the
current prices on their websites. The Test on Voice and speech speaks one short line.

## Adding a provider

Each side has one list of providers, in `ReGlassAssistant`:

- voices: `VoiceProvider.all`, in `Voice/VoiceProvider.swift`;
- recognizers: `SpeechProvider.all`, in `Speech/SpeechProvider.swift`.

The settings screen shows whatever is in them. A new provider is one new type that keeps the contract, its provider
value beside it, and one line in the list. The contracts are written on the protocols: `Voice` in `Voice/Voice.swift`
and `RecognitionEngine` in `Speech/Transcriber.swift`. In short:

**A voice** takes the reply's sentences, in order, as they come, and returns 24 kHz mono signed 16-bit PCM as soon as
it's made. It starts on the first sentence. When its stream is cancelled, it stops all work at once. When it can't
speak, it hands the sentences it hasn't spoken to its fallback, Apple's voice, and reports why with
`onRoute(.apple(reason:))`. It throws only when it has no fallback. It never logs text.

**A recognizer** takes 16 kHz mono signed 16-bit PCM from the start of the request, in bursts, and must never drop
any. It reports text with `update(_:isFinal:)`. ReGlass decides when the request ends and then calls `finish()`,
which waits at most about 1.5 s for the last words. `cancel()` stops at once. A recognizer never throws: when it
fails, it hands the request to the iPhone's recognizer (`standIn`), or calls `engineStopped(_:)`.

### Example: an OpenAI voice

This sketch adds OpenAI text to speech. It isn't part of ReGlass. Check the details against
[OpenAI's text-to-speech guide](https://platform.openai.com/docs/guides/text-to-speech) and its
[API reference](https://platform.openai.com/docs/api-reference/audio/createSpeech): pick an OpenAI text-to-speech
model and one of its voices there.

**1. The key.** Add `case openAI` to `AssistantKey` in `Keys/KeyStore.swift`, with its `providerName` ("OpenAI").
The compiler then points at what else needs it: the key's words on the Keys screen (`KeysView.swift`), a section
there for it, and a cheap test call in `AssistantController.testKey`.

**2. The voice.** `Voice/OpenAIVoice.swift`, one request per sentence:

```swift
import Foundation

/// An OpenAI text-to-speech voice: one request per sentence, in order, as 24 kHz mono PCM.
final class OpenAIVoice: Voice, @unchecked Sendable {
    let name = "OpenAI"
    /// See OpenAI's text-to-speech guide for the models and their voices.
    private let model = "an OpenAI text-to-speech model"
    private let voice = "one of its voices"
    private let fallback: any Voice
    private let session = URLSession(configuration: .ephemeral)

    init(fallback: any Voice) {
        self.fallback = fallback
    }

    func speak(_ sentences: AsyncStream<String>,
               onRoute: @escaping @Sendable (VoiceRoute) -> Void) -> AsyncThrowingStream<[Int16], Error> {
        AsyncThrowingStream { continuation in
            // Replayable, so Apple's voice can pick up at the sentence that failed.
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
            // The wearer tapped, a new wake word came, the link dropped: stop everything at once.
            continuation.onTermination = { _ in
                pump.cancel()
                work.cancel()
            }
        }
    }

    private func run(_ feed: SentenceFeed, onRoute: @escaping @Sendable (VoiceRoute) -> Void,
                     emit: @escaping ([Int16]) -> Void) async throws {
        var resumeAt = 0
        var reason = "There's no OpenAI key yet."
        if let key = try? KeyStore.shared.read(.openAI) {
            onRoute(.provider("OpenAI voice"))
            do {
                for await (index, sentence) in feed.stream(from: 0) {
                    resumeAt = index
                    for try await chunk in synthesize(sentence, key: key) { emit(chunk) }
                }
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                reason = "OpenAI couldn't be reached."
                AssistantLog.add("OpenAI voice failed (\(type(of: error))) at sentence \(resumeAt + 1)")
            }
        }
        // Apple's voice says what's left, from the sentence that failed.
        try Task.checkCancellation()
        let why = reason
        for try await chunk in fallback.speak(feed.texts(from: resumeAt),
                                              onRoute: { _ in onRoute(.apple(reason: why)) }) {
            emit(chunk)
        }
    }

    /// One sentence. OpenAI documents `response_format: "pcm"` as raw 24 kHz 16-bit mono samples, little-endian:
    /// exactly what a voice returns. If that ever changes, resample with `StreamingConverter`.
    private func synthesize(_ text: String, key: String) -> AsyncThrowingStream<[Int16], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
                    request.httpMethod = "POST"
                    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONValue.object([
                        "model": .string(model), "voice": .string(voice),
                        "input": .string(text), "response_format": .string("pcm"),
                    ]).encoded()
                    let (bytes, response) = try await session.bytes(for: request)
                    switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
                    case 200: break
                    case 401, 403: throw VoiceError.unauthorized
                    case 429: throw VoiceError.rateLimited
                    case let status: throw VoiceError.http(status)
                    }
                    var decoder = PCMByteDecoder()
                    var pending = Data()
                    for try await byte in bytes {
                        pending.append(byte)
                        if pending.count >= 4_800 {   // 100 ms
                            continuation.yield(decoder.decode(pending))
                            pending.removeAll(keepingCapacity: true)
                        }
                    }
                    if !pending.isEmpty { continuation.yield(decoder.decode(pending)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

A sentence that fails part-way is said again from its start by Apple's voice. `ElevenLabsVoice` does better with
ElevenLabs' timing data, and fetches the next sentence while one plays; this sketch keeps it simple.

**3. The provider,** beside the type:

```swift
extension VoiceProvider {
    static let openAI = VoiceProvider(
        id: "openAI", title: "OpenAI", subtitle: "A voice from OpenAI",
        privacy: "Each reply's text goes to OpenAI to be spoken.",
        key: .openAI, logName: "OpenAI",
        make: { fallback in OpenAIVoice(fallback: fallback) })
}
```

`id` is saved as the owner's choice, so never change it once it has shipped. `needs:` can say what else is missing
(ElevenLabs says "Needs a voice ID."), and `test:` can give the Test better messages. Without `test:`, the Test speaks
a line through the voice itself.

**4. One line** in `VoiceProvider.all`:

```swift
static let all: [VoiceProvider] = [
    .iPhone,
    .elevenLabs,
    .openAI,
]
```

Voice and speech now lists OpenAI, with its privacy line, its Test, and its key's row while the key is missing. Add
it to the privacy table in this file too.

### Example: a speech recognizer

The same shape. OpenAI also has realtime transcription; check
[OpenAI's speech-to-text guide](https://platform.openai.com/docs/guides/speech-to-text) for the current API and
the audio format it takes. If it wants a rate other than 16 kHz, resample with `StreamingConverter`.

```swift
/// A cloud recognizer, in the shape of `ScribeEngine` (the full example).
final class OpenAIRecognizer: RecognitionEngine, @unchecked Sendable {
    let name = "OpenAI"
    private weak var owner: Transcriber?
    private let standIn: @Sendable () async -> RecognitionEngine?
    private let lock = NSLock()
    /// Everything heard so far, for a hand-over to the iPhone's recognizer.
    private var heard: [[Int16]] = []

    private init(_ request: RecognitionRequest) {
        owner = request.owner
        standIn = request.standIn
    }

    /// Nil when it can't take this request: the iPhone's recognizer listens instead.
    static func make(_ request: RecognitionRequest) -> OpenAIRecognizer? {
        guard let key = try? KeyStore.shared.read(.openAI) else { return nil }
        let engine = OpenAIRecognizer(request)
        engine.connect(key: key)   // in the background: return at once
        return engine
    }

    func append(_ samples: [Int16]) {
        // 16 kHz mono Int16, possibly before the connection is up: keep it, send it once it is.
        lock.withLock { heard.append(samples) }
    }

    func finish() async {
        // Tell the service the audio has ended, wait at most about 1.5 s for the last words, return.
    }

    func cancel() {
        // Close the connection. Report nothing more.
    }

    private func connect(key: String) {
        // Open the connection, then send what's in `heard` and everything after it.
        // As words come back:   owner?.update(text, isFinal: false)
        // A finished segment:   owner?.update(text, isFinal: true)
        // If it fails:          let engine = await standIn(), give it `heard`, then send new audio to it
        //                       (ScribeEngine.switchToStandIn does exactly this).
    }
}

extension SpeechProvider {
    static let openAI = SpeechProvider(
        id: "openAI", title: "OpenAI", subtitle: "In the cloud",
        privacy: "What you say goes to OpenAI to be written down.",
        key: .openAI, logName: "OpenAI",
        makeEngine: { request in OpenAIRecognizer.make(request) })
}
```

Then one line in `SpeechProvider.all`. Turn off any end-of-speech detection the service has: ReGlass decides when
you've finished, and calls `finish()`.
