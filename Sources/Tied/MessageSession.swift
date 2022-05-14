//
//  MessageSession.swift
//
//
//  Created by Yachin Ilya on 14.05.2022.
//

import Combine
import Foundation

public struct MessageSession {
    let publisher: CoAPMessagePublisher
    let token: UInt64
    let sendHandler: (Data) -> Void
}
