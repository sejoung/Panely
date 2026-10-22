import Foundation
import llama

/// A line translated before the ones being asked for, handed to the model as
/// context so names, who's speaking and their speech level carry over.
nonisolated struct TranslationContextLine: Sendable, Equatable {
    let source: String
    let translation: String
}

/// One of the asked-for lines, back from the model. `index` is its position
/// in the request.
nonisolated struct TranslatedLine: Sendable, Equatable {
    let index: Int
    let text: String
}

/// Translates a run of balloons at once. `GemmaTranslator` in the app; tests
/// use stand-ins that need no model.
nonisolated protocol BalloonTranslating: Sendable {
    /// Whether it can translate now — the model is downloaded.
    func isReady() -> Bool
    /// Load the model ahead of the first request (a job calls this while OCR
    /// reads its first page).
    func prepare() async throws
    /// The lines' translations, each as soon as the model has written it.
    /// A line the model never answers is left out; the stream ends after the
    /// last line it could get, or throws.
    func translate(
        _ lines: [String],
        context: [TranslationContextLine],
        from source: TranslationLanguage,
        to target: TranslationLanguage
    ) -> AsyncThrowingStream<TranslatedLine, any Error>
}

/// Gemma 4 E2B (`TranslationModel`) run in the app with llama.cpp, on the GPU
/// (Metal).
///
/// Balloons go in numbered, with the job's last few translations as context,
/// and come back as `[n] translation` lines, read off the output as the model
/// writes them so each balloon shows the moment it's done. The prompt asks
/// for the original's speech level to be kept — the model does in one pass
/// what Apple Translation needed a second model for. A line the model skips
/// is asked for again on its own.
///
/// One model in memory for the whole app (about 3.5 GB, most of it the
/// memory-mapped file), loaded on first use and let go after two idle
/// minutes. Requests run one at a time on the actor's own thread: generating
/// is seconds of blocking work that mustn't sit on Swift's shared pool.
actor GemmaTranslator: BalloonTranslating {
    /// The app's one model — each controller and retranslation shares it.
    static let shared = GemmaTranslator()

    nonisolated static let contextSize: UInt32 = 8192
    nonisolated static let idleTimeout: Duration = .seconds(120)

    nonisolated let files: TranslationModelFiles
    private let queue = DispatchSerialQueue(label: "io.github.sejoung.Panely.gemma", qos: .utility)
    private var runtime: LlamaRuntime?
    private var unloadTask: Task<Void, Never>?

    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    init(files: TranslationModelFiles = TranslationModelFiles()) {
        self.files = files
    }

    nonisolated func isReady() -> Bool { files.isInstalled }

    func prepare() async throws {
        unloadTask?.cancel()
        defer { scheduleUnload() }
        guard runtime == nil else { return }
        let runtime = try loadRuntime()
        // A few tokens of a real prompt: the GPU's first generation sets up
        // its pipelines, which would otherwise hold up the first balloons.
        _ = try runtime.generate(
            prompt: GemmaPrompt.build(lines: ["こんにちは"], context: [], from: .japanese, to: .korean),
            maxTokens: 4
        ) { _ in true }
    }

    nonisolated func translate(
        _ lines: [String],
        context: [TranslationContextLine],
        from source: TranslationLanguage,
        to target: TranslationLanguage
    ) -> AsyncThrowingStream<TranslatedLine, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.run(lines, context: context, from: source, to: target, into: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Drop the model from memory now (it was deleted, say).
    func unload() {
        unloadTask?.cancel()
        unloadTask = nil
        runtime = nil
    }

    private func run(
        _ lines: [String],
        context: [TranslationContextLine],
        from source: TranslationLanguage,
        to target: TranslationLanguage,
        into continuation: AsyncThrowingStream<TranslatedLine, any Error>.Continuation
    ) {
        unloadTask?.cancel()
        defer { scheduleUnload() }
        do {
            let runtime = try runtime ?? loadRuntime()
            var answered = Set<Int>()
            // Synchronous all the way: no other request can slip in between
            // and clear the model's memory mid-answer.
            func ask(_ asked: [Int]) throws {
                let prompt = GemmaPrompt.build(lines: asked.map { lines[$0] }, context: context, from: source, to: target)
                var reader = GemmaPrompt.LineReader()
                let emit: (String) -> Void = { text in
                    for (number, translation) in reader.read(text) {
                        guard asked.indices.contains(number - 1) else { continue }
                        let index = asked[number - 1]
                        guard answered.insert(index).inserted else { continue }
                        continuation.yield(TranslatedLine(index: index, text: GemmaPrompt.clean(translation, target: target)))
                    }
                }
                let output = try runtime.generate(prompt: prompt, maxTokens: GemmaPrompt.maxTokens(asked.map { lines[$0] })) { text in
                    emit(text)
                    return !Task.isCancelled
                }
                emit(output + "\n")
                try Task.checkCancellation()
            }
            try ask(Array(lines.indices))
            for index in lines.indices where !answered.contains(index) {
                try ask([index])
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    private func loadRuntime() throws -> LlamaRuntime {
        guard files.isInstalled else { throw TranslationModelError.notInstalled }
        let start = ContinuousClock.now
        let loaded: LlamaRuntime
        do {
            loaded = try LlamaRuntime(path: files.fileURL.path, contextSize: Self.contextSize, gpuLayers: 99)
        } catch {
            // Not enough GPU memory, say: the CPU is slower but works.
            AppLog.error(.reader, "Translation model failed to load on the GPU", metadata: ["error": "\(error)"])
            loaded = try LlamaRuntime(path: files.fileURL.path, contextSize: Self.contextSize, gpuLayers: 0)
        }
        runtime = loaded
        let elapsed = start.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        AppLog.info(.reader, "Translation model loaded", metadata: [
            "model": "\(files.model.id)", "seconds": "\(String(format: "%.1f", seconds))",
        ])
        return loaded
    }

    private func scheduleUnload() {
        unloadTask?.cancel()
        unloadTask = Task {
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled else { return }
            self.unload()
            AppLog.info(.reader, "Translation model unloaded after being idle")
        }
    }
}

/// The prompt Gemma 4 gets and how its answer is read — the same as the
/// Windows version's, so both translate alike.
nonisolated enum GemmaPrompt {
    /// Gemma 4's chat format, written out: llama.cpp's template engine
    /// doesn't know Gemma 4's template (measured: it refuses it). Thinking
    /// stays off — the turn opens straight into the model's answer.
    static func build(
        lines: [String],
        context: [TranslationContextLine],
        from source: TranslationLanguage,
        to target: TranslationLanguage
    ) -> String {
        let from = englishName(source)
        let to = englishName(target)
        var prompt = "<|turn>user\n"
        prompt += "You translate \(from) comic dialogue into natural \(to).\n"
        prompt += "Rules:\n"
        prompt += "- Translate every numbered line. Output exactly one line per input line, as \"[n] translation\", nothing else.\n"
        prompt += "- Keep each speaker's speech level: polite speech stays polite, plain or casual speech stays casual."
        switch target {
        case .korean: prompt += " In Korean, polite speech is 존댓말 (-요/-습니다) and casual speech is 반말."
        case .japanese: prompt += " In Japanese, polite speech uses です/ます."
        case .chineseSimplified, .chineseTraditional, .english: break
        }
        prompt += "\n"
        prompt += "- Keep names, honorifics and terms consistent with the earlier lines.\n"
        prompt += "- \" / \" inside a line marks a line break in the balloon; keep it.\n"
        prompt += "- Do not add explanations.\n"
        if !context.isEmpty {
            prompt += "\nEarlier lines (\(from) → \(to)), for context only:\n"
            for line in context {
                prompt += "\(oneLine(line.source)) → \(oneLine(line.translation))\n"
            }
        }
        prompt += "\nTranslate:\n"
        for (index, line) in lines.enumerated() {
            prompt += "[\(index + 1)] \(oneLine(line))\n"
        }
        prompt += "<turn|>\n<|turn>model\n"
        return prompt
    }

    /// Room to answer: a margin, plus a few tokens a character — Japanese
    /// and Korean can take more tokens translated than they had characters.
    static func maxTokens(_ lines: [String]) -> Int {
        64 + lines.reduce(0) { $0 + 16 + 3 * $1.utf16.count }
    }

    /// `[n] translation` lines in `output`; other lines are ignored.
    static func parse(_ output: String) -> [(number: Int, text: String)] {
        var found: [(Int, String)] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if let parsed = parseLine(line) { found.append(parsed) }
        }
        return found
    }

    private static func parseLine(_ line: Substring) -> (Int, String)? {
        let trimmed = line.drop { $0 == " " || $0 == "\t" }
        guard trimmed.first == "[", let close = trimmed.firstIndex(of: "]") else { return nil }
        let digits = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
        guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let number = Int(digits) else { return nil }
        let text = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))
        return text.isEmpty ? nil : (number, text)
    }

    /// Reads lines off the output while it's being written: each call gets
    /// the whole output so far and returns the `[n]` lines completed since
    /// the last call.
    struct LineReader {
        private var consumed = 0

        mutating func read(_ output: String) -> [(number: Int, text: String)] {
            let utf8 = output.utf8
            guard let lastNewline = utf8.lastIndex(of: UInt8(ascii: "\n")) else { return [] }
            let end = utf8.distance(from: utf8.startIndex, to: lastNewline) + 1
            guard end > consumed else { return [] }
            let start = utf8.index(utf8.startIndex, offsetBy: consumed)
            let chunk = String(output[start..<utf8.index(utf8.startIndex, offsetBy: end)])
            consumed = end
            return GemmaPrompt.parse(chunk)
        }
    }

    /// Back into the balloon's shape: " / " was a line break. Outside
    /// Japanese, a run of the long-vowel mark (ーー, a manga dash) is a dash.
    static func clean(_ text: String, target: TranslationLanguage) -> String {
        var result = text.replacingOccurrences(of: " / ", with: "\n").trimmingCharacters(in: .whitespaces)
        if target != .japanese {
            result = result.replacing(#/ー{2,}/#) { String(repeating: "—", count: $0.output.count) }
        }
        return result
    }

    /// A balloon's text on one prompt line: its line breaks become " / ".
    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " / ")
    }

    static func englishName(_ language: TranslationLanguage) -> String {
        switch language {
        case .japanese: "Japanese"
        case .chineseSimplified: "Simplified Chinese"
        case .chineseTraditional: "Traditional Chinese"
        case .korean: "Korean"
        case .english: "English"
        }
    }
}

