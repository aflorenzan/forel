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

import Testing
import Foundation
@testable import ForelCore

/// A filled form as OCR (or a text export) reads it: labels on their own
/// line with the value under them, or `Label: value` on one line, with the
/// accents and capitalization of the printed form.
private let filledForm = """
SOLICITUD ACCESO VPN TERCEROS
Fecha Solicitud
15/03/2026
Nombre usuario que utilizará el acceso
Juan Pérez Gómez
Nombre del contrato: ACME Servicios / Soporte
Teléfono
809-555-0101
"""

private let dateField = DocumentFieldSpec(label: "fecha solicitud", token: "fecha", type: .date)
private let userField = DocumentFieldSpec(label: "nombre usuario que utilizara el acceso", token: "usuario", type: .personName)
private let contractField = DocumentFieldSpec(label: "nombre del contrato", token: "contrato", type: .text, otherLabels: ["Teléfono"])

private func fieldCondition(_ spec: DocumentFieldSpec, _ op: Operator = .isFound) -> Condition {
    makeCondition(.documentField, op, spec.encoded())
}

private func lines(_ text: String, confidence: Double = 1) -> [DocumentTextLine] {
    text.components(separatedBy: "\n").map { DocumentTextLine(text: $0, confidence: confidence) }
}

@Suite struct DocumentFieldsTests {
    // MARK: - Field definition

    @Test func specRoundTripsThroughTheConditionValue() {
        let spec = DocumentFieldSpec(label: "Cargo/Puesto", token: "cargo", type: .text, otherLabels: ["Teléfono"], minConfidence: 0.5)
        #expect(DocumentFieldSpec.decode(spec.encoded()) == spec)
        #expect(spec.encoded().contains("Cargo/Puesto"), "slashes stay readable in the stored value")
    }

    @Test func specDecodingFallsBackToDefaultsAndRejectsNonJSON() {
        let spec = DocumentFieldSpec.decode(#"{"label":"Contract"}"#)
        #expect(spec == DocumentFieldSpec(label: "Contract"))
        #expect(spec?.minConfidence == DocumentFieldSpec.defaultMinConfidence)
        #expect(DocumentFieldSpec.decode("Contract") == nil)
    }

    @Test func tokenNamesMustBeIdentifiers() {
        #expect(DocumentFieldSpec.isValidTokenName("contract_2"))
        #expect(!DocumentFieldSpec.isValidTokenName("2contract"))
        #expect(!DocumentFieldSpec.isValidTokenName("contract name"))
        #expect(!DocumentFieldSpec.isValidTokenName(""))
    }

    // MARK: - Label matching

    @Test func labelsMatchIgnoringCaseAccentsAndSmallOCRMistakes() {
        #expect(DocumentFieldParser.labelScore("NOMBRE USUARIO QUE UTILIZARÁ EL ACCESO", label: "nombre usuario que utilizara el acceso") == 1)
        #expect(DocumentFieldParser.labelScore("Nombre de1 contrat0", label: "Nombre del contrato") >= DocumentFieldParser.labelThreshold)
        #expect(DocumentFieldParser.labelScore("Teléfono", label: "Nombre del contrato") < DocumentFieldParser.labelThreshold)
    }

    @Test func valueIsReadFromTheLabelLineOrTheLinesBelowIt() {
        let form = lines(filledForm)
        #expect(DocumentFieldParser.valueAfterLabel(form, label: "nombre del contrato", otherLabels: [])?.text == "ACME Servicios / Soporte")
        #expect(DocumentFieldParser.valueAfterLabel(form, label: "nombre usuario que utilizara el acceso", otherLabels: [])?.text == "Juan Pérez Gómez")
    }

    @Test func fuzzyLabelTakesTheValueOnTheNextLine() {
        let form = lines("Nombre de1 contrat0\nACME")
        #expect(DocumentFieldParser.valueAfterLabel(form, label: "nombre del contrato", otherLabels: [])?.text == "ACME")
    }

    @Test func anotherLabelIsNeverTakenAsTheValueOfAnEmptyField() {
        let form = lines("Nombre usuario que utilizará el acceso\nDocumento de identidad\n001-1234567-8")
        let document = DocumentText(lines: form, strategy: .plainText)

        // Without knowing the form's other labels, the next label looks like a name…
        #expect(DocumentFieldParser.lookup(userField, in: document, otherLabels: []).value?.text == "Documento de identidad")
        // …with them, it's skipped and the field is correctly reported as missing.
        let lookup = DocumentFieldParser.lookup(userField, in: document, otherLabels: ["documento de identidad"])
        #expect(lookup.value == nil)
    }

    // MARK: - Dates

    @Test func datesAreDayFirstUnlessTheSecondNumberCannotBeAMonth() {
        #expect(DocumentFieldParser.parseDay(in: "15/03/2026")?.day == DocumentFieldDay(year: 2026, month: 3, day: 15))
        #expect(DocumentFieldParser.parseDay(in: "12/31/2026")?.day == DocumentFieldDay(year: 2026, month: 12, day: 31))
        #expect(DocumentFieldParser.parseDay(in: "Fecha: 05-06-26")?.day == DocumentFieldDay(year: 2026, month: 6, day: 5))
        #expect(DocumentFieldParser.parseDay(in: "31/02/2026") == nil)
        #expect(DocumentFieldParser.parseDay(in: "809-555-0101") == nil)
    }

    @Test func dateTokensDefaultToISOAndAcceptACustomFormat() {
        let value = DocumentFieldValue(text: "2026-03-15", day: DocumentFieldDay(year: 2026, month: 3, day: 15), confidence: 1)
        #expect(value.rendered() == "2026-03-15")
        #expect(value.rendered(format: "yyyyMMdd") == "20260315")
    }

    // MARK: - Lookup

    @Test func lookupFindsEveryFieldOfAFilledForm() {
        let document = DocumentText(lines: lines(filledForm), strategy: .plainText)
        #expect(DocumentFieldParser.lookup(dateField, in: document, otherLabels: [])
            .value?.day == DocumentFieldDay(year: 2026, month: 3, day: 15))
        #expect(DocumentFieldParser.lookup(userField, in: document, otherLabels: []).value?.text == "Juan Pérez Gómez")
        #expect(DocumentFieldParser.lookup(contractField, in: document, otherLabels: []).value?.text == "ACME Servicios / Soporte")
    }

