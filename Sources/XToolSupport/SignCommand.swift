import XUtils
import Foundation
import XKit
import ArgumentParser
import XCLIUtils

/// Sign an already-built .app for development, without a device connection: registers the
/// app (and its extensions) with the signed-in team, fetches the development profiles and
/// signs in place, as `xtool dev build --sign` does after building. For apps finished by
/// other tools (asset catalogs, resources) and installed some other way, e.g. on an Apple TV
/// through pymobiledevice3.
struct SignCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sign",
        abstract: "Sign a built .app for development, in place"
    )

    @Argument(
        help: "The .app to sign"
    ) var path: String

    func run() async throws {
        guard let token = try AuthToken.savedIfPresent() else {
            throw Console.Error("`sign` requires logging in with `xtool auth`")
        }
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension == "app", url.dirExists else {
            throw Console.Error("\(path) is not an .app directory")
        }

        let installer = IntegratedInstaller(
            auth: token.authData(),
            delegate: XToolInstallerDelegate()
        )
        do {
            defer { d.out.print() }
            let bundleID = try await installer.signInPlace(app: url)
            d.out.print("Signed \(url.lastPathComponent) as \(bundleID)")
        } catch let error as CancellationError {
            throw error
        } catch {
            d.out.print("Error: \(error)")
            throw ExitCode.failure
        }
    }
}
