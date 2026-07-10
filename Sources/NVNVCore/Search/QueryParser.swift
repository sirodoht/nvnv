import Foundation

public struct SearchQuery: Equatable, Sendable {
    public struct Term: Equatable, Sendable {
        public let value: String
        public let isPhrase: Bool

        public init(value: String, isPhrase: Bool) {
            self.value = value
            self.isPhrase = isPhrase
        }
    }

    public let rawValue: String
    public let terms: [Term]

    public init(_ rawValue: String) {
        self.rawValue = rawValue
        self.terms = QueryParser.parse(rawValue)
    }

    public var isEmpty: Bool { terms.isEmpty }
}

public enum QueryParser {
    public static func parse(_ input: String) -> [SearchQuery.Term] {
        var terms: [SearchQuery.Term] = []
        var current = ""
        var quoted = false
        var escaping = false

        func appendCurrent(phrase: Bool) {
            guard !current.isEmpty else { return }
            terms.append(.init(value: current, isPhrase: phrase))
            current = ""
        }

        for scalar in input.unicodeScalars {
            if quoted {
                if escaping {
                    if scalar == "\"" || scalar == "\\" { current.unicodeScalars.append(scalar) }
                    else {
                        current.append("\\")
                        current.unicodeScalars.append(scalar)
                    }
                    escaping = false
                } else if scalar == "\\" {
                    escaping = true
                } else if scalar == "\"" {
                    appendCurrent(phrase: true)
                    quoted = false
                } else {
                    current.unicodeScalars.append(scalar)
                }
            } else if scalar == "\"" {
                appendCurrent(phrase: false)
                quoted = true
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                appendCurrent(phrase: false)
            } else {
                current.unicodeScalars.append(scalar)
            }
        }
        if escaping { current.append("\\") }
        appendCurrent(phrase: quoted)
        return terms
    }
}
