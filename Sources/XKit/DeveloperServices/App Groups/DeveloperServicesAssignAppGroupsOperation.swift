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
        existingGroups: [String: DeveloperServicesAppGroup]
    ) async throws -> DeveloperServicesAppGroup {
        let sanitized = ProvisioningIdentifiers.sanitize(groupID: groupID)
        let exact = ProvisioningIdentifiers.preferExactIdentifiers
        // Same order as bundle identifiers: the group as written, an earlier prefixed
        // one, then register as written and fall back to the prefix.
        if exact, let existingGroup = existingGroups[groupID.rawValue] {
            return existingGroup
        }
        if let existingGroup = existingGroups[ProvisioningIdentifiers.groupID(fromSanitized: sanitized, context: context).rawValue] {
            return existingGroup
        }
        func create(_ id: DeveloperServicesAppGroup.GroupID, name: String) async throws -> DeveloperServicesAppGroup {
            try await client.send(DeveloperServicesAddAppGroupRequest(
                platform: .iOS,
                teamID: xcodeAuthData.teamID,
                name: name,
                groupID: id
            ))
        }
        if exact, groupID.rawValue.hasPrefix(ProvisioningIdentifiers.groupPrefix),
           let created = try? await create(groupID, name: ProvisioningIdentifiers.safeify(identifier: groupID.rawValue)) {
            return created
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
        // Keyed by the registered group identifier as is.
        let dict = Dictionary(existing.map { ($0.groupID.rawValue, $0) }, uniquingKeysWith: { $1 })
        let groups = try await groupIDs.concurrentMap { groupID in
            try await getOrCreateAppGroup(groupID, existingGroups: dict)
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
