import Foundation
import PDFKit
import Vision
import UIKit
import ZIPFoundation

struct KariExtractedPart: Codable { var location: String; var text: String }
actor KariMemoryExtractor {
    private let textLimit = 10_000_000
    func cached(_ url: URL) throws -> [KariExtractedPart]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode([KariExtractedPart].self, from: Data(contentsOf: url))
    }
    func cache(_ parts: [KariExtractedPart], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(parts).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    func extract(_ url: URL) throws -> [KariExtractedPart] {
        switch url.pathExtension.lowercased() {
        case "pdf": return try pdf(url)
        case "txt", "md", "markdown":
            let data = try Data(contentsOf: url)
            let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            guard let text = String(data: data, encoding: .utf8) ?? ((data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])) ? String(data: data, encoding: .utf16) : String(data: data, encoding: String.Encoding(rawValue: gb))) else { throw KariError.message("无法识别文本编码") }
            guard text.utf8.count <= textLimit else { throw KariError.message("提取文本超过 10 MB") }
            return [.init(location: "正文", text: text)]
        case "docx", "xlsx", "pptx": return try office(url)
        default: throw KariError.message("支持 PDF、TXT、Markdown、DOCX、XLSX、PPTX")
        }
    }
    private func pdf(_ url: URL) throws -> [KariExtractedPart] {
        guard let document = PDFDocument(data: try Data(contentsOf: url, options: .mappedIfSafe)) else { throw KariError.message("PDF 文件无法读取") }
        if document.isLocked && !document.unlock(withPassword: "") { throw KariError.message("PDF 需要密码，请先解密后导入") }
        guard document.pageCount <= 500 else { throw KariError.message("PDF 最多 500 页") }
        var parts: [KariExtractedPart] = []; var total = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let text: String = try autoreleasepool {
                let existing = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !existing.isEmpty { return existing }
                let bounds = page.bounds(for: .mediaBox)
                guard bounds.width > 0, bounds.height > 0 else { return "" }
                let scale = min(2, 1800 / max(bounds.width, bounds.height))
                let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                guard let cg = image.cgImage else { return "" }
                let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
                request.recognitionLanguages = ["zh-Hans", "en-US"]; request.usesLanguageCorrection = true
                try VNImageRequestHandler(cgImage: cg).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }
            total += text.utf8.count
            guard total <= textLimit else { throw KariError.message("提取文本超过 10 MB") }
            if !text.isEmpty { parts.append(.init(location: "第 \(index + 1) 页", text: text)) }
        }
        return parts
    }
    private func office(_ url: URL) throws -> [KariExtractedPart] {
        let archive = try Archive(url: url, accessMode: .read)
        var expanded: UInt64 = 0
        for entry in archive {
            expanded += UInt64(entry.uncompressedSize)
            guard expanded <= 200_000_000 else { throw KariError.message("文档解压后超过 200 MB") }
        }
        func xml(_ path: String) throws -> KariOfficeXML {
            guard let entry = archive[path] else { throw KariError.message("Office 文档结构不完整") }
            guard entry.uncompressedSize <= 20_000_000 else { throw KariError.message("单个文档分区超过 20 MB") }
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            let delegate = KariOfficeXML(); let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false; parser.delegate = delegate
            guard parser.parse() else { throw KariError.message("Office XML 无法解析") }
            return delegate
        }
        var parts: [KariExtractedPart] = []
        if url.pathExtension.lowercased() == "docx" {
            let value = try xml("word/document.xml")
            parts = value.paragraphs.enumerated().map { .init(location: "段落 \($0.offset + 1)", text: $0.element) }
        } else if url.pathExtension.lowercased() == "pptx" {
            var paths = archive.map(\.path).filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") && !$0.contains("/_rels/") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if archive["ppt/presentation.xml"] != nil, archive["ppt/_rels/presentation.xml.rels"] != nil {
                let order = try xml("ppt/presentation.xml").slideIDs
                let relations = try xml("ppt/_rels/presentation.xml.rels").relationships
                paths = try order.map { id in
                    guard let target = relations[id] else { throw KariError.message("幻灯片顺序关系不完整") }
                    let base = URL(fileURLWithPath: "/ppt/").appendingPathComponent(target).standardized.path
                    let path = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    guard archive[path] != nil else { throw KariError.message("幻灯片文件缺失") }; return path
                }
            }
            for (index, path) in paths.enumerated() {
                try Task.checkCancellation(); parts.append(.init(location: "幻灯片 \(index + 1)", text: try xml(path).paragraphs.joined(separator: "\n")))
            }
        } else {
            let shared = archive["xl/sharedStrings.xml"] == nil ? [] : try xml("xl/sharedStrings.xml").sharedStrings
            let paths = archive.map(\.path).filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") && !$0.contains("/_rels/") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let workbook = try xml("xl/workbook.xml")
            let relationships = try xml("xl/_rels/workbook.xml.rels").relationships
            for path in paths {
                try Task.checkCancellation()
                let name = workbook.sheets.first { pair in
                    guard let target = relationships[pair.1] else { return false }
                    return path == "xl/" + target || path == target.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                }?.0 ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
                var rows: [[(String, String)]] = []; var rowKey = ""
                for cell in try xml(path).cells {
                    let value = cell.type == "s" ? (Int(cell.value).flatMap { shared.indices.contains($0) ? shared[$0] : nil } ?? cell.value) : cell.value
                    guard !value.isEmpty else { continue }
                    let key = String(cell.reference.filter(\.isNumber))
                    if key != rowKey || rows.isEmpty { rows.append([]); rowKey = key }
                    rows[rows.count - 1].append((cell.reference, value))
                }
                let headers = rows.first?.map { $0.1 }.joined(separator: " | ") ?? ""
                for (index, row) in rows.enumerated() {
                    let range = (row.first?.0 ?? "") + ":" + (row.last?.0 ?? "")
                    let content = row.map { $0.0 + ": " + $0.1 }.joined(separator: " | ")
                    parts.append(.init(location: "\(name) · \(range)", text: name + "\n" + (index > 0 ? headers + "\n" : "") + content))
                }
            }
        }
        guard parts.reduce(0, { $0 + $1.text.utf8.count }) <= textLimit else { throw KariError.message("提取文本超过 10 MB") }
        return parts
    }
}