    @Test func lookupExplainsWhyAFieldIsMissing() {
        let document = DocumentText(lines: lines("Fecha Solicitud\npendiente"), strategy: .plainText)
        #expect(DocumentFieldParser.lookup(contractField, in: document, otherLabels: []) == .notFound(reason: "Label “nombre del contrato” not found."))
        #expect(DocumentFieldParser.lookup(dateField, in: document, otherLabels: []) == .notFound(reason: "No valid date after “fecha solicitud”."))
        let empty = DocumentText(lines: [], strategy: .none, message: "PDF has no readable text.")
        #expect(DocumentFieldParser.lookup(dateField, in: empty, otherLabels: []) == .notFound(reason: "PDF has no readable text."))
    }

    @Test func lowConfidenceValuesNeedTheTextLayerToVouchForThem() {
        let unsure = lines("Nombre del contrato\nACME", confidence: 0.6)
        let ocrOnly = DocumentText(lines: unsure, strategy: .pdfOCR)
        #expect(DocumentFieldParser.lookup(contractField, in: ocrOnly, otherLabels: []).value == nil)

        let vouched = DocumentText(lines: unsure, embeddedText: "… Nombre del contrato ACME …", strategy: .pdfOCR)
        #expect(DocumentFieldParser.lookup(contractField, in: vouched, otherLabels: []).value?.text == "ACME")

        var lenient = contractField
        lenient.minConfidence = 0
        #expect(DocumentFieldParser.lookup(lenient, in: ocrOnly, otherLabels: []).value?.text == "ACME")
    }

    // MARK: - Tokens

    @Test func tokensFillPlaceholdersWithFileNameSafeValues() throws {
        let tokens = DocumentFieldTokens(
            values: [
                "contrato": DocumentFieldValue(text: "ACME / Soporte: TI", confidence: 1),
                "fecha": DocumentFieldValue(text: "2026-03-15", day: DocumentFieldDay(year: 2026, month: 3, day: 15), confidence: 1),
            ],
            declared: ["contrato", "fecha"]
        )
        #expect(try tokens.substitute("{fecha:yyyyMMdd} - {contrato} - {name}") == "20260315 - ACME - Soporte - TI - {name}")
    }

