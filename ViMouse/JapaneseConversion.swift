import Foundation
import CommonCrypto
import Darwin
#if canImport(Carbon)
import Carbon
#endif

struct JapaneseConversionCandidate: Equatable {
    let text: String
    let score: Double
    let isNative: Bool
    let reading: String?
    let isLearned: Bool

    init(text: String, score: Double, isNative: Bool = false, reading: String? = nil, isLearned: Bool = false) {
        self.text = text
        self.score = score
        self.isNative = isNative
        self.reading = reading
        self.isLearned = isLearned
    }
}

/// Local word learning plus legacy context-specific ranking, bounded to 90 days/512 entries.
final class SelfConversionPersonalizer {
    static let shared = SelfConversionPersonalizer(
        defaults: UserDefaults(suiteName: "com.s21g.ViMouse.conversionLearning")!,
        enabled: { SelfConversionSettings.learningEnabled })
    private struct Entry: Codable {
        let key: String
        let text: String
        var count: Int
        var updated: TimeInterval
    }
    private let queue = DispatchQueue(label: "ViMouse.conversionLearning")
    private let defaults: UserDefaults
    private let enabled: () -> Bool
    private let now: () -> Date
    private var entries: [Entry] = []
    private var undoEntries: [Entry]?
    private var words: [Entry] = []
    private var undoWords: [Entry]?
    private let wordsStorageKey = "words.v1"
    private let storageKey = "preferences.v1"
    private let lifetime: TimeInterval = 90 * 86400

    init(defaults: UserDefaults, enabled: @escaping () -> Bool, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.enabled = enabled
        self.now = now
        if let data = defaults.data(forKey: storageKey), data.count <= 2_000_000,
           let decoded = try? JSONDecoder().decode([Entry].self, from: data), decoded.count <= 512 {
            entries = decoded.filter {
                $0.key.count == 64 && $0.key.allSatisfy { "0123456789abcdef".contains($0) }
                    && !$0.text.isEmpty && $0.text.count <= 1024 && (1...100).contains($0.count)
                    && $0.updated.isFinite && $0.updated <= now().timeIntervalSince1970
                    && $0.updated >= now().timeIntervalSince1970 - lifetime
            }
        }
        if let data = defaults.data(forKey: wordsStorageKey), data.count <= 2_000_000,
           let decoded = try? JSONDecoder().decode([Entry].self, from: data), decoded.count <= 512 {
            words = decoded.filter {
                $0.key.count == 64 && $0.key.allSatisfy { "0123456789abcdef".contains($0) }
                    && !$0.text.isEmpty && $0.text.count <= 1024 && (1...100).contains($0.count)
                    && !$0.text.unicodeScalars.contains(where: { $0.value < 32 })
                    && $0.updated.isFinite && $0.updated <= now().timeIntervalSince1970
                    && $0.updated >= now().timeIntervalSince1970 - lifetime
            }
        }
        trimHistory(at: now().timeIntervalSince1970)
        persist()
    }

    private func wordKey(_ input: String) -> String {
        key(input: RomajiKanaConverter.hiragana(input), context: "")
    }

    private func trimHistory(at timestamp: TimeInterval) {
        entries.removeAll { $0.updated < timestamp - lifetime }
        words.removeAll { $0.updated < timestamp - lifetime }
        entries.sort { $0.updated > $1.updated }
        words.sort { $0.updated > $1.updated }
        while entries.count + words.count > 512 {
            if (entries.last?.updated ?? .infinity) < (words.last?.updated ?? .infinity) {
                entries.removeLast()
            } else { words.removeLast() }
        }
    }

    private func key(input: String, context: String) -> String {
        // Length-prefixed input, exact case and a short context digest prevent
        // ambiguous-key collisions and cross-context preference pollution.
        let value = "\(input.utf8.count):\(input)\(context.suffix(64))"
        let data = Data(value.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func rerank(_ candidates: [JapaneseConversionCandidate], input: String, context: String) -> [JapaneseConversionCandidate] {
        queue.sync {
            guard enabled() else { return candidates }
            let cutoff = now().timeIntervalSince1970 - lifetime
            let learned = words.filter { $0.key == wordKey(input) && $0.updated >= cutoff }
                .sorted { $0.updated == $1.updated ? $0.count > $1.count : $0.updated > $1.updated }
                .prefix(5)
            let additions = learned.map { entry in
                candidates.first(where: { $0.text == entry.text })
                    ?? JapaneseConversionCandidate(text: entry.text, score: 1.0, reading: RomajiKanaConverter.hiragana(input), isLearned: true)
            }
            let learnedTexts = Set(additions.map(\.text))
            let remaining = candidates.filter { !learnedTexts.contains($0.text) }
            let head = Array(remaining.prefix(5).prefix { $0.isNative })
            guard !head.isEmpty else { return additions + remaining }
            let digest = key(input: input, context: context)
            let preferences = entries.filter { $0.key == digest && $0.count >= 2 && $0.updated >= cutoff }
            let ranked = head.enumerated().sorted { lhs, rhs in
                let left = preferences.first { $0.text == lhs.element.text }
                let right = preferences.first { $0.text == rhs.element.text }
                if (left?.updated ?? 0) != (right?.updated ?? 0) {
                    return (left?.updated ?? 0) > (right?.updated ?? 0)
                }
                if (left?.count ?? 0) != (right?.count ?? 0) {
                    return (left?.count ?? 0) > (right?.count ?? 0)
                }
                return lhs.offset < rhs.offset
            }.map { $0.element }
            return additions + ranked + Array(remaining.dropFirst(head.count))
        }
    }

    func record(_ decision: SelfConversionDecisionEvent) {
        queue.sync {
            let snapshot = decision.snapshot
            guard enabled(), ["final_commit", "partial_commit"].contains(decision.action) else { return }
            var pairs: [(String, String)] = []
            if let selected = snapshot.selectedCandidate, snapshot.candidates.contains(selected),
               decision.committedOutput == (decision.action == "final_commit" ? snapshot.composedText : selected.text) {
                pairs.append((snapshot.input, selected.text))
            }
            if decision.action == "final_commit", decision.committedOutput == snapshot.composedText,
               let input = snapshot.learningInput, let text = snapshot.learningText {
                pairs.append((input, text))
            }
            pairs = pairs.filter { input, text in
                !input.isEmpty && input.unicodeScalars.count <= 256 && input.contains(where: { $0.isLetter })
                    && !text.isEmpty && text.count <= 1024 && text != input
                    && !text.unicodeScalars.contains(where: { $0.value < 32 })
            }
            guard !pairs.isEmpty else { return }
            undoEntries = entries
            undoWords = words
            let timestamp = now().timeIntervalSince1970
            var seen = Set<String>()
            for (input, text) in pairs {
                let digest = wordKey(input)
                guard seen.insert(digest + ":" + text).inserted else { continue }
                if let index = words.firstIndex(where: { $0.key == digest && $0.text == text }) {
                    words[index].count = min(100, words[index].count + 1)
                    words[index].updated = timestamp
                } else {
                    words.append(Entry(key: digest, text: text, count: 1, updated: timestamp))
                }
            }
            trimHistory(at: timestamp)
            persist()
        }
    }

    func clear() {
        queue.sync {
            entries = []
            words = []
            undoEntries = nil
            undoWords = nil
            defaults.removeObject(forKey: storageKey)
            defaults.removeObject(forKey: wordsStorageKey)
        }
    }

    func undoLastLearning() {
        queue.sync {
            guard let previous = undoEntries else { return }
            entries = previous.filter { $0.updated >= now().timeIntervalSince1970 - lifetime }
            words = (undoWords ?? []).filter { $0.updated >= now().timeIntervalSince1970 - lifetime }
            undoEntries = nil
            undoWords = nil
            persist()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: storageKey) }
        if let data = try? JSONEncoder().encode(words) { defaults.set(data, forKey: wordsStorageKey) }
    }
}

protocol JapaneseConversionServing: AnyObject {
    var conversionDebounceDelay: TimeInterval { get }
    func convert(
        _ input: String,
        context: String,
        callbackQueue: DispatchQueue,
        completion: @escaping ([JapaneseConversionCandidate]) -> Void
    )
    func convertSuffix(_ input: String, context: String, completion: @escaping ([JapaneseConversionCandidate]) -> Void)
}

extension JapaneseConversionServing {
    var conversionDebounceDelay: TimeInterval { 2.0 }
    func convertSuffix(_ input: String, context: String, completion: @escaping ([JapaneseConversionCandidate]) -> Void) {
        convert(input, context: context, completion: completion)
    }

