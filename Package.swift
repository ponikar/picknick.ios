// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Picknick",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "Picknick", targets: ["PicknickCore", "PicknickStore", "PicknickPhotos", "PicknickIndexer"]),
        .library(name: "PicknickCore", targets: ["PicknickCore"]),
        .library(name: "PicknickStore", targets: ["PicknickStore"]),
        .library(name: "PicknickPhotos", targets: ["PicknickPhotos"]),
        .library(name: "PicknickIndexer", targets: ["PicknickIndexer"]),
        .library(name: "PicknickVision", targets: ["PicknickVision"]),
        .library(name: "PicknickPlaces", targets: ["PicknickPlaces"]),
        .library(name: "PicknickSearch", targets: ["PicknickSearch"]),
        .library(name: "PicknickTestSupport", targets: ["PicknickTestSupport"]),
        .library(name: "PicknickCLIP", targets: ["PicknickCLIP"]),
        .library(name: "PicknickBroker", targets: ["PicknickBroker"]),
        .executable(name: "picknick-trace", targets: ["PicknickTrace"]),
    ],
    targets: [
        .target(name: "PicknickCore"),
        .target(name: "PicknickStore", dependencies: ["PicknickCore"]),
        .target(name: "PicknickPhotos", dependencies: ["PicknickCore"]),
        .target(name: "PicknickIndexer", dependencies: ["PicknickCore"]),
        .target(name: "PicknickVision", dependencies: ["PicknickCore"]),
        .target(name: "PicknickPlaces", dependencies: ["PicknickCore"]),
        .target(name: "PicknickSearch", dependencies: ["PicknickCore"]),
        .target(name: "PicknickTestSupport", dependencies: ["PicknickCore"]),
        .target(name: "PicknickCLIP", dependencies: ["PicknickCore"]),
        .target(name: "PicknickBroker", dependencies: ["PicknickCore", "PicknickSearch"]),

        .executableTarget(
            name: "PicknickTrace",
            dependencies: ["PicknickCore", "PicknickStore", "PicknickIndexer", "PicknickTestSupport"]
        ),

        .testTarget(name: "PicknickCoreTests", dependencies: ["PicknickCore", "PicknickTestSupport"]),
        .testTarget(name: "PicknickStoreTests", dependencies: ["PicknickStore", "PicknickTestSupport"]),
        .testTarget(name: "PicknickVisionTests", dependencies: ["PicknickVision", "PicknickCore"]),
        .testTarget(name: "PicknickPlacesTests", dependencies: ["PicknickPlaces", "PicknickCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "PicknickIndexerTests", dependencies: ["PicknickIndexer", "PicknickStore", "PicknickTestSupport"]),
        .testTarget(name: "PicknickSearchTests", dependencies: ["PicknickSearch", "PicknickStore", "PicknickTestSupport"]),
        .testTarget(name: "PicknickBrokerTests", dependencies: ["PicknickBroker", "PicknickStore", "PicknickTestSupport"]),
        .testTarget(
            name: "PicknickCLIPTests",
            dependencies: ["PicknickCLIP", "PicknickTestSupport"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
