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

public protocol MessageCode {
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
    public init(
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
    public init(
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
    public init(
        code: Code.Response,
        type: CoAPMessage.MessageType,
        messageId: UInt16,
        token: UInt64,
        options: CoAPMessage.MessageOptionSet = [],
        payload: Data = Data()
    ) {
        self.init(code: code as MessageCode, type: type, messageId: messageId, token: token, options: options, payload: payload)
    }
    
    static func empty(type: CoAPMessage.MessageType, messageId: UInt16) -> CoAPMessage {
        CoAPMessage(code: Code.empty, type: type, messageId: messageId, token: 0, options: [], payload: Data())
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
        //  0               1               2               3
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
    
    // Decode actually.
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
        let token = (0 ..< tokenLength).map { offset -> UInt8 in
            let b = buffer.load(fromByteOffset: 4 + Int(offset), as: UInt8.self)
            return b
        }.reduce(into: UInt64(0)) {
            $0 = UInt64($0 << 8) | UInt64($1)
        }
        
        guard let pointer = buffer.bindMemory(to: UInt8.self).baseAddress else { throw MessageError.formatError }
        var offset = 4 + Int(tokenLength)
        let maxOffset = buffer.count // If no payload there's no payload separator. Options parsing should stop once the buffer end reached.
        var options: CoAPMessage.MessageOptionSet = []
        try MessageOptionSet.parseOptions(parsing: pointer, startOffset: &offset, maxOffset: maxOffset, output: &options)
        
        var payload = Data()
        
        if offset < maxOffset {
            // Check payload separator value is correct.
            guard pointer.advanced(by: offset).withMemoryRebound(to: UInt8.self, capacity: 1, { $0.pointee }) == 0xFF else {
                throw MessageError.formatError
            }
            offset += 1 // Skip the payload separator.
            let capacity = maxOffset - offset
            payload = pointer.advanced(by: offset).withMemoryRebound(to: UInt8.self, capacity: capacity) {
                Data(bytes: $0, count: capacity)
            }
        }
        
        return CoAPMessage(
            version: version,
            code: code,
            type: type,
            messageId: messageId,
            token: token,
            options: options,
            payload: payload
        )
    }
}

extension CoAPMessage: Equatable {
    public static func == (lhs: CoAPMessage, rhs: CoAPMessage) -> Bool {
        lhs.version == rhs.version &&
        lhs.code == rhs.code &&
        lhs.type == rhs.type &&
        lhs.messageId == rhs.messageId &&
        lhs.token == rhs.token &&
        lhs.options == rhs.options &&
        lhs.payload == rhs.payload
    }
}

extension CoAPMessage {
    static func createOptionsSet(_ options: [CoAPMessage.MessageOptionKey: Data]) -> CoAPMessage.MessageOptionSet {
        CoAPMessage.MessageOptionSet(options)
    }
}

extension CoAPMessage.MessageOptionSet: DataEncodable {
    init(_ options: [CoAPMessage.MessageOptionKey: Data]) {
        self = options.map {
            CoAPMessage.MessageOption(key: $0.key, value: $0.value)
        }
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
                
                output.append(UInt8(optionDeltaValue) << 4 + UInt8(optionLengthValue))
                output.append(contentsOf: extendedDeltaValue)
                output.append(contentsOf: extendedLengthValue)
                output.append(contentsOf: option.value)
                
                lastDelta += delta
            }
        
        return output
    }
    
    // Option Delta and Option Length values explained per RFC 7252:
    //
    //  4-bit unsigned integer.  A value between 0 and 12
    //     indicates the Option Delta.  Three values are reserved for special
    //     constructs:
    //
    //     13:  An 8-bit unsigned integer follows the initial byte and
    //        indicates the Option Delta minus 13.
    //
    //     14:  A 16-bit unsigned integer in network byte order follows the
    //        initial byte and indicates the Option Delta minus 269.
    //
    //     15:  Reserved for the Payload Marker.  If the field is set to this
    //        value but the entire byte is not the payload marker, this MUST
    //        be processed as a message format error.
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
    
    fileprivate static func parseOptions(
        parsing bytes: UnsafePointer<UInt8>,
        startOffset offset: UnsafeMutablePointer<Int>,
        maxOffset: Int,
        output: UnsafeMutablePointer<[CoAPMessage.MessageOption]>
    ) throws {
        // Options format per RFC 7252:
        //
        //    0   1   2   3   4   5   6   7
        //  +---------------+---------------+
        //  |               |               |
        //  |  Option Delta | Option Length |   1 byte
        //  |               |               |
        //  +---------------+---------------+
        //  \                               \
        //  /         Option Delta          /   0-2 bytes
        //  \          (extended)           \
        //  +-------------------------------+
        //  \                               \
        //  /         Option Length         /   0-2 bytes
        //  \          (extended)           \
        //  +-------------------------------+
        //  \                               \
        //  /                               /
        //  \                               \
        //  /         Option Value          /   0 or more bytes
        //  \                               \
        //  /                               /
        //  \                               \
        //  +-------------------------------+
        //
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
            let optionBody = bytes.advanced(by: offset.pointee).withMemoryRebound(to: UInt8.self, capacity: optionLength) {
                Data(bytes: $0, count: optionLength)
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
    typealias MessageOptionSet = [MessageOption]
}

extension CoAPMessage {
    // To limit option keys which could be passed to `func szx()`.
    enum BlockOptionType: UInt8 {
        case block1 = 27
        case block2 = 23
        
        var option: MessageOptionKey {
            MessageOptionKey(rawValue: self.rawValue)!
        }
    }
    
    func szx(_ block: CoAPMessage.BlockOptionType) -> UInt4 {
        // If no option set we are treating it as maximal size (6).
        // SZX affects block size as 2^(SZX+4) meaning 0 is 16 bytes and 6 is 1024.
        guard let option: UInt32 = self.options.first(where: {$0.key == block.option})?.value.into() else { return 6 }
        return UInt4(option & 0b111)
    }
    
    // Actual size 16 to 1024.
    static func blockSize(szx: UInt4) -> Int { 1 << (szx + 4) }
    
    /// Only applies to outgoing messages.
    var isObserve: Bool {
        self.options.contains(where: { $0.key == .observe && $0.value.into() == 0 })
    }
    
    /// Check M bit in block1, block2 options.
    func areMoreBlocksExpected(_ block: CoAPMessage.BlockOptionType) -> Bool {
        guard let block2Option = self.options.first(where: {$0.key == block.option})?.value,
              let lastByte = block2Option.withUnsafeBytes({$0.last}) else { return false }
        return (lastByte >> 3) & 0b1 == 1
    }
    
    var blockNumber: UInt32 {
        guard let block2Option: UInt32 = self.options.first(where: {$0.key == .block2})?.value.into() else { return 0 }
        return block2Option >> 4
    }
    
    /// Create an ACK with original mesage ID.
    func prepareAcknowledgement() -> CoAPMessage {
        CoAPMessage.empty(type: .acknowledgement, messageId: self.messageId)
    }
}

protocol CoAPMessageOptionValue {}

public extension CoAPMessage.MessageOption {
    static func block1(num: UInt32, more: Bool, szx: UInt4) -> CoAPMessage.MessageOption {
        Self.blockOption(for: .block1, num: num, more: more, szx: szx)
    }
    
    static func block2(num: UInt32, more: Bool, szx: UInt4) -> CoAPMessage.MessageOption {
        Self.blockOption(for: .block2, num: num, more: more, szx: szx)
    }
}

extension CoAPMessage.MessageOption {
    // Careful! Valid `CoAPMessage.MessageOptionKey`s are only .block1 and .block2 yet any key might be passed by mistake.
    fileprivate static func blockOption(for key: CoAPMessage.MessageOptionKey, num: UInt32, more: Bool, szx: UInt4) -> CoAPMessage.MessageOption {
        CoAPMessage.MessageOption(key: key, value: try! UInt32(num << 4 | (more ? 1 : 0) << 3 | UInt32(szx)).into())
    }
    
    enum ObserveValue: UInt8, CoAPMessageOptionValue, DataEncodable {
        case isObserve = 0
        case cancelObserve = 1
        
        init?(data: Data) {
            guard let i: UInt8 = data.into() else { return nil }
            self.init(rawValue: i)
        }
        
        func encode() throws -> Data {
            try rawValue.into()
        }
    }
    
    struct BlockValue: CoAPMessageOptionValue, DataEncodable {
        enum Error: Swift.Error {
            case illegalData
            case numTooLarge(UInt32)
            case unsupportedSZX(UInt4)
        }
        
        let blockNumber: UInt32
        let moreBlocksExpected: Bool
        let szx: UInt4
        
        init(blockNumber: UInt32, moreBlocksExpected: Bool, szx: UInt4) throws {
            guard blockNumber < (UInt32.max >> 12) else { throw Error.numTooLarge(blockNumber) }
            guard szx < 6 else { throw Error.unsupportedSZX(szx) }
            self.blockNumber = blockNumber
            self.moreBlocksExpected = moreBlocksExpected
            self.szx = szx
        }
        
        init(data: Data) throws {
            guard let option: UInt32 = data.into() else { throw Error.illegalData }
            blockNumber = option >> 4
            moreBlocksExpected = (option >> 3 & 0b1) == 1
            szx = UInt4(option & 0b111)
        }
        
        func encode() throws -> Data {
            try UInt32(blockNumber << 4 | (moreBlocksExpected ? 1 : 0) << 3 | UInt32(szx)).into()
        }
    }
}


extension CoAPMessage.MessageOptionSet {
    
    func ifMatch() -> Data? {
        guard let option = first(where: { $0.key == .ifMatch }) else { return nil }
        return option.value
    }
    
    func uriHost() -> String? {
        guard let option = first(where: { $0.key == .uriHost }) else { return nil }
        return String(data: option.value, encoding: .utf8)
    }
    
    func etag() -> Data? {
        guard let option = first(where: { $0.key == .etag }) else { return nil }
        return option.value
    }
    
    func ifNoneMatch() -> Bool {
        return first(where: { $0.key == .ifNoneMatch }) != nil
    }
    
    func observe() -> CoAPMessage.MessageOption.ObserveValue? {
        guard let option = first(where: { $0.key == .observe }) else { return nil }
        return CoAPMessage.MessageOption.ObserveValue(data: option.value)
    }
    
    func uriPort() -> UInt16? {
        guard let option = first(where: { $0.key == .uriPort }) else { return nil }
        return option.value.into()
    }
    
    func locationPath() -> String? {
        guard let option = first(where: { $0.key == .locationPath }) else { return nil }
        return String(data: option.value, encoding: .utf8)
    }
    
    func uriPath() -> String? {
        guard let option = first(where: { $0.key == .uriPath }) else { return nil }
        return String(data: option.value, encoding: .utf8)
    }
    
    func contentFormat() -> UInt16? {
        guard let option = first(where: { $0.key == .contentFormat }) else { return nil }
        return option.value.into()
    }
    
    func maxAge() -> UInt32? {
        guard let option = first(where: { $0.key == .maxAge }) else { return nil }
        return option.value.into()
    }
    
    func uriQuery() -> String? {
        guard let option = first(where: { $0.key == .uriQuery }) else { return nil }
        return String(data: option.value, encoding: .utf8)
    }
    
    func accept() -> UInt16? {
        guard let option = first(where: { $0.key == .accept }) else { return nil }
        return option.value.into()
    }
    
    func locationQuery() -> String? {
        guard let option = first(where: { $0.key == .locationQuery }) else { return nil }
        return String(data: option.value, encoding: .utf8)
    }
    
    func block2() -> CoAPMessage.MessageOption.BlockValue? {
        guard let option = first(where: { $0.key == .block2 }) else { return nil }
        return try? CoAPMessage.MessageOption.BlockValue(data: option.value)
    }
    
    func block1() -> CoAPMessage.MessageOption.BlockValue? {
        guard let option = first(where: { $0.key == .block1 }) else { return nil }
        return try? CoAPMessage.MessageOption.BlockValue(data: option.value)
    }
    
    func size2() -> UInt32? {
        guard let option = first(where: { $0.key == .size2 }) else { return nil }
        return option.value.into()
    }
    
    func proxyUri() -> String? {
        guard let option = first(where: { $0.key == .proxyUri }) else { return nil }
        return String(data: option.value, encoding: .utf8)
    }
    
    func proxyScheme() -> String? {
        guard let option = first(where: { $0.key == .proxyScheme }) else { return nil }
        return String(data: option.value, encoding: .utf8)
    }
    
    func size1() -> UInt32? {
        guard let option = first(where: { $0.key == .size1 }) else { return nil }
        return option.value.into()
    }
}



private extension UInt32 {
    init(_ optionKey: CoAPMessage.MessageOptionKey) {
        self.init(optionKey.rawValue)
    }
}