    func convert(
        _ input: String,
        context: String,
        completion: @escaping ([JapaneseConversionCandidate]) -> Void
    ) {
        convert(input, context: context, callbackQueue: .main, completion: completion)
    }
}

/// Symbol-only conversion stays local, even when the remote engine returns only ASCII.
/// Text, decimal numbers, URLs and source code containing letters keep their usual conversion path.
enum JapanesePunctuationConverter {
    private static let variants: [Character: [String]] = [
        ",": ["、", "，", ","], "、": ["、", "，", ","], "，": ["、", "，", ","],
        ".": ["。", "．", ".", "・"], "。": ["。", "．", "."], "．": ["。", "．", "."],
        "!": ["！", "!"], "！": ["！", "!"], "?": ["？", "?"], "？": ["？", "?"],
        ":": ["：", ":"], ";": ["；", ";"],
        "(": ["（", "("], ")": ["）", ")"],
        "[": ["「", "『", "【", "［", "["], "]": ["」", "』", "】", "］", "]"],
        "{": ["｛", "{"], "}": ["｝", "}"],
        "<": ["〈", "《", "＜", "<"], ">": ["〉", "》", "＞", ">"],
        "\"": ["“", "”", "〝", "〟", "＂", "\""], "'": ["‘", "’", "＇", "'"],
        "-": ["ー", "−", "－", "―", "-"], "~": ["〜", "～", "~"],
        "/": ["／", "・", "/"], "\\": ["＼", "￥", "\\"],
        "|": ["｜", "|"], "_": ["＿", "_"], "*": ["＊", "※", "*"],
        "&": ["＆", "&"], "@": ["＠", "@"], "#": ["＃", "#"],
        "%": ["％", "%"], "+": ["＋", "+"], "=": ["＝", "="],
        "$": ["＄", "$"], "^": ["＾", "^"], "`": ["｀", "`"],
    ]

    static func candidates(for input: String) -> [JapaneseConversionCandidate]? {
        guard !input.isEmpty, input.count <= 32,
              input.allSatisfy({ variants[$0] != nil }) else { return nil }
        var texts: [String]
        if input.count == 1, let character = input.first {
            texts = variants[character]!
        } else {
            let preferred = input.map { variants[$0]![0] }.joined()
            let fullWidth = input.unicodeScalars.map { scalar -> String in
                if (0x21...0x7E).contains(scalar.value), let wide = UnicodeScalar(scalar.value + 0xFEE0) {
                    return String(wide)
                }
                return String(scalar)
            }.joined()
            texts = [preferred, fullWidth]
            if input == "..." { texts.insert("…", at: 0) }
            if input == ".." { texts.insert("‥", at: 0) }
            if input == "--" { texts.insert("――", at: 0) }
        }
        texts.append(input)
        var seen = Set<String>()
        return texts.filter { seen.insert($0).inserted }.enumerated().map { index, text in
            JapaneseConversionCandidate(text: text, score: 0.99 - Double(index) * 0.01)
        }
    }
}

/// A lazy Cartesian product: the rightmost punctuation position advances first.
/// Store digits rather than materializing an exponentially large candidate list.
struct JapanesePunctuationCombinationCursor {
    private let characters: [Character]
    private let positions: [Int]
    private let alternatives: [[Character]]
    private var digits: [Int]

    init?(text: String) {
        // Literal URLs, email addresses and code should retain their separators.
        guard !text.contains("://"), !text.contains("@"), !text.contains("`") else { return nil }
        let groups = [
            "。．.・･", "、，,", "／/・･", "！!", "？?", "：:", "；;",
            "（(", "）)", "「『【［[", "」』】］]", "｛{", "｝}",
            "〈《＜<", "〉》＞>", "“〝＂\"", "”〟＂\"", "‘＇'", "’＇'",
            "ー−－―—–-", "〜～~", "…‥", "＊※*", "＼￥\\", "｜|"
        ].map { Array($0) }
        characters = Array(text)
        var slots: [Int] = []
        var choices: [[Character]] = []
        for (position, character) in characters.enumerated() {
            // A kana prolonged-sound mark belongs to the word, e.g. スーパー.
            if character == "ー", position > 0,
               characters[position - 1].unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) { continue }
            // Decimal points and number-grouping separators are not punctuation slots.
            if ".．,，".contains(character), position > 0, position + 1 < characters.count,
               characters[position - 1].isNumber, characters[position + 1].isNumber { continue }
            guard let group = groups.first(where: { $0.contains(character) }) else { continue }
            slots.append(position)
            choices.append([character] + group.filter { $0 != character })
        }
        guard !slots.isEmpty else { return nil }
        positions = slots
        alternatives = choices
        digits = Array(repeating: 0, count: slots.count)
    }

    mutating func move(forward: Bool) -> String {
        for slot in digits.indices.reversed() {
            let count = alternatives[slot].count
            digits[slot] = (digits[slot] + (forward ? 1 : count - 1)) % count
            if (forward ? digits[slot] != 0 : digits[slot] != count - 1) { break }
        }
        var output = characters
        for slot in positions.indices { output[positions[slot]] = alternatives[slot][digits[slot]] }
        return String(output)
    }
}

enum RomajiKanaConverter {
    static func hiragana(_ input: String) -> String {
        let lowercased = input.lowercased()
        var output = ""
        var index = lowercased.startIndex

        while index < lowercased.endIndex {
            if let punctuation = punctuationTable[lowercased[index]] {
                output += punctuation
                index = lowercased.index(after: index)
                continue
            }

            if lowercased[index] == "n" {
                let next = lowercased.index(after: index)
                if next == lowercased.endIndex {
                    output += "ん"
                    index = next
                    continue
                }
                if lowercased[next] == "n" {
                    output += "ん"
                    index = next
                    continue
                }
                if !isVowel(lowercased[next]) && lowercased[next] != "y" {
                    output += "ん"
                    index = next
                    continue
                }
            }

            if let (kana, nextIndex) = longestKanaMatch(in: lowercased, from: index) {
                output += kana
                index = nextIndex
                continue
            }

            let next = lowercased.index(after: index)
            if next < lowercased.endIndex,
               lowercased[index] == lowercased[next],
               !isVowel(lowercased[index]),
               lowercased[index] != "n" {
                output += "っ"
                index = next
                continue
            }

            output.append(lowercased[index])
            index = next
        }

        return output
    }

    private static func longestKanaMatch(in input: String, from index: String.Index) -> (String, String.Index)? {
        for length in stride(from: 3, through: 1, by: -1) {
            guard let end = input.index(index, offsetBy: length, limitedBy: input.endIndex) else { continue }
            let token = String(input[index..<end])
            if let kana = table[token] {
                return (kana, end)
            }
        }
        return nil
    }

    private static func isVowel(_ character: Character) -> Bool {
        ["a", "i", "u", "e", "o"].contains(character)
    }

    private static let punctuationTable: [Character: String] = [
        ".": "。",
        ",": "、",
        "?": "？",
        "!": "！",
    ]

