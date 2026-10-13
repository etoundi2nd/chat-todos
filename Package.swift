// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ChatTodos",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ChatTodos", path: "Sources/ChatTodos"),
        .testTarget(name: "ChatTodosTests", dependencies: ["ChatTodos"], path: "Tests/ChatTodosTests"),
    ]
)
