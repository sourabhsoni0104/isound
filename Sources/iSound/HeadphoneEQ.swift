import Combine
import Foundation

/// Headphone correction profiles from the AutoEq project (thousands of models).
final class HeadphoneEQLibrary: ObservableObject {
    struct Entry: Identifiable, Hashable {
        let id: String      // path inside AutoEq/results
        let name: String
        let source: String  // who measured it
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    private static let base = "https://raw.githubusercontent.com/jaakkopasanen/AutoEq/master/results/"
    private static let cache = Store.directory.appendingPathComponent("autoeq-index.md")

    func loadIndex() {
        guard entries.isEmpty, !loading else { return }
        if let text = try? String(contentsOf: Self.cache, encoding: .utf8) {
            entries = Self.parse(text)
            if !entries.isEmpty { return }
        }
        loading = true
        error = nil
        URLSession.shared.dataTask(with: URL(string: Self.base + "INDEX.md")!) { [weak self] data, _, err in
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading = false
                guard let data, let text = String(data: data, encoding: .utf8) else {
                    self.error = err?.localizedDescription ?? "Couldn't download the headphone list"
                    return
                }
                try? data.write(to: Self.cache)
                self.entries = Self.parse(text)
            }
        }.resume()
    }

    /// "- [Apple AirPods Pro](./crinacle/711%20in-ear/Apple%20AirPods%20Pro) by crinacle on 711"
    static func parse(_ text: String) -> [Entry] {
        text.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("- ["), let close = line.range(of: "]("), let end = line.range(of: ")", range: close.upperBound..<line.endIndex) else { return nil }
            let name = String(line[line.index(line.startIndex, offsetBy: 3)..<close.lowerBound])
            var path = String(line[close.upperBound..<end.lowerBound])
            if path.hasPrefix("./") { path.removeFirst(2) }
            let source = line[end.upperBound...].replacingOccurrences(of: " by ", with: "").trimmingCharacters(in: .whitespaces)
            return Entry(id: path, name: name, source: source)
        }
    }

    func setEntriesForTesting(_ e: [Entry]) { entries = e }

    func search(_ query: String) -> [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return Array(entries.prefix(200)) }
        let words = q.split(separator: " ")
        return Array(entries.filter { e in words.allSatisfy { e.name.lowercased().contains($0) } }.prefix(200))
    }

    func fetch(_ entry: Entry, completion: @escaping (ParametricEQ?) -> Void) {
        let folder = entry.id.removingPercentEncoding ?? entry.id
        let file = "\(folder)/\(entry.name) ParametricEQ.txt"
        guard let encoded = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: Self.base + encoded) else { completion(nil); return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            let eq = data.flatMap { String(data: $0, encoding: .utf8) }.flatMap { FilterFileParser.parse($0, name: entry.name) }
            DispatchQueue.main.async { completion(eq) }
        }.resume()
    }
}