    @Test func aDeclaredButMissingFieldRefusesInsteadOfWritingThePlaceholder() {
        let tokens = DocumentFieldTokens(values: [:], declared: ["contrato"])
        #expect(throws: ActionError.self) { try tokens.substitute("{contrato}") }
        #expect((try? DocumentFieldTokens.none.substitute("{contrato}")) == "{contrato}")
    }

    @Test func tokensForARuleReadEachDeclaredField() {
        let dir = TempDir()
        let file = dir.file("form.txt", contents: filledForm)
        let missing = DocumentFieldSpec(label: "correo electronico", token: "correo")
        let conditions = [fieldCondition(dateField), fieldCondition(userField), fieldCondition(contractField), fieldCondition(missing), makeCondition(.extension_, .is, "txt")]

        let tokens = DocumentFieldExtractor.tokens(for: conditions, path: file)
        #expect(tokens.declared == ["fecha", "usuario", "contrato", "correo"])
        #expect(tokens.values["usuario"]?.text == "Juan Pérez Gómez")
        #expect(tokens.values["correo"] == nil)
    }

    // MARK: - Conditions

    @Test func documentFieldConditionMatchesFoundAndMissingFields() {
        let dir = TempDir()
        let file = dir.file("form.txt", contents: filledForm)
        let missing = DocumentFieldSpec(label: "correo electronico", token: "correo")

        #expect(ConditionEvaluator.evaluate(fieldCondition(contractField), path: file))
        #expect(!ConditionEvaluator.evaluate(fieldCondition(contractField, .isNotFound), path: file))
        #expect(!ConditionEvaluator.evaluate(fieldCondition(missing), path: file))
        #expect(ConditionEvaluator.evaluate(fieldCondition(missing, .isNotFound), path: file))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.documentField, .isFound, "not a field"), path: file))
    }

    @Test func documentFieldConditionUsesSiblingLabelsAsOtherLabels() {
        let dir = TempDir()
        let file = dir.file("form.txt", contents: "Nombre usuario que utilizará el acceso\nDocumento de identidad\n001-1234567-8")
        let idField = DocumentFieldSpec(label: "documento de identidad", token: "cedula")
        let siblings = [fieldCondition(userField), fieldCondition(idField)]

        #expect(ConditionEvaluator.evaluate(fieldCondition(userField), path: file))
        #expect(!ConditionEvaluator.evaluate(fieldCondition(userField), path: file, siblings: siblings))
    }

    @Test func folderPathMatchesTheEnclosingFolder() {
        let dir = TempDir()
        let sorted = dir.dir("Sorted/ACME")
        let file = (sorted as NSString).appendingPathComponent("form.txt")
        try? "x".write(toFile: file, atomically: true, encoding: .utf8)

        #expect(ConditionEvaluator.evaluate(makeCondition(.folderPath, .is, sorted + "/"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.folderPath, .contains, "/Sorted/"), path: file))
        #expect(!ConditionEvaluator.evaluate(makeCondition(.folderPath, .doesNotContain, "Sorted"), path: file))
        #expect(ConditionEvaluator.evaluate(makeCondition(.folderPath, .doesNotContain, "Sorted"), path: dir.file("top.txt")))
    }

    // MARK: - Actions

    @Test func renameUsesDocumentFieldTokens() throws {
        let dir = TempDir()
        let file = dir.file("scan (signed).txt", contents: filledForm)
        let conditions = [fieldCondition(dateField), fieldCondition(userField), fieldCondition(contractField)]
        let fields = DocumentFieldExtractor.tokens(for: conditions, path: file)
        let rename = makeAction(.rename, .object(["pattern": .string("{fecha:yyyyMMdd} - {contrato} - {usuario}")]))

        let plan = try ActionExecutor.plan(rename, path: file, fields: fields)
        let expected = (dir.path as NSString).appendingPathComponent("20260315 - ACME Servicios - Soporte - Juan Pérez Gómez.txt")
        #expect(plan.targetPath == expected)

        let applied = try ActionExecutor.execute(rename, path: file, fields: fields)
        #expect(applied.newPath == expected)
        #expect(FileManager.default.fileExists(atPath: expected))
    }

