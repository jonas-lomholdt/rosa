import Foundation

/// Converts Adblock Plus / EasyList filter syntax into WebKit content-blocker JSON
/// (`WKContentRuleList`). Supports the common subset: network rules (`||domain^`, `|`, `*`, `^`),
/// the usual `$` options, `@@` exceptions, `@@…$document` site exceptions and `##` element hiding.
/// Anything else (regex rules, procedural cosmetics, scriptlets, redirects, …) is skipped.
enum FilterListConverter {
    /// Bump when conversion output changes, so cached compiled lists are rebuilt.
    static let version = 1

    /// WebKit refuses lists above 150k rules.
    static let maxRules = 145_000

    struct Result: Sendable {
        let json: String
        let ruleCount: Int
        let skipped: Int
    }

    static func convert(_ text: String) -> Result {
        var blockRules: [[String: Any]] = []
        var exceptionRules: [[String: Any]] = []
        var genericSelectors: [String] = []
        var specificSelectors: [String: [String]] = [:]
        var skipped = 0

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }

            if let separator = line.range(of: "##") {
                let domains = String(line[..<separator.lowerBound])
                let selector = String(line[separator.upperBound...])
                guard isSupportedSelector(selector), !domains.contains("#") else { skipped += 1; continue }
                if domains.isEmpty {
                    genericSelectors.append(selector)
                } else {
                    specificSelectors[domains, default: []].append(selector)
                }
                continue
            }
            // Other cosmetic syntaxes: exceptions (#@#), procedural (#?#), CSS injection (#$#), scriptlets (#%#).
            if line.range(of: #"#[@?$%]+#"#, options: .regularExpression) != nil {
                skipped += 1
                continue
            }

