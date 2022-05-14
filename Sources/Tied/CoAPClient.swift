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

typealias CoAPMessagePublisher = PassthroughSubject<Data, Error>

public class CoAPClient {
    private var connections: [NWEndpoint: Connection] = [:]
    public func session(with settings: Settings) -> MessageSession {
        let connection = mustGetConnection(with: settings)
        let publisher = connection.messagePublisher

        return MessageSession(publisher: publisher, token: 0) { message in
            connection.sendMessage(message)
        }
    }

    private func mustGetConnection(with settings: Settings) -> Connection {
        if let connection = connections[settings.endpoint] {
            return connection
        }
        return Connection(settings: settings)
    }

    fileprivate class Connection {
        internal init(settings: Settings) {
            networkConnection = NWConnection(to: settings.endpoint, using: Self.mustGetParameters(with: settings))
            messagePublisher = CoAPMessagePublisher()
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

        let messagePublisher: CoAPMessagePublisher
        private let networkConnection: NWConnection
        private var timestamp: TimeInterval
        private var pingTimer: Timer?
    }

    public struct Settings {
        let endpoint: NWEndpoint
        let pingEvery: Int // Seconds
        let security: Security?

        public struct Security {
            internal init(psk: Data, pskHint: String = "", cipherSuite: SSLCipherSuite = TLS_PSK_WITH_AES_128_GCM_SHA256) {
                self.psk = psk
                self.pskHint = pskHint
                self.cipherSuite = cipherSuite
            }

            let psk: Data
            let pskHint: String
            let cipherSuite: SSLCipherSuite // Adds ciphersuite but doesn't guarantie it's use
        }
    }
}

extension CoAPClient.Connection {
    private func setupPublisher() {
        networkConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            os_log("Connection to %@ state %@", log: .default, type: .debug, self.networkConnection.endpoint.debugDescription, "\(state)")
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
        networkConnection.receiveMessage { [weak self] completeContent, contentContext, isComplete, error in
            guard let self = self else { return }
            print(completeContent, contentContext, isComplete, error)

            self.timestamp = Date().timeIntervalSince1970

            if let error = error {
                self.messagePublisher.send(completion: .failure(error))
                self.networkConnection.cancel()
            }
            if let message = completeContent {
                self.messagePublisher.send(message)
            }

            self.doReads()
        }
    }

    private static func mustGetParameters(with settings: CoAPClient.Settings) -> NWParameters {
        if let security = settings.security {
            return NWParameters(dtls: tlsWithPSKOptions(security), udp: NWProtocolUDP.Options())
        }
        return .udp
    }

    private static func tlsWithPSKOptions(_ security: CoAPClient.Settings.Security) -> NWProtocolTLS.Options {
        let tlsOptions = NWProtocolTLS.Options()
        let semaphore = DispatchSemaphore(value: 0)
        security.psk.withUnsafeBytes { (pointer: UnsafeRawBufferPointer) in
            defer { semaphore.signal() }
            let dd = DispatchData(bytes: pointer)
            let hint = DispatchData(bytes: security.pskHint.data(using: .utf8)!.withUnsafeBytes { $0 })
            sec_protocol_options_add_pre_shared_key(tlsOptions.securityProtocolOptions, dd as __DispatchData, hint as __DispatchData)
            sec_protocol_options_append_tls_ciphersuite(tlsOptions.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(security.cipherSuite))!)
        }
        semaphore.wait()
        return tlsOptions
    }

    private static func pingTimer(with settings: CoAPClient.Settings, handler: @escaping (_ timer: Timer) -> Void) -> Timer? {
        if settings.pingEvery == 0 { return nil }
        return Timer(timeInterval: TimeInterval(settings.pingEvery), repeats: true) { timer in
            handler(timer)
        }
    }
}

extension CoAPClient.Connection {
    func sendMessage(_ message: Data) {
        networkConnection.send(content: message, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                self.messagePublisher.send(completion: .failure(error))
            }
        })
    }
}
