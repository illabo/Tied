<p align="center">
<img src="Sources/Resources/TiedIcon.webp" alt="Tied Icon" title="Tied" height="250"/><br>
<font size="20">Tied</font>
</p>

---
Tied is the implementation of CoAP client intended to be used on mobile. The library is built around `Network` and `Combine` frameworks to quck start in Apple ecosystem and seamlesly work with `Network` objects. E.g. you might want to use `NWBrowser` doing service discovery for you and providing `NWEndpoint`s to send CoAP messages. 

CoAP is [constrained application protocol](https://datatracker.ietf.org/doc/html/rfc7252).

This repo is still 'Work in progress', not the full spec is covered, however it is good enough to be used for most trivial cases. Started as a pastime project is platted to be pushed forward sporadically when I have the time on weekends.

### Quickstart
```swift
Tied.newConnection(with: Tied.Settings(endpoint: endpoint))
    .sendMessage(payload: "Cat piss or sauvignon blanc?".data(using: .utf8)!)
    .castingResponsePayloads { payload in
        String(data: payload, encoding: .utf8)
    }
```

### Hardcore
```swift
Tied.newConnection(with: Tied.Settings(
    endpoint: NWEndpoint.hostPort(host: "127.0.0.1", port: 5683), pingEvery: 3, parameters: {
        let psk = Data()
        let tlsOptions = NWProtocolTLS.Options()
        let key = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let hint = "Key \(Date())".data(using: .utf8)!.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(tlsOptions.securityProtocolOptions, key as __DispatchData, hint as __DispatchData)
        sec_protocol_options_append_tls_ciphersuite(tlsOptions.securityProtocolOptions, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        return NWParameters(dtls: tlsOptions, udp: NWProtocolUDP.Options())
    }())
).sendMessage(CoAPMessage(version: .v1, 
                          code: CoAPMessage.Code.Method.get,
                          type: .confirmable,
                          messageId: randomUnsigned(),
                          token: randomUnsigned(),
                          options: [CoAPMessage.MessageOption.block1(num: 0, more: true, szx: 6)],
                          payload: Data()))
    .republishResponsePayloads()
    .map { payload in
        String(data: payload, encoding: .utf8)
    }
```
