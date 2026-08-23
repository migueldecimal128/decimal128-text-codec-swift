// swift-tools-version: 6.0
// SPDX-License-Identifier: MIT
import PackageDescription

// The codec is one Swift file with no dependencies. The platform floor is set
// by `UInt128`, which is the public boundary type and carries a SwiftStdlib 6.0
// availability. Declaring the floor here rather than annotating the API keeps
// the four functions free of `@available` and the call sites free of
// `if #available`.
//
// VERIFY_ENABLED arms the internal-state assertions. It is defined for debug
// builds only: a release consumer compiles this source into their own program
// and must not take a trap inside a library on data they do not control. The
// `demand` checks -- buffer sizing and the precision invariant -- are live in
// every configuration regardless.
let codecSwiftSettings: [SwiftSetting] = [
    .define("VERIFY_ENABLED", .when(configuration: .debug))
]

let package = Package(
    name: "Decimal128TextCodec",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11),
        .visionOS(.v2),
    ],
    products: [
        .library(
            name: "Decimal128TextCodec",
            targets: ["Decimal128TextCodec"]
        )
    ],
    targets: [
        .target(
            name: "Decimal128TextCodec",
            swiftSettings: codecSwiftSettings
        ),
        // The conformance vectors are vendored under Tests/.../vectors and read
        // at run time through Bundle.module, rather than transcribed into Swift
        // source. The reference transcribes them because Kotlin commonTest has
        // no portable file access; SwiftPM resources have no such limitation,
        // and a data file is one hop closer to the corpus of record.
        .testTarget(
            name: "Decimal128TextCodecTests",
            dependencies: ["Decimal128TextCodec"],
            resources: [.copy("vectors")],
            swiftSettings: codecSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
