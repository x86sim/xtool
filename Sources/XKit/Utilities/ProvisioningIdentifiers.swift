//
//  ProvisioningIdentifiers.swift
//  XKit
//
//  Created by Kabir Oberai on 14/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation

enum ProvisioningIdentifiers {}

extension ProvisioningIdentifiers {

    static let idPrefix = "XTL-"
    static let groupPrefix = "group."
    static let namePrefix = "XTool "

    static func sanitize(identifier: String) -> String {
        guard identifier.hasPrefix(Self.idPrefix) else { return identifier }
        return identifier.split(separator: ".").dropFirst().joined(separator: ".")
    }

    static func identifier(fromSanitized sanitized: String, context: SigningContext) -> String {
        let uuid = context.auth.identityID.split(separator: "-")[0].uppercased()
        return "\(Self.idPrefix)\(uuid).\(sanitized)"
    }

    /// How an app's identifiers (and its extensions') are registered.
    enum Mode: Sendable { case exact, prefixed }

    /// Whether to register identifiers exactly as the project spells them, like Xcode.
    /// xtool's prefix (XTL-<id>.) only avoids collisions with identifiers another team owns.
    /// The exact identifier when the team has it or has neither form; an app only registered
    /// with the prefix (installed by xtool before) keeps it; the prefix when Apple refuses the
    /// exact identifier (another team has it). An app's extensions follow the app.
    /// XTOOL_PREFIX_IDS=1 always prefixes, as xtool did before.
    static var preferExactIdentifiers: Bool {
        ProcessInfo.processInfo.environment["XTOOL_PREFIX_IDS"] != "1"
    }

    static func safeify(identifier: String) -> String {
        identifier.replacingOccurrences(of: ".", with: " ")
    }

    static func sanitize(groupID: DeveloperServicesAppGroup.GroupID) -> String {
        var id = groupID.rawValue
        if id.hasPrefix(Self.groupPrefix) { id.removeFirst(Self.groupPrefix.count) }
        return sanitize(identifier: id)
    }

    /// Whether a registered group was named by xtool (group.XTL-<id>.…).
    static func isPrefixed(groupID: DeveloperServicesAppGroup.GroupID) -> Bool {
        var id = groupID.rawValue
        if id.hasPrefix(Self.groupPrefix) { id.removeFirst(Self.groupPrefix.count) }
        return id.hasPrefix(Self.idPrefix)
    }

    static func groupID(fromSanitized sanitized: String, context: SigningContext) -> DeveloperServicesAppGroup.GroupID {
        .init(rawValue: "\(Self.groupPrefix)\(identifier(fromSanitized: sanitized, context: context))")
    }

    static func groupName(fromSanitized sanitized: String) -> String {
        "\(Self.namePrefix)group \(safeify(identifier: sanitized))"
    }

    static func appName(fromSanitized sanitized: String) -> String {
        "\(Self.namePrefix)\(safeify(identifier: sanitized))"
    }

}
