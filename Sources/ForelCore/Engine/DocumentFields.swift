// Forel - A native macOS file-automation app
// Copyright (C) 2026  Lab421
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// Reads labeled values out of forms for the `document_field` condition.
//
// A document field is "the value printed next to (or under) a label", e.g.
// `Contract name: ACME` or a scanned form where the label sits on one line
// and the handwritten/typed value on the next. The condition matches when the
// value is found and looks like the configured type (text, person name,
// date), and the value is then available to the same rule's actions as a
// `{token}` — in Rename patterns and in Move/Copy's "Sort into subfolder".
//
// Forms are usually filled PDFs or scans whose values are not part of the
// text layer, so PDFs and images are read with on-device OCR, line by line,
// keeping Vision's confidence for each line. Labels are matched
// case- and accent-insensitively and tolerate small OCR mistakes (edit
// distance), the same way a person skims a form. Plain documents fall back
// to the `contents` extraction pipeline with full confidence.
//
// When nothing reliable is found the lookup says why (label missing, value
// isn't a date, OCR confidence too low…), which the Dry Run surfaces. Results
// are cached per file version so several field conditions — and the actions
// that use their tokens — only OCR a file once.

import Foundation
import CoreGraphics
import ImageIO
import PDFKit

// MARK: - Field definition

/// What kind of value a document field holds. Drives validation of the value
/// read next to the label, and how its token is rendered.
public enum DocumentFieldType: String, CaseIterable, Codable, Sendable {
    case text
    case personName = "person_name"
    case date

    public var label: String {
        switch self {
        case .text: return "Text"
        case .personName: return "Person name"
        case .date: return "Date"
        }
    }
}

/// The settings of one `document_field` condition, stored as JSON in the
/// condition's `value` so no schema migration is needed.
public struct DocumentFieldSpec: Codable, Equatable, Sendable {
    /// The label printed on the form, e.g. "Contract name".
    public var label: String
    /// Name used to reference the value in actions, e.g. `contract` → `{contract}`.
    public var token: String
    public var type: DocumentFieldType
    /// Other labels printed on the same form. A line that looks like one of
    /// them is never taken as this field's value (an empty field followed by
    /// the next label).
    public var otherLabels: [String]
    /// Minimum OCR confidence (0…1) for the value, unless the same value is
    /// also present in the PDF's text layer. 0 disables the check.
    public var minConfidence: Double

    public static let defaultMinConfidence = 0.8

    enum CodingKeys: String, CodingKey {
        case label
        case token
        case type
        case otherLabels = "other_labels"
        case minConfidence = "min_confidence"
    }

    public init(
        label: String = "",
        token: String = "",
        type: DocumentFieldType = .text,
        otherLabels: [String] = [],
        minConfidence: Double = DocumentFieldSpec.defaultMinConfidence
    ) {
        self.label = label
        self.token = token
        self.type = type
        self.otherLabels = otherLabels
        self.minConfidence = minConfidence
    }

    /// Tolerant decoding: missing keys fall back to defaults, so a rule saved
    /// by an older build (or edited by hand) still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        type = (try? container.decodeIfPresent(DocumentFieldType.self, forKey: .type)) ?? .text
        otherLabels = (try? container.decodeIfPresent([String].self, forKey: .otherLabels)) ?? []
        minConfidence = (try? container.decodeIfPresent(Double.self, forKey: .minConfidence)) ?? Self.defaultMinConfidence
    }

    /// Parses a condition value. `nil` when it isn't a field definition.
    public static func decode(_ value: String) -> DocumentFieldSpec? {
        guard let data = value.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DocumentFieldSpec.self, from: data)
    }

    /// Serializes to the condition value format (stable key order).
    public func encoded() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    /// Tokens the rename pattern already uses; a field can't shadow them.
    public static let reservedTokens: Set<String> = [
        "name", "extension", "date_created", "date_modified", "current_date", "size",
    ]

    /// Letters, digits and underscores, starting with a letter.
    public static func isValidTokenName(_ token: String) -> Bool {
        token.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil
    }

    /// Short human summary for the rule list, e.g. `“Contract name” → {contract}`.
    public var summary: String {
        let shownLabel = label.trimmingCharacters(in: .whitespaces).isEmpty ? "…" : label
        let shownToken = token.isEmpty ? "" : " → {\(token)}"
        return "“\(shownLabel)” (\(type.label.lowercased()))\(shownToken)"
    }
}