private final class KariOfficeXML: NSObject, XMLParserDelegate {
    struct Cell { var reference: String; var type: String; var value: String }
    var paragraphs: [String] = []; var sharedStrings: [String] = []; var cells: [Cell] = []
    var slideIDs: [String] = []
    var sheets: [(String, String)] = []; var relationships: [String: String] = [:]
    private var capture = false; private var paragraph = ""; private var shared = ""; private var cell: Cell?
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        let local = name.components(separatedBy: ":").last ?? name
        if local == "p" { paragraph = "" }
        if local == "si" { shared = "" }
        if local == "c" { cell = Cell(reference: attributes["r"] ?? "", type: attributes["t"] ?? "", value: "") }
        if ["t", "v"].contains(local) { capture = true }
        if local == "tab" { paragraph += "\t" }
        if local == "br" { paragraph += "\n" }
        if local == "sldId", let id = attributes["r:id"] { slideIDs.append(id) }
        if local == "sheet" { sheets.append((attributes["name"] ?? "", attributes["r:id"] ?? "")) }
        if local == "Relationship", let id = attributes["Id"], let target = attributes["Target"] { relationships[id] = target }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capture { paragraph += string; shared += string; if cell != nil { cell!.value += string } }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let local = name.components(separatedBy: ":").last ?? name
        if ["t", "v"].contains(local) { capture = false }
        if local == "p", !paragraph.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { paragraphs.append(paragraph) }
        if local == "si" { sharedStrings.append(shared) }
        if local == "c", let value = cell { cells.append(value); cell = nil }
    }
}