    private static let table: [String: String] = [
        "a": "あ", "i": "い", "u": "う", "e": "え", "o": "お",
        "ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ",
        "kya": "きゃ", "kyu": "きゅ", "kyo": "きょ",
        "sa": "さ", "shi": "し", "si": "し", "su": "す", "se": "せ", "so": "そ",
        "sha": "しゃ", "shu": "しゅ", "sho": "しょ", "sya": "しゃ", "syu": "しゅ", "syo": "しょ",
        "ta": "た", "chi": "ち", "ti": "ち", "tsu": "つ", "tu": "つ", "te": "て", "to": "と",
        "cha": "ちゃ", "chu": "ちゅ", "cho": "ちょ", "tya": "ちゃ", "tyu": "ちゅ", "tyo": "ちょ",
        "na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の",
        "nya": "にゃ", "nyu": "にゅ", "nyo": "にょ",
        "ha": "は", "hi": "ひ", "fu": "ふ", "hu": "ふ", "he": "へ", "ho": "ほ",
        "hya": "ひゃ", "hyu": "ひゅ", "hyo": "ひょ",
        "ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も",
        "mya": "みゃ", "myu": "みゅ", "myo": "みょ",
        "ya": "や", "yu": "ゆ", "yo": "よ",
        "ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ",
        "rya": "りゃ", "ryu": "りゅ", "ryo": "りょ",
        "wa": "わ", "wo": "を",
        "ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご",
        "gya": "ぎゃ", "gyu": "ぎゅ", "gyo": "ぎょ",
        "za": "ざ", "ji": "じ", "zi": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ",
        "ja": "じゃ", "ju": "じゅ", "jo": "じょ", "jya": "じゃ", "jyu": "じゅ", "jyo": "じょ",
        "da": "だ", "di": "ぢ", "du": "づ", "de": "で", "do": "ど",
        "ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ",
        "bya": "びゃ", "byu": "びゅ", "byo": "びょ",
        "pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ",
        "pya": "ぴゃ", "pyu": "ぴゅ", "pyo": "ぴょ",
        "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ",
        "va": "ゔぁ", "vi": "ゔぃ", "vu": "ゔ", "ve": "ゔぇ", "vo": "ゔぉ",
        "la": "ぁ", "li": "ぃ", "lu": "ぅ", "le": "ぇ", "lo": "ぉ",
        "xa": "ぁ", "xi": "ぃ", "xu": "ぅ", "xe": "ぇ", "xo": "ぉ",
        "ltu": "っ", "xtu": "っ",
    ]
}

enum SelfConversionKeyInterpreter {
#if canImport(Carbon)
    static func startsConversion(for keyCode: Int) -> Bool {
        keyCode == kVK_JIS_Kana
    }

    static func isSelfConversionToggleShortcut(for keyCode: Int, flags: InputHook.Flags) -> Bool {
        flags.ctrl &&
            !flags.shift &&
            !flags.opt &&
            !flags.cmd &&
            !flags.fnc &&
            keyCode == KeyMapping.keyCode(for: .selfConversionToggle)
    }

    static func shouldPassThroughActiveConversion(_ flags: InputHook.Flags) -> Bool {
        flags.cmd
    }

    static func isPartialCommitKey(for keyCode: Int) -> Bool {
        keyCode == kVK_Tab
    }

    static func character(for keyCode: Int, flags: InputHook.Flags) -> String? {
        guard let code = UInt16(exactly: keyCode) else { return nil }
        // Translate the physical key using the Roman layout underlying the IME.
        // Event Unicode at the HID tap can be empty or depend on the active IME.
        if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            if let bytes = CFDataGetBytePtr(data), CFDataGetLength(data) >= MemoryLayout<UCKeyboardLayout>.size {
                let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                let modifiers = flags.shift ? UInt32(shiftKey >> 8) : 0
                var deadKeyState: UInt32 = 0
                var length = 0
                var buffer = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), modifiers,
                                            flags.keyboardType ?? UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                            &deadKeyState, buffer.count, &length, &buffer)
                if status == noErr, length > 0, length <= buffer.count {
                    let text = String(utf16CodeUnits: buffer, count: length)
                    if text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) { return text }
                }
            }
        }
        // Keep synthetic key injection and missing-layout environments usable.
        return asciiCharacter(for: keyCode, shift: flags.shift)
    }

    static func isSuffixInputShortcut(for keyCode: Int, flags: InputHook.Flags) -> Bool {
        // JIS: Ctrl+colon key; ANSI: Ctrl+Shift+semicolon. Respect the actual
        // layout instead of binding the shortcut to one physical key code.
        flags.ctrl && !flags.opt && !flags.cmd && !flags.fnc
            && character(for: keyCode, flags: flags) == ":"
    }

    static func asciiCharacter(for keyCode: Int, shift: Bool) -> String? {
        if let letter = letters[keyCode] {
            return shift ? letter.uppercased() : letter
        }
        if let pair = digits[keyCode] {
            return shift ? pair.shifted : pair.plain
        }
        if let pair = symbols[keyCode] {
            return shift ? pair.shifted : pair.plain
        }
        return nil
    }

    private static let letters: [Int: String] = [
        kVK_ANSI_A: "a", kVK_ANSI_B: "b", kVK_ANSI_C: "c", kVK_ANSI_D: "d",
        kVK_ANSI_E: "e", kVK_ANSI_F: "f", kVK_ANSI_G: "g", kVK_ANSI_H: "h",
        kVK_ANSI_I: "i", kVK_ANSI_J: "j", kVK_ANSI_K: "k", kVK_ANSI_L: "l",
        kVK_ANSI_M: "m", kVK_ANSI_N: "n", kVK_ANSI_O: "o", kVK_ANSI_P: "p",
        kVK_ANSI_Q: "q", kVK_ANSI_R: "r", kVK_ANSI_S: "s", kVK_ANSI_T: "t",
        kVK_ANSI_U: "u", kVK_ANSI_V: "v", kVK_ANSI_W: "w", kVK_ANSI_X: "x",
        kVK_ANSI_Y: "y", kVK_ANSI_Z: "z",
    ]

    private static let digits: [Int: (plain: String, shifted: String)] = [
        kVK_ANSI_0: ("0", ")"), kVK_ANSI_1: ("1", "!"), kVK_ANSI_2: ("2", "@"),
        kVK_ANSI_3: ("3", "#"), kVK_ANSI_4: ("4", "$"), kVK_ANSI_5: ("5", "%"),
        kVK_ANSI_6: ("6", "^"), kVK_ANSI_7: ("7", "&"), kVK_ANSI_8: ("8", "*"),
        kVK_ANSI_9: ("9", "("),
    ]

    private static let symbols: [Int: (plain: String, shifted: String)] = [
        kVK_Space: (" ", " "),
        kVK_ANSI_Minus: ("-", "_"),
        kVK_ANSI_Equal: ("=", "+"),
        kVK_ANSI_LeftBracket: ("[", "{"),
        kVK_ANSI_RightBracket: ("]", "}"),
        kVK_ANSI_Backslash: ("\\", "|"),
        kVK_ANSI_Semicolon: (";", ":"),
        kVK_ANSI_Quote: ("'", "\""),
        kVK_ANSI_Comma: (",", "<"),
        kVK_ANSI_Period: (".", ">"),
        kVK_ANSI_Slash: ("/", "?"),
        kVK_ANSI_Grave: ("`", "~"),
    ]
#endif
}

struct SelfConversionStartKeyReleaseFilter {
    private var startKeyCode: Int?

    mutating func rememberStartKey(_ keyCode: Int) {
        startKeyCode = keyCode
    }

    mutating func shouldIgnoreRelease(for keyCode: Int) -> Bool {
        guard startKeyCode == keyCode else {
            return false
        }
        startKeyCode = nil
        return true
    }
}

final class JapaneseConversionClient: JapaneseConversionServing {
    typealias Completion = ([JapaneseConversionCandidate]) -> Void
    typealias DetailedCompletion = (JapaneseConversionResult) -> Void
    private let personalizer: SelfConversionPersonalizer
    var conversionDebounceDelay: TimeInterval { SelfConversionSettings.backend == .local ? 0 : 2.0 }
    private let requestLock = NSLock()
    private var requestVersions = [false: 0, true: 0]
    private func nextRequest(suffix: Bool) -> Int {
        requestLock.lock(); defer { requestLock.unlock() }
        requestVersions[suffix, default: 0] += 1
        return requestVersions[suffix]!
    }
    private func isCurrent(_ version: Int, suffix: Bool) -> Bool {
        requestLock.lock(); defer { requestLock.unlock() }
        return requestVersions[suffix] == version
    }

