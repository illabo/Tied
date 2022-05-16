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

protocol MessageCode {
    var rawValue: UInt8? { get }
}

extension MessageCode {
    var codeError: Error { NSError(domain: "CoAP Message Code Error", code: -1000) }
}

typealias DataCodable = DataEncodable & DataDecodable

public struct CoAPMessage {
    internal init(
        version: CoAPMessage.Version = .v1,
        code: MessageCode,
        type: CoAPMessage.MessageType,
        messageId: UInt8,
        token: UInt64,
        options: CoAPMessage.MessageOptionSet,
        payload: Data
    ) {
        self.version = version
        self.code = code
        self.type = type
        self.messageId = messageId
        self.token = token
        self.options = options
        self.payload = payload
    }

    var version: Version
    var code: MessageCode
    var type: MessageType
    var messageId: UInt8
    var token: UInt64
    var options: MessageOptionSet
    var payload: Data

    private var tokenLength: UInt4 { UInt4(tokenData.count) }
    private var tokenData: Data { Data(withUnsafeBytes(of: token) { [UInt8]($0) }.drop { $0 == .zero }) }
}

extension CoAPMessage: DataCodable {
    func encode() throws -> Data {
        guard let code = code.rawValue else {
            throw code.codeError
        }
        
        var output = Data()

        output.append(UInt8((version.rawValue << 2) + type.rawValue | tokenLength))
        output.append(code)
        output.append(messageId)
        output.append(contentsOf: withUnsafeBytes(of: token) { [UInt8]($0) })
        output.append(contentsOf: options.encode())
        output.append(UInt8.max) // Payload separator.
        output.append(contentsOf: payload)

        return output
    }

    static func with(_: UnsafeMutableRawBufferPointer) throws -> CoAPMessage {
        throw NSError(domain: "Error", code: 0)
    }
}

extension CoAPMessage.MessageOptionSet: DataCodable {
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

extension CoAPMessage {
    public enum Version: UInt4 {
        case v1 = 1
    }

    public enum Code: MessageCode {
        case empty
        case custom(codeClass: UInt8, codeDetail: UInt8)
        
        public var rawValue: UInt8? {
            switch self {
            case .empty:
                return Self.value(codeClass: 0, codeDetail: 00)
            case .custom(codeClass: let c, codeDetail: let dd):
                return Self.value(codeClass: c, codeDetail: dd)
            }
        }

        public enum Method: MessageCode {
            case get
            case post
            case put
            case delete

            public var rawValue: UInt8? {
                switch self {
                case .get:
                    return Code.value(codeClass: 0, codeDetail: 01)
                case .post:
                    return Code.value(codeClass: 0, codeDetail: 02)
                case .put:
                    return Code.value(codeClass: 0, codeDetail: 03)
                case .delete:
                    return Code.value(codeClass: 0, codeDetail: 04)
                }
            }
        }

        public enum Request: MessageCode {
            case created
            case deleted
            case valid
            case changed
            case content
            case badRequest
            case unauthorized
            case badOption
            case forbidden
            case notFound
            case methodNotAllowed
            case notAcceptable
            case preconditionFailed
            case requestEntityTooLarge
            case unsupportedContentFormat
            case internalServerError
            case notImplemented
            case badGateway
            case serviceUnavailable
            case gatewayTimeout
            case proxyingNotSupported

            public var rawValue: UInt8? {
                switch self {
                case .created:
                    return Code.value(codeClass: 2, codeDetail: 01)
                case .deleted:
                    return Code.value(codeClass: 2, codeDetail: 02)
                case .valid:
                    return Code.value(codeClass: 2, codeDetail: 03)
                case .changed:
                    return Code.value(codeClass: 2, codeDetail: 04)
                case .content:
                    return Code.value(codeClass: 2, codeDetail: 05)
                case .badRequest:
                    return Code.value(codeClass: 4, codeDetail: 00)
                case .unauthorized:
                    return Code.value(codeClass: 4, codeDetail: 01)
                case .badOption:
                    return Code.value(codeClass: 4, codeDetail: 02)
                case .forbidden:
                    return Code.value(codeClass: 4, codeDetail: 03)
                case .notFound:
                    return Code.value(codeClass: 4, codeDetail: 04)
                case .methodNotAllowed:
                    return Code.value(codeClass: 4, codeDetail: 05)
                case .notAcceptable:
                    return Code.value(codeClass: 4, codeDetail: 06)
                case .preconditionFailed:
                    return Code.value(codeClass: 4, codeDetail: 12)
                case .requestEntityTooLarge:
                    return Code.value(codeClass: 4, codeDetail: 13)
                case .unsupportedContentFormat:
                    return Code.value(codeClass: 4, codeDetail: 15)
                case .internalServerError:
                    return Code.value(codeClass: 5, codeDetail: 00)
                case .notImplemented:
                    return Code.value(codeClass: 5, codeDetail: 01)
                case .badGateway:
                    return Code.value(codeClass: 5, codeDetail: 02)
                case .serviceUnavailable:
                    return Code.value(codeClass: 5, codeDetail: 03)
                case .gatewayTimeout:
                    return Code.value(codeClass: 5, codeDetail: 04)
                case .proxyingNotSupported:
                    return Code.value(codeClass: 5, codeDetail: 05)
                }
            }
        }

        static func value(codeClass: UInt8, codeDetail: UInt8) -> UInt8? {
            // No more than 3 bits per class and 5 bits per detail.
            guard codeClass <= 0b111, codeDetail <= 0b11111 else { return nil }
            return UInt8((codeClass << 5) + codeDetail)
        }
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
        case etag = 4
        case ifNoneMatch = 5
        case observe = 6
        case uriPort = 7
        case locationPath = 8
        case uriPath = 11
        case contentFormat = 12
        case maxAge = 14
        case uriQuery = 15
        case accept = 17
        case locationQuery = 20
        case block2 = 23
        case block1 = 27
        case size2 = 28
        case proxyUri = 35
        case proxyScheme = 39
        case size1 = 60

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    typealias MessageOptionSet = [MessageOption]
}

private extension UInt32 {
    init(_ optionKey: CoAPMessage.MessageOptionKey) {
        self.init(optionKey.rawValue)
    }
}
