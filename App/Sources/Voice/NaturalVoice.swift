import AVFoundation
import CoreML
import NaturalLanguage

/// The natural voices: Kyutai's Pocket TTS running on device with Core ML,
/// borrowed from MB Books. `ios-build.sh` embeds the model and voices in the
/// app under `Pocket/`; without them Tea Three falls back to iPhone voices.
nonisolated enum NaturalVoice {
    struct Voice: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let kind: String
    }

    /// Best first, by MB Books' naturalness ranking. All licensed for commercial use.
    static let voices: [Voice] = [
        Voice(id: "george", name: "George", kind: "Studio recording"),
        Voice(id: "mary", name: "Mary", kind: "Studio recording"),
        Voice(id: "jane", name: "Jane", kind: "Studio recording"),
        Voice(id: "eve", name: "Eve", kind: "Studio recording"),
        Voice(id: "anna", name: "Anna", kind: "Studio recording"),
        Voice(id: "eponine", name: "Eponine", kind: "Studio recording"),
        Voice(id: "vera", name: "Vera", kind: "Studio recording"),
        Voice(id: "michael", name: "Michael", kind: "Studio recording"),
        Voice(id: "fantine", name: "Fantine", kind: "Studio recording"),
        Voice(id: "azelma", name: "Azelma", kind: "Studio recording"),
        Voice(id: "bill_boerst", name: "Bill", kind: "Audiobook narrator"),
        Voice(id: "caro_davy", name: "Caro", kind: "Audiobook narrator"),
        Voice(id: "peter_yearsley", name: "Peter", kind: "Audiobook narrator"),
        Voice(id: "alba", name: "Alba", kind: "Voice actor"),
        Voice(id: "charles", name: "Charles", kind: "Studio recording"),
        Voice(id: "paul", name: "Paul", kind: "Studio recording"),
        Voice(id: "stuart_bell", name: "Stuart", kind: "Audiobook narrator"),
    ]

    static let identifierPrefix = "pocket:"
    static var directory: URL? { Bundle.main.url(forResource: "Pocket", withExtension: nil) }
    static var isAvailable: Bool { directory != nil }

    static func voice(forIdentifier identifier: String) -> Voice? {
        guard identifier.hasPrefix(identifierPrefix) else { return nil }
        return voices.first { identifierPrefix + $0.id == identifier }
    }
}

/// Owns the synthesizer on one background queue: Core ML models aren't
/// thread-safe, and loading takes a second or two, so it's loaded once.
nonisolated final class NaturalVoiceEngine: @unchecked Sendable {
    static let shared = NaturalVoiceEngine()

    private let queue = DispatchQueue(label: "com.shlokbhakta.teathree.pocket", qos: .userInitiated)
    private var synthesizer: PocketSynthesizer?

    /// Loads the models ahead of the first reply.
    func prewarm() {
        guard NaturalVoice.isAvailable else { return }
        queue.async { _ = try? self.loaded() }
    }

    func synthesize(_ text: String, voice: String) async throws -> [Float] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let synthesizer = try self.loaded()
                    if !synthesizer.hasVoice(voice), let directory = NaturalVoice.directory {
                        try synthesizer.loadVoice(id: voice, from: directory.appending(path: "voices/\(voice).bin"))
                    }
                    continuation.resume(returning: try synthesizer.synthesize(text, voice: voice).samples)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func loaded() throws -> PocketSynthesizer {
        if let synthesizer { return synthesizer }
        guard let directory = NaturalVoice.directory else { throw CocoaError(.fileNoSuchFile) }
        #if targetEnvironment(simulator)
        // The simulator has no Metal Performance Shaders graph backend.
        let units = MLComputeUnits.cpuOnly
        #else
        let units = MLComputeUnits.cpuAndGPU
        #endif
        let loaded = try PocketSynthesizer(directory: directory, tokenizer: PocketTokenizer.bundled(), transformerUnits: units)
        synthesizer = loaded
        return loaded
    }
}

/// Plays synthesized speech sentence by sentence: the first sentence starts
/// as soon as it's ready while the rest render behind it.
final class NaturalVoicePlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let format = AVAudioFormat(standardFormatWithSampleRate: PocketSynthesizer.sampleRate, channels: 1)!
    private var generation = 0

    init() {
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)
    }

    /// Speaks `text` in `voice` and returns when it has finished (or was stopped).
    func speak(_ text: String, voice: String, rate: Double) async throws {
        generation += 1
        let mine = generation
        let sentences = Self.sentences(in: text)
        guard !sentences.isEmpty else { return }
        timePitch.rate = Float(rate)
        if !engine.isRunning { try engine.start() }
        player.play()

        var next: Task<[Float], Error>? = Task { try await NaturalVoiceEngine.shared.synthesize(sentences[0], voice: voice) }
        var lastPlayed: Task<Void, Never>?
        for index in sentences.indices {
            guard let rendering = next else { break }
            let samples = try await rendering.value
            guard mine == generation else { return }
            if index + 1 < sentences.count {
                let sentence = sentences[index + 1]
                next = Task { try await NaturalVoiceEngine.shared.synthesize(sentence, voice: voice) }
            } else {
                next = nil
            }
            lastPlayed = schedule(samples)
        }
        await lastPlayed?.value
    }

    func stop() {
        generation += 1
        player.stop()
        engine.stop()
    }

    private func schedule(_ samples: [Float]) -> Task<Void, Never> {
        let pause = Int(PocketSynthesizer.sampleRate * 0.12)
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count + pause))
        else { return Task {} }
        buffer.frameLength = buffer.frameCapacity
        let channel = buffer.floatChannelData![0]
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        (channel + samples.count).update(repeating: 0, count: pause)
        // Scheduled now, in order; the callback comes on an audio thread.
        let (played, finished) = AsyncStream<Void>.makeStream()
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable _ in
            finished.finish()
        }
        return Task { for await _ in played {} }
    }

    static func sentences(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        return tokenizer.tokens(for: text.startIndex..<text.endIndex)
            .map { text[$0].trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
