//
//  DeveloperServicesAddAppOperation.swift
//  XKit
//
//  Created by Kabir Oberai on 14/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import DeveloperAPI
import Dependencies

public struct DeveloperServicesAddAppOperation: DeveloperServicesOperation {

    @Dependency(\.signer) private var signer

    public enum Error: LocalizedError, CustomStringConvertible {
        case invalidApp(URL)
        case tooManyAppGroups(bundleID: String, groups: [DeveloperServicesAppGroup.GroupID])
        /// Apple refused to register the identifier as written (another team has it).
        case identifierUnavailable(String)
        /// Apple refused to register the identifier, with its explanation.
        case registrationRefused(String, String)

        public var errorDescription: String? {
            description
        }

        public var description: String {
            switch self {
            case .invalidApp(let url):
                "Invalid app: \(url.path)"
            case .tooManyAppGroups(let bundleID, let groups):
                """
                App '\(bundleID)' requests multiple app groups: \(groups.map(\.rawValue).joined(separator: ", ")), \
                which is not permitted when using a free team.
                """
            case .identifierUnavailable(let identifier):
                "The identifier '\(identifier)' is not available to this team"
            case .registrationRefused(let identifier, let detail):
                "Apple refused to register '\(identifier)': \(detail.isEmpty ? "409 Conflict" : detail)"
            }
        }
    }

    public let context: SigningContext
    public let signingInfo: SigningInfo
    public let root: URL
    public init(context: SigningContext, signingInfo: SigningInfo, root: URL) {
        self.context = context
        self.signingInfo = signingInfo
        self.root = root
    }

    /// Registers the app with the given entitlements
    private func upsertApp(
        bundleID: String,
        entitlements: Entitlements,
        isFreeTeam: Bool,
        mode: ProvisioningIdentifiers.Mode,
        registered: [Components.Schemas.BundleId]
    ) async throws -> Components.Schemas.BundleId {
        let prefixedBundleID = ProvisioningIdentifiers.identifier(fromSanitized: bundleID, context: self.context)
        let wanted = mode == .exact ? bundleID : prefixedBundleID

        let appID: Components.Schemas.BundleId
        if let existing = registered.first(where: { $0.attributes?.identifier == wanted }) {
            appID = existing
        } else {
            let name = mode == .exact
                ? ProvisioningIdentifiers.safeify(identifier: bundleID)
                : ProvisioningIdentifiers.appName(fromSanitized: bundleID)
            let response = try await context.developerAPIClient.bundleIdsCreateInstance(
                body: .json(
                    .init(
                        data: .init(
                            _type: .bundleIds,
                            attributes: .init(
                                name: name,
                                platform: .init(.ios),
                                identifier: wanted
                            )
                        )
                    )
                )
            )
            switch response {
            case .created(let created):
                appID = try created.body.json.data
            case .conflict(let conflict):
                let details = ((try? conflict.body.json)?.errors ?? []).map(\.detail)
                // Apple's wording for an identifier another team owns; other 409s (e.g. the
                // free-team App ID limit) are reported as they are.
                let unavailable = details.contains {
                    $0.localizedCaseInsensitiveContains("not available")
                        || $0.localizedCaseInsensitiveContains("already")
                }
                if unavailable, mode == .exact {
                    throw Error.identifierUnavailable(wanted)
                }
                throw Error.registrationRefused(wanted, details.joined(separator: "; "))
            default:
                appID = try response.created.body.json.data
            }
        }

        let existingCapabilitiesList = try await context.developerAPIClient
            .bundleIdsBundleIdCapabilitiesGetToManyRelated(.init(path: .init(id: appID.id)))
            .ok.body.json.data
        let existingCapabilities = [Components.Schemas.CapabilityType: Components.Schemas.BundleIdCapability](
            existingCapabilitiesList.compactMap { cap in
                (cap.attributes?.capabilityType).map { ($0, cap) }
            },
            uniquingKeysWith: { $1 }
        )

        let wantedCapabilitiesList = try entitlements.entitlements().compactMap(\.anyCapability)
        let wantedCapabilities = [Components.Schemas.CapabilityType: [Components.Schemas.CapabilitySetting]](
            wantedCapabilitiesList.map { ($0.capabilityType, $0.settings ?? []) },
            uniquingKeysWith: { $1 }
        )

        for (typ, cap) in existingCapabilities {
            if let wantedSettings = wantedCapabilities[typ] {
                if wantedSettings != (cap.attributes?.settings ?? []) {
                    _ = try await context.developerAPIClient.bundleIdCapabilitiesUpdateInstance(
                        path: .init(id: cap.id),
                        body: .json(
                            .init(
                                data: .init(
                                    _type: .bundleIdCapabilities,
                                    id: cap.id,
                                    attributes: .init(
                                        capabilityType: typ,
                                        settings: wantedSettings
                                    )
                                )
                            )
                        )
                    )
                    .ok
                }
            } else {
                // DeveloperServices doesn't allow deleting these capabilities
                let requiredCapabilities: Set<Components.Schemas.CapabilityType.Value1Payload> = [.inAppPurchase]
                if let capType = cap.attributes?.capabilityType?.value1, !requiredCapabilities.contains(capType) {
                    _ = try await context.developerAPIClient
                        .bundleIdCapabilitiesDeleteInstance(path: .init(id: cap.id))
                        .noContent
                }
            }
        }
        for (typ, settings) in wantedCapabilities {
            guard existingCapabilities[typ] == nil else { continue }
            _ = try await context.developerAPIClient.bundleIdCapabilitiesCreateInstance(
                body: .json(.init(data: .init(
                    _type: .bundleIdCapabilities,
                    attributes: .init(
                        capabilityType: typ,
                        settings: settings
                    ),
                    relationships: .init(
                        bundleId: .init(
                            data: .init(
                                _type: .bundleIds,
                                id: appID.id
                            )
                        ),
                        // not public but required iff using ds2 API
                        capability: context.auth.isPublicAPI ? nil : .init(
                            data: .init(
                                _type: .capabilities,
                                id: typ
                            )
                        )
                    )
                )))
            )
            .created.body
        }

        return appID
    }

