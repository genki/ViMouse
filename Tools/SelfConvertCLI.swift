import Foundation

@main
struct SelfConvertCLI {
    static func main() {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let fallbackOnly = arguments.removeAll("--fallback-only")
        let input = arguments.joined(separator: " ")

        guard !input.isEmpty else {
            fputs("usage: self-convert [--fallback-only] ascii-romaji\n", stderr)
            exit(64)
        }

        let fallback = SelfConversionCandidateBuilder.fallbackCandidates(for: input)
        if fallbackOnly {
            printCandidates(fallback, label: "fallback")
            return
        }

        if let endpoint = ProcessInfo.processInfo.environment["SELF_CONVERT_ENDPOINT"], !endpoint.isEmpty {
            SelfConversionSettings.apiEndpoint = endpoint
        }
        if let timeout = ProcessInfo.processInfo.environment["SELF_CONVERT_TIMEOUT"].flatMap(Double.init), timeout > 0 {
            SelfConversionSettings.setRequestTimeout(timeout)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var finalCandidates = fallback
        let client = JapaneseConversionClient()
        client.convert(input, callbackQueue: .global()) { candidates in
            finalCandidates = candidates
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            printCandidates(fallback, label: "fallback-timeout")
            return
        }

        printCandidates(finalCandidates, label: "vmc")
    }

    private static func printCandidates(_ candidates: [JapaneseConversionCandidate], label: String) {
        let rows = candidates.map { candidate in
            [
                "text": candidate.text,
                "score": candidate.score,
            ] as [String: Any]
        }
        let root: [String: Any] = [
            "source": label,
            "candidates": rows,
        ]

        guard
            let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            print(root)
            return
        }
        print(text)
    }
}

private extension Array where Element == String {
    mutating func removeAll(_ option: String) -> Bool {
        let found = contains(option)
        self = filter { $0 != option }
        return found
    }
}
