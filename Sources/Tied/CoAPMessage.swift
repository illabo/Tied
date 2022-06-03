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
    static func with(_ buffer: UnsafeRawBufferPointer) throws -> Self
}

protocol MessageCode {
    var rawValue: UInt8? { get }
}

extension MessageCode {
    var codeError: Error { NSError(domain: "CoAP Message Code Error", code: -1000) }
}

func == (lhs: MessageCode, rhs: MessageCode) -> Bool {
    lhs.rawValue == rhs.rawValue
}

typealias DataCodable = DataEncodable & DataDecodable

public struct CoAPMessage {
    internal init(
        version: CoAPMessage.Version = .v1,
        code: MessageCode,
        type: CoAPMessage.MessageType,
        messageId: UInt16,
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

    // Additional init to have the type hint for `MessageCode`.
    internal init(
        code: Code.Method,
        type: CoAPMessage.MessageType,
        messageId: UInt16,
        token: UInt64,
        options: CoAPMessage.MessageOptionSet = [],
        payload: Data = Data()
    ) {
        self.init(code: code as MessageCode, type: type, messageId: messageId, token: token, options: options, payload: payload)
    }

    // Additional init to have the type hint for `MessageCode`.
    internal init(
        code: Code.Response,
        type: CoAPMessage.MessageType,
        messageId: UInt16,
        token: UInt64,
        options: CoAPMessage.MessageOptionSet = [],
        payload: Data = Data()
    ) {
        self.init(code: code as MessageCode, type: type, messageId: messageId, token: token, options: options, payload: payload)
    }

    var version: Version
    var code: MessageCode
    var type: MessageType
    var messageId: UInt16
    var token: UInt64
    var options: MessageOptionSet
    var payload: Data

    private var tokenLength: UInt4 { code == Code.empty ? 0 : UInt4(tokenData.count) }
    private var tokenData: Data { Data(withUnsafeBytes(of: token.bigEndian) { [UInt8]($0) }.drop { $0 == .zero }) }
}

extension CoAPMessage: DataCodable {
    enum MessageError: Error {
        case formatError
    }

    func encode() throws -> Data {
        guard let codeValue = code.rawValue else {
            throw code.codeError
        }

        // Message format per RFC 7252:
        //
        //  0                   1                   2                   3
        //  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
        // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // |Ver| T |  TKL  |      Code     |          Message ID           |
        // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // |   Token (if any, TKL bytes) ...
        // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // |   Options (if any) ...
        // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        // |1 1 1 1 1 1 1 1|    Payload (if any) ...
        // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        var output = Data()

        // Constructing and appending the first byte (Ver, T, TKL).
        // Version and Type are of type UInt4 here.
        let verT = (version.rawValue << 2) + type.rawValue
        output.append(UInt8(verT) << 4 | UInt8(tokenLength))
        output.append(codeValue)
        // Look after endianness!
        output.append(contentsOf: Swift.withUnsafeBytes(of: messageId.bigEndian) { [UInt8]($0) })

        // 'Empty Message' code 0.00 should not have anything beyond first 4 bytes.
        if code == Code.empty { return output }

        output.append(contentsOf: tokenData)
        output.append(contentsOf: options.encode())

        // If payload is not empty add separator and actual payload data.
        guard payload.isEmpty == false else { return output }
        output.append(UInt8.max) // Payload separator.
        output.append(contentsOf: payload)

        return output
    }

