import Foundation

struct Language: Hashable, Identifiable {
    let code: String
    let name: String
    var id: String { code }

    /// Codes as Google Translate uses them.
    static let all: [Language] = [
        ("en", "English"), ("vi", "Vietnamese"), ("zh-CN", "Chinese (Simplified)"), ("zh-TW", "Chinese (Traditional)"),
        ("ja", "Japanese"), ("ko", "Korean"), ("th", "Thai"), ("id", "Indonesian"), ("ms", "Malay"), ("tl", "Filipino"),
        ("hi", "Hindi"), ("fr", "French"), ("de", "German"), ("es", "Spanish"), ("pt", "Portuguese"), ("it", "Italian"),
        ("nl", "Dutch"), ("sv", "Swedish"), ("da", "Danish"), ("no", "Norwegian"), ("fi", "Finnish"), ("pl", "Polish"),
        ("cs", "Czech"), ("uk", "Ukrainian"), ("ru", "Russian"), ("el", "Greek"), ("tr", "Turkish"), ("ar", "Arabic"),
        ("he", "Hebrew"), ("fa", "Persian"),
    ].map { Language(code: $0.0, name: $0.1) }

    static func name(_ code: String) -> String {
        all.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }?.name
            ?? Locale(identifier: "en_US").localizedString(forIdentifier: code) ?? code
    }

    /// "pt-PT" and "pt" are the same language; the two Chinese scripts are not.
    static func same(_ a: String, _ b: String) -> Bool {
        a.caseInsensitiveCompare(b) == .orderedSame || base(a) == base(b) && base(a) != "zh"
    }

    private static func base(_ code: String) -> String {
        code.split(separator: "-").first.map { $0.lowercased() } ?? code.lowercased()
    }

    /// The system's preferred languages that Google Translate knows, e.g. ["en", "vi"] for en-VN, vi-VN.
    static var preferred: [String] {
        Locale.preferredLanguages.compactMap { identifier in
            let language = Locale.Language(identifier: identifier)
            guard var code = language.languageCode?.identifier else { return nil }
            if code == "zh" { code = language.script?.identifier == "Hant" ? "zh-TW" : "zh-CN" }
            return all.contains(where: { $0.code == code }) ? code : nil
        }
    }
}

/// Google Translate's keyless endpoint, the one browser extensions use. The text is sent to Google.
enum Translator {
    struct Result {
        let text: String
        let source: String
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func translate(_ text: String, to target: String, from source: String = "auto") async throws -> Result {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "gtx"), URLQueryItem(name: "sl", value: source),
            URLQueryItem(name: "tl", value: target), URLQueryItem(name: "dt", value: "t"),
        ]
        // POST, so long text doesn't hit URL length limits.
        var request = URLRequest(url: components.url!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        request.httpBody = ("q=" + (text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw Failure(errorDescription: http.statusCode == 429 ? "Google Translate is rate limiting requests, try again shortly"
                                                                   : "Google Translate returned HTTP \(http.statusCode)")
        }
        // [[["translated","original",…], …], null, "detected-source", …]
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let sentences = root.first as? [Any] else {
            throw Failure(errorDescription: "Couldn't read Google Translate's response")
        }
        let translated = sentences.compactMap { ($0 as? [Any])?.first as? String }.joined()
        let detected = root.count > 2 ? root[2] as? String : nil
        return Result(text: translated, source: detected ?? source)
    }
}

/// Live translation of whatever is typed, debounced. Without a chosen target it translates to
/// `preferred`, or to `alternate` when the text is already in `preferred`.
@MainActor
final class Translation: ObservableObject {
    enum Status: Equatable {
        case idle, translating, done
        case failed(String)
    }

    @Published private(set) var input = ""
    @Published private(set) var output = ""
    @Published private(set) var source: String?
    @Published private(set) var status = Status.idle
    /// A language picked with ⌘K; nil means automatic.
    @Published private(set) var chosenTarget: String?

    /// Called when a translation finishes or fails.
    var onChange: (() -> Void)?

    private let preferred: String
    private let alternate: String?
    private var requested: (input: String, target: String?)?
    private var task: Task<Void, Never>?

    init(config: TranslationConfig, target: String? = nil) {
        preferred = config.target
        alternate = config.fallback
        chosenTarget = target
    }

    /// The language the output is in (or will be in, before the first result).
    var target: String {
        if let chosenTarget { return chosenTarget }
        if let source, Language.same(source, preferred), let alternate { return alternate }
        return preferred
    }

    var isTranslating: Bool { status == .translating }

    /// "English → Vietnamese"; the source is detected by Google.
    var direction: String {
        let from = source.map(Language.name) ?? "Detect language"
        return "\(from) → \(Language.name(target))"
    }

    func update(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let requested, requested.input == text, requested.target == chosenTarget { return }
        requested = (text, chosenTarget)
        input = text
        task?.cancel()
        guard !text.isEmpty else {
            (output, source, status) = ("", nil, .idle)
            return
        }
        status = .translating
        let chosen = chosenTarget, guess = source
        task = Task { [weak self, preferred, alternate] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            do {
                // Start from the last detected language, so typing Vietnamese doesn't cost two requests per keystroke.
                let first = chosen ?? (guess.map { Language.same($0, preferred) } == true ? alternate ?? preferred : preferred)
                var result = try await Translator.translate(text, to: first)
                if chosen == nil {
                    let wanted = Language.same(result.source, preferred) ? alternate ?? preferred : preferred
                    if !Language.same(wanted, first) { result = try await Translator.translate(text, to: wanted) }
                }
                guard !Task.isCancelled, let self else { return }
                (output, source, status) = (result.text, result.source, .done)
            } catch {
                guard !Task.isCancelled, let self else { return }
                status = .failed(error.localizedDescription)
            }
            self?.onChange?()
        }
    }

    /// Picks the output language (nil for automatic); the next `update` translates again, even the same text.
    func choose(_ target: String?) {
        chosenTarget = target
        requested = nil
    }
}
