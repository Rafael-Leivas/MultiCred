import Foundation

/// Keyword matching over the guide. Deliberately simple and deterministic:
/// no embeddings, no network. Accents, case and a trailing plural "s" are ignored.
enum GuideSearch {
    private static let stopwords: Set<String> = [
        "a", "o", "as", "os", "um", "uma", "de", "do", "da", "dos", "das", "no", "na", "nos", "nas",
        "em", "e", "ou", "que", "para", "pra", "por", "com", "sem", "como", "eu", "meu", "minha",
        "meus", "minhas", "quero", "queria", "preciso", "tenho", "onde", "qual", "esta", "estao", "ao",
        "se", "me", "isso", "isto", "ele", "ela", "ja", "mais", "ser", "fazer", "faco",
    ]

    static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR")).lowercased()
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && !stopwords.contains($0) }
            .map { $0.count > 3 && $0.hasSuffix("s") ? String($0.dropLast()) : $0 }
    }

    static func score(_ entry: Guide.Entry, query: [String]) -> Double {
        guard !query.isEmpty else { return 0 }
        let querySet = Set(query)
        let joinedQuery = " " + query.joined(separator: " ") + " "
        var score = 0.0
        // Unique tokens, so an entry with many synonyms does not beat a closer one.
        var keywordTokens = Set<String>()
        var phrase = false
        for keyword in entry.keywords {
            let words = tokens(keyword)
            keywordTokens.formUnion(words)
            if words.count > 1, joinedQuery.contains(" " + words.joined(separator: " ") + " ") { phrase = true }
        }
        if phrase { score += 5 }
        score += Double(querySet.intersection(keywordTokens).count) * 2
        score += Double(querySet.intersection(tokens(entry.title)).count) * 2
        score += Double(querySet.intersection(tokens(entry.id)).count)
        return score
    }

    /// Entries ranked best first; entries scoring under `minimum` are dropped.
    static func rank(_ entries: [Guide.Entry], for text: String, minimum: Double = 4) -> [Guide.Entry] {
        let query = tokens(text)
        return entries
            .enumerated()
            .map { (index: $0.offset, entry: $0.element, score: score($0.element, query: query)) }
            .filter { $0.score >= minimum }
            .sorted { ($0.score, -$0.index) > ($1.score, -$1.index) }
            .map(\.entry)
    }
}
