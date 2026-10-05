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

import Foundation

/// Validates rule-level constraints so callers can surface issues before
/// persisting a rule that would silently produce wrong results at run time.
public enum RuleValidator {
    public struct Issue: Equatable {
        public let message: String
        public init(message: String) { self.message = message }
    }

    public static func validate(_ conditions: [Condition]) -> [Issue] {
        var seenTokens: Set<String> = []
        return conditions.compactMap { condition in
            if condition.value.trimmingCharacters(in: .whitespaces).isEmpty {
                return Issue(message: "Condition value cannot be empty")
            }
            if condition.operator == .matchesRegex,
               (try? NSRegularExpression(pattern: condition.value)) == nil {
                return Issue(message: "Regex pattern is invalid")
            }
            if condition.kind == .documentField {
                return documentFieldIssue(condition, seenTokens: &seenTokens)
            }
            return nil
        }
    }

    private static func documentFieldIssue(_ condition: Condition, seenTokens: inout Set<String>) -> Issue? {
        guard let spec = DocumentFieldSpec.decode(condition.value) else {
            return Issue(message: "Document field settings are invalid")
        }
        if spec.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return Issue(message: "Document field label cannot be empty")
        }
        guard DocumentFieldSpec.isValidTokenName(spec.token) else {
            return Issue(message: "Document field token must start with a letter and use only letters, digits, or _")
        }
        if DocumentFieldSpec.reservedTokens.contains(spec.token) {
            return Issue(message: "Document field token {\(spec.token)} is already a built-in rename token")
        }
        if !seenTokens.insert(spec.token).inserted {
            return Issue(message: "Document field token {\(spec.token)} is used more than once")
        }
        if !(0...1).contains(spec.minConfidence) {
            return Issue(message: "Document field minimum confidence must be between 0% and 100%")
        }
        return nil
    }

    public static func validate(_ actions: [Action]) -> [Issue] {
        actions.compactMap { action in
            switch action.kind {
            case .moveToFolder, .copyToFolder:
                if action.params[ActionParam.destination]?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                    return Issue(message: "Destination path cannot be empty")
                }
            case .rename:
                if action.params[ActionParam.pattern]?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                    return Issue(message: "Rename pattern cannot be empty")
                }
            case .addTag, .removeTag:
                if tags(in: action).isEmpty {
                    return Issue(message: "At least one tag is required")
                }
            case .openApplication:
                if action.params[ActionParam.applicationPath]?.stringValue?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                    return Issue(message: "Application cannot be empty")
                }
            default:
                break
            }
            return nil
        }
    }

    private static func tags(in action: Action) -> [String] {
        if let tags = action.params[ActionParam.tags]?.arrayValue {
            return tags.compactMap(\.stringValue)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        if let tag = action.params["tag"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tag.isEmpty {
            return [tag]
        }
        return []
    }
}
