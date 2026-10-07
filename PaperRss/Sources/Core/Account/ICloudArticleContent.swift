import Compression
import CryptoKit
import Foundation

/// Only original RSS fields. Derived previews, extracted web pages, AI and
/// credentials are intentionally absent from this contract.
struct ICloudArticleContent: Codable, Sendable, Equatable {
    let title: String
    let author: String?
    let url: String?
    let publishedAt: Double?
    let summary: String
    let contentHTML: String?

    init(_ article: ArticleRecord) {
        title = article.title; author = article.author; url = article.url
        publishedAt = article.publishedAt; summary = article.summary; contentHTML = article.contentHTML
    }
}

enum ICloudArticleContentCodec {
    // Independent bounds for compressed assets and expanded RSS text. A large
    // article stays local and is reported separately, never blocks state sync.
    static let maximumExpandedBytes = 8 * 1024 * 1024
    static let maximumCompressedBytes = 2 * 1024 * 1024
    static let inlineBytes = 64 * 1024

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func encode(_ content: ICloudArticleContent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let source = try encoder.encode(content)
        guard source.count <= maximumExpandedBytes else { throw ICloudRecordError.malformedRecord }
        var output = Data(count: min(source.count + 1024, maximumCompressedBytes + 1))
        let capacity = output.count
        let size = output.withUnsafeMutableBytes { destination in
            source.withUnsafeBytes { input in
                compression_encode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    input.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard size > 0, size <= maximumCompressedBytes else { throw ICloudRecordError.malformedRecord }
        output.count = size
        return output
    }

    static func decode(_ data: Data, expectedHash: String) throws -> ICloudArticleContent {
        guard !data.isEmpty, data.count <= maximumCompressedBytes, hash(data) == expectedHash
        else { throw ICloudRecordError.malformedRecord }
        // Grow only as needed. One extra byte distinguishes exact-limit input
        // from truncated decompression, which the Compression API reports as
        // a full destination buffer rather than an error.
        var capacity = min(64 * 1024, maximumExpandedBytes + 1)
        while true {
            var output = Data(count: capacity)
            let size = output.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { input in
                    compression_decode_buffer(destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                        input.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_LZFSE)
                }
            }
            guard size > 0 else { throw ICloudRecordError.malformedRecord }
            if size < capacity {
                output.count = size
                guard let object = try JSONSerialization.jsonObject(with: output) as? [String: Any],
                      Set(object.keys).isSubset(of: ["title", "author", "url", "publishedAt", "summary", "contentHTML"])
                else { throw ICloudRecordError.malformedRecord }
                let content = try JSONDecoder().decode(ICloudArticleContent.self, from: output)
                guard content.publishedAt?.isFinite != false else { throw ICloudRecordError.malformedRecord }
                return content
            }
            guard capacity <= maximumExpandedBytes else { throw ICloudRecordError.malformedRecord }
            capacity = min(capacity * 2, maximumExpandedBytes + 1)
        }
    }
}