// MARK: - Lookup results

/// A calendar day read from a form, kept as plain numbers (no time zone).
public struct DocumentFieldDay: Equatable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    var date: Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: components)
    }
}

/// A value found next to a field's label.
public struct DocumentFieldValue: Equatable, Sendable {
    /// The value as read, with whitespace collapsed.
    public let text: String
    /// Set for `date` fields.
    public let day: DocumentFieldDay?
    /// OCR confidence (0…1); 1 for text read directly from the file.
    public let confidence: Double

    public init(text: String, day: DocumentFieldDay? = nil, confidence: Double) {
        self.text = text
        self.day = day
        self.confidence = confidence
    }

    /// The token's text. Dates default to `yyyy-MM-dd` (like the other date
    /// tokens) and accept a custom format: `{date:yyyyMMdd}`.
    public func rendered(format: String? = nil) -> String {
        guard let day, let date = day.date else { return text }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let trimmed = format?.trimmingCharacters(in: .whitespaces) ?? ""
        formatter.dateFormat = trimmed.isEmpty ? "yyyy-MM-dd" : trimmed
        return formatter.string(from: date)
    }
}

public enum DocumentFieldLookup: Equatable, Sendable {
    case found(DocumentFieldValue)
    /// `reason` is a short, plain-language explanation for the Dry Run.
    case notFound(reason: String)

    public var value: DocumentFieldValue? {
        if case .found(let value) = self { return value }
        return nil
    }
}

/// One recognized line of a document, top to bottom.
public struct DocumentTextLine: Equatable, Sendable {
    public let text: String
    public let confidence: Double

    public init(text: String, confidence: Double) {
        self.text = text
        self.confidence = confidence
    }
}

/// The readable lines of a file, plus its embedded text (the PDF text layer)
/// used to vouch for low-confidence OCR values.
public struct DocumentText: Sendable {
    public let lines: [DocumentTextLine]
    public let embeddedText: String
    public let strategy: ContentStrategy
    public let message: String?

    public init(lines: [DocumentTextLine], embeddedText: String = "", strategy: ContentStrategy, message: String? = nil) {
        self.lines = lines
        self.embeddedText = embeddedText
        self.strategy = strategy
        self.message = message
    }
}

// MARK: - Tokens for actions

/// Field values a rule's conditions read from one file, for its actions.
/// `declared` holds every token the rule defines, found or not, so an action
/// can refuse to run with a missing value instead of writing `{token}`
/// literally into a file or folder name.
public struct DocumentFieldTokens: Equatable, Sendable {
    public var values: [String: DocumentFieldValue]
    public var declared: Set<String>

    public init(values: [String: DocumentFieldValue] = [:], declared: Set<String> = []) {
        self.values = values
        self.declared = declared
    }

    public static let none = DocumentFieldTokens()

    private static let placeholderPattern = #"\{([A-Za-z][A-Za-z0-9_]*)(?::([^{}]*))?\}"#