    static func with(_ buffer: UnsafeRawBufferPointer) throws -> CoAPMessage {
        let firstByte = buffer.load(fromByteOffset: 0, as: UInt8.self)
        let tokenLength = firstByte & 0b0000_1111
        let mostSignificant = UInt4(clamping: firstByte >> 4)
        guard
            let type = MessageType(rawValue: mostSignificant & 0b0011),
            let version = Version(rawValue: (mostSignificant >> 2) & 0b0011),
            let code = Code.code(from: buffer.load(fromByteOffset: 1, as: UInt8.self))
        else { throw MessageError.formatError }
        let messageId = buffer.load(fromByteOffset: 2, as: UInt16.self)
        let token = (0 ..< tokenLength).map { offset in
            buffer.load(fromByteOffset: 4 + Int(offset), as: UInt8.self)
        }.withUnsafeBytes { $0.bindMemory(to: UInt64.self).baseAddress?.pointee } // $0.load(as: UInt64.self) }

        guard let pointer = buffer.bindMemory(to: UInt8.self).baseAddress else { throw MessageError.formatError }
//        let splitOptionPayload = buffer.load(fromByteOffset: 4 + Int(tokenLength), as: [UInt8].self).split(separator: 0xFF, maxSplits: 1).map { Data($0) }
//        let options: MessageOptionSet = try splitOptionPayload.first?.withUnsafeBytes { try CoAPMessage.MessageOptionSet.with($0) } ?? []
//        let payload: Data = splitOptionPayload.last ?? Data()
        var offset = 4 + Int(tokenLength)
        let maxOffset = buffer.count
        var options: CoAPMessage.MessageOptionSet = []
        try MessageOptionSet.parseOptions(parsing: pointer, startOffset: &offset, maxOffset: maxOffset, output: &options)

        return CoAPMessage(
            version: version,
            code: code,
            type: type,
            messageId: messageId,
            token: token!,
            options: options,
            payload: Data()
        )
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

                output.append(UInt8(optionDeltaValue) << 4 + UInt8(optionLengthValue))
                output.append(contentsOf: extendedDeltaValue)
                output.append(contentsOf: extendedLengthValue)
                output.append(contentsOf: option.value)

                lastDelta += delta
            }

        return output
    }

    static func with(_ buffer: UnsafeRawBufferPointer) throws -> Self {
        buffer.load(as: CoAPMessage.MessageOptionSet.self)
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

    static func seekSeparatorIndex(in bytes: [UInt8]) -> Int {
        var skipping = 0
        bytes.enumerated().forEach { enumeratedBytes in
            let offset = enumeratedBytes.offset

            // Check only currently awaited delta and length byte
            if offset != skipping { return }
            if offset == skipping, enumeratedBytes.element == 0xFF { return }

            let byte = bytes[offset]
            let length = byte & 0b1111
            let delta = byte >> 4

            skipping += 1
            var skipExtendedDelta = 0
            if delta == Self.extendTo8bitIndicator {
                skipExtendedDelta = 1
                skipping += 1
            }
            if delta == Self.extendTo16bitIndicator {
                skipExtendedDelta = 2
                skipping += 2
            }
            if length < Self.extendTo8bitIndicator {
                skipping += Int(length)
            }
            if length == Self.extendTo8bitIndicator {
                let lengthByte = bytes[offset + 1 + skipExtendedDelta]
                skipping += (1 + Int(Self.extendTo8bitIndicator) + Int(lengthByte))
            }
            if length == Self.extendTo16bitIndicator {
                let lengthByte = UInt16(bytes[offset + 1 + skipExtendedDelta] | bytes[offset + 2 + skipExtendedDelta])
                skipping += (1 + Int(Self.extendTo16bitIndicator) + Int(lengthByte))
            }
        }
        return skipping
    }

    static func parseOptionHeaderLength(optionHeaderByte byte: UInt8) throws -> Int {
        var headerLength = 1 // As we already have 1 byte with non-extended delta and length
        let optionLength = byte & 0b1111
        let optionDelta = byte >> 4
        if optionDelta == Self.extendTo8bitIndicator {
            headerLength += 1
        }
        if optionDelta == Self.extendTo16bitIndicator {
            headerLength += 2
        }
        if optionDelta > Self.extendTo16bitIndicator {
            throw CoAPMessage.MessageError.formatError
        }
        if optionLength == Self.extendTo8bitIndicator {
            headerLength += 1
        }
        if optionLength == Self.extendTo16bitIndicator {
            headerLength += 2
        }
        if optionLength > Self.extendTo16bitIndicator {
            throw CoAPMessage.MessageError.formatError
        }
        return headerLength
    }

    static func parseOptions(
        parsing bytes: UnsafePointer<UInt8>,
        startOffset offset: UnsafeMutablePointer<Int>,
        maxOffset: Int,
        output: UnsafeMutablePointer<[CoAPMessage.MessageOption]>
    ) throws {
        var deltaLength = bytes.advanced(by: offset.pointee).pointee
        var lastDelta = 0

        while deltaLength != 0xFF, offset.pointee < maxOffset {
            offset.pointee += 1

            var optionLength = Int(deltaLength & 0b1111)
            var optionDelta = Int(deltaLength >> 4)

            optionDelta = try Self.optionDeltaOrLengthValue(initialValue: optionDelta, parsing: bytes, currentOffset: offset)
            optionLength = try Self.optionDeltaOrLengthValue(initialValue: optionLength, parsing: bytes, currentOffset: offset)

            // Here we should get the Option Number.
            let optionNumber = optionDelta + lastDelta
            let optionBody = bytes.advanced(by: offset.pointee).withMemoryRebound(to: UInt8.self, capacity: optionLength) { b in
                Data(bytes: b, count: optionLength)
            }

            guard let optionKey = CoAPMessage.MessageOptionKey(rawValue: UInt8(optionNumber)) else {
                throw CoAPMessage.MessageError.formatError
            }

            output.pointee.append(CoAPMessage.MessageOption(key: optionKey, value: optionBody))

            // Prep for the next parse.
            lastDelta += optionDelta
            offset.pointee += optionLength

            deltaLength = bytes.advanced(by: offset.pointee).pointee
        }
    }

    // Returns the final value of extended Option Delta or Option Length
    private static func optionDeltaOrLengthValue(
        initialValue: Int,
        parsing bytes: UnsafePointer<UInt8>,
        currentOffset offset: UnsafeMutablePointer<Int>
    ) throws -> Int {
        var value = initialValue
        if value == Int(Self.extendTo8bitIndicator) {
            let extendedLength = bytes.advanced(by: offset.pointee).pointee
            value += Int(extendedLength)
            offset.pointee += 1
        }
        if value == Int(Self.extendTo16bitIndicator) {
            let extendedLength = bytes.advanced(by: offset.pointee).withMemoryRebound(to: UInt16.self, capacity: 1) { $0.pointee }
            value += Int(extendedLength) + 0xFF
            offset.pointee += 2
        }
        if value > Int(Self.extendTo16bitIndicator) { throw CoAPMessage.MessageError.formatError }

        return value
    }
}

public extension CoAPMessage {
    enum Version: UInt4 {
        case v1 = 1
    }

