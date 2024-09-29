<p align="center">
<img src="Sources/Resources/TiedIcon.webp" alt="Tied Icon" title="Tied" height="250"/><br>
<font size="20">Tied</font>
</p>

---
Tied is the implementation of CoAP client intended to be used on mobile. The library utilizes the latest concepts introduced by Apple and built around Network and Combine frameworks.

CoAP is [constrained application protocol](https://datatracker.ietf.org/doc/html/rfc7252).

This repo is currently 'Work in progress'. Started as a pastime project is platted to be pushed forward sporadically when I have the time on weekends.

### Quickstart
```swift
Tied.newConnection(with: Tied.Settings(endpoint: endpoint))
    .sendMessage(payload: "Cat piss or sauvignon blanc?".data(using: .utf8)!)
    .castingResponsePayloads { payload in
        String(data: payload, encoding: .utf8)
    }
```