    /// Replaces `{token}` and `{token:format}` placeholders of declared fields
    /// with their (sanitized) values. Placeholders that aren't fields — the
    /// built-in rename tokens, or literal braces — are left untouched.
    /// Throws when a declared field wasn't found in this file, or its value
    /// is empty once made safe for a file name.
    public func substitute(_ template: String) throws -> String {
        guard !declared.isEmpty, template.contains("{"),
              let regex = try? NSRegularExpression(pattern: Self.placeholderPattern) else {
            return template
        }
        let result = NSMutableString(string: template)
        let matches = regex.matches(in: template, range: NSRange(template.startIndex..., in: template))
        // Back to front, so earlier ranges stay valid as later ones change length.
        for match in matches.reversed() {
            guard let nameRange = Range(match.range(at: 1), in: template) else { continue }
            let name = String(template[nameRange])
            guard declared.contains(name) else { continue }
            guard let value = values[name] else {
                throw ActionError("Document field {\(name)} was not found in this file")
            }
            let format = Range(match.range(at: 2), in: template).map { String(template[$0]) }
            let safe = DocumentFieldParser.safeFileNameComponent(value.rendered(format: format))
            if safe.isEmpty {
                throw ActionError("Document field {\(name)} is empty once made safe for a file name")
            }
            result.replaceCharacters(in: match.range, with: safe)
        }
        return result as String
    }
}

// MARK: - Parsing (pure)

/// Text matching used by field lookup. Pure functions, unit-tested directly.
enum DocumentFieldParser {
    /// A line is taken as the field's label at this similarity…
    static let labelThreshold = 0.78
    /// …and a candidate value is rejected as "another label" at this one.
    static let otherLabelThreshold = 0.86
    /// How many lines after the label may hold its value.
    static let valueLookahead = 3

    /// Case- and accent-insensitive form used for comparisons.
    static func folded(_ value: String) -> String {
        compact(value)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .lowercased()
    }

