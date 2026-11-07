# YAMLCamel for Swift

YAMLCamel reads and writes YAML in Swift. It includes Codable encoding and decoding alongside an untyped document API. Separate gzip and HTTP products let an application take only the I/O support it needs.

Copyright 2026, Spark Software Development, LLC.

## Features

`YAMLDecoder` and `YAMLEncoder` work with your `Decodable` and `Encodable` types. For documents whose shape is decided at runtime, the untyped API exposes ordinary values and the `YAMLValue` tree without requiring an application model.

The parser targets the [YAML 1.2.2](https://yaml.org/spec/1.2.2/) core schema and handles block and flow collections, quoted and block strings, anchors, aliases, tags, and document streams. The Swift value model uses string keys for mappings. The test suite documents the remaining syntax differences. Parser and emitter limits cover sizes, nesting and the work needed to build or write a document. You can sort keys when stable output matters.

Sequence readers can decode top-level block-sequence elements as they are requested or as byte chunks arrive. File and gzip sequence readers use the same approach, so a caller can process a large list without first building the entire result array.

The `YAMLCamel` parser and emitter use Foundation with no third-party package dependencies, so they can fit into an existing app without adding another package to resolve. `YAMLCamelGzip` adds system-zlib compression, and `YAMLCamelHTTP` adds YAML requests and responses over URLSession. File access, compression and transport have replaceable interfaces in the three products' source directories.

## Configuration

Set options on the encoder, decoder or I/O client. The package has no required environment variables or configuration file.

| Setting | Purpose |
| --- | --- |
| `YAMLLimits` | Input bytes, nesting, nodes, scalars, aliases, documents and duplicate-key policy. |
| `YAMLEmitLimits` | Output byte, node and nesting bounds. |
| `YAMLEncoder.options.sortKeys` | Sort mapping keys; defaults to `false`. |
| `GzipLimits` | Compressed and inflated byte limits. |
| `YAMLHTTPLimits` | HTTP response and decompression limits. |
| `YAMLFileIO`, `YAMLCompression`, `YAMLTransport` | Route I/O through your own implementations. |

## Build & Deploy

Use the Swift 6 toolchain. The package targets macOS 10.15, iOS 13, tvOS 13 and watchOS 6 or newer, and also builds on Linux; install zlib headers on Linux for the gzip and HTTP products. Run `swift build` and `swift test --no-parallel` from the checkout. Add the package as a Swift Package Manager dependency and select `YAMLCamel`, `YAMLCamelGzip` or `YAMLCamelHTTP` for the consuming target. Pin the reviewed package release or revision.

## License

PolyForm Noncommercial 1.0.0 OR PolyForm Small Business 1.0.0, at your choice. Source-available, but not open-source. See [License](LICENSE.MD) for the full terms.

The Noncommercial option permits noncommercial use. The Small Business option also permits use for a company's benefit when it has fewer than 100 employees and independent contractors combined and less than USD 1,000,000 in prior-tax-year revenue, measured in 2019 dollars and adjusted for inflation as the licence specifies. Its company definition includes related organisations under common control. Both options permit modifications and redistribution for their permitted purposes, subject to their conditions.

## Forking and Contributions

The [License](LICENSE.MD) permits modifications, forks and redistribution for the permitted purposes of either option, subject to its conditions. Our [Contribution Policy](CONTRIBUTING.md) also grants additional permissions for contribution forks, review and controlled testing. The limits and deadlines on that additional permission do not narrow independent rights granted by the software licence, applicable law or the hosting platform's terms.

Contributions are welcome. You retain ownership, but Spark may use and commercially relicense submitted contributions, including under proprietary terms, even if a submission is declined or withdrawn. Read and accept the contribution agreement before submitting a change.
