//
//  DeveloperServicesAssignAppGroupsOperation.swift
//  XKit
//
//  Created by Kabir Oberai on 14/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import DeveloperAPI
import XUtils

public struct DeveloperServicesAssignAppGroupsOperation: DeveloperServicesOperation {

    public let context: SigningContext
    public let groupIDs: [DeveloperServicesAppGroup.GroupID]
    public let appID: Components.Schemas.BundleId
    public let xcodeAuthData: XcodeAuthData

    private let client: DeveloperServicesClient

    public init?(
        context: SigningContext,
        groupIDs: [DeveloperServicesAppGroup.GroupID],
        appID: Components.Schemas.BundleId
    ) {
        self.context = context
        self.groupIDs = groupIDs
        self.appID = appID

        guard case .xcode(let authData) = context.auth else { return nil }
        self.xcodeAuthData = authData

        self.client = DeveloperServicesClient(authData: authData)
    }

    private func getOrCreateAppGroup(
        _ groupID: DeveloperServicesAppGroup.GroupID,
        existingGroups: [DeveloperServicesAppGroup]
    ) async throws -> DeveloperServicesAppGroup {
        let sanitized = ProvisioningIdentifiers.sanitize(groupID: groupID)
        // The group as written when registered, else an earlier xtool registration of it
        // (group.XTL-<id>. from this or another sign-in, matched loosely as xtool always did).
        let matches = existingGroups.filter { ProvisioningIdentifiers.sanitize(groupID: $0.groupID) == sanitized }
        if ProvisioningIdentifiers.preferExactIdentifiers,
           let exact = matches.first(where: { $0.groupID.rawValue == groupID.rawValue }) {
            return exact
        }
        if let prefixed = matches.first(where: { ProvisioningIdentifiers.isPrefixed(groupID: $0.groupID) }) {
            return prefixed
        }
        if let any = matches.first {
            return any
        }
        func create(_ id: DeveloperServicesAppGroup.GroupID, name: String) async throws -> DeveloperServicesAppGroup {
            try await client.send(DeveloperServicesAddAppGroupRequest(
                platform: .iOS,
                teamID: xcodeAuthData.teamID,
                name: name,
                groupID: id
            ))
        }
        if ProvisioningIdentifiers.preferExactIdentifiers,
           groupID.rawValue.hasPrefix(ProvisioningIdentifiers.groupPrefix) {
            return try await create(groupID, name: ProvisioningIdentifiers.safeify(identifier: groupID.rawValue))
        }
        return try await create(
            ProvisioningIdentifiers.groupID(fromSanitized: sanitized, context: context),
            name: ProvisioningIdentifiers.groupName(fromSanitized: sanitized)
        )
    }

    public func perform() async throws -> [DeveloperServicesAppGroup.GroupID] {
        let existing = try await client.send(DeveloperServicesListAppGroupsRequest(
            platform: .iOS, teamID: xcodeAuthData.teamID
        ))

        let groups = try await groupIDs.concurrentMap { groupID in
            try await getOrCreateAppGroup(groupID, existingGroups: existing)
        }

        _ = try await client.send(
            DeveloperServicesAssignAppGroupRequest(
                platform: .iOS,
                teamID: xcodeAuthData.teamID,
                appIDID: appID.id,
                groupIDs: groups.map(\.id)
            )
        )

        return groups.map(\.groupID)
    }

}