            guard let rule = networkRule(line) else { skipped += 1; continue }
            if rule.isException {
                exceptionRules.append(rule.json)
            } else {
                blockRules.append(rule.json)
            }
        }

        var cosmeticRules: [[String: Any]] = []
        for chunk in genericSelectors.chunked(into: 50) {
            cosmeticRules.append(hideRule(chunk, trigger: ["url-filter": ".*"]))
        }
        for (domains, selectors) in specificSelectors.sorted(by: { $0.key < $1.key }) {
            guard case .condition(let key, let values) = domainCondition(domains.split(separator: ",")) else {
                skipped += selectors.count
                continue
            }
            for chunk in selectors.chunked(into: 50) {
                cosmeticRules.append(hideRule(chunk, trigger: ["url-filter": ".*", key: values]))
            }
        }

        // Exceptions (ignore-previous-rules) must come after the rules they override.
        var rules = blockRules + cosmeticRules + exceptionRules
        if rules.count > maxRules {
            skipped += rules.count - maxRules
            rules = Array(blockRules.prefix(maxRules - cosmeticRules.count - exceptionRules.count))
                + cosmeticRules + exceptionRules
        }

        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return Result(json: String(decoding: data, as: UTF8.self), ruleCount: rules.count, skipped: skipped)
    }

    // MARK: - Network rules

    private static let allResourceTypes: Set<String> = [
        "document", "image", "style-sheet", "script", "font", "raw", "svg-document", "media", "popup", "ping",
    ]

    private static let resourceTypes: [String: Set<String>] = [
        "script": ["script"],
        "image": ["image"],
        "stylesheet": ["style-sheet"],
        "font": ["font"],
        "media": ["media"],
        "object": ["raw"],
        "xmlhttprequest": ["raw"],
        "xhr": ["raw"],
        "websocket": ["raw"],
        "other": ["raw"],
        "ping": ["ping"],
        "beacon": ["ping"],
        "subdocument": ["document"],
        "frame": ["document"],
        "popup": ["popup"],
    ]

    private static func networkRule(_ line: String) -> (json: [String: Any], isException: Bool)? {
        var text = Substring(line)
        let isException = text.hasPrefix("@@")
        if isException { text = text.dropFirst(2) }

        var pattern = String(text)
        var options: [Substring] = []
        if let dollar = pattern.lastIndex(of: "$"), dollar != pattern.startIndex || pattern.count > 1 {
            options = pattern[pattern.index(after: dollar)...].split(separator: ",")
            pattern = String(pattern[..<dollar])
        }
        // Regex rules (/…/) use syntax WebKit's matcher doesn't support.
        if pattern.count > 1, pattern.hasPrefix("/"), pattern.hasSuffix("/") { return nil }

        var trigger: [String: Any] = [:]
        var types = Set<String>()
        var excludedTypes = Set<String>()
        var isDocumentException = false

        for rawOption in options {
            var option = rawOption.lowercased()
            let negated = option.hasPrefix("~")
            if negated { option.removeFirst() }

            switch option {
            case "third-party", "3p":
                trigger["load-type"] = [negated ? "first-party" : "third-party"]
            case "first-party", "1p", "~third-party":
                trigger["load-type"] = [negated ? "third-party" : "first-party"]
            case "match-case":
                trigger["url-filter-is-case-sensitive"] = true
            case "important":
                break
            case "document", "doc":
                guard !negated else { return nil }
                if isException { isDocumentException = true } else { types.insert("document") }
            default:
                if option.hasPrefix("domain=") || option.hasPrefix("from=") {
                    let value = option.split(separator: "=", maxSplits: 1).last ?? ""
                    switch domainCondition(value.split(separator: "|")) {
                    case .invalid: return nil
                    case .none: break
                    case .condition(let key, let values): trigger[key] = values
                    }
                } else if let mapped = resourceTypes[option] {
                    if negated { excludedTypes.formUnion(mapped) } else { types.formUnion(mapped) }
                } else {
                    // csp, redirect, removeparam, generichide, elemhide, popunder, … aren't expressible.
                    return nil
                }
            }
        }

        if isDocumentException {
            // "@@||example.com^$document" turns blocking off on that whole site.
            guard let host = plainHost(in: pattern) else { return nil }
            return (["trigger": ["url-filter": ".*", "if-domain": ["*" + host]], "action": ["type": "ignore-previous-rules"]], true)
        }

        guard let urlFilter = regex(fromPattern: pattern) else { return nil }
        trigger["url-filter"] = urlFilter
        if types.isEmpty, !excludedTypes.isEmpty { types = allResourceTypes.subtracting(excludedTypes) }
        if !types.isEmpty { trigger["resource-type"] = types.sorted() }

        let action = isException ? "ignore-previous-rules" : "block"
        return (["trigger": trigger, "action": ["type": action]], isException)
    }

    /// Adblock pattern → the regex subset WebKit supports (no alternation, no counted repetition).
    static func regex(fromPattern rawPattern: String) -> String? {
        var pattern = Substring(rawPattern)
        guard pattern.allSatisfy(\.isASCII) else { return nil }
        if pattern.isEmpty || pattern == "*" { return ".*" }

        var result = ""
        if pattern.hasPrefix("||") {
            result = "^[^:]+://+([^:/]+\\.)?"
            pattern = pattern.dropFirst(2)
        } else if pattern.hasPrefix("|") {
            result = "^"
            pattern = pattern.dropFirst()
        }
        var anchoredEnd = false
        if pattern.hasSuffix("|") {
            anchoredEnd = true
            pattern = pattern.dropLast()
        }

        for character in pattern {
            switch character {
            case "*": result += ".*"
            case "^": result += "[^a-zA-Z0-9_.%-]"
            case ".", "+", "?", "$", "(", ")", "[", "]", "\\": result += "\\" + String(character)
            case "{", "}", "|": return nil
            default: result.append(character)
            }
        }
        if anchoredEnd { result += "$" }
        return result.isEmpty ? nil : result
    }

    /// "||example.com^" → "example.com"; nil for anything that isn't a bare host pattern.
    private static func plainHost(in pattern: String) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        var host = pattern.dropFirst(2)
        if host.hasSuffix("^") { host = host.dropLast() }
        let value = host.lowercased()
        return isValidDomain(value) ? value : nil
    }

    // MARK: - Domains & cosmetics

    private enum DomainCondition {
        case none
        case invalid
        case condition(key: String, values: [String])
    }

    /// WebKit can't mix if-domain and unless-domain in one trigger, so positive domains win.
    private static func domainCondition(_ domains: [Substring]) -> DomainCondition {
        var include: [String] = []
        var exclude: [String] = []
        for raw in domains {
            let domain = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if domain.isEmpty { continue }
            if domain.hasPrefix("~") {
                exclude.append(String(domain.dropFirst()))
            } else {
                include.append(domain)
            }
        }
        if !include.isEmpty {
            guard include.allSatisfy(isValidDomain) else { return .invalid }
            return .condition(key: "if-domain", values: include.map { "*" + $0 })
        }
        if !exclude.isEmpty {
            guard exclude.allSatisfy(isValidDomain) else { return .invalid }
            return .condition(key: "unless-domain", values: exclude.map { "*" + $0 })
        }
        return .none
    }

    private static func isValidDomain(_ domain: String) -> Bool {
        !domain.isEmpty && domain.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") }
    }

    /// Plain CSS only: no procedural/extended pseudo-classes, scriptlets or HTML filters.
    private static func isSupportedSelector(_ selector: String) -> Bool {
        guard !selector.isEmpty, selector.allSatisfy(\.isASCII),
              !selector.hasPrefix("+"), !selector.hasPrefix("^") else { return false }
        let unsupported = [
            ":-abp-", ":has(", ":has-text(", ":contains(", ":xpath(", ":style(", ":matches-", ":upward(",
            ":remove(", ":min-text-length(", ":watch-attr(", ":others(", ":if(", ":if-not(", "[-ext-",
        ]
        return !unsupported.contains { selector.contains($0) }
    }

    private static func hideRule(_ selectors: [String], trigger: [String: Any]) -> [String: Any] {
        ["trigger": trigger, "action": ["type": "css-display-none", "selector": selectors.joined(separator: ", ")]]
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