    /// Collapses runs of whitespace (including newlines) and trims.
    static func compact(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func levenshtein(_ left: String, _ right: String) -> Int {
        let a = Array(left)
        let b = Array(right)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for (i, lhs) in a.enumerated() {
            var current = [i + 1]
            for (j, rhs) in b.enumerated() {
                current.append(min(
                    current[j] + 1,
                    previous[j + 1] + 1,
                    previous[j] + (lhs == rhs ? 0 : 1)
                ))
            }
            previous = current
        }
        return previous[b.count]
    }

    /// How much `line` looks like `label` (0…1). 1 when the line contains the
    /// label; otherwise the edit-distance similarity of the line's start,
    /// which tolerates OCR mistakes ("Nombre de1 contrato").
    static func labelScore(_ line: String, label: String) -> Double {
        let normalizedLabel = folded(label)
        guard !normalizedLabel.isEmpty else { return 0 }
        let normalized = folded(line)
        if normalized.contains(normalizedLabel) { return 1.0 }
        let prefix = String(normalized.prefix(normalizedLabel.count + 12))
        let distance = levenshtein(prefix, normalizedLabel)
        return 1.0 - Double(distance) / Double(max(prefix.count, normalizedLabel.count, 1))
    }

    static func looksLikeLabel(_ value: String, labels: [String]) -> Bool {
        labels.contains { labelScore(value, label: $0) >= otherLabelThreshold }
    }

    /// Strips separators that commonly sit between a label and its value.
    static func trimmedValue(_ value: String) -> String {
        compact(value).trimmingCharacters(in: CharacterSet(charactersIn: ":：-–—=|.").union(.whitespaces))
    }

    /// The value printed after `label`: the rest of the label's own line, or
    /// the first of the next few lines that isn't empty or another label.
    static func valueAfterLabel(_ lines: [DocumentTextLine], label: String, otherLabels: [String]) -> (text: String, confidence: Double)? {
        let foldedLabel = folded(label)
        for index in lines.indices where labelScore(lines[index].text, label: label) >= labelThreshold {
            let original = compact(lines[index].text)
            let normalized = folded(original)
            if let range = normalized.range(of: foldedLabel) {
                let offset = normalized.distance(from: normalized.startIndex, to: range.upperBound)
                if offset < original.count {
                    let split = original.index(original.startIndex, offsetBy: offset)
                    let tail = trimmedValue(String(original[split...]))
                    if !tail.isEmpty && !looksLikeLabel(tail, labels: otherLabels) {
                        return (tail, lines[index].confidence)
                    }
                }
            }
            let upper = min(index + 1 + valueLookahead, lines.count)
            guard index + 1 < upper else { continue }
            for candidate in lines[(index + 1)..<upper] {
                let value = trimmedValue(candidate.text)
                if value.isEmpty || looksLikeLabel(value, labels: otherLabels) { continue }
                return (value, min(lines[index].confidence, candidate.confidence))
            }
        }
        return nil
    }

    /// The first valid date on the label's line or the next few lines.
    /// Day-first (`31/12/2026`), switching to month-first only when the
    /// second number can't be a month (`12/31/2026`). Two-digit years are 20xx.
    static func dateAfterLabel(_ lines: [DocumentTextLine], label: String) -> (day: DocumentFieldDay, raw: String, confidence: Double)? {
        for index in lines.indices where labelScore(lines[index].text, label: label) >= labelThreshold {
            let upper = min(index + 1 + valueLookahead, lines.count)
            for valueIndex in index..<upper {
                guard let parsed = parseDay(in: lines[valueIndex].text) else { continue }
                return (parsed.day, parsed.raw, min(lines[index].confidence, lines[valueIndex].confidence))
            }
        }
        return nil
    }

    static func parseDay(in text: String) -> (day: DocumentFieldDay, raw: String)? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(\d{1,2})[./-](\d{1,2})[./-](\d{2,4})\b"#) else { return nil }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let wholeRange = Range(match.range, in: text),
                  let firstRange = Range(match.range(at: 1), in: text),
                  let secondRange = Range(match.range(at: 2), in: text),
                  let yearRange = Range(match.range(at: 3), in: text),
                  let first = Int(text[firstRange]),
                  let second = Int(text[secondRange]),
                  var year = Int(text[yearRange]) else { continue }
            if year < 100 { year += 2000 }
            var day = first
            var month = second
            if first <= 12 && second > 12 {
                day = second
                month = first
            }
            // Reject impossible dates (31/02) instead of letting the calendar roll them over.
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            guard let date = calendar.date(from: components) else { continue }
            let verified = calendar.dateComponents([.year, .month, .day], from: date)
            guard verified.year == year, verified.month == month, verified.day == day else { continue }
            return (DocumentFieldDay(year: year, month: month, day: day), String(text[wholeRange]))
        }
        return nil
    }

    /// At least two words, with letters, no e-mail address, reasonable length.
    static func isValidPersonName(_ value: String) -> Bool {
        let text = compact(value)
        return text.count >= 5 && text.count <= 120 && text.contains(" ") && !text.contains("@")
            && text.rangeOfCharacter(from: .letters) != nil
    }

    /// A short value with at least one letter — so a stray phone number or
    /// ID printed further down an empty field isn't taken for its value.
    static func isValidText(_ value: String) -> Bool {
        let text = compact(value)
        return text.count >= 2 && text.count <= 120 && text.rangeOfCharacter(from: .letters) != nil
    }

    /// Makes a value usable as one file or folder name component: no path
    /// separators, colons or control characters, no leading/trailing dots or
    /// spaces (which macOS strips or rejects).
    static func safeFileNameComponent(_ value: String) -> String {
        var result = compact(value)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
        result = result.replacingOccurrences(of: #"[\\\x00-\x1f]"#, with: "-", options: .regularExpression)
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    }

    /// Finds `spec`'s value in already-extracted text.
    static func lookup(_ spec: DocumentFieldSpec, in document: DocumentText, otherLabels: [String]) -> DocumentFieldLookup {
        let label = spec.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return .notFound(reason: "The field has no label.") }
        guard !document.lines.isEmpty else {
            return .notFound(reason: document.message ?? "No readable text.")
        }
        guard document.lines.contains(where: { labelScore($0.text, label: label) >= labelThreshold }) else {
            return .notFound(reason: "Label “\(label)” not found.")
        }

        let raw: String
        let value: DocumentFieldValue
        switch spec.type {
        case .date:
            guard let found = dateAfterLabel(document.lines, label: label) else {
                return .notFound(reason: "No valid date after “\(label)”.")
            }
            raw = found.raw
            value = DocumentFieldValue(
                text: String(format: "%04d-%02d-%02d", found.day.year, found.day.month, found.day.day),
                day: found.day,
                confidence: found.confidence
            )
        case .text, .personName:
            // The field's own label counts as "another label" too: a
            // repeated label line is never its own value.
            guard let found = valueAfterLabel(document.lines, label: label, otherLabels: otherLabels + [label]) else {
                return .notFound(reason: "No value after “\(label)”.")
            }
            if spec.type == .personName, !isValidPersonName(found.text) {
                return .notFound(reason: "“\(found.text)” doesn't look like a person's name.")
            }
            if spec.type == .text, !isValidText(found.text) {
                return .notFound(reason: "“\(found.text)” is not a usable value.")
            }
            raw = found.text
            value = DocumentFieldValue(text: found.text, confidence: found.confidence)
        }

        let vouchedByEmbeddedText = !document.embeddedText.isEmpty
            && folded(document.embeddedText).contains(folded(raw))
        if spec.minConfidence > 0, value.confidence < spec.minConfidence, !vouchedByEmbeddedText {
            let read = Int((value.confidence * 100).rounded())
            let needed = Int((spec.minConfidence * 100).rounded())
            return .notFound(reason: "Read “\(value.text)” with \(read)% confidence (needs \(needed)%).")
        }
        return .found(value)
    }
}

