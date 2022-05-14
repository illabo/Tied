//
//  Client.swift
//
//
//  Created by Yachin Ilya on 14.05.2022.
//

import Combine
import Foundation
import Network
import os.log

typealias CoAPMessagePublisher = PassthroughSubject<Data, Error>

public class Client {
    private var connections: [NWEndpoint: Connection] = [:]
    public func session(with settings: Settings) {
        mustGetConnection(with: settings)
    }

    private func mustGetConnection(with settings: Settings) -> Connection {
        if let connection = connections[settings.endpoint] {
            return connection
        }
        return Connection(
            networkConnection: NWConnection(to: settings.endpoint, using: mustGetParameters(with: settings))
        )
    }

    private func mustGetParameters(with settings: Settings) -> NWParameters {
        if let security = settings.security {
            return NWParameters(dtls: tlsWithPSKOptions(security), udp: NWProtocolUDP.Options())
        }
        return .udp
    }

    private func tlsWithPSKOptions(_ security: Settings.Security) -> NWProtocolTLS.Options {
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

    private func pingTimer(with settings: Settings, handler: @escaping (_ timer: Timer, _ endpoint: NWEndpoint) -> Void) -> Timer? {
        if settings.pingEvery == 0 { return nil }
        return Timer(timeInterval: TimeInterval(settings.pingEvery), repeats: true) { timer in
            handler(timer, settings.endpoint)
        }
    }

    private struct Connection {
        internal init(networkConnection: NWConnection) {
            self.networkConnection = networkConnection
            messagePublisher = CoAPMessagePublisher()
            timestamp = Date().timeIntervalSince1970
            pingTimer = nil // We don't want to start timer here yet. Once connection is `ready` we'd start the timer.
        }

        let networkConnection: NWConnection
        let messagePublisher: CoAPMessagePublisher
        var timestamp: TimeInterval
        var pingTimer: Timer?
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
