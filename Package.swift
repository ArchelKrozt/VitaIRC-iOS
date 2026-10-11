// swift-tools-version:5.9
import PackageDescription

// The IRC core (protocol, settings, logs, network services). The iOS app in App/ uses it;
// it also builds on macOS so its checks run with `swift run CoreChecks`.
let package = Package(
    name: "VitaIRCCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [.library(name: "VitaIRCCore", targets: ["VitaIRCCore"])],
    targets: [
        .target(name: "VitaIRCCore"),
        // checks: `swift run CoreChecks` (a program, so it needs no XCTest)
        .executableTarget(name: "CoreChecks", dependencies: ["VitaIRCCore"]),
        // a VitaIRC user without screen, to test profiles between apps
        .executableTarget(name: "VitaPeer", dependencies: ["VitaIRCCore"]),
    ]
)