    /// Registers the app and creates a profile. Returns the resultant entitlements as well as
    /// the profile (note that the profile does not necessarily include all of the entitlements
    /// that the app has).
    static func isTVOS(app: URL) -> Bool {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let platforms = plist["CFBundleSupportedPlatforms"] as? [String]
        else { return false }
        return platforms.contains { $0.hasPrefix("AppleTV") }
    }

    private func addApp(
        _ app: URL,
        isFreeTeam: Bool,
        mode: ProvisioningIdentifiers.Mode,
        registered: [Components.Schemas.BundleId]
    ) async throws -> ProvisioningInfo {
        let infoURL = app.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
            let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            let bundleID = dict["CFBundleIdentifier"] as? String,
            let executable = dict["CFBundleExecutable"] as? String else {
            throw Error.invalidApp(app)
        }
        let executableURL = app.appendingPathComponent(executable)

        var entitlements: Entitlements
        // if the executable doesn't already have entitlements, that's
        // okay. We don't have to throw an error.
        if let entitlementsData = try? await signer.analyze(executable: executableURL),
            let decodedEntitlements = try? PropertyListDecoder().decode(Entitlements.self, from: entitlementsData) {
            entitlements = decodedEntitlements

            if isFreeTeam {
                // re-assign rather than using updateEntitlements since the latter will
                // retain unrecognized entitlements
                let filtered = try entitlements.entitlements().filter { $0.anyCapability?.isFree != false }
                if let groups = filtered.lazy.compactMap({ $0 as? AppGroupEntitlement }).first?.rawValue,
                    groups.count > 1 {
                    throw Error.tooManyAppGroups(bundleID: bundleID, groups: groups)
                }
                entitlements = try Entitlements(entitlements: filtered)
            }
        } else {
            entitlements = try Entitlements(entitlements: [])
        }

        let appID = try await upsertApp(
            bundleID: bundleID, entitlements: entitlements, isFreeTeam: isFreeTeam,
            mode: mode, registered: registered
        )
        let newBundleID = appID.attributes!.identifier!

        let teamID = try signingInfo.certificate.teamID()
        try entitlements.update(
            teamID: .init(rawValue: teamID),
            bundleID: newBundleID
        )
        // set get-task-allow to YES, required for dev certs
        try entitlements.updateEntitlements { ents in
            if let getTaskAllow = ents.firstIndex(where: { $0 is GetTaskAllowEntitlement }) {
                ents[getTaskAllow] = GetTaskAllowEntitlement(rawValue: true)
            } else {
                ents.append(GetTaskAllowEntitlement(rawValue: true))
            }
        }

        if var entitlementsArray = try? entitlements.entitlements(),
            let groupsIdx = entitlementsArray.firstIndex(where: { $0 is AppGroupEntitlement }),
            let groupsEntitlement = entitlementsArray[groupsIdx] as? AppGroupEntitlement {
            let groups = groupsEntitlement.rawValue

            if let operation = DeveloperServicesAssignAppGroupsOperation(
                context: self.context,
                groupIDs: groups,
                appID: appID,
                mode: mode
            ) {
                let newGroups = try await operation.perform()
                entitlementsArray[groupsIdx] = AppGroupEntitlement(rawValue: newGroups)
                try entitlements.setEntitlements(entitlementsArray)
            }
        }

        let mobileprovision = try await DeveloperServicesFetchProfileOperation(
            context: self.context,
            bundleID: newBundleID,
            signingInfo: signingInfo,
            isTVOS: Self.isTVOS(app: app)
        ).perform()

        return ProvisioningInfo(
            newBundleID: newBundleID,
            entitlements: entitlements,
            mobileprovision: mobileprovision
        )
    }

