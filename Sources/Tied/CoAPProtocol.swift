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

    func handleInput(framer : NWProtocolFramer.Instance) -> Int {
        while true {
        var messageLength = 0
        var message: CoAPMessage?
        let parsed = framer.parseInput(minimumIncompleteLength: 4, maximumLength: Int(IPV6_MMTU)){(buffer, isComplete) -> Int in
            guard let buffer = buffer?.withUnsafeBytes({$0}) else { return 0 }
            do {
            message = try CoAPMessage.with(buffer)
            } catch {
                return 0
            }
            messageLength = buffer.count
            return buffer.count
        }
        guard parsed, let message = message else {
            // Ask for one more byte if failed to parse.
            return 1
        }
        
        if framer.deliverInputNoCopy(length: messageLength, message: .init(coapMessage: message), isComplete: true) == false {
            return 0
        }
        }
    }

    func handleOutput(framer : NWProtocolFramer.Instance, message : NWProtocolFramer.Message, messageLength : Int, isComplete : Bool) {
        if let data = try? message.coapMessage.encode() {
        framer.writeOutput(data: data)
        }
    }
}

extension NWProtocolFramer.Message {
    convenience init(coapMessage: CoAPMessage){
        self.init(definition: CoAPProtocol.definition)
        self["CoAPMessage"] = coapMessage
    }
    
    var coapMessage: CoAPMessage {
        self["CoAPMessage"] as! CoAPMessage
    }
}
