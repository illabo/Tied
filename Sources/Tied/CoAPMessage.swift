//
//  CoAPMessage.swift
//
//
//  Created by Yachin Ilya on 15.05.2022.
//

import Foundation
import Network

public struct CoAPMessage {
    var token: UInt64
    var payload: Data
    var metadata: NWProtocolFramer.Message
    var observe: Bool
    var data: Data {
        payload
    }
}

extension NWProtocolFramer.Message {}
