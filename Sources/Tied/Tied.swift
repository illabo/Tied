//
//  CoAPClient.swift
//
//
//  Created by Yachin Ilya on 14.05.2022.
//

import Combine
import Foundation
import Network
import os.log

typealias ConnectionMessagesPublisher = PassthroughSubject<CoAPMessage, Error>

public struct Tied {
    public static func newConnection(with settings: Settings) -> Connection {
        Connection(settings: settings)
    }
    
    public class Connection {
        fileprivate init(settings: Settings) {
            networkConnection = NWConnection(to: settings.endpoint, using: Self.mustGetParameters(with: settings))
            messagePublisher = ConnectionMessagesPublisher()
            timestamp = Date().timeIntervalSince1970
            pingTimer = settings.pingEvery == 0 ? nil : Self.pingTimer(with: settings) { [weak self] timer in
                guard let networkConnection = self?.networkConnection else { return }
                networkConnection.send(content: Data(), completion: .contentProcessed { [weak self] error in
                    guard let self = self else { return }
                    if let error = error {
                        self.messagePublisher.send(completion: .failure(error))
                    }
                })
                timer.fireDate = Date().addingTimeInterval(TimeInterval(settings.pingEvery))
            }
            
            setupPublisher()
        }
        
        let messagePublisher: ConnectionMessagesPublisher
        private let networkConnection: NWConnection
        private var timestamp: TimeInterval
        private var pingTimer: Timer?
        private var szx: Int = 6
    }
    
    public struct Settings {
        public let endpoint: NWEndpoint
        public let pingEvery: Int // Seconds
        public let security: Security?
        
        public init(endpoint: NWEndpoint, pingEvery: Int = 0, security: Security? = nil) {
            self.endpoint = endpoint
            self.pingEvery = pingEvery
            self.security = security
        }
        
        public struct Security {
            public init(psk: Data, pskHint: String = "", cipherSuite: SSLCipherSuite = TLS_PSK_WITH_AES_128_GCM_SHA256) {
                self.psk = psk
                self.pskHint = pskHint
                self.cipherSuite = cipherSuite
            }
            
            let psk: Data
            let pskHint: String
            let cipherSuite: SSLCipherSuite // Adds ciphersuite but doesn't guarantee its use
        }
    }
}

extension Tied.Connection {
    private func setupPublisher() {
        networkConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            os_log("Connection to %{public}@ is %{public}@", log: .default, type: .debug, self.networkConnection.endpoint.debugDescription, "\(state)")
            switch state {
            case .ready:
                self.doReads()
            case let .failed(error):
                self.messagePublisher.send(completion: .failure(error))
                self.pingTimer?.invalidate()
            case .cancelled:
                self.messagePublisher.send(completion: .finished)
                self.pingTimer?.invalidate()
            default:
                break
            }
        }
        networkConnection.start(queue: DispatchQueue.global(qos: .default))
    }
    
    private func doReads() {
        guard networkConnection.state == .ready else { return }
        networkConnection.receiveMessage { [weak self] completeContent, _, _, error in
            guard let self = self else { return }
            
            self.timestamp = Date().timeIntervalSince1970
            
            if let error = error {
                self.messagePublisher.send(completion: .failure(error))
                self.networkConnection.cancel()
                return
            }
            
            if let data = completeContent, let message = try? CoAPMessage.with(data.withUnsafeBytes { $0 }) {
                self.szx = message.szx(.block2)
                self.messagePublisher.send(message)
            }
            
            self.doReads()
        }
    }
    
    private static func mustGetParameters(with settings: Tied.Settings) -> NWParameters {
        var parameters: NWParameters
        if let security = settings.security {
            return NWParameters(dtls: tlsWithPSKOptions(security), udp: NWProtocolUDP.Options())
        }
        parameters = .udp
        return parameters
    }
    
    private static func tlsWithPSKOptions(_ security: Tied.Settings.Security) -> NWProtocolTLS.Options {
        let tlsOptions = NWProtocolTLS.Options()
        let key = security.psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let hint = security.pskHint.data(using: .utf8)!.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tlsOptions.securityProtocolOptions, key as __DispatchData, hint as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tlsOptions.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(security.cipherSuite))!)
        return tlsOptions
    }
    
    private static func pingTimer(with settings: Tied.Settings, handler: @escaping (_ timer: Timer) -> Void) -> Timer? {
        if settings.pingEvery == 0 { return nil }
        return Timer(timeInterval: TimeInterval(settings.pingEvery), repeats: true) { timer in
            handler(timer)
        }
    }
}

extension Tied.Connection {
    /// Sane defaults for effortless message sends.
    public func sendMessage(method: CoAPMessage.Code.Method = .get,
                            type: CoAPMessage.MessageType = .confirmable,
                            observe: Bool = false,
                            path: String? = nil,
                            payload: Data) -> CoAPMessagePublisher {
        let options: CoAPMessage.MessageOptionSet = [
            observe == false ? nil : CoAPMessage.MessageOption(key: .observe, value: try! UInt8(0).into()),
            path?.isEmpty ?? true ? nil : CoAPMessage.MessageOption(key: .uriPath, value: path!.data(using: .utf8) ?? Data()),
        ]
            .compactMap{ $0 }
        
        let message = CoAPMessage(code: method, type: type, messageId: randomUnsigned(), token: randomUnsigned(), options: options, payload: payload)
        return sendMessage(message)
    }
    
    /// More raw access to `CoAPMessage` type allowing going almost full manual.
    public func sendMessage(_ message: CoAPMessage) -> CoAPMessagePublisher {
        CoAPMessagePublisher(connection: self, outgoingMessage: message)
    }
    
    // It is the method used internally. Called from MessageSubscription class upon setup,
    // sending ACKs or when message session publisher is done.
    func performMessageSend(_ message: CoAPMessage) {
        networkConnection.send(content: try? message.encode(), completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.messagePublisher.send(completion: .failure(error))
            }
        })
    }
    
    func stopSession(for token: UInt64) {
        // Message to unsubscribe observer from resource.
        let message = CoAPMessage(code: .get,
                                  type: .nonconfirmable,
                                  messageId: randomUnsigned(),
                                  token: token,
                                  options: [.init(key: .observe, value: try! UInt8(1).into())],
                                  payload: Data())
        performMessageSend(message)
    }
    
    func cancel() {
        messagePublisher.send(completion: .finished)
        networkConnection.cancel()
    }
    
    private func randomUnsigned<U>() -> U where U: UnsignedInteger, U: FixedWidthInteger {
        let byteCount = U.self.bitWidth / UInt8.bitWidth
        var randomBytes = Data(count: byteCount)
        
        withUnsafeMutableBytes(of: &randomBytes) { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, baseAddress)
        }
        
        return randomBytes.withUnsafeBytes {
            $0.load(as: U.self)
        }
    }
}

private extension CoAPMessage {
    // To limit option keys which could be passed to `func szx()`.
    enum SZX: UInt8 {
        case block1 = 27
        case block2 = 23
        
        var option: MessageOptionKey {
            MessageOptionKey(rawValue: self.rawValue)!
        }
    }
    
    func szx(_ block: CoAPMessage.SZX) -> Int {
        // If no option set we are treating it as maximal size (6).
        // SZX affects block size as 2^(SZX+4) meaning 0 is 16 bytes and 6 is 1024.
        guard let option: UInt32 = self.options.first(where: {$0.key == block.option})?.value.into() else { return 6 }
        return Int(option & 0b111)
    }
    
    // Actual size 16 to 1024.
    static func blockSize(szx: Int) -> Int { 1 << (szx + 4) }
}