// MARK: - Extraction (file system, OCR)

public enum DocumentFieldExtractor {
    /// Forms carry their fields up front; OCR beyond this is wasted time.
    static let maxPDFPages = 2
    /// Higher than the `contents` OCR scale: small form print needs it.
    static let pdfRenderScale: CGFloat = 2.5

    private static let cache = DocumentTextCache()

    /// Looks up one field in the file at `path`.
    public static func lookup(_ spec: DocumentFieldSpec, otherLabels: [String] = [], path: String) -> DocumentFieldLookup {
        DocumentFieldParser.lookup(spec, in: documentText(path: path), otherLabels: otherLabels)
    }

    /// Labels of the other field conditions in `conditions` plus `spec`'s own
    /// "other labels" — none of them can be `spec`'s value.
    public static func otherLabels(for spec: DocumentFieldSpec, siblings conditions: [Condition]) -> [String] {
        let siblingLabels = conditions
            .filter { $0.kind == .documentField }
            .compactMap { DocumentFieldSpec.decode($0.value)?.label }
            .filter { DocumentFieldParser.folded($0) != DocumentFieldParser.folded(spec.label) }
        return (spec.otherLabels + siblingLabels)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The values of every document field `conditions` define, read from
    /// `path`, for the rule's actions.
    public static func tokens(for conditions: [Condition], path: String) -> DocumentFieldTokens {
        var tokens = DocumentFieldTokens()
        for condition in conditions where condition.kind == .documentField {
            guard let spec = DocumentFieldSpec.decode(condition.value),
                  DocumentFieldSpec.isValidTokenName(spec.token) else { continue }
            tokens.declared.insert(spec.token)
            if tokens.values[spec.token] == nil,
               let value = lookup(spec, otherLabels: otherLabels(for: spec, siblings: conditions), path: path).value {
                tokens.values[spec.token] = value
            }
        }
        return tokens
    }

    /// The file's lines, from OCR for PDFs and images and from the `contents`
    /// pipeline otherwise. Cached per path, size and modification date.
    public static func documentText(path: String) -> DocumentText {
        let key = cacheKey(path)
        if let key, let cached = cache.value(for: key) { return cached }
        let text = readDocumentText(path: path)
        if let key { cache.store(text, for: key) }
        return text
    }

    private static func readDocumentText(path: String) -> DocumentText {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "pdf" {
            return readPDF(path: path)
        }
        if ContentExtractor.imageExtensions.contains(ext) {
            return readImage(path: path)
        }
        let extraction = ContentExtractor.extract(path: path)
        guard let text = extraction.text else {
            return DocumentText(lines: [], strategy: extraction.strategy, message: extraction.message)
        }
        return DocumentText(lines: lines(from: text), embeddedText: text, strategy: extraction.strategy)
    }

    private static func readPDF(path: String) -> DocumentText {
        if fileSize(path) > ContentExtractor.pdfMaxBytes {
            return DocumentText(lines: [], strategy: .none, message: "PDF exceeds the 100 MB limit.")
        }
        guard let document = PDFDocument(url: URL(fileURLWithPath: path)) else {
            return DocumentText(lines: [], strategy: .none, message: "Could not open PDF.")
        }
        let pageCount = min(document.pageCount, maxPDFPages)
        var ocrLines: [DocumentTextLine] = []
        var embedded: [String] = []
        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }
            if let text = page.string { embedded.append(text) }
            if let image = ContentExtractor.renderPDFPage(page, scale: pdfRenderScale),
               let recognized = ContentExtractor.recognizeLines(in: image) {
                ocrLines.append(contentsOf: recognized)
            }
        }
        let embeddedText = embedded.joined(separator: "\n")
        if !ocrLines.isEmpty {
            return DocumentText(lines: ocrLines, embeddedText: embeddedText, strategy: .pdfOCR)
        }
        // OCR unavailable or found nothing: the text layer is still worth a try.
        let textLines = lines(from: embeddedText)
        if !textLines.isEmpty {
            return DocumentText(lines: textLines, embeddedText: embeddedText, strategy: .pdfText)
        }
        return DocumentText(lines: [], strategy: .none, message: "PDF has no readable text.")
    }

    private static func readImage(path: String) -> DocumentText {
        if fileSize(path) > ContentExtractor.ocrImageMaxBytes {
            return DocumentText(lines: [], strategy: .none, message: "Image exceeds the 25 MB OCR limit.")
        }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return DocumentText(lines: [], strategy: .none, message: "Could not open image.")
        }
        if image.width > ContentExtractor.ocrMaxDimension || image.height > ContentExtractor.ocrMaxDimension {
            return DocumentText(lines: [], strategy: .none, message: "Image is too large for OCR.")
        }
        guard let recognized = ContentExtractor.recognizeLines(in: image), !recognized.isEmpty else {
            return DocumentText(lines: [], strategy: .none, message: "No text found in image.")
        }
        return DocumentText(lines: recognized, strategy: .imageOCR)
    }

    private static func lines(from text: String) -> [DocumentTextLine] {
        text.components(separatedBy: .newlines)
            .map { DocumentFieldParser.compact($0) }
            .filter { !$0.isEmpty }
            .map { DocumentTextLine(text: $0, confidence: 1) }
    }

    private static func fileSize(_ path: String) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? UInt64) ?? 0
    }

    private static func cacheKey(_ path: String) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date else { return nil }
        let size = (attrs[.size] as? UInt64) ?? 0
        return "\(path)|\(size)|\(modified.timeIntervalSince1970)"
    }
}

/// Small most-recently-used cache of extracted documents. Rules are evaluated
/// one file at a time, so a handful of entries is enough to share one OCR
/// pass between a rule's field conditions, its Dry Run, and its actions.
private final class DocumentTextCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(key: String, text: DocumentText)] = []
    private let capacity = 8

    func value(for key: String) -> DocumentText? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.key == key }) else { return nil }
        let entry = entries.remove(at: index)
        entries.append(entry)
        return entry.text
    }

    func store(_ text: DocumentText, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.key == key }
        entries.append((key, text))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }
}