    enum Code: MessageCode {
        case empty
        case custom(codeClass: UInt8, codeDetail: UInt8)

        public var rawValue: UInt8? {
            switch self {
            case .empty:
                return Self.value(codeClass: 0, codeDetail: 00)
            case let .custom(codeClass: c, codeDetail: dd):
                return Self.value(codeClass: c, codeDetail: dd)
            }
        }

        public enum Method: MessageCode, CaseIterable {
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

        public enum Response: MessageCode, CaseIterable {
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

        static func code(from value: UInt8) -> MessageCode? {
            if value == 0 { return Self.empty }
            if let methodCode = Method.allCases.first(where: { $0.rawValue == value }) {
                return methodCode
            }
            if let responseCode = Response.allCases.first(where: { $0.rawValue == value }) {
                return responseCode
            }
            return Self.custom(codeClass: (value >> 5) & 0b111, codeDetail: value & 0b11111)
        }
    }

    enum MessageType: UInt4 {
        case confirmable = 0
        case nonconfirmable = 1
        case acknowledgement = 2
        case reset = 3
    }

    struct MessageOption: Comparable {
        let key: MessageOptionKey
        let value: Data

        public static func < (lhs: Self, rhs: Self) -> Bool {
            lhs.key < rhs.key
        }
    }

    enum MessageOptionKey: UInt8, Comparable {
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

    // Yes, it's not a Set but set in common sense.
    internal typealias MessageOptionSet = [MessageOption]
}

private extension UInt32 {
    init(_ optionKey: CoAPMessage.MessageOptionKey) {
        self.init(optionKey.rawValue)
    }
}