    /// Registers the app + its extensions, returning the profile and entitlements of each
    public func perform() async throws -> [URL: ProvisioningInfo] {
        var apps: [URL] = [root]

        for pluginsDir in ["PlugIns", "Extensions"] {
            let plugins = root.appendingPathComponent(pluginsDir)
            guard plugins.dirExists else { continue }
            apps += plugins.implicitContents.filter { $0.pathExtension.lowercased() == "appex" }
        }
        // A companion watch app (Watch/<Name>.app, identifier <app id>.watchkitapp) and its
        // extensions get their own App IDs and profiles like the app's extensions.
        let watch = root.appendingPathComponent("Watch")
        if watch.dirExists {
            for watchApp in watch.implicitContents where watchApp.pathExtension.lowercased() == "app" {
                apps.append(watchApp)
                for pluginsDir in ["PlugIns", "Extensions"] {
                    let plugins = watchApp.appendingPathComponent(pluginsDir)
                    guard plugins.dirExists else { continue }
                    apps += plugins.implicitContents.filter { $0.pathExtension.lowercased() == "appex" }
                }
            }
        }

        let isFreeTeam = try await context.auth.team()?.isFree == true

        // The app decides exact vs prefixed identifiers; its extensions (and app groups)
        // follow it, since an extension's identifier must start with the app's. App IDs are
        // listed once and matched locally: filter[identifier] is a prefix filter.
        let registered = try await DeveloperAPIPages(\.links.next) {
            try await context.developerAPIClient.bundleIdsGetCollection().ok.body.json
        }
        .map(\.data)
        .reduce(into: [], +=)
        let rootMode = try identifierMode(for: root, registered: registered)
        let rootInfo: ProvisioningInfo
        do {
            rootInfo = try await addApp(root, isFreeTeam: isFreeTeam, mode: rootMode, registered: registered)
        } catch Error.identifierUnavailable where rootMode == .exact {
            return try await provision(apps: apps, isFreeTeam: isFreeTeam, mode: .prefixed, registered: registered)
        }
        let extensions = Array(apps.dropFirst())
        var result = try await provision(
            apps: extensions, isFreeTeam: isFreeTeam, mode: rootMode, registered: registered
        )
        result[root] = rootInfo
        return result
    }

    /// The identifier as written when the team has it (e.g. registered by Xcode, so the build
    /// replaces the Xcode-built app) or has neither form; the prefixed one when only that is
    /// registered (an app xtool installed before keeps its identity and data). Opting out with
    /// XTOOL_PREFIX_IDS=1 always gives the prefix.
    private func identifierMode(
        for app: URL, registered: [Components.Schemas.BundleId]
    ) throws -> ProvisioningIdentifiers.Mode {
        guard ProvisioningIdentifiers.preferExactIdentifiers else { return .prefixed }
        let infoURL = app.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = dict["CFBundleIdentifier"] as? String else {
            throw Error.invalidApp(app)
        }
        let prefixed = ProvisioningIdentifiers.identifier(fromSanitized: bundleID, context: context)
        let identifiers = Set(registered.compactMap { $0.attributes?.identifier })
        if identifiers.contains(bundleID) { return .exact }
        return identifiers.contains(prefixed) ? .prefixed : .exact
    }

    private func provision(
        apps: [URL], isFreeTeam: Bool, mode: ProvisioningIdentifiers.Mode,
        registered: [Components.Schemas.BundleId]
    ) async throws -> [URL: ProvisioningInfo] {
        try await withThrowingTaskGroup(
            of: (URL, ProvisioningInfo).self,
            returning: [URL: ProvisioningInfo].self
        ) { group in
            for app in apps {
                group.addTask {
                    let info = try await addApp(app, isFreeTeam: isFreeTeam, mode: mode, registered: registered)
                    return (app, info)
                }
            }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
    }

}
