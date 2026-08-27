//
//  DocumentClassifierService.swift
//  IntelliDocScanSignPDF
//

import Foundation
import NaturalLanguage
import OSLog
import UIKit

/// On-device document intelligence: reads OCR text with NaturalLanguage, finds
/// the entity / type / date / total anchors, then generates clean file names
/// and a smart folder route.
actor DocumentClassifierService {
    static let shared = DocumentClassifierService()

    private let logger = Logger(subsystem: "app.rork.scanvault", category: "classifier")

    // MARK: - Entry point

    /// Recognizes text from the first pages and classifies it.
    func classify(pages: [UIImage]) async -> DocumentClassification {
        var text = ""
        for page in pages.prefix(3) {
            text += await OCRService.shared.recognizedText(in: page) + "\n"
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return DocumentClassification(
                confidence: 0,
                suggestedNames: [],
                matchedKeywords: []
            )
        }
        return classify(text: text)
    }

    /// Pure-text classifier — deterministic, testable, no OCR dependency.
    nonisolated static func classify(text: String) -> DocumentClassification {
        let lowered = text.lowercased()

        // --- Entity ------------------------------------------------------
        let entity = detectEntity(in: text, lowered: lowered)

        // --- Document type ------------------------------------------------
        let typeVerdict = scoreDocumentType(in: lowered)

        // --- Dates & totals ------------------------------------------------
        let date = extractDate(in: text)
        let total = extractTotal(in: lowered)

        // --- Category routing ---------------------------------------------
        let category = route(docType: typeVerdict.type, text: lowered)

        // --- Confidence -----------------------------------------------------
        var confidence = 0.0
        if let type = typeVerdict.type {
            confidence += min(0.55, Double(typeVerdict.score) * 0.18)
        }
        if entity != nil { confidence += 0.2 }
        if date != nil { confidence += 0.1 }
        if total != nil { confidence += 0.1 }
        confidence = min(1, confidence)

        // --- Name suggestions -----------------------------------------------
        let names = suggestedNames(entity: entity, type: typeVerdict.type, date: date, total: total)

        return DocumentClassification(
            entity: entity,
            docType: typeVerdict.type,
            date: date,
            total: total,
            category: category,
            confidence: confidence,
            suggestedNames: names,
            matchedKeywords: typeVerdict.keywords
        )
    }

    func classify(text: String) -> DocumentClassification {
        Self.classify(text: text)
    }

    // MARK: - Entity detection

    /// Known vendors & institutions matched case-insensitively.
    private static let knownEntities: [(needle: String, display: String)] = [
        ("home depot", "Home Depot"), ("lowe's", "Lowe's"), ("menards", "Menards"),
        ("walmart", "Walmart"), ("target", "Target"), ("costco", "Costco"),
        ("amazon", "Amazon"), ("best buy", "Best Buy"), ("apple store", "Apple"),
        ("irs", "IRS"), ("internal revenue", "IRS"), ("franchise tax", "Franchise Tax Board"),
        ("geico", "Geico"), ("state farm", "State Farm"), ("allstate", "Allstate"),
        ("progressive", "Progressive"), ("usaa", "USAA"),
        ("chase", "Chase Bank"), ("bank of america", "Bank of America"),
        ("wells fargo", "Wells Fargo"), ("citibank", "Citi"), ("capital one", "Capital One"),
        ("amex", "American Express"), ("american express", "American Express"),
        ("visa", "Visa"), ("mastercard", "Mastercard"), ("paypal", "PayPal"),
        ("walgreens", "Walgreens"), ("cvs", "CVS"), ("rite aid", "Rite Aid"),
        ("mayo clinic", "Mayo Clinic"), ("kaiser", "Kaiser Permanente"),
        ("blue cross", "Blue Cross"), ("bluecross", "Blue Cross"), ("aetna", "Aetna"),
        ("cigna", "Cigna"), ("united healthcare", "United Healthcare"), ("medicare", "Medicare"),
        ("delta air", "Delta"), ("united air", "United Airlines"), ("southwest", "Southwest"),
        ("at&t", "AT&T"), ("verizon", "Verizon"), ("comcast", "Comcast"), ("xfinity", "Xfinity"),
        ("duke energy", "Duke Energy"), ("pg&e", "PG&E"), ("national grid", "National Grid"),
        ("uber", "Uber"), ("lyft", "Lyft"), ("airbnb", "Airbnb"),
    ]

    private static func detectEntity(in text: String, lowered: String) -> String? {
        for (needle, display) in knownEntities where lowered.contains(needle) {
            return display
        }

        // "Dr. Smith" / "Dr. Jane Smith" medical provider.
        if let raw = text.range(of: #"Dr\.?\s+[A-Za-z]+"#, options: .regularExpression) {
            let cleaned = String(text[raw]).trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.count >= 4 { return titleCased(cleaned) }
        }

        // NaturalLanguage organization tagger catches unknown orgs.
        if let org = dominantOrganization(in: text) { return org }

        return nil
    }

    /// Most frequent organization name recognized by the NLTagger.
    private static func dominantOrganization(in text: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        var counts: [String: Int] = [:]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, tagRange in
            guard tag == .organizationName else { return true }
            let name = String(text[tagRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.count >= 3, name.count <= 30, name != name.uppercased() || name.count <= 4 else { return true }
            counts[name.capitalized, default: 0] += 1
            return true
        }

        return counts
            .filter { $0.value >= 2 }
            .max { $0.value < $1.value }?
            .key
    }

    // MARK: - Document type

    private struct TypeVerdict {
        var type: String?
        var score: Int
        var keywords: [String]
    }

    private static let typeSignatures: [(type: String, category: DocumentCategory?, keywords: [String])] = [
        ("Receipt", .receiptsExpenses,
         ["receipt", "thank you for shopping", "subtotal", "register", "sku", "qty", "cashier", "change due", "store #"]),
        ("Invoice", .receiptsExpenses,
         ["invoice", "amount due", "bill to", "remit to", "net 30", "net 15", "purchase order", "po number"]),
        ("Tax Form", .taxFinance,
         ["w-2", "w-2 wage", "w-9", "form 1040", "1040", "1099", "1098", "tax return", "schedule c", "schedule a", "ein", "irs"]),
        ("Bank Statement", .taxFinance,
         ["statement", "account balance", "closing balance", "beginning balance", "finance charge", "apr", "statement period"]),
        ("Payslip", .taxFinance,
         ["pay stub", "paystub", "gross pay", "net pay", "ytd", "federal withholding", "fica"]),
        ("Prescription", .medicalHealth,
         ["prescription", "rx", "refill", "dosage", "prescriber", "dispense", "mg", "pharmacy"]),
        ("Medical Record", .medicalHealth,
         ["patient", "diagnosis", "clinic", "hospital", "blood pressure", "lab results", "hemoglobin", "provider", "dob"]),
        ("Insurance Claim", .medicalHealth,
         ["claim number", "policy number", "deductible", "copay", "co-pay", "explanation of benefits", "eob"]),
        ("Lease Agreement", .legalContracts,
         ["lease", "landlord", "tenant", "security deposit", "premises", "monthly rent", "lessor", "lessee"]),
        ("NDA", .legalContracts,
         ["nondisclosure", "non-disclosure", "confidential", "mutual agreement", "disclosing party", "receiving party"]),
        ("Contract", .legalContracts,
         ["agreement", "contract", "hereby", "party of the first part", "terms and conditions", "governing law", "signature"]),
        ("Personal ID", .personalIDs,
         ["driver license", "driver's license", "passport", "identification card", "license no", "date of birth", "id number"]),
        ("Utility Bill", .taxFinance,
         ["utility", "electric bill", "water bill", "gas bill", "service address", "kwh", "billing period"]),
        ("Boarding Pass", .receiptsExpenses,
         ["boarding pass", "flight", "gate", "seat", "departure", "arrival", "confirmation code"]),
    ]

    private static func scoreDocumentType(in lowered: String) -> TypeVerdict {
        var best: (type: String, score: Int, keywords: [String])?
        for signature in typeSignatures {
            let hits = signature.keywords.filter { lowered.contains($0) }
            let score = hits.count
            guard score > 0 else { continue }
            if score > (best?.score ?? 0) {
                best = (signature.type, score, hits)
            }
        }
        guard let best else { return TypeVerdict(type: nil, score: 0, keywords: []) }
        return TypeVerdict(type: best.type, score: best.score, keywords: best.keywords)
    }

    // MARK: - Dates & totals

    private static func extractDate(in text: String) -> Date? {
        // ISO / numeric forms: 2026-08-26, 08/26/2026, 8-26-26.
        let numericPattern = #"(?:\d{4}[-/.]\d{1,2}[-/.]\d{1,2})|(?:\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4})"#
        // Written forms: "August 26, 2026" / "Aug 26 2026" / "26 August 2026".
        let writtenPattern = #"(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t|tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\s+\d{1,2},?\s+\d{4}"#

        let formatterUS = DateFormatter()
        formatterUS.locale = Locale(identifier: "en_US_POSIX")
        formatterUS.timeZone = .current

        for pattern in [writtenPattern, numericPattern] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                guard let swiftRange = Range(match.range, in: text) else { continue }
                let candidate = String(text[swiftRange])
                for format in ["MMMM d, yyyy", "MMM d, yyyy", "MMMM d yyyy", "MMM d yyyy",
                               "yyyy-MM-dd", "yyyy/MM/dd", "MM/dd/yyyy", "M/d/yyyy",
                               "MM-dd-yyyy", "MM/dd/yy", "M-d-yy"] {
                    formatterUS.dateFormat = format
                    if let date = formatterUS.date(from: candidate) {
                        return date
                    }
                }
            }
        }
        return nil
    }

    private static let moneyPattern = #"(?:\$|usd\s?)\s?(\d{1,3}(?:,\d{3})*|\d+)(?:\.(\d{2}))?"#

    private static func extractTotal(in lowered: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: moneyPattern) else { return nil }

        var labelled: Double?
        var largest: Double?

        for line in lowered.components(separatedBy: .newlines) {
            let isTotalLine = ["total", "amount due", "balance", "grand total", "amount paid"]
                .contains { line.contains($0) }

            let range = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: range) {
                guard match.numberOfRanges >= 2,
                      let wholeRange = Range(match.range(at: 1), in: line)
                else { continue }
                var value = Double(line[wholeRange].replacingOccurrences(of: ",", with: "")) ?? 0
                if let centsRange = Range(match.range(at: 2), in: line),
                   let cents = Double(line[centsRange]) {
                    value += cents / 100
                }
                guard value > 0 else { continue }
                if isTotalLine { labelled = max(labelled ?? 0, value) }
                largest = max(largest ?? 0, value)
            }
        }
        return labelled ?? largest
    }

    // MARK: - Routing

    private static func route(docType: String?, text lowered: String) -> DocumentCategory? {
        if let docType,
           let signature = typeSignatures.first(where: { $0.type == docType }),
           let category = signature.category {
            return category
        }
        // Fallback keyword routing for unrecognized types.
        let routes: [(DocumentCategory, [String])] = [
            (.taxFinance, ["tax", "income", "bank", "payment", "statement", "finance"]),
            (.medicalHealth, ["health", "medical", "doctor", "patient", "clinic"]),
            (.legalContracts, ["agreement", "contract", "legal", "party", "confidential"]),
            (.personalIDs, ["license", "passport", "birth certificate", "identification"]),
        ]
        for (category, needles) in routes where needles.contains(where: lowered.contains) {
            return category
        }
        return nil
    }

    // MARK: - Naming

    private static func suggestedNames(
        entity: String?,
        type: String?,
        date: Date?,
        total: Double?
    ) -> [String] {
        var names: [String] = []

        // 1. Canonical file name: YYYY-MM-DD_[Entity]_[DocType].pdf
        if let type {
            let day = (date ?? Date.now).formatted(
                .iso8601.year().month().day().dateSeparator(.dash)
            )
            let entityPart = entity.map { $0.replacingOccurrences(of: " ", with: "") } ?? "Document"
            let typePart = type.replacingOccurrences(of: " ", with: "")
            names.append("\(day)_\(entityPart)_\(typePart)")
        }

        // 2. Friendly display name.
        if let entity, let type {
            let day = (date ?? Date.now).formatted(.dateTime.month(.abbreviated).day().year())
            names.append("\(entity) \(type) — \(day)")
        } else if let type {
            names.append("\(type) — \(Date.now.formatted(.dateTime.month(.abbreviated).day().year()))")
        }

        // 3. Money-anchored name.
        if let total, let type {
            names.append("\(type) · \(total.formatted(.currency(code: "USD")))")
        } else if let entity {
            names.append("\(entity) Document")
        }

        guard !names.isEmpty else { return [] }
        return Array(names.prefix(3))
    }

    // MARK: - Helpers

    private static func titleCased(_ value: String) -> String {
        value.replacingOccurrences(of: "^dr\\.?\\s*", with: "Dr. ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
