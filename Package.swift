// swift-tools-version: 5.7
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "TinfoilChat",
    platforms: [
        .iOS(.v15)
    ],
    dependencies: [
        // RevenueCat SDK for in-app purchases
        .package(url: "https://github.com/RevenueCat/purchases-ios.git", from: "4.31.0"),
        
        // Existing dependencies should be added here as well
        // Add any other SPM dependencies your project uses
    ],
    targets: [
        .target(
            name: "TinfoilChat",
            dependencies: [
                .product(name: "RevenueCat", package: "purchases-ios"),
            ]
        )
    ]
)