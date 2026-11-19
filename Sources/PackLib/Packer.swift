import Foundation
import XUtils
import Subprocess

public struct Packer: Sendable {
    public let buildSettings: BuildSettings
    public let plan: Plan

    public init(buildSettings: BuildSettings, plan: Plan) {
        self.plan = plan
        self.buildSettings = buildSettings
    }

    private func build(_ settings: BuildSettings? = nil) async throws {
        let buildSettings = settings ?? self.buildSettings
        let xtoolDir = URL(fileURLWithPath: "xtool")
        let packageDir = xtoolDir.appendingPathComponent(".xtool-tmp")
        try? FileManager.default.removeItem(at: packageDir)
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)

        if URL(fileURLWithPath: "Packages").dirExists {
            try FileManager.default.createSymbolicLink(
                atPath: packageDir.appendingPathComponent("Packages").path,
                withDestinationPath: "../../Packages"
            )
        }

        let packageSwift = packageDir.appendingPathComponent("Package.swift")
        // Carry the root package's tvOS/watchOS/visionOS deployment targets into the builder.
        // Use the same version Info.plist gets (MinimumOSVersion), so the binary and the plist agree.
        let declared = plan.app.infoPlist[Planner.minimumOSVersionsKey] as? [String: Sendable] ?? [:]
        let extraPlatforms = [("tvos", "tvOS"), ("watchos", "watchOS"), ("visionos", "visionOS")]
            .map { key, name in ".\(name)(\"\(Self.minimumOSVersion(declared: declared, packageName: key))\")," }
            .joined(separator: " ")
        let contents = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "\(plan.app.product)-Builder",
            platforms: [
                .iOS("\(plan.app.deploymentTarget)"), \(extraPlatforms)
            ],
            dependencies: [
                .package(name: "RootPackage", path: "../.."),
            ],
            targets: [
                \(
                    plan.allProducts.map {
                        """
                        .executableTarget(
                            name: "\($0.targetName)",
                            dependencies: [
                                .product(name: "\($0.product)", package: "RootPackage"),
                            ],
                            linkerSettings: \($0.linkerSettings)
                        )
                        """
                    }
                    .joined(separator: ",\n")
                )
            ]
        )\n
        """
        try Data(contents.utf8).write(to: packageSwift)

        // The builder package is built with --disable-automatic-resolution, which
        // requires a Package.resolved. Without one, any branch-pinned dependency of
        // the root package fails the build ("a resolved file is required when
        // automatic dependency resolution is disabled ... but now has a different
        // revision-based requirement"). The root package was resolved when the plan
        // was dumped, so reuse its pins.
        let rootResolved = URL(fileURLWithPath: "Package.resolved")
        if FileManager.default.fileExists(atPath: rootResolved.path) {
            try FileManager.default.copyItem(
                at: rootResolved,
                to: packageDir.appendingPathComponent("Package.resolved")
            )
        }

        for product in plan.allProducts {
            let sources: URL = packageDir.appendingPathComponent("Sources/\(product.targetName)", isDirectory: true)
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try Data().write(to: sources.appendingPathComponent("stub.c", isDirectory: false))
        }

        let buildConfig = try await buildSettings
            .withPackagePath(packageDir.path)
            .swiftPMInvocation(
                forTool: "build",
                arguments: [
                    "--scratch-path", ".build",
                    // resolving can cause SwiftPM to overwrite the root package deps
                    // with just the deps needed for the builder package (which is to
                    // say, any "dev dependencies" of the root package may be removed.)
                    // fortunately we've already resolved the root package by this point
                    // in order to dump the plan, so we can skip resolution here to skirt
                    // the issue.
                    "--disable-automatic-resolution",
                ],
            )
        try await Subprocess.run(
            buildConfig,
            output: .currentStandardOutput,
            error: .currentStandardError,
        )
        .checkSuccess()
    }

    public func pack() async throws -> URL {
        try await build()

        let output = try TemporaryDirectory(name: "\(plan.app.product).app")

        let outputURL = output.url

        var binDir = Self.productsDir(for: buildSettings)
        if Self.needsWatchArm64Slice(triple: buildSettings.triple) {
            binDir = try await universalWatchProducts(arm64_32Dir: binDir)
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for product in plan.allProducts {
                try pack(
                    product: product,
                    binDir: binDir,
                    outputURL: product.directory(inApp: outputURL),
                    &group
                )
            }

            while !group.isEmpty {
                do {
                    try await group.next()
                } catch is CancellationError {
                    // continue
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        }

        let dest = URL(fileURLWithPath: "xtool").appendingPathComponent(outputURL.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        try output.persist(at: dest)
        return dest
    }

    @Sendable private func pack(
        product: Plan.Product,
        binDir: URL,
        outputURL: URL,
        _ group: inout ThrowingTaskGroup<Void, Error>
    ) throws {
        @Sendable func packFileToRoot(srcName: String) async throws {
            let srcURL = URL(fileURLWithPath: srcName)
            let destURL = outputURL.appendingPathComponent(srcURL.lastPathComponent)
            try FileManager.default.copyItem(at: srcURL, to: destURL)

            try Task.checkCancellation()
        }

        @Sendable func packFile(srcName: String, dstName: String? = nil, sign: Bool = false) async throws {
            let srcURL = URL(fileURLWithPath: srcName, relativeTo: binDir)
            let dstURL = URL(fileURLWithPath: dstName ?? srcURL.lastPathComponent, relativeTo: outputURL)
            try? FileManager.default.createDirectory(at: dstURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: srcURL, to: dstURL)

            try Task.checkCancellation()
        }

        // Ensure output directory is available
        try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

        for command in product.resources {
            group.addTask {
                switch command {
                case .bundle(let package, let target):
                    try await packFile(srcName: "\(package)_\(target).bundle")
                case .binaryTarget(let name):
                    let src = URL(fileURLWithPath: "\(name).framework/\(name)", relativeTo: binDir)
                    let magic = Data("!<arch>\n".utf8)
                    let thinMagic = Data("!<thin>\n".utf8)
                    guard let bytes = try? FileHandle(forReadingFrom: src).read(upToCount: magic.count) else {
                        // if we can't find the binary, it might be a static framework that SwiftPM
                        // did not copy into the .build directory. we don't need to pack it anyway.
                        break
                    }
                    // if the magic matches one of these it's a static archive; don't embed it.
                    // https://github.com/apple/llvm-project/blob/e716ff14c46490d2da6b240806c04e2beef01f40/llvm/include/llvm/Object/Archive.h#L33
                    // swiftlint:disable:previous line_length
                    if bytes != magic && bytes != thinMagic {
                        try await packFile(srcName: "\(name).framework", dstName: "Frameworks/\(name).framework", sign: true)
                    }
                case .library(let name):
                    guard product.type == .application else { break }
                    try await packFile(srcName: "lib\(name).dylib", dstName: "Frameworks/lib\(name).dylib", sign: true)
                case .root(let source):
                    try await packFileToRoot(srcName: source)
                }
            }
        }
        if let iconPath = product.iconPath {
            group.addTask {
                try await packFileToRoot(srcName: iconPath)
            }
        }
        group.addTask {
            try await packFile(srcName: product.targetName, dstName: product.product)
        }
        group.addTask {
            var info = product.infoPlist

            let minOS = info.removeValue(forKey: Planner.minimumOSVersionsKey) as? [String: Sendable] ?? [:]
            let userKeys = Set(info.removeValue(forKey: Planner.userInfoKeysKey) as? [String] ?? [])
            Packer.applyPlatformKeys(
                to: &info, triple: buildSettings.triple, minOS: minOS,
                isApp: product.type == .application, userKeys: userKeys
            )
            for (key, value) in Packer.buildEnvironmentKeys(triple: buildSettings.triple) where info[key] == nil {
                info[key] = value
            }
            if product.type == .application {
                try Data("APPL????".utf8).write(to: outputURL.appendingPathComponent("PkgInfo"))
            }

            if let iconPath = product.iconPath {
                let iconName = URL(fileURLWithPath: iconPath).deletingPathExtension().lastPathComponent
                info["CFBundleIconFile"] = iconName
            }

            let infoPath = outputURL.appendingPathComponent("Info.plist")
            let encodedPlist = try PropertyListSerialization.data(
                fromPropertyList: info,
                format: .xml,
                options: 0
            )
            try encodedPlist.write(to: infoPath)
        }
    }

    /// Xcode builds device watchOS apps for arm64_32 and arm64 (ARCHS_STANDARD) and
    /// ships a universal binary. Do the same when building for arm64_32 on device;
    /// XTOOL_WATCHOS_ARM64=0 keeps the single arm64_32 slice.
    static func needsWatchArm64Slice(triple: String) -> Bool {
        osName(for: triple) == "watchos"
            && triple.hasPrefix("arm64_32-")
            && !triple.contains("simulator")
            && ProcessInfo.processInfo.environment["XTOOL_WATCHOS_ARM64"] != "0"
    }

    /// Where a build leaves its products.
    static func productsDir(for settings: BuildSettings) -> URL {
        let binPath: String
        switch settings.buildSystem {
        case .swiftPM:
            binPath = "\(settings.triple)/\(settings.configuration.rawValue)"
        case .swiftBuild:
            let platformName = Packer.sdkPlatformName(for: settings.triple)
            binPath = "out/Products/\(settings.configuration.swiftBuildValue)-\(platformName)"
        }
        return URL(fileURLWithPath: ".build/\(binPath)", isDirectory: true)
    }

    /// Copies the arm64_32 products aside, builds the arm64 slice, and merges every
    /// Mach-O product (executables, dylibs, framework binaries) with lipo into the copy,
    /// which is what gets packed. The build's own products dir is never rewritten, so an
    /// incremental rebuild cannot take a merged binary for its own output.
    private func universalWatchProducts(arm64_32Dir: URL) async throws -> URL {
        let fm = FileManager.default
        let merged = URL(fileURLWithPath: ".build/xtool-watchos-universal", isDirectory: true)
        try? fm.removeItem(at: merged)
        try fm.copyItem(at: arm64_32Dir, to: merged)

        var thin: [String] = []
        for name in (try? fm.contentsOfDirectory(atPath: merged.path)) ?? [] {
            let rel = name.hasSuffix(".framework") ? "\(name)/\(name.dropLast(".framework".count))" : name
            guard let cpuType = Self.thinMachOCPUType(merged.appendingPathComponent(rel)) else { continue }
            guard cpuType == Self.cpuTypeARM64_32 else {
                throw StringError("\(rel) in \(arm64_32Dir.path) is not arm64_32; remove .build and build again")
            }
            thin.append(rel)
        }

        let arm64Settings = try await BuildSettings(
            configuration: buildSettings.configuration,
            triple: "arm64" + buildSettings.triple.dropFirst("arm64_32".count),
            buildSystem: buildSettings.buildSystem,
            packagePath: buildSettings.packagePath,
            options: buildSettings.customOptions
        )
        try await build(arm64Settings)
        let arm64Dir = Self.productsDir(for: arm64Settings)

        let lipo = ProcessInfo.processInfo.environment["LIPO"] ?? "llvm-lipo"
        for rel in thin {
            let arm64File = arm64Dir.appendingPathComponent(rel)
            guard Self.thinMachOCPUType(arm64File) == Self.cpuTypeARM64 else { continue }
            let file = merged.appendingPathComponent(rel)
            let output = merged.appendingPathComponent(rel + ".universal")
            try await Subprocess.run(
                .name(lipo),
                arguments: ["-create", file.path, arm64File.path, "-output", output.path],
                output: .currentStandardOutput,
                error: .currentStandardError,
            ).checkSuccess()
            try fm.removeItem(at: file)
            try fm.moveItem(at: output, to: file)
        }
        return merged
    }

    private static let cpuTypeARM64: UInt32 = 0x0100_000C
    private static let cpuTypeARM64_32: UInt32 = 0x0200_000C

    /// The cputype of a thin (non-fat) Mach-O file, or nil.
    private static func thinMachOCPUType(_ url: URL) -> UInt32? {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let bytes = try? handle.read(upToCount: 8), bytes.count == 8 else { return nil }
        let magic = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        guard magic == 0xfeedface || magic == 0xfeedfacf else { return nil }
        return bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
    }

    /// The OS component of an Apple triple without its version: ios, tvos, watchos, xros, macosx.
    static func osName(for triple: String) -> String {
        let components = triple.split(separator: "-").map(String.init)
        guard let appleIndex = components.firstIndex(of: "apple"),
              components.indices.contains(appleIndex + 1) else { return "ios" }
        return String(components[appleIndex + 1].prefix { !$0.isNumber })
    }

    /// SwiftBuild's products directory suffix (Release-<name>).
    static func sdkPlatformName(for triple: String) -> String {
        let sim = triple.contains("simulator")
        switch osName(for: triple) {
        case "tvos": return sim ? "appletvsimulator" : "appletvos"
        case "watchos": return sim ? "watchsimulator" : "watchos"
        case "xros", "visionos": return sim ? "xrsimulator" : "xros"
        case "macos", "macosx": return "macosx"
        default: return sim ? "iphonesimulator" : "iphoneos"
        }
    }

    /// The DT* keys Xcode writes from the SDK and Xcode it built with (App Store
    /// processing reads them). Read from the installed Darwin SDK and the Xcode
    /// version plist `xtool sdk install` keeps next to the .xtoolsdk. Empty when
    /// either is missing, e.g. on macOS builds through Xcode.
    static func buildEnvironmentKeys(triple: String) -> [String: Sendable] {
        #if os(macOS)
        return [:]
        #else
        guard let sdk = try? DarwinSDK.current() else { return [:] }
        let platformDir: String = switch cfBundleSupportedPlatforms(for: triple).first {
        case "AppleTVOS": "AppleTVOS"
        case "AppleTVSimulator": "AppleTVSimulator"
        case "WatchOS": "WatchOS"
        case "WatchSimulator": "WatchSimulator"
        case "XROS": "XROS"
        case "XRSimulator": "XRSimulator"
        case "iPhoneSimulator": "iPhoneSimulator"
        case "MacOSX": "MacOSX"
        default: "iPhoneOS"
        }
        let sdkDir = sdk.bundle.appendingPathComponent("Developer/Platforms/\(platformDir).platform/Developer/SDKs/\(platformDir).sdk")
        guard let settingsData = try? Data(contentsOf: sdkDir.appendingPathComponent("SDKSettings.json")),
              let settings = try? JSONSerialization.jsonObject(with: settingsData) as? [String: Any],
              let version = settings["Version"] as? String,
              let canonicalName = settings["CanonicalName"] as? String,
              let systemVersionData = try? Data(contentsOf: sdkDir.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")),
              let systemVersion = try? PropertyListSerialization.propertyList(from: systemVersionData, format: nil) as? [String: Any],
              let sdkBuild = systemVersion["ProductBuildVersion"] as? String
        else { return [:] }
        var keys: [String: Sendable] = [
            "DTCompiler": "com.apple.compilers.llvm.clang.1_0",
            "DTPlatformBuild": sdkBuild,
            "DTPlatformName": sdkPlatformName(for: triple),
            "DTPlatformVersion": version,
            "DTSDKBuild": sdkBuild,
            "DTSDKName": canonicalName,
        ]
        let cache = ProcessInfo.processInfo.environment["SDK_CACHE"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/xtool")
        // The plist of the Xcode the installed SDK came from: it is named after that
        // SDK's iPhoneOS SDK (darwin-iPhoneOS27.2.xtoolsdk.version.plist).
        let iPhoneOSSDKs = sdk.bundle.appendingPathComponent("Developer/Platforms/iPhoneOS.platform/Developer/SDKs")
        let iPhoneOSName = ((try? FileManager.default.contentsOfDirectory(atPath: iPhoneOSSDKs.path)) ?? [])
            .first { $0.hasPrefix("iPhoneOS") && $0 != "iPhoneOS.sdk" && $0.hasSuffix(".sdk") }
            .map { String($0.dropLast(".sdk".count)) }
        let xcodePlist = iPhoneOSName
            .flatMap { try? Data(contentsOf: cache.appendingPathComponent("darwin-\($0).xtoolsdk.version.plist")) }
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        if let xcodePlist,
           let xcodeVersion = xcodePlist["CFBundleShortVersionString"] as? String,
           let xcodeBuild = xcodePlist["ProductBuildVersion"] as? String {
            let parts = (xcodeVersion.split(separator: ".").map(String.init) + ["0", "0"]).prefix(3)
            let major = Int(parts[parts.startIndex]) ?? 0
            keys["DTXcode"] = String(format: "%02d", major) + parts.dropFirst().joined()
            keys["DTXcodeBuild"] = xcodeBuild
        }
        // Xcode records the build host's macOS build; there is none on Linux. Set
        // BUILD_MACHINE_OS_BUILD to reproduce a specific Xcode build exactly.
        if let host = ProcessInfo.processInfo.environment["BUILD_MACHINE_OS_BUILD"] {
            keys["BuildMachineOSBuild"] = host
        }
        return keys
        #endif
    }

    /// The deployment target for a tvOS, watchOS or visionOS build: the root package's,
    /// else xtool's minimum for that platform.
    static func minimumOSVersion(declared: [String: Sendable], packageName: String) -> String {
        declared[packageName] as? String
            ?? ["tvos": "17.0", "watchos": "10.0", "visionos": "1.0"][packageName] ?? "1.0"
    }

    /// Info.plist keys Xcode sets per platform. CFBundleSupportedPlatforms, DTPlatformName
    /// and (except on watchOS and visionOS) UIRequiredDeviceCapabilities are always set, as
    /// xtool always did for iOS; the other platform keys are defaults that keys from the
    /// project's own Info.plist (`userKeys`) override.
    static func applyPlatformKeys(
        to info: inout [String: Sendable], triple: String, minOS: [String: Sendable],
        isApp: Bool, userKeys: Set<String> = []
    ) {
        func set(_ key: String, _ value: Sendable) {
            if !userKeys.contains(key) { info[key] = value }
        }
        func remove(_ keys: [String]) {
            for key in keys where !userKeys.contains(key) { info.removeValue(forKey: key) }
        }
        let os = osName(for: triple)
        // SwiftPM platform names in Package.swift
        if let packageName = ["tvos": "tvos", "watchos": "watchos", "xros": "visionos", "visionos": "visionos"][os] {
            set("MinimumOSVersion", minimumOSVersion(declared: minOS, packageName: packageName))
        }
        info["CFBundleSupportedPlatforms"] = cfBundleSupportedPlatforms(for: triple)
        info["DTPlatformName"] = sdkPlatformName(for: triple)
        guard isApp else { return }
        let orientations = ["UISupportedInterfaceOrientations", "UISupportedInterfaceOrientations~ipad"]
        switch os {
        case "tvos":
            info["UIRequiredDeviceCapabilities"] = ["arm64"]
            set("UIDeviceFamily", [3])
            set("LSRequiresIPhoneOS", true)
            remove(orientations)
        case "watchos":
            info.removeValue(forKey: "UIRequiredDeviceCapabilities")
            set("UIDeviceFamily", [4])
            set("WKApplication", true)
            set("WKRunsIndependentlyOfCompanionApp", true)
            // Xcode 27 writes this for every watchOS app.
            set("MinimumOSVersion~ipad", "9.0")
            remove(orientations)
        case "xros", "visionos":
            info.removeValue(forKey: "UIRequiredDeviceCapabilities")
            set("UIDeviceFamily", [7])
            remove(orientations)
        default:
            info["UIRequiredDeviceCapabilities"] = ["arm64"]
            info["LSRequiresIPhoneOS"] = true
        }
    }

    static func cfBundleSupportedPlatforms(for triple: String) -> [String] {
        let components = triple.split(separator: "-").map(String.init)
        guard let appleIndex = components.firstIndex(of: "apple"),
              components.indices.contains(appleIndex + 1) else {
            return ["iPhoneOS"]
        }

        let os = components[appleIndex + 1].prefix { !$0.isNumber }
        switch os {
        case "ios" where components.contains("simulator"):
            return ["iPhoneSimulator"]
        case "ios":
            return ["iPhoneOS"]
        case "macos", "macosx":
            return ["MacOSX"]
        case "tvos":
            return [components.contains("simulator") ? "AppleTVSimulator" : "AppleTVOS"]
        case "watchos":
            return [components.contains("simulator") ? "WatchSimulator" : "WatchOS"]
        case "xros", "visionos":
            return [components.contains("simulator") ? "XRSimulator" : "XROS"]
        default:
            return ["iPhoneOS"]
        }
    }
}

extension Plan.Product {
    fileprivate var dynamicLibraries: [String] {
        resources.compactMap {
            if case .library(let name) = $0 { return name } else { return nil }
        }
    }

    fileprivate var linkerSettings: String {
        switch self.type {
        case .application:
            // SwiftBuild only embeds dynamic library products; without an explicit
            // link the app executable never references them and dies at load time
            // (or at link time when they are needed to satisfy imports).
            let linkLines = dynamicLibraries.map { name in
                "\n            .linkedLibrary(\"\(name)\"),"
            }.joined()
            return """
        [
            .unsafeFlags([
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
            ]),\(linkLines)
        ]
"""
        case .appExtension:
            return """
        [
            // Link to Foundation framework which implements the _NSExtensionMain entrypoint
            .linkedFramework("Foundation"),
            .unsafeFlags([
                // Set the entry point to Foundation`_NSExtensionMain
                "-Xlinker", "-e", "-Xlinker", "_NSExtensionMain",
                // Include frameworks that the host app may use
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/Frameworks",
            ]),
        ]
        """
        }
    }
}
