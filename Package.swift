// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MoneroMiner",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "MoneroMiner",
            targets: ["MoneroMiner"]
        ),
    ],
    targets: [
        .target(
            name: "CRandomX",
            path: "Sources/CRandomX",
            exclude: [
                "jit_compiler_x86.cpp",
                "jit_compiler_x86_static.S",
                "jit_compiler_x86_static.asm",
                "assembly_generator_x86.cpp",
                "argon2_avx2.c",
                "argon2_ssse3.c",
                "asm",
                "cpu_rv64.S",
                "jit_compiler_rv64.cpp",
                "jit_compiler_rv64_static.S",
                "jit_compiler_rv64_vector.cpp",
                "jit_compiler_rv64_vector_static.S",
                "aes_hash_rv64_vector.cpp",
                "aes_hash_rv64_zvkned.cpp",
                "tests",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .unsafeFlags(["-O3", "-mcpu=apple-a12"]),
            ],
            cxxSettings: [
                .unsafeFlags(["-O3", "-mcpu=apple-a12"]),
            ],
            linkerSettings: [
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "MoneroMiner",
            dependencies: ["CRandomX"],
            path: "Sources/Miner"
        ),
    ],
    cxxLanguageStandard: .cxx14
)