    init(personalizer: SelfConversionPersonalizer = .shared) {
        self.personalizer = personalizer
        if SelfConversionSettings.backend == .local { LocalJapaneseConversionEngine.shared.warmUp() }
    }

    func convert(_ input: String, context: String = "", callbackQueue: DispatchQueue = .main, completion: @escaping Completion) {
        convertDetailed(input, context: context, callbackQueue: callbackQueue) { result in
            completion(result.candidates)
        }
    }

    func convertSuffix(_ input: String, context: String, completion: @escaping Completion) {
        convertDetailed(input, context: context, candidateLimit: 50) { completion($0.candidates) }
    }

    func convertDetailed(_ input: String, context: String = "", callbackQueue: DispatchQueue = .main, candidateLimit: Int? = nil, completion: @escaping DetailedCompletion) {
        let start = Date()
        let suffixLane = candidateLimit != nil
        let version = nextRequest(suffix: suffixLane)
        let fallback = personalizer.rerank(SelfConversionCandidateBuilder.fallbackCandidates(for: input, context: context), input: input, context: context)
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            completion(JapaneseConversionResult(candidates: [], source: .emptyInput, elapsed: 0, detail: nil))
            return
        }
        if let punctuation = JapanesePunctuationConverter.candidates(for: input) {
            callbackQueue.async {
                completion(JapaneseConversionResult(candidates: punctuation, source: .localPunctuation, elapsed: Date().timeIntervalSince(start), detail: nil))
            }
            return
        }
        if SelfConversionSettings.backend == .local {
            LocalJapaneseConversionEngine.shared.queue.async {
                let superseded = JapaneseConversionResult(candidates: [], source: .localSuperseded, elapsed: Date().timeIntervalSince(start), detail: nil)
                guard self.isCurrent(version, suffix: suffixLane) else {
                    callbackQueue.async { completion(superseded) }; return
                }
                let result: JapaneseConversionResult
                do {
                    let root = try LocalJapaneseConversionEngine.shared.convert(input, context: String(context.unicodeScalars.suffix(2048)), limit: candidateLimit ?? 5)
                    let parsed = SelfConversionCandidateBuilder.parseCandidates(from: root, input: input)
                    guard !parsed.isEmpty else { throw LocalJapaneseConversionEngine.Failure("Local engine returned no candidates") }
                    let merged = SelfConversionCandidateBuilder.mergeResponse(root: root, parsed: parsed, fallback: fallback, context: context, requiredText: input)
                    result = JapaneseConversionResult(candidates: self.personalizer.rerank(merged, input: input, context: context), source: .localEngine, elapsed: Date().timeIntervalSince(start), detail: nil)
                } catch {
                    // An unavailable local engine must never silently send input over the network.
                    result = JapaneseConversionResult(candidates: fallback, source: .fallbackLocalError, elapsed: Date().timeIntervalSince(start), detail: error.localizedDescription)
                }
                callbackQueue.async {
                    completion(self.isCurrent(version, suffix: suffixLane) ? result : superseded)
                }
            }
            return
        }
        guard let url = SelfConversionSettings.apiEndpointURL else {
            completion(JapaneseConversionResult(candidates: fallback, source: .fallbackNoEndpoint, elapsed: 0, detail: nil))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let requestTimeout = JapaneseConversionRequestBuilder.requestTimeout(for: input)
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var requestBody = JapaneseConversionRequestBuilder.requestBody(for: input, context: context)
        if let candidateLimit { requestBody["limit"] = candidateLimit }
        request.httpBody = try? JSONSerialization.data(withJSONObject: requestBody)

        let lock = NSLock()
        var didFinish = false
        let finish: (JapaneseConversionResult) -> Void = { result in
            lock.lock()
            if didFinish {
                lock.unlock()
                return
            }
            didFinish = true
            lock.unlock()
            callbackQueue.async { completion(result) }
        }

        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            let elapsed = Date().timeIntervalSince(start)
            guard
                error == nil,
                let data = data,
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                finish(JapaneseConversionResult(
                    candidates: fallback,
                    source: .fallbackNetworkError,
                    elapsed: elapsed,
                    detail: error?.localizedDescription
                ))
                return
            }

            let parsed = SelfConversionCandidateBuilder.parseCandidates(from: root, input: input)
            let candidates = SelfConversionCandidateBuilder.mergeResponse(
                root: root,
                parsed: parsed,
                fallback: fallback,
                context: context,
                requiredText: input
            )
            finish(JapaneseConversionResult(
                candidates: self.personalizer.rerank(candidates, input: input, context: context),
                source: parsed.isEmpty ? .fallbackFilteredVMC : .vmc,
                elapsed: elapsed,
                detail: SelfConversionCandidateBuilder.responseSummary(from: root)
            ))
        }
        task.resume()

        DispatchQueue.global().asyncAfter(deadline: .now() + requestTimeout) {
            lock.lock()
            let shouldCancel = !didFinish
            lock.unlock()
            guard shouldCancel else { return }
            task.cancel()
            finish(JapaneseConversionResult(
                candidates: fallback,
                source: .fallbackTimeout,
                elapsed: Date().timeIntervalSince(start),
                detail: nil
            ))
        }
    }

    func submitDecision(_ decision: SelfConversionDecisionEvent) {
        // Feedback is local only. The stateless conversion server needs no
        // committed text, selected candidate or learning history.
        personalizer.record(decision)
    }
}

struct JapaneseConversionResult {
    let candidates: [JapaneseConversionCandidate]
    let source: JapaneseConversionSource
    let elapsed: TimeInterval
    let detail: String?
}

struct SelfConversionDecisionSnapshot {
    let input: String
    let context: String
    let committedText: String
    let composedText: String
    let selectedIndex: Int
    let selectedCandidate: JapaneseConversionCandidate?
    let candidates: [JapaneseConversionCandidate]
    var explicitSelection: Bool = false
    var learningInput: String? = nil
    var learningText: String? = nil
}

struct SelfConversionDecisionEvent {
    let action: String
    let snapshot: SelfConversionDecisionSnapshot
    let committedOutput: String?

    func requestBody() -> [String: Any] {
        let selectedText = snapshot.selectedCandidate?.text ?? ""
        let selectedBody: [String: Any] = snapshot.selectedCandidate.map(Self.candidateBody) ?? [:]
        let selectedScore: Any = snapshot.selectedCandidate.map { $0.score } ?? NSNull()
        let unselected = snapshot.candidates.enumerated()
            .filter { index, _ in index != snapshot.selectedIndex }
            .map { _, candidate in Self.candidateBody(candidate) }

        return [
            "schema_version": 1,
            "kind": "vimouse_self_conversion_decision",
            "app": "ViMouse",
            "app_version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "created_at": Self.iso8601String(from: Date()),
            "action": action,
            "input": snapshot.input,
            "context": snapshot.context,
            "committed_text_before": snapshot.committedText,
            "composed_text": snapshot.composedText,
            "committed_output": committedOutput ?? "",
            "selected_index": snapshot.selectedIndex,
            "selected": selectedBody,
            "selected_text": selectedText,
            "selected_score": selectedScore,
            "candidates": snapshot.candidates.map(Self.candidateBody),
            "unselected_candidates": unselected,
        ]
    }

    private static func candidateBody(_ candidate: JapaneseConversionCandidate) -> [String: Any] {
        [
            "text": candidate.text,
            "score": candidate.score,
        ]
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"
        return formatter.string(from: date)
    }
}

enum JapaneseConversionSource: String {
    case localEngine = "local-engine"
    case fallbackLocalError = "fallback-local-error"
    case localSuperseded = "local-superseded"
    case vmc
    case fallbackFilteredVMC = "fallback-filtered-vmc"
    case fallbackTimeout = "fallback-timeout"
    case fallbackNetworkError = "fallback-network-error"
    case localPunctuation = "local-punctuation"
    case fallbackNoEndpoint = "fallback-no-endpoint"
    case emptyInput = "empty-input"
}

