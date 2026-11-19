//
//  DeveloperServicesFetchProfileOperation.swift
//  XKit
//
//  Created by Kabir Oberai on 13/10/19.
//  Copyright © 2019 Kabir Oberai. All rights reserved.
//

import Foundation
import Superutils
import DeveloperAPI

public struct DeveloperServicesFetchProfileOperation: DeveloperServicesOperation {

    public enum Errors: Error {
        case bundleIDNotFound
        case tooManyMatchingBundleIDs
        case invalidProfileData
    }

    public let context: SigningContext
    public let bundleID: String
    public let signingInfo: SigningInfo
    /// tvOS apps need a TVOS_APP_DEVELOPMENT profile listing Apple TVs; every other
    /// device platform (iPhone, iPad, Watch, Vision Pro) uses IOS_APP_DEVELOPMENT.
    public let isTVOS: Bool
    public init(context: SigningContext, bundleID: String, signingInfo: SigningInfo, isTVOS: Bool = false) {
        self.context = context
        self.bundleID = bundleID
        self.signingInfo = signingInfo
        self.isTVOS = isTVOS
    }

    public func perform() async throws -> Mobileprovision {
        let bundleIDs = try await context.developerAPIClient
            .bundleIdsGetCollection(query: .init(
                filter_lbrack_identifier_rbrack_: [bundleID],
                fields_lbrack_profiles_rbrack_: [.bundleId],
                include: [.profiles]
            ))
            .ok.body.json

        // filter[identifier] is a prefix filter so we need to manually upgrade to equality
        let filtered = bundleIDs.data.filter { $0.attributes?.identifier == self.bundleID }

        let bundleID: Components.Schemas.BundleId
        switch filtered.count {
        case 0:
            throw Errors.bundleIDNotFound
        case 1:
            bundleID = filtered[0]
        default:
            throw Errors.tooManyMatchingBundleIDs
        }

        // match locally rather than with filter[serialNumber]: server-side matching bugs out
        // when the serial has leading zeroes (#305)
        let certs = try await DeveloperAPIPages(\.links.next) {
            try await context.developerAPIClient.certificatesGetCollection().ok.body.json
        }
        .map(\.data)
        .reduce(into: [], +=)
        .filter { $0.attributes?.serialNumber.map(signingInfo.certificate.hasSerialNumber) == true }

        let allDevices = try await DeveloperAPIPages(\.links.next) {
            try await context.developerAPIClient.devicesGetCollection().ok.body.json
        }
        .map(\.data)
        .reduce(into: [], +=)
        .filter {
            $0.attributes?.status?.value1 != .disabled
            && $0.attributes?.deviceClass?.value1.map { isTVOS ? $0 == .appleTv : $0.supportsIOSApps } == true
        }

        try Task.checkCancellation()

        let profileName = isTVOS ? "XTL tvOS profile \(bundleID.id)" : "XTL profile \(bundleID.id)"

        let profiles = bundleID.relationships?.profiles?.data ?? []
        if !profiles.isEmpty {
            // we can't create multiple profiles with the same name, so
            // if there's already one delete it first
            let matchingProfiles = try await context.developerAPIClient.profilesGetCollection(query: .init(
                filter_lbrack_name_rbrack_: [profileName],
                filter_lbrack_id_rbrack_: profiles.map(\.id),
                fields_lbrack_profiles_rbrack_: [.name],
            ))
            .ok.body.json.data
            .filter { $0.attributes?.name == profileName }

            _ = try await matchingProfiles.concurrentMap {
                try await context.developerAPIClient.profilesDeleteInstance(path: .init(id: $0.id)).noContent
            }
        }

        let response = try await context.developerAPIClient.profilesCreateInstance(
            body: .json(
                .init(
                    data: .init(
                        _type: .profiles,
                        attributes: .init(
                            name: profileName,
                            profileType: .init(isTVOS ? .tvosAppDevelopment : .iosAppDevelopment)
                        ),
                        relationships: .init(
                            bundleId: .init(
                                data: .init(_type: .bundleIds, id: bundleID.id)
                            ),
                            devices: .init(data: allDevices.map {
                                .init(_type: .devices, id: $0.id)
                            }),
                            certificates: .init(data: certs.map {
                                .init(_type: .certificates, id: $0.id)
                            })
                        )
                    )
                )
            )
        )
        .created.body.json.data

        guard let contentString = response.attributes?.profileContent,
              let contentData = Data(base64Encoded: contentString)
              else { throw Errors.invalidProfileData }

        return try Mobileprovision(data: contentData)
    }

}

extension Components.Schemas.Device.AttributesPayload.DeviceClassPayload.Value1Payload {
    fileprivate var supportsIOSApps: Bool {
        switch self {
        case .ipad, .iphone, .ipod, .appleWatch, .appleVisionPro: true
        default: false
        }
    }
}