    @Test func moveDestinationUsesDocumentFieldTokens() throws {
        let dir = TempDir()
        let file = dir.file("form.txt", contents: filledForm)
        let destination = dir.dir("Forms")
        let fields = DocumentFieldExtractor.tokens(for: [fieldCondition(contractField)], path: file)
        let move = makeAction(.moveToFolder, .object([
            "destination": .string((destination as NSString).appendingPathComponent("Contracts/{contrato}")),
        ]))

        let expected = (destination as NSString).appendingPathComponent("Contracts/ACME Servicios - Soporte/form.txt")
        #expect(try ActionExecutor.plan(move, path: file, fields: fields).targetPath == expected)
        #expect(try ActionExecutor.execute(move, path: file, fields: fields).newPath == expected)
        #expect(FileManager.default.fileExists(atPath: expected))
    }

    @Test func destinationCombinesDateTokensAndDocumentFields() throws {
        let dir = TempDir()
        let file = dir.file("form.txt", contents: filledForm)
        let fields = DocumentFieldExtractor.tokens(for: [fieldCondition(contractField)], path: file)
        let move = makeAction(.moveToFolder, .object([
            "destination": .string((dir.path as NSString).appendingPathComponent("Forms/{year}/{contrato}")),
        ]))

        let attrs = try FileManager.default.attributesOfItem(atPath: file)
        let date = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) ?? Date()
        let year = Calendar.current.component(.year, from: date)
        let expected = (dir.path as NSString).appendingPathComponent("Forms/\(year)/ACME Servicios - Soporte/form.txt")
        #expect(try ActionExecutor.plan(move, path: file, fields: fields).targetPath == expected)
    }

    @Test func moveRefusesWhenItsDestinationFieldIsMissing() {
        let dir = TempDir()
        let file = dir.file("other.txt", contents: "no form here")
        let fields = DocumentFieldExtractor.tokens(for: [fieldCondition(contractField)], path: file)
        let move = makeAction(.moveToFolder, .object([
            "destination": .string((dir.dir("Forms") as NSString).appendingPathComponent("{contrato}")),
        ]))

        #expect(throws: ActionError.self) { try ActionExecutor.plan(move, path: file, fields: fields) }
        #expect(throws: ActionError.self) { try ActionExecutor.execute(move, path: file, fields: fields) }
        #expect(FileManager.default.fileExists(atPath: file))
    }

    @Test func verifiedMoveAndCopyRecordTheChecksum() throws {
        let dir = TempDir()
        let destination = dir.dir("Archive")
        let helloSHA256 = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        #expect(try ActionExecutor.sha256(dir.file("probe.txt", contents: "hello")) == helloSHA256)

        let moved = dir.file("moved.txt", contents: "hello")
        let move = makeAction(.moveToFolder, .object(["destination": .string(destination), "verify_checksum": .bool(true)]))
        #expect(try ActionExecutor.plan(move, path: moved).description.hasSuffix(", verifying SHA-256"))
        let appliedMove = try ActionExecutor.execute(move, path: moved)
        #expect(appliedMove.message == "SHA-256 verified: \(helloSHA256)")
        #expect(appliedMove.newPath == (destination as NSString).appendingPathComponent("moved.txt"))
        #expect(!FileManager.default.fileExists(atPath: moved))

        let copied = dir.file("copied.txt", contents: "hello")
        let copy = makeAction(.copyToFolder, .object(["destination": .string(destination), "verify_checksum": .bool(true)]))
        let appliedCopy = try ActionExecutor.execute(copy, path: copied)
        #expect(appliedCopy.message == "SHA-256 verified: \(helloSHA256)")
        #expect(appliedCopy.copiedPath.map { FileManager.default.fileExists(atPath: $0) } == true)
        #expect(FileManager.default.fileExists(atPath: copied))
    }

    @Test func aCorruptedTransferIsUndoneAndFails() throws {
        let dir = TempDir()
        let file = dir.file("form.txt", contents: "original")
        let landed = (dir.dir("Archive") as NSString).appendingPathComponent("form.txt")

        #expect(throws: ActionError.self) {
            try ActionExecutor.verifiedTransfer(path: file) {
                try FileManager.default.moveItem(atPath: file, toPath: landed)
                try "damaged".write(toFile: landed, atomically: true, encoding: .utf8)
                return Applied(newPath: landed, undo: .move(from: file, to: landed))
            }
        }
        #expect(FileManager.default.fileExists(atPath: file))
        #expect(!FileManager.default.fileExists(atPath: landed))
    }

    // MARK: - Rule engine (Dry Run, Run Now, watcher share these paths)

    /// The form-filing setup this feature exists for: complete forms are
    /// filed under `Forms/<contract>/<date> - <contract> - <user>`, verified;
    /// incomplete ones are tagged for review instead; and a filed form is
    /// left alone by the review rule (and by later runs).
    private func formRules(target: String) -> [Rule] {
        let notFiled = makeCondition(.folderPath, .doesNotContain, (target as NSString).lastPathComponent)
        let ready = makeRule(
            name: "File VPN form",
            conditions: [notFiled, fieldCondition(dateField), fieldCondition(userField), fieldCondition(contractField)],
            actions: [
                makeAction(.moveToFolder, .object([
                    "destination": .string((target as NSString).appendingPathComponent("{contrato}")),
                    "verify_checksum": .bool(true),
                ]), position: 0),
                makeAction(.rename, .object(["pattern": .string("{fecha:yyyyMMdd} - {contrato} - {usuario}")]), position: 1),
            ]
        )
        let review = makeRule(
            name: "Review VPN form",
            conditions: [notFiled, makeCondition(.contents, .matchesRegex, "(?i)solicitud acceso vpn terceros")],
            actions: [makeAction(.addTag, .object(["tags": .stringArray(["Review"])]))]
        )
        return [ready, review]
    }

    @Test func completeFormsAreFiledAndIncompleteOnesAreTaggedForReview() throws {
        let dir = TempDir()
        let downloads = dir.dir("Downloads")
        let target = (downloads as NSString).appendingPathComponent("VPN Forms")
        let rules = formRules(target: target)
        let complete = (downloads as NSString).appendingPathComponent("vpn.txt")
        let incomplete = (downloads as NSString).appendingPathComponent("vpn-draft.txt")
        try filledForm.write(toFile: complete, atomically: true, encoding: .utf8)
        try filledForm.replacingOccurrences(of: "Nombre del contrato: ACME Servicios / Soporte", with: "Nombre del contrato:")
            .write(toFile: incomplete, atomically: true, encoding: .utf8)

        let expected = (target as NSString).appendingPathComponent("ACME Servicios - Soporte/20260315 - ACME Servicios - Soporte - Juan Pérez Gómez.txt")

        // Dry Run shows the same destination, and what each field read.
        let preview = try #require(RuleEngine.previewFile(path: complete, depth: 0, rules: rules))
        #expect(preview.rules.map(\.ruleName) == ["File VPN form"])
        #expect(preview.rules[0].actions.last?.targetPath == expected)
        #expect(preview.rules[0].conditions.contains { $0.detail == "{usuario} = Juan Pérez Gómez (100% confidence)" })

        let filed = RuleEngine.run(path: complete, depth: 0, rules: rules, batchId: "batch")
        #expect(filed.matched == ["File VPN form"])
        #expect(FileManager.default.fileExists(atPath: expected))
        #expect(filed.history.first { $0.actionKind == .moveToFolder }?.message?.hasPrefix("SHA-256 verified: ") == true)

        let reviewed = RuleEngine.run(path: incomplete, depth: 0, rules: rules, batchId: "batch")
        #expect(reviewed.matched == ["Review VPN form"])
        #expect(FinderTags.read(incomplete) == ["Review"])

        // A later scan of the filed form (e.g. the watcher seeing it arrive) does nothing.
        #expect(RuleEngine.run(path: expected, depth: 2, rules: rules.map { var rule = $0; rule.recursionDepth = nil; return rule }, batchId: "batch").matched.isEmpty)
    }
}
