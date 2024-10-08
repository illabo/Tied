//
//  File.swift
//
//
//  Created by Yachin Ilya on 29.09.2024.
//

import Foundation
import Tied
import Combine
import Network

@main
class TiedExample {
    private let connection: Tied.Connection
    private var disposable: AnyCancellable?

    static func main() async {
        let example = TiedExample()
        await example.run()
    }

    init() {
        let settings = Tied.Settings(host: "127.0.0.1")
        connection = Tied.newConnection(with: settings)
    }

    func run() async {
        disposable = connection.sendMessage(method: .get, type: .confirmable, observe: true, uriOptions: try! CoAPURIOptions(paths: ["/hello_obs"]))
            .castingResponsePayloads { payload in
                String(data: payload, encoding: .utf8)
            }
            .sink { [weak self] completion in
                print("Observe ended with \(completion)")
                self?.disposable = nil
            } receiveValue: { message in
                print("Got message: \(message ?? "NONE")")
            }
        
        while disposable != nil { }
    }
}

