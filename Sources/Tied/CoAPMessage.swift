//
//  CoAPMessage.swift
//
//
//  Created by Yachin Ilya on 15.05.2022.
//

import Foundation
import Network
import UInt4

public struct CoAPMessage: Codable {
    var version: Version
    var type: MessageType
    var tokenLength: UInt4 { UInt4(withUnsafeBytes(of: token) { [UInt8]($0) }.drop { $0 == .zero }.count) }
    var messageId: UInt8
    var token: UInt64
    var options: MessageOptionSet
    var payload: Data
    var metadata: NWProtocolFramer.Message
    var observe: Bool
    var data: Data {
        payload
    }

    public enum Version: UInt4 {
        case v1 = 1
    }

    public enum MessageType: UInt4 {
        case confirmable = 0
        case nonconfirmable = 1
        case acknowledgement = 2
        case reset = 3
    }

    public struct MessageOption, Comparable, Codable {
        let key: MessageOptionKey
        let value: Data

        static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.key < rhs.key
        }
    }

    public enum MessageOptionKey: UInt4, Comparable {
        case ifMatch = 1
        case uriHost = 3
        case eTag = 4
        case ifNoneMatch = 5
        case uriPort = 7
        case locationPath = 8
        case uriPath = 11
        case contentFormat = 12
        case maxAge = 14
        case uriQuery = 15
        case accept = 17
        case locationQuery = 20
        case proxyUri = 35
        case proxyScheme = 39
        case size1 = 60

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    typealias MessageOptionSet = [MessageOption]
}

extension CoAPMessage.MessageOptionSet: Codable {}
