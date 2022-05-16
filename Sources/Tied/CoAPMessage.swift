//
//  CoAPMessage.swift
//
//
//  Created by Yachin Ilya on 15.05.2022.
//

import Foundation
import Network
import UInt4

protocol DataEncodable {
    func encode() throws -> Data
}

protocol DataDecodable {
    static func with(_ buffer: UnsafeMutableRawBufferPointer) throws -> Self
}

typealias DataCodable = DataEncodable & DataDecodable

public struct CoAPMessage {
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

    public struct MessageOption: Comparable {
        let key: MessageOptionKey
        let value: Data

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.key < rhs.key
        }
    }

    public enum MessageOptionKey: UInt8, Comparable {
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

extension CoAPMessage.MessageOptionSet: DataCodable {
    private enum CodingError: Error {
        case encoding(String)
        case decoding(String)
    }

    func encode() -> Data {
        var lastDelta: UInt32 = 0
        var output = Data()

        sorted()
            .forEach { option in
                let delta = UInt32(option.key) - lastDelta
                let length = UInt32(option.value.count)

                let (optionDeltaValue, extendedDeltaValue) = Self.checkExtendedValue(delta)
                let (optionLengthValue, extendedLengthValue) = Self.checkExtendedValue(length)

                output.append(UInt8(optionDeltaValue | optionLengthValue))
                output.append(contentsOf: extendedDeltaValue)
                output.append(contentsOf: extendedLengthValue)
                output.append(contentsOf: option.value)

                lastDelta += UInt32(option.key)
            }

        return output
    }
    
    static func with(_: UnsafeMutableRawBufferPointer) throws -> Self {
        []
    }
    
    private static let extendTo8bitIndicator: UInt4 = 13
    private static let extendTo16bitIndicator: UInt4 = 14
    private static let reservedIndicator: UInt4 = 15

    private static func checkExtendedValue(_ value: UInt32) -> (UInt4, Data) {
        if value < Self.extendTo8bitIndicator {
            return (
                UInt4(clamping: value),
                Data()
            )
        }
        let extendedTo16bitCheck = (UInt16(Self.extendTo16bitIndicator) + 0xFF)
        if value >= Self.extendTo8bitIndicator, value < extendedTo16bitCheck {
            return (
                Self.extendTo8bitIndicator,
                Data([UInt8(value - UInt32(Self.extendTo8bitIndicator))])
            )
        }
        if value >= extendedTo16bitCheck {
            return (
                Self.extendTo16bitIndicator,
                Data(Swift.withUnsafeBytes(of: UInt16(clamping: value) - extendedTo16bitCheck) { [UInt8]($0) })
            )
        }
        return (0, Data())
    }
}

private extension UInt32 {
    init(_ optionKey: CoAPMessage.MessageOptionKey) {
        self.init(optionKey.rawValue)
    }
}
