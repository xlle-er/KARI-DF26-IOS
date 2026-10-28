// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "KariNative", defaultLocalization: "en", platforms: [.iOS(.v15)],
    products: [.library(name: "KariNative", targets: ["KariNative"])],
    dependencies: [.package(url: "https://github.com/google/GoogleSignIn-iOS.git", from: "9.0.0"), .package(url: "https://github.com/google-ai-edge/mediapipe.git", revision: "e9794ef55e2509c09aa8b6ba1764b797db8eb200")],
    targets: [.target(name: "KariNative", dependencies: [.product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"), .product(name: "MediaPipeTasksVision", package: "mediapipe")],
                      resources: [.copy("Resources/Face"), .copy("Resources/Models"), .process("Resources/LiveSetup.json"), .process("Resources/IdleScenes.json"), .process("Resources/en.lproj"), .process("Resources/zh-Hans.lproj")])]
)
