// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BiomimeticRadarCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "BiomimeticRadarCore", targets: ["BiomimeticRadarCore"])],
    targets: [
        .target(
            name: "BiomimeticRadarCore", path: "BiomimeticRadar",
            exclude: ["App", "Views", "Services", "Resources"],
            sources: [
                "Models/SensorModels.swift", "Models/ExperimentModels.swift", "Processing/SignalProcessor.swift",
                "Processing/SyntheticDataSimulator.swift", "Processing/LightningCoupling.swift",
                "Processing/SignalCensus.swift",
                "Processing/FFT.swift", "Processing/BandRegistry.swift", "Processing/CrossBandCoupling.swift",
                "Processing/ReferenceSignals.swift", "Processing/EmitterSchedule.swift",
                "Processing/StreamChunk.swift", "Processing/QualityGates.swift",
                "Processing/QualityGatesSession.swift", "Processing/InterferenceRegistry.swift",
            ]),
        .testTarget(
            name: "BiomimeticRadarCoreTests", dependencies: ["BiomimeticRadarCore"], path: "BiomimeticRadarTests",
            resources: [.copy("golden")]),
    ]
)