/// A llama.cpp model and one context, reused for every request: the
/// context's memory is cleared before each prompt rather than a new context
/// made (which costs time and memory). Greedy decoding — the same input
/// always gives the same translation.
///
/// Not thread-safe; `GemmaTranslator` owns it.
nonisolated final class LlamaRuntime {
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer

    private static let backend: Void = {
        llama_log_set({ level, text, _ in
            // Only errors: llama.cpp otherwise prints hundreds of lines per load.
            guard level == GGML_LOG_LEVEL_ERROR, let text else { return }
            AppLog.error(.reader, "llama.cpp", metadata: ["message": "\(String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines))"])
        }, nil)
        llama_backend_init()
    }()

    init(path: String, contextSize: UInt32, gpuLayers: Int32) throws {
        _ = Self.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = gpuLayers
        guard let model = llama_model_load_from_file(path, modelParams) else {
            throw TranslationModelError.loadFailed
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = contextSize
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw TranslationModelError.loadFailed
        }
        self.model = model
        self.context = context
        vocab = llama_model_get_vocab(model)
    }

    deinit {
        llama_free(context)
        llama_model_free(model)
    }

    /// Generate up to `maxTokens` after `prompt`, handing `onText` the whole
    /// output so far after every token; it returns false to stop early.
    /// Returns the output.
    func generate(prompt: String, maxTokens: Int, onText: (String) -> Bool) throws -> String {
        llama_memory_clear(llama_get_memory(context), true)
        var tokens = tokenize(prompt)
        let contextSize = Int(llama_n_ctx(context))
        guard tokens.count + maxTokens <= contextSize else {
            throw TranslationModelError.promptTooLong(tokens: tokens.count)
        }

        let batchSize = max(1, Int(llama_n_batch(context)))
        var start = 0
        while start < tokens.count {
            let count = min(batchSize, tokens.count - start)
            let result = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress! + start, Int32(count)))
            }
            guard result == 0 else { throw TranslationModelError.decodeFailed(result) }
            start += count
        }

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_greedy())

        var bytes: [UInt8] = []
        var piece = [CChar](repeating: 0, count: 256)
        for _ in 0..<maxTokens {
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if length > 0 {
                bytes.append(contentsOf: piece[0..<Int(length)].map { UInt8(bitPattern: $0) })
            }
            // Pieces can split a character; the partial one shows as U+FFFD
            // until the rest arrives, and line reading only looks up to the
            // last newline, which never falls inside a character.
            guard onText(String(decoding: bytes, as: UTF8.self)) else { break }
            let result = llama_decode(context, llama_batch_get_one(&token, 1))
            guard result == 0 else { throw TranslationModelError.decodeFailed(result) }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let utf8Count = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(utf8Count) + 2)
        // add_special: BOS; parse_special: the turn markers are tokens.
        var count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), true, true)
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = llama_tokenize(vocab, text, utf8Count, &tokens, Int32(tokens.count), true, true)
        }
        return Array(tokens.prefix(Int(max(0, count))))
    }
}
