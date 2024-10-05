//
//  CoAPClient.swift
//
//
//  Created by Yachin Ilya on 14.05.2022.
//

import Combine
import Foundation
import Network
import UInt4
import os.log

typealias ConnectionMessagesPublisher = PassthroughSubject<CoAPMessage, Error>

public struct Tied {
    public static func newConnection(with settings: Settings) -> Connection {
        Connection(settings: settings)
    }
    
    public class Connection {
        fileprivate init(settings: Settings) {
            networkConnection = NWConnection(to: settings.endpoint, using: settings.parameters)
            messagePublisher = ConnectionMessagesPublisher()
            timestamp = Date().timeIntervalSince1970
            pingTimer = settings.pingEvery == 0 ? nil : Self.pingTimer(with: settings) { [weak self] timer in
                guard let self else { return }
                
                // TODO: add adjustable number of ping misses or timeout to settings.
                if self.timestamp + Double(settings.pingEvery * 3) < timer.fireDate.timeIntervalSince1970 {
                    messagePublisher.send(completion: .failure(Tied.ConectionError.timedOut))
                    return
                }
                
                self.performMessageSend(CoAPMessage.empty(type: .confirmable, messageId: randomUnsigned()))
                timer.fireDate = Date().addingTimeInterval(TimeInterval(settings.pingEvery))
            }
            
            setupPublisher()
        }
        
        let messagePublisher: ConnectionMessagesPublisher
        private let networkConnection: NWConnection
        private var timestamp: TimeInterval
        private var pingTimer: Timer?
    }
    
    public struct Settings {
        public let endpoint: NWEndpoint
        public let pingEvery: Int // Seconds
        public let parameters: NWParameters
        
        /// For those not willing to import `Network` into the project it is enough to pass only the host
        /// to be connected to. Port by default is set to CoAP standard 5683. If custom value for port is provided
        /// but `NWEndpoint.Port` can't be created for it (impossible scenario but still better mention) the port will
        /// be reverted back to 5683.
        public init(host: String, port: UInt16 = 5683, pingEvery: Int = 0, transport: Transport = .udp, security: Security? = nil) {
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 5683)
            self.init(endpoint: endpoint, pingEvery: pingEvery, transport: transport, security: security)
        }
        
        public init(endpoint: NWEndpoint, pingEvery: Int = 0, transport: Transport = .udp, security: Security? = nil) {
            self.endpoint = endpoint
            self.pingEvery = pingEvery
            self.parameters = Self.mustGetParameters(transport: transport, security: security)
        }
        
        /// While the library focuses on the most basic security with PSK
        /// the library user if free to set whatever NWParameters they want to have enabling
        /// the them to modify everything `Network` framework allows to adjust.
        public init(endpoint: NWEndpoint, pingEvery: Int = 0, parameters: NWParameters) {
            self.endpoint = endpoint
            self.pingEvery = pingEvery
            self.parameters = parameters
        }
        
        public enum Transport {
            case tcp
            case udp
            
            func parameters(_ options: NWProtocolTLS.Options? = nil) -> NWParameters {
                switch self {
                case .tcp:
                    // If options aren't nil TLS gets enabled.
                    // Otherwise it is plain TCP (`NWParameters.tcp`) with default options.
                    return NWParameters(tls: options)
                case .udp:
                    // If options aren't nil DTLS gets enabled.
                    // Otherwise it is plain UDP (`NWParameters.udp`) with default options.
                    return NWParameters(dtls: options)
                }
            }
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
        
        private static func mustGetParameters(transport: Transport, security: Security?) -> NWParameters {
            if let security = security {
                return transport.parameters(tlsWithPSKOptions(security))
            }
            return transport.parameters()
        }
        
        private static func tlsWithPSKOptions(_ security: Tied.Settings.Security) -> NWProtocolTLS.Options {
            let tlsOptions = NWProtocolTLS.Options()
            let key = security.psk.withUnsafeBytes { DispatchData(bytes: $0) }
            let hint = security.pskHint.data(using: .utf8)!.withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(tlsOptions.securityProtocolOptions, key as __DispatchData, hint as __DispatchData)
            sec_protocol_options_append_tls_ciphersuite(tlsOptions.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(security.cipherSuite))!)
            return tlsOptions
        }
    }
    
    enum ConectionError: Error {
        case timedOut
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
                self.messagePublisher.send(message)
            }
            
            self.doReads()
        }
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
        
        // TODO: block1 chunking have to be done in CoAPMessagePublisher!
        let message = CoAPMessage(code: method, type: type, messageId: randomUnsigned(), token: randomUnsigned(), options: options, payload: payload)
        return sendMessage(message)
    }
    
    /// More raw access to `CoAPMessage` type allowing going almost full manual.
    public func sendMessage(_ message: CoAPMessage) -> CoAPMessagePublisher {
        CoAPMessagePublisher(connection: self, outgoingMessages: message)
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
}

