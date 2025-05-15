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
                    self.pingTimer?.invalidate()
                    self.pingTimer = nil
                    return
                }
                
                self.performMessageSend(CoAPMessage.empty(type: .confirmable, messageId: randomUnsigned()))
                timer.fireDate = Date().addingTimeInterval(TimeInterval(settings.pingEvery))
            }
            if let pingTimer {
                        RunLoop.current.add(pingTimer, forMode: .default)
                    }
            
            setupPublisher()
        }
        
        let messagePublisher: ConnectionMessagesPublisher
        private let networkConnection: NWConnection
        private var timestamp: TimeInterval
        private var pingTimer: Timer?
        // Stored between message sends.
        // SZX keeps server preference and applies to all the transfers. Need to be visible to `CoAPMessagePublisher`.
        var block1Szx: UInt4 = 6
        // Active sessions' tokens.
        private var sessionTokens = Set<UInt64>()
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
            
            do {
                if let data = completeContent?.map({ $0.bigEndian }) {
                    let message = try data.withUnsafeBytes { buffer in
                        try CoAPMessage.with(buffer)
                      }
                    // Set SZX for future transfers.
                    if let szx = message.options.block1()?.szx { self.block1Szx = szx }
                    // If the message has code Empty (0.00) theres no token. In `CoAPMessage` type it would be set to 0.
                    // Empty messages act as ACKs or RSTs and have to be relayed to `messagePublisher`.
                    guard message.token == 0 || sessionTokens.contains(message.token) else {
                        // If message is unexpected send RST to server to stop further retransmissions.
                        performMessageSend(CoAPMessage.empty(type: .reset, messageId: message.messageId))
                        return
                    }
                    self.messagePublisher.send(message)
                }
            } catch {
                os_log(.error, "Error decoding the message: %{public}@", "\(error)")
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
    public func sendMessage(method: CoAPMessage.Code.Method? = nil,
                            type: CoAPMessage.MessageType = .confirmable,
                            observe: Bool = false,
                            uriOptions: CoAPURIOptions? = nil,
                            ifMatch: [Data]? = nil,
                            ifNoneMatch: Bool = false,
                            contentFormat: UInt16? = nil,
                            accept: UInt16? = nil,
                            payload: Data = Data()) -> CoAPMessagePublisher {
        // If method is not set default to GET when the payload is empty
        // and default to POST when there's some payload.
        let method = method ?? (payload.isEmpty ? .get : .post)
        return CoAPMessagePublisher(
            connection: self,
            outgoingMessages: CoAPMessageQueue(method: method, type: type, token: randomUnsigned(), observe: observe, uriOptions: uriOptions, ifMatch: ifMatch, ifNoneMatch: ifNoneMatch, contentFormat: contentFormat, accept: accept, payload: payload)
        )
    }
    
    /// Discouraged to use unless you need full control over the messages you send
    public func sendMessage(_ messages: CoAPMessage...) -> CoAPMessagePublisher {
        CoAPMessagePublisher(connection: self, outgoingMessages: PresetCoAPMessageQueue(messages: messages))
    }
    
    // It is the method used internally. Called from MessageSubscription class upon setup,
    // sending ACKs or when message session publisher is done.
    func performMessageSend(_ message: CoAPMessage) {
        // Don't forget to memoize the session. :)
        sessionTokens.insert(message.token)
        networkConnection.send(content: try? message.encode(), completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.messagePublisher.send(completion: .failure(error))
            }
        })
    }
    
    // If not provided with 'observed' parameter prefer to
    // notify server about termination of communication.
    func stopSession(for token: UInt64, observed: Bool = true) {
        self.sessionTokens.remove(token)
        // If not observed no need to notify by send unsubscribe message.
        // Optionally you might want to send RST to server instead.
        guard observed else { return }
        // Message to unsubscribe observer from resource.
        let message = CoAPMessage(code: .get,
                                  type: .nonconfirmable,
                                  messageId: randomUnsigned(),
                                  token: token,
                                  options: [
                                    CoAPMessage.MessageOption(key: .observe, value: try! CoAPMessage.MessageOption.ObserveValue.cancelObserve.encode())
                                  ],
                                  payload: Data())
        performMessageSend(message)
    }
    
    func cancel() {
        messagePublisher.send(completion: .finished)
        networkConnection.cancel()
    }
}

