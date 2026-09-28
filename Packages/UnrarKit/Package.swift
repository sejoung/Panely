// swift-tools-version:5.9
import PackageDescription

// Vendored UnrarKit (abbeycode/UnrarKit 2.10) built against RARLAB's unrar
// source. UnrarKit ships no SwiftPM manifest, so it lives here as a local
// package. See README.md for the exact upstream versions and local patches.

// unrar .cpp files that are `#include`d by other translation units, or that
// belong only to the command-line tool / Windows builds. Mirrors the `lib`
// target in unrar's makefile (OBJECTS + LIB_OBJ are compiled, the rest not).
let unrarNonLibSources = [
    "arccmt.cpp", "blake2s_sse.cpp", "blake2sp.cpp", "cmdfilter.cpp", "cmdmix.cpp",
    "coder.cpp", "crypt1.cpp", "crypt2.cpp", "crypt3.cpp", "crypt5.cpp",
    "hardlinks.cpp", "isnt.cpp", "log.cpp", "model.cpp", "motw.cpp", "rarpch.cpp",
    "recvol.cpp", "recvol3.cpp", "recvol5.cpp", "rs.cpp", "suballoc.cpp",
    "threadmisc.cpp", "uicommon.cpp", "uiconsole.cpp", "uisilent.cpp", "ulinks.cpp",
    "unpack15.cpp", "unpack20.cpp", "unpack30.cpp", "unpack50.cpp", "unpack50frag.cpp",
    "unpack50mt.cpp", "unpackinline.cpp", "uowners.cpp",
    "win32acl.cpp", "win32lnk.cpp", "win32stm.cpp",
].map { "unrar/\($0)" }

let package = Package(
    name: "UnrarKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UnrarKit", targets: ["UnrarKit"]),
    ],
    targets: [
        .target(
            name: "UnrarKit",
            path: "Sources/UnrarKit",
            exclude: unrarNonLibSources + ["unrar/license.txt", "unrar/acknow.txt"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include/UnrarKit"),
                .headerSearchPath("unrar"),
                .headerSearchPath("Categories"),
                .define("SILENT"),
                .define("RARDLL"),
                .unsafeFlags(["-w"]),
            ],
            cxxSettings: [
                .headerSearchPath("include/UnrarKit"),
                .headerSearchPath("unrar"),
                .headerSearchPath("Categories"),
                .define("SILENT"),
                .define("RARDLL"),
                .unsafeFlags(["-w"]),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx17
)
