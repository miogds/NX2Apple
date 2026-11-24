import Foundation

/// The device family the shared app is built for: an iPhone or iPad, or an Apple Vision Pro. The build target stays
/// `BuildTarget.ios` for both (the one shared app on a device): the Build page's card decides the platform, and everything that
/// differs between the two is here. The engine side is patches 0064 to 0067 (`DM_SDK=xros`, `--platform visionos`).
package enum DevicePlatform: String, Equatable {
    case ios, visionos

    /// From devicectl's `hardwareProperties.platform` ("iOS", "visionOS", "xrOS" in older tools), nil for any other device.
    package init?(devicectl name: String?) {
        switch name {
        case "iOS": self = .ios
        case "visionOS", "xrOS": self = .visionos
        default: return nil
        }
    }

    /// The SDK's name: `DM_SDK` of build_ipa.sh and build_shell.sh, and the suffix of Xcode's products folder.
    package var sdk: String { self == .visionos ? "xros" : "iphoneos" }
    package var productsFolder: String { "Release-" + sdk }

    /// What the build script gets before `--shell-framework`: nothing for the iPhone, its default.
    package var scriptArguments: [String] { self == .visionos ? ["--platform", "visionos"] : [] }

    /// The folder in a game's build folder that holds its framework. A visionOS framework has one of its own, so an iPhone
    /// build of the same game keeps its framework (the script keeps its shader libraries and its app build apart the same way).
    package var frameworkFolder: String { self == .visionos ? "shell-framework-xros" : "shell-framework" }
    package static let frameworkFolders = [DevicePlatform.ios.frameworkFolder, DevicePlatform.visionos.frameworkFolder]

    /// The platform a built framework is for, from the folder it lies in (`frameworkFolder`). nil path: the iPhone's.
    package init(framework: String?) {
        self = framework.map { (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent } == DevicePlatform.visionos.frameworkFolder ? .visionos : .ios
    }

    /// The folder of the device's shader libraries in a game's build folder (`shader/ios`, `shader/xros`: the script's IOS_LIBS).
    package var shaderFolder: String { self == .visionos ? "xros" : "ios" }

    // ---- the shell folder ----

    /// A framework runs on the platform it was built for only, so the visionOS shared app has a shell folder of its own (its
    /// shell.json, frameworks, project and derived data): the iPhone's folder with this suffix. Everything that takes a shell
    /// folder reads the platform from its name, so the two never mix.
    package static let visionRootSuffix = "-visionos"

    package func root(_ iosRoot: String) -> String { self == .visionos ? iosRoot + Self.visionRootSuffix : iosRoot }

    package init(root: String) {
        self = (root as NSString).lastPathComponent.hasSuffix(Self.visionRootSuffix) ? .visionos : .ios
    }

    /// What build_shell.sh needs beyond the iPhone's environment.
    package var environment: [String: String] { self == .visionos ? ["DM_SDK": sdk] : [:] }
}