enum JapaneseConversionRequestBuilder {
    static func requestBody(for input: String, context: String = "") -> [String: Any] {
        let maxNewTokens = maxNewTokens(for: input)
        return [
            "input": input,
            "context": context,
            "max_len": maxNewTokens,
            "max_new_tokens": maxNewTokens,
            "num_beams": numBeams(for: input),
        ]
    }

    static func maxNewTokens(for input: String) -> Int {
        let characterCount = input.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard characterCount > 40 else { return 16 }
        return min(48, max(24, Int(ceil(Double(characterCount) * 0.8))))
    }

    static func numBeams(for input: String) -> Int {
        input.trimmingCharacters(in: .whitespacesAndNewlines).count > 40 ? 3 : 5
    }

    static func requestTimeout(for input: String) -> TimeInterval {
        let configured = SelfConversionSettings.requestTimeout
        return input.trimmingCharacters(in: .whitespacesAndNewlines).count > 40
            ? max(configured, 18.0)
            : configured
    }
}

enum SelfConversionCandidateBuilder {
    static func fallbackCandidates(for input: String, context: String = "") -> [JapaneseConversionCandidate] {
        if let punctuation = JapanesePunctuationConverter.candidates(for: input) { return punctuation }
        let kana = RomajiKanaConverter.hiragana(input)
        var candidates = contextualFallbackCandidates(for: input, context: context)
        candidates.append(contentsOf: semanticFallbackCandidates(for: input))
        candidates.append(JapaneseConversionCandidate(text: kana, score: 0.2))
        if kana != input {
            candidates.append(JapaneseConversionCandidate(text: input, score: 0.05))
        }
        return merge(parsed: [], fallback: candidates, requiredText: input)
    }

    private static func contextualFallbackCandidates(for input: String, context: String) -> [JapaneseConversionCandidate] {
        let normalized = input.lowercased().filter { $0.isLetter || $0.isNumber }
        let normalizedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [JapaneseConversionCandidate] = []

        if normalized.contains("osietekudasai") || normalized.contains("oshietekudasai") {
            candidates.append(JapaneseConversionCandidate(
                text: "教えてください",
                score: normalizedContext.isEmpty ? 0.56 : 0.82
            ))
        }

        if normalized.contains("tenkinituite") || normalized.contains("tenkinitsuite") {
            candidates.append(JapaneseConversionCandidate(text: "天気について", score: 0.72))
        }

        return candidates
    }

    private static func semanticFallbackCandidates(for input: String) -> [JapaneseConversionCandidate] {
        let normalized = input.lowercased().filter { $0.isLetter || $0.isNumber }
        var candidates: [JapaneseConversionCandidate] = []

        if let phrase = lightweightPhraseCandidate(for: input) {
            candidates.append(JapaneseConversionCandidate(text: phrase, score: 0.56))
        }

        if normalized.contains("koreha"),
           normalized.contains("henkan"),
           normalized.contains("mode"),
           normalized.contains("desu") {
            candidates.append(JapaneseConversionCandidate(text: "これは変換モードです", score: 0.62))
            candidates.append(JapaneseConversionCandidate(text: "これは変換モードです。", score: 0.6))
        }

        if normalized.contains("yoroshiku") {
            candidates.append(JapaneseConversionCandidate(text: "よろしくお願いします", score: 0.58))
        }

        if normalized.contains("arigatou") || normalized.contains("arigato") {
            candidates.append(JapaneseConversionCandidate(text: "ありがとうございます", score: 0.58))
        }

        if normalized.contains("otsukaresama") {
            candidates.append(JapaneseConversionCandidate(text: "お疲れさまです", score: 0.58))
        }

        if normalized.contains("kakuninsitekudasai") || normalized.contains("kakuninshitekudasai") {
            candidates.append(JapaneseConversionCandidate(text: "確認してください", score: 0.5))
        }

        if normalized.contains("kaizensitekudasai") || normalized.contains("kaizenshitekudasai") {
            candidates.append(JapaneseConversionCandidate(text: "改善してください", score: 0.5))
        }

        if normalized.contains("jikkousitekudasai") || normalized.contains("jikkoushitekudasai") {
            candidates.append(JapaneseConversionCandidate(text: "実行してください", score: 0.5))
        }

        if normalized.contains("tuikasitekudasai") || normalized.contains("tsuikasitekudasai") {
            candidates.append(JapaneseConversionCandidate(text: "追加してください", score: 0.5))
        }

        return candidates
    }

    private static func lightweightPhraseCandidate(for input: String) -> String? {
        let lowered = input.lowercased()
        let compact = lowered.filter { $0.isLetter || $0.isNumber }
        guard compact.count >= 4 else { return nil }

        var output = ""
        var index = compact.startIndex
        while index < compact.endIndex {
            guard let match = longestPhraseToken(in: compact, from: index) else {
                return nil
            }
            output += match.text
            index = match.nextIndex
        }

        let punctuation = trailingJapanesePunctuation(for: lowered)
        return output + punctuation
    }

    private static func longestPhraseToken(in input: String, from index: String.Index) -> (text: String, nextIndex: String.Index)? {
        for token in phraseTokens {
            guard let end = input.index(index, offsetBy: token.romaji.count, limitedBy: input.endIndex),
                  input[index..<end] == token.romaji else {
                continue
            }
            return (token.text, end)
        }
        return nil
    }

    private static func trailingJapanesePunctuation(for input: String) -> String {
        var result = ""
        for character in input.reversed() {
            switch character {
            case ".":
                result = "。" + result
            case ",":
                result = "、" + result
            case "?":
                result = "？" + result
            case "!":
                result = "！" + result
            case " ", "\n", "\t", "\r":
                continue
            default:
                return result
            }
        }
        return result
    }

    static func parseCandidates(from text: String) -> [JapaneseConversionCandidate] {
        parseCandidates(from: text, input: nil)
    }

    static func parseCandidates(from text: String, input: String?) -> [JapaneseConversionCandidate] {
        guard
            let jsonText = jsonObjectSubstring(in: text),
            let data = jsonText.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data)
        else {
            return plainTextCandidate(from: text, input: input)
        }

