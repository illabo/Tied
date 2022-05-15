//
//  CoAPMessage.swift
//
//
//  Created by Yachin Ilya on 15.05.2022.
//

import Foundation

public struct CoAPMessage {
    var token: UInt64
    var payload: Data
    var observe: Bool
    var data: Data {
        payload
    }
}
