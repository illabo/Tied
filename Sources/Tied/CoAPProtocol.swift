//
//  CoAPProtocol.swift
//
//
//  Created by Yachin Ilya on 15.05.2022.
//

import Network

class CoAPProtocol: NWProtocolFramerImplementation {
    static let definition = NWProtocolFramer.Definition(implementation: CoAPProtocol.self)
    static var label: String { "CoAP Protocol" }

    required init(framer _: NWProtocolFramer.Instance) {}
    func start(framer _: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult { return .ready }
    func wakeup(framer _: NWProtocolFramer.Instance) {}
    func stop(framer _: NWProtocolFramer.Instance) -> Bool { return true }
    func cleanup(framer _: NWProtocolFramer.Instance) {}

    func handleInput(framer _: NWProtocolFramer.Instance) -> Int {
        // TODO: implement
        0
    }

    func handleOutput(framer _: NWProtocolFramer.Instance, message _: NWProtocolFramer.Message, messageLength _: Int, isComplete _: Bool) {
        // TODO: implement
    }
}