        if let object = root as? [String: Any] {
            return parseCandidates(from: object, input: input)
        }
        if let rawCandidates = root as? [[String: Any]] {
            return parseCandidateRows(rawCandidates, input: input)
        }
        return []
    }

    static func parseCandidates(from root: [String: Any], input: String?) -> [JapaneseConversionCandidate] {
        if usesNativeRanking(root), let rows = root["candidates"] as? [[String: Any]] {
            // Mozc's deterministic conversion paths are not LLM generations.
            // Keep their tested rank order, rather than applying LLM-specific
            // punctuation, uppercase, domain or instruction-echo heuristics.
            return rows.prefix(50).enumerated().compactMap { index, row in
                guard let text = row["text"] as? String, !text.isEmpty,
                      text.count <= 1024, !text.contains("\u{FFFD}"),
                      !text.unicodeScalars.contains(where: { $0.value < 32 }) else { return nil }
                return JapaneseConversionCandidate(text: text, score: 1 - Double(index + 1) / 1000, isNative: true, reading: row["key"] as? String)
            }
        }
        if let response = root["response"] as? String {
            return parseCandidates(from: response, input: input)
        }

        if let rawChoices = root["choices"] as? [[String: Any]] {
            let candidates = parseChoiceRows(rawChoices, input: input)
            if !candidates.isEmpty {
                return candidates
            }
        }

        if let rawCandidates = root["candidates"] as? [[String: Any]] {
            let candidates = parseCandidateRows(rawCandidates, input: input)
            if !candidates.isEmpty {
                return candidates
            }
        }

        if let output = root["output"] as? String, !output.isEmpty {
            let score = scoreValue(from: root["score"], defaultValue: 1.0)
            return parseCandidateRows([["text": output, "score": score]], input: input)
        }

        return []
    }

    private static func usesNativeRanking(_ root: [String: Any]) -> Bool {
        root["ok"] as? Bool == true &&
            root["kind"] as? String == "vimouse-mozc-v2" &&
            root["ranking"] as? String == "native-top5-v1"
    }

    static func mergeResponse(
        root: [String: Any], parsed: [JapaneseConversionCandidate],
        fallback: [JapaneseConversionCandidate], context: String = "",
        requiredText: String? = nil
    ) -> [JapaneseConversionCandidate] {
        if let input = requiredText, let punctuation = JapanesePunctuationConverter.candidates(for: input) {
            return punctuation
        }
        guard usesNativeRanking(root), !parsed.isEmpty else {
            return merge(parsed: parsed, fallback: fallback, context: context, requiredText: requiredText)
        }
        // Native output is already the conversion of input, excluding history.
        // Do not strip a legitimate repeated prefix or fuse local phrase guesses.
        var seen = Set<String>()
        var result = parsed.filter { seen.insert($0.text).inserted }
        if let original = requiredText, !original.isEmpty, !seen.contains(original) {
            result.append(JapaneseConversionCandidate(text: original, score: 0.05))
        }
        return result
    }

    static func responseSummary(from root: [String: Any]) -> String? {
        var parts: [String] = []
        if let output = root["output"] as? String, !output.isEmpty {
            parts.append("output=\(output)")
        }
        if let rawOutput = root["raw_output"] as? String, !rawOutput.isEmpty {
            parts.append("raw_output=\(rawOutput)")
        }
        if let elapsed = root["elapsed"] {
            parts.append("server_elapsed=\(elapsed)")
        }
        if let ok = root["ok"] {
            parts.append("ok=\(ok)")
        }
        if let error = root["error"] as? String, !error.isEmpty {
            parts.append("error=\(error)")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func parseCandidateRows(_ rawCandidates: [[String: Any]], input: String?) -> [JapaneseConversionCandidate] {
        return rawCandidates.compactMap { raw in
            let text = candidateText(from: raw)
            guard !text.isEmpty else { return nil }
            if rejectsUngroundedTrailingPunctuation(text, input: input) {
                return nil
            }
            if rejectsLowQualityCandidate(text, input: input) {
                return nil
            }
            if rejectsUngroundedDomainCandidate(text, input: input) {
                return nil
            }
            if rejectsUngroundedCommandSuffixCandidate(text, input: input) {
                return nil
            }
            if rejectsUnexpectedUppercaseLatin(in: text, input: input) {
                return nil
            }
            let score = scoreValue(from: raw["score"], defaultValue: 0)
            return JapaneseConversionCandidate(text: text, score: score)
        }
        .sorted { $0.score > $1.score }
    }

    private static func parseChoiceRows(_ rawChoices: [[String: Any]], input: String?) -> [JapaneseConversionCandidate] {
        var candidates: [JapaneseConversionCandidate] = []
        for raw in rawChoices {
            let content: String?
            if let message = raw["message"] as? [String: Any] {
                content = message["content"] as? String
            } else {
                content = raw["text"] as? String
            }
            guard let content else { continue }
            let parsed = parseCandidates(from: content, input: input)
            let scored = parsed.map { candidate in
                JapaneseConversionCandidate(
                    text: candidate.text,
                    score: scoreValue(from: raw["score"], defaultValue: candidate.score)
                )
            }
            candidates.append(contentsOf: scored)
        }
        return merge(parsed: candidates, fallback: [])
    }

    private static func plainTextCandidate(from text: String, input: String?) -> [JapaneseConversionCandidate] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\n"),
              !trimmed.hasPrefix("{"),
              !trimmed.hasPrefix("["),
              trimmed.count <= 120,
              !rejectsUngroundedTrailingPunctuation(trimmed, input: input),
              !rejectsLowQualityCandidate(trimmed, input: input),
              !rejectsUngroundedCommandSuffixCandidate(trimmed, input: input),
              !rejectsUnexpectedUppercaseLatin(in: trimmed, input: input) else {
            return []
        }
        return [JapaneseConversionCandidate(text: trimmed, score: 0.7)]
    }

    private static func candidateText(from raw: [String: Any]) -> String {
        for key in ["text", "output", "candidate"] {
            if let text = raw[key] as? String {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return ""
    }

    private static func scoreValue(from raw: Any?, defaultValue: Double) -> Double {
        let rawScore: Double
        if let value = raw as? Double {
            rawScore = value
        } else if let value = raw as? NSNumber {
            rawScore = value.doubleValue
        } else if let value = raw as? String, let parsed = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            rawScore = parsed
        } else {
            rawScore = defaultValue
        }
        return min(max(rawScore, 0), 1)
    }

    private static func rejectsLowQualityCandidate(_ candidateText: String, input: String?) -> Bool {
        if candidateText.contains("\u{FFFD}") {
            return true
        }

        if candidateText.contains("Input:") ||
            candidateText.contains("Reading hint:") ||
            candidateText.contains("Return JSON") ||
            candidateText.contains("candidates") {
            return true
        }

        guard let input else { return false }
        let normalizedInput = input.lowercased().filter { $0.isLetter || $0.isNumber }
        guard normalizedInput.count >= 6 else { return false }
        if containsJapaneseCharacter(candidateText) {
            return false
        }
        if containsProtectedLatinTerm(candidateText, normalizedInput: normalizedInput) {
            return false
        }

        let latinLikeCount = candidateText.unicodeScalars.filter { scalar in
            let value = scalar.value
            return (65...90).contains(value) ||
                (97...122).contains(value) ||
                (48...57).contains(value) ||
                value == 32 ||
                value == 44 ||
                value == 45 ||
                value == 46 ||
                value == 95
        }.count
        return latinLikeCount >= max(4, candidateText.unicodeScalars.count - 2)
    }

    private static func rejectsUngroundedDomainCandidate(_ candidateText: String, input: String?) -> Bool {
        guard let input else { return false }
        let normalizedInput = input.lowercased().filter { $0.isLetter || $0.isNumber }
        guard normalizedInput.count >= 6 else { return false }

        for term in guardedDomainTerms where candidateText.contains(term.text) {
            if term.inputCues.contains(where: { normalizedInput.contains($0) }) {
                continue
            }
            return true
        }
        return false
    }

    private static func rejectsUngroundedCommandSuffixCandidate(_ candidateText: String, input: String?) -> Bool {
        guard let input else { return false }
        let normalizedInput = input.lowercased().filter { $0.isLetter || $0.isNumber }
        let normalizedCandidate = candidateText.trimmingCharacters(in: .whitespacesAndNewlines)
        let coreCandidate = normalizedCandidate.trimmingCharacters(in: commandTrailingPunctuation)

        if standalonePleaseDoInputs.contains(normalizedInput) {
            return !standalonePleaseDoCandidates.contains(coreCandidate)
        }

        if standalonePleaseInputs.contains(normalizedInput) {
            return !standalonePleaseCandidates.contains(coreCandidate)
        }

        if normalizedInput.hasSuffix("kudasai") {
            return !normalizedCandidate.contains("ください") && !normalizedCandidate.contains("下さい")
        }

        return false
    }

    private static func rejectsUngroundedTrailingPunctuation(_ candidateText: String, input: String?) -> Bool {
        guard let input else { return false }
        guard let candidatePunctuation = trailingPunctuationKind(in: candidateText) else {
            return false
        }
        guard let inputPunctuation = trailingPunctuationKind(in: input) else {
            return true
        }
        return candidatePunctuation != inputPunctuation
    }

    private static func trailingPunctuationKind(in text: String) -> Character? {
        for character in text.trimmingCharacters(in: .whitespacesAndNewlines).reversed() {
            switch character {
            case ".", "。":
                return "."
            case ",", "、":
                return ","
            case "?", "？":
                return "?"
            case "!", "！":
                return "!"
            default:
                return nil
            }
        }
        return nil
    }

    private static func containsProtectedLatinTerm(_ candidateText: String, normalizedInput: String) -> Bool {
        protectedLatinTerms.contains { term in
            candidateText.contains(term.display) && normalizedInput.contains(term.inputKey)
        }
    }

    private static func containsJapaneseCharacter(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x9FFF:
                return true
            default:
                return false
            }
        }
    }

    static func merge(
        parsed: [JapaneseConversionCandidate],
        fallback: [JapaneseConversionCandidate],
        context: String = "",
        requiredText: String? = nil
    ) -> [JapaneseConversionCandidate] {
        var bestByText: [String: JapaneseConversionCandidate] = [:]
        let parsedCandidates = stripEchoedContext(from: parsed, context: context).filter {
            !rejectsContextEchoFragmentCandidate($0.text, input: requiredText, context: context)
        }
        for candidate in parsedCandidates + fallback {
            if let current = bestByText[candidate.text], current.score >= candidate.score {
                continue
            }
            bestByText[candidate.text] = candidate
        }

        let sorted = bestByText.values.sorted { $0.score > $1.score }
        let expanded = sorted.dropFirst(Self.defaultCandidateLimit)
            .filter { $0.score >= Self.expandedCandidateScoreThreshold }
        var result = deduplicated(candidates: Array(sorted.prefix(Self.defaultCandidateLimit)) + expanded)

        if let requiredText = requiredText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requiredText.isEmpty,
           !result.contains(where: { $0.text == requiredText }) {
            let requiredCandidate = bestByText[requiredText]
                ?? JapaneseConversionCandidate(text: requiredText, score: 0.05)
            result.append(requiredCandidate)
        }
        return result
    }

    private static func deduplicated(candidates: [JapaneseConversionCandidate]) -> [JapaneseConversionCandidate] {
        var seen = Set<String>()
        return candidates.filter { candidate in
            if seen.contains(candidate.text) {
                return false
            }
            seen.insert(candidate.text)
            return true
        }
    }

    private static let defaultCandidateLimit = 5
    private static let expandedCandidateScoreThreshold = 0.8

    private static func stripEchoedContext(
        from candidates: [JapaneseConversionCandidate],
        context: String
    ) -> [JapaneseConversionCandidate] {
        let prefixes = contextEchoPrefixes(from: context)
        guard !prefixes.isEmpty else { return candidates }

        return candidates.map { candidate in
            let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
            for prefix in prefixes where text.hasPrefix(prefix) {
                let suffixStart = text.index(text.startIndex, offsetBy: prefix.count)
                let suffix = String(text[suffixStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !suffix.isEmpty {
                    return JapaneseConversionCandidate(text: suffix, score: candidate.score)
                }
            }
            return candidate
        }
    }

    private static func contextEchoPrefixes(from context: String) -> [String] {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var prefixes = Set<String>()
        prefixes.insert(trimmed)

        for line in trimmed.components(separatedBy: .newlines) {
            let part = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if part.count >= 2 {
                prefixes.insert(part)
            }
        }

        return prefixes
            .filter { $0.count >= 2 }
            .sorted { $0.count > $1.count }
    }

    private static func rejectsContextEchoFragmentCandidate(
        _ candidateText: String,
        input: String?,
        context: String
    ) -> Bool {
        let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCandidate = candidateText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let input, !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        guard !trimmedContext.isEmpty,
              !trimmedCandidate.isEmpty,
              startsWithContextFragment(trimmedCandidate, context: trimmedContext),
              !isGroundedInInputReading(trimmedCandidate, input: input) else {
            return false
        }
        return true
    }

    private static func startsWithContextFragment(_ candidateText: String, context: String) -> Bool {
        let maximumLength = min(10, candidateText.count)
        guard maximumLength >= 3 else { return false }
        for length in stride(from: maximumLength, through: 3, by: -1) {
            let end = candidateText.index(candidateText.startIndex, offsetBy: length)
            let prefix = String(candidateText[..<end])
            if context.contains(prefix) {
                return true
            }
        }
        return false
    }

    private static func isGroundedInInputReading(_ candidateText: String, input: String?) -> Bool {
        guard let input else { return false }
        let inputReading = kanaProjection(RomajiKanaConverter.hiragana(input))
        guard inputReading.count >= 4 else { return true }
        let candidateReading = kanaProjection(candidateText)
        guard candidateReading.count >= 2 else { return true }

        let prefixLength = min(4, candidateReading.count)
        let candidatePrefixEnd = candidateReading.index(candidateReading.startIndex, offsetBy: prefixLength)
        let candidatePrefix = String(candidateReading[..<candidatePrefixEnd])
        if inputReading.hasPrefix(candidatePrefix) || inputReading.contains(candidatePrefix) {
            return true
        }

        let shorterPrefixLength = min(2, candidateReading.count)
        let shorterPrefixEnd = candidateReading.index(candidateReading.startIndex, offsetBy: shorterPrefixLength)
        return inputReading.hasPrefix(String(candidateReading[..<shorterPrefixEnd]))
    }

    private static func kanaProjection(_ text: String) -> String {
        String(text.unicodeScalars.compactMap { scalar in
            switch scalar.value {
            case 0x3041...0x3096:
                return Character(scalar)
            case 0x30A1...0x30F6:
                return Character(UnicodeScalar(scalar.value - 0x60)!)
            default:
                return nil
            }
        })
    }

    private static func rejectsUnexpectedUppercaseLatin(in candidateText: String, input: String?) -> Bool {
        guard let input else { return false }
        let normalizedInput = input.lowercased().filter { $0.isLetter || $0.isNumber }

        for run in latinRuns(in: candidateText) {
            guard run.count >= 2, run.rangeOfCharacter(from: .uppercaseLetters) != nil else { continue }
            if input.contains(run) {
                continue
            }
            if allowsProtectedLatinRun(run, candidateText: candidateText, normalizedInput: normalizedInput) {
                continue
            }
            return true
        }
        return false
    }

    private static func allowsProtectedLatinRun(_ run: String, candidateText: String, normalizedInput: String) -> Bool {
        for term in protectedLatinTerms where candidateText.contains(term.display) {
            guard term.runs.contains(run), normalizedInput.contains(term.inputKey) else {
                continue
            }
            if term.inputKey == "ui" {
                return normalizedInput.hasPrefix("ui") ||
                    normalizedInput.contains("uiwo") ||
                    normalizedInput.contains("uiw") ||
                    normalizedInput.contains("uino")
            }
            return true
        }
        return false
    }

    private static func latinRuns(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""

        for scalar in text.unicodeScalars {
            let value = scalar.value
            let isAsciiLetter = (65...90).contains(value) || (97...122).contains(value)
            let isAsciiDigit = (48...57).contains(value)
            let isJoiner = value == 35 || value == 43 || value == 45 || value == 46 || value == 95

            if isAsciiLetter || (!current.isEmpty && (isAsciiDigit || isJoiner)) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }

        if !current.isEmpty {
            runs.append(current)
        }
        return runs
    }

    private static func jsonObjectSubstring(in text: String) -> String? {
        let starts = text.indices.filter { text[$0] == "{" || text[$0] == "[" }
        for start in starts {
            let endCharacter: Character = text[start] == "{" ? "}" : "]"
            var end = text.endIndex
            while let candidateEnd = text[..<end].lastIndex(of: endCharacter), start <= candidateEnd {
                let candidate = String(text[start...candidateEnd])
                if let data = candidate.data(using: .utf8),
                   (try? JSONSerialization.jsonObject(with: data)) != nil {
                    return candidate
                }
                end = candidateEnd
            }
        }
        return nil
    }

    private static let protectedLatinTerms: [(display: String, inputKey: String, runs: Set<String>)] = [
        ("API", "api", ["API"]),
        ("App Store Connect", "appstoreconnect", ["App", "Store", "Connect"]),
        ("CNPG", "cnpg", ["CNPG"]),
        ("GitHub", "github", ["GitHub"]),
        ("Google Analytics", "googleanalytics", ["Google", "Analytics"]),
        ("Google Chrome", "googlechrome", ["Google", "Chrome"]),
        ("LLM", "llm", ["LLM"]),
        ("MF", "mf", ["MF"]),
        ("PVC", "pvc", ["PVC"]),
        ("RDP", "rdp", ["RDP"]),
        ("Search Console", "searchconsole", ["Search", "Console"]),
        ("SSH", "ssh", ["SSH"]),
        ("UI", "ui", ["UI"]),
        ("ViMouse", "vimouse", ["ViMouse"]),
    ]

    private static let phraseTokens: [(romaji: String, text: String)] = [
        ("appstoreconnect", "App Store Connect"),
        ("searchconsole", "Search Console"),
        ("shitekudasai", "してください"),
        ("sitekudasai", "してください"),
        ("animeeshon", "アニメーション"),
        ("animeshon", "アニメーション"),
        ("kyouha", "今日は"),
        ("tennki", "天気"),
        ("tenki", "天気"),
        ("iidesu", "いいです"),
        ("ii", "いい"),
        ("arigatou", "ありがとう"),
        ("arigato", "ありがとう"),
        ("konnichiha", "こんにちは"),
        ("konbanha", "こんばんは"),
        ("ohayou", "おはよう"),
        ("otsukaresama", "お疲れさま"),
        ("onegaishimasu", "お願いします"),
        ("yoroshiku", "よろしく"),
        ("kakunin", "確認"),
        ("kaizen", "改善"),
        ("jikkou", "実行"),
        ("jisshi", "実施"),
        ("henkan", "変換"),
        ("nihongo", "日本語"),
        ("vimouse", "ViMouse"),
        ("tesuto", "テスト"),
        ("anime", "アニメ"),
        ("mode", "モード"),
        ("deshita", "でした"),
        ("desita", "でした"),
        ("kudasai", "ください"),
        ("shimasu", "します"),
        ("simasu", "します"),
        ("masita", "ました"),
        ("mashita", "ました"),
        ("desu", "です"),
        ("masu", "ます"),
        ("koreha", "これは"),
        ("soreha", "それは"),
        ("areha", "あれは"),
        ("watashiha", "私は"),
        ("bokuh", "僕"),
        ("bokuha", "僕は"),
        ("wo", "を"),
        ("ha", "は"),
        ("ga", "が"),
        ("ni", "に"),
        ("de", "で"),
        ("to", "と"),
        ("no", "の"),
    ].sorted { $0.romaji.count > $1.romaji.count }

    private static let commandTrailingPunctuation = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ".。,!！?？"))

    private static let standalonePleaseDoInputs: Set<String> = [
        "shitekudasai",
        "sitekudasai",
    ]

    private static let standalonePleaseDoCandidates: Set<String> = [
        "してください",
        "して下さい",
    ]

    private static let standalonePleaseInputs: Set<String> = [
        "kudasai",
    ]

    private static let standalonePleaseCandidates: Set<String> = [
        "ください",
        "下さい",
    ]

    private static let guardedDomainTerms: [(text: String, inputCues: Set<String>)] = [
        ("収集系", ["shuushuukei", "syuushuukei", "shushukei", "syushukei"]),
        ("補助探", ["hojotan"]),
        ("Search Console", ["searchconsole"]),
        ("Google Analytics", ["googleanalytics"]),
        ("CNPG", ["cnpg"]),
        ("PVC", ["pvc"]),
        ("vacuum", ["vacuum"]),
        ("WinVR", ["winvr"]),
        ("winvr", ["winvr"]),
    ]
}

/// Dynamically loaded ABI 1 avoids linking the macOS 14 ARM SDK into the legacy Intel app.
/// All engine access, including initialization, stays on this serial queue.
private final class LocalJapaneseConversionEngine {
    static let shared = LocalJapaneseConversionEngine()
    let queue = DispatchQueue(label: "ViMouse.localConversion", qos: .userInitiated)
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    private typealias Create = @convention(c) (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> UnsafeMutableRawPointer?
    private typealias Convert = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, UnsafeRawPointer?) -> UnsafeMutablePointer<CChar>?
    private typealias Free = @convention(c) (UnsafeMutablePointer<CChar>?) -> Void
    private typealias Defaults = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private var handle: UnsafeMutableRawPointer?
    private var engine: UnsafeMutableRawPointer?
    private var converter: Convert?
    private var freeResult: Free?
    private var defaults: Defaults?
    private var profile: URL?
    private var initializationFailure: Error?

    func warmUp() { queue.async { try? self.load() } }
    private func symbol<T>(_ name: String, as type: T.Type) throws -> T {
        guard let address = dlsym(handle, name) else { throw Failure("Missing local engine symbol: \(name)") }
        return unsafeBitCast(address, to: type)
    }
    private func load() throws {
        if let initializationFailure { throw initializationFailure }
        if engine != nil { return }
        do {
            if let reason = SelfConversionSettings.localUnavailableReason { throw Failure(reason) }
            #if arch(arm64)
            guard #available(macOS 14.0, *) else { throw Failure("Local conversion requires macOS 14 or later. Select Server in settings on this Mac.") }
            #else
            throw Failure("Local conversion requires Apple Silicon. Select Server in settings on this Mac.")
            #endif
            guard let resources = Bundle.main.resourceURL else { throw Failure("Local conversion resources are missing") }
            let library = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libvimouse_ime.dylib")
            guard let loaded = dlopen(library.path, RTLD_NOW | RTLD_LOCAL) else {
                throw Failure("Local conversion library could not load: \(dlerror().map { String(cString: $0) } ?? "unknown error")")
            }
            handle = loaded
            let abi = try symbol("vmime_abi_version", as: (@convention(c) () -> UInt32).self)
            guard abi() == 1 else { throw Failure("Unsupported local engine ABI") }
            let create = try symbol("vmime_create", as: Create.self)
            converter = try symbol("vmime_convert", as: Convert.self)
            freeResult = try symbol("vmime_free", as: Free.self)
            defaults = try symbol("vmime_default_options", as: Defaults.self)
            let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("ViMouse-local-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            profile = directory
            let data = resources.appendingPathComponent("LocalConversion/mozc.data").path
            let lexicon = resources.appendingPathComponent("LocalConversion/lexicon").path
            var error: UnsafeMutablePointer<CChar>?
            engine = data.withCString { dataPtr in lexicon.withCString { lexiconPtr in directory.path.withCString { create(dataPtr, lexiconPtr, $0, &error) } } }
            defer { if let error { freeResult?(error) } }
            guard engine != nil else { throw Failure(error.map { String(cString: $0) } ?? "Local engine initialization failed") }
        } catch {
            if let profile { try? FileManager.default.removeItem(at: profile) }
            profile = nil
            if let handle { dlclose(handle) }
            handle = nil
            initializationFailure = error
            throw error
        }
    }
    func convert(_ input: String, context: String, limit: Int) throws -> [String: Any] {
        try load()
        guard input.unicodeScalars.count <= 256, context.unicodeScalars.count <= 2048,
              !input.utf8.contains(0), !context.utf8.contains(0) else { throw Failure("Local conversion input exceeds engine limits") }
        // ABI 1's 64-bit options layout is pinned by the bundled header and manifest.
        let options = UnsafeMutableRawPointer.allocate(byteCount: 48, alignment: 8)
        defer { options.deallocate() }
        defaults?(options)
        guard options.load(as: UInt32.self) == 48 else { throw Failure("Unexpected local options layout") }
        options.storeBytes(of: Int32(min(50, max(1, limit))), toByteOffset: 16, as: Int32.self)
        guard let result = input.withCString({ inputPtr in context.withCString { converter?(engine, inputPtr, $0, options) } }) else { throw Failure("Local engine allocation failed") }
        defer { freeResult?(result) }
        guard var root = try JSONSerialization.jsonObject(with: Data(String(cString: result).utf8)) as? [String: Any] else { throw Failure("Invalid local engine response") }
        guard root["ok"] as? Bool == true else { throw Failure(root["error"] as? String ?? "Local engine conversion failed") }
        root["kind"] = "vimouse-mozc-v2"
        root["ranking"] = "native-top5-v1"
        return root
    }
    deinit {
        if let engine, let destroy = try? symbol("vmime_destroy", as: (@convention(c) (UnsafeMutableRawPointer?) -> Void).self) { destroy(engine) }
        if let profile { try? FileManager.default.removeItem(at: profile) }
        if let handle { dlclose(handle) }
    }
}
