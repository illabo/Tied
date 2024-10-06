//
//  CoAPMessageRepository.swift
//
//
//  Created by Yachin Ilya on 06.10.2024.
//

import Foundation
import UInt4

protocol CoAPMessageRepository: AnyObject {
    var type: CoAPMessage.MessageType { get }
    var token: UInt64 { get }
    func nextMessage() -> CoAPMessage?
    func dequeue(messageId: UInt16)
    func enqueue(num: UInt32, szx: UInt4)
    func enqueue(message: CoAPMessage)
    func inQueue(messageId: UInt16) -> Bool
    func resetQueue()
}

class PresetCoAPMessageQueue: CoAPMessageRepository {
    var type: CoAPMessage.MessageType { messageQueue.first!.type }
    var token: UInt64 { messageQueue.first!.token }
    private var messageQueue: [CoAPMessage]
    private var acknowledgedMessageIds = Set<UInt16>()
    
    init(messages: [CoAPMessage]) {
        messageQueue = messages
    }
    
    func nextMessage() -> CoAPMessage? {
        messageQueue.first(where: { acknowledgedMessageIds.contains($0.messageId) == false })
    }
    
    // Next block number and SZX are ignored because there's now control over library user predefined messages.
    func enqueue(num _: UInt32, szx _: UInt4) { }
    
    func dequeue(messageId: UInt16) {
        acknowledgedMessageIds.insert(messageId)
    }
    
    func enqueue(message: CoAPMessage) {
        messageQueue.append(message)
    }
    
    func inQueue(messageId: UInt16) -> Bool {
        messageQueue.map(\.messageId).contains(messageId) &&
        (acknowledgedMessageIds.contains(messageId) == false)
    }
    
    func resetQueue() {
        acknowledgedMessageIds.removeAll()
    }
}

class CoAPMessageQueue: CoAPMessageRepository {
    let type: CoAPMessage.MessageType
    let token: UInt64
    private let method: CoAPMessage.Code.Method
    private let observe: Bool
    private let uriOptions: CoAPURIOptions?
    private let ifMatch: [Data]?
    private let ifNoneMatch: Bool
    private let contentFormat: UInt16?
    private let accept: UInt16?
    private let payload: Data
    // Position to track where to start the next payload block.
    private var lastCutPosition: Int = 0
    private var messageQueue = [CoAPMessage]()
    
    internal init(method: CoAPMessage.Code.Method,
                  type: CoAPMessage.MessageType,
                  token: UInt64,
                  observe: Bool,
                  uriOptions: CoAPURIOptions?,
                  ifMatch: [Data]?,
                  ifNoneMatch: Bool,
                  contentFormat: UInt16?,
                  accept: UInt16?,
                  payload: Data) {
        self.method = method
        self.type = type
        self.token = token
        self.observe = observe
        self.uriOptions = uriOptions
        self.ifMatch = ifMatch
        self.ifNoneMatch = ifNoneMatch
        self.contentFormat = contentFormat
        self.accept = accept
        self.payload = payload
    }
    
    func nextMessage() -> CoAPMessage? {
        if let retransmitted = messageQueue.first {
            return retransmitted
        }
        return nil
    }
    
    // To get initial message set num 0.
    func enqueue(num: UInt32, szx: UInt4) {
        let blockSize = CoAPMessage.MessageOption.BlockValue.blockSize(szx: szx)
        let nextCut = lastCutPosition + blockSize
        var options = CoAPMessage.MessageOptionSet()
        if num != 0, payload.count <= lastCutPosition {
            return // Nothing to enqueue. All the block1 messages have been dequeued.
        }
        if let host = uriOptions?.host {
            options.append(CoAPMessage.MessageOption(key: .uriHost, value: host.data(using: .utf8) ?? Data()))
        }
        if let port = uriOptions?.port {
            options.append(CoAPMessage.MessageOption(key: .uriPort, value: try! port.into()))
        }
        options.append(contentsOf: uriOptions?.paths.compactMap { path in
            CoAPMessage.MessageOption(key: .uriPath, value: path.data(using: .utf8) ?? Data())
        } ?? [])
        options.append(contentsOf: uriOptions?.queries.compactMap { query in
            CoAPMessage.MessageOption(key: .uriQuery, value: query.data(using: .utf8) ?? Data())
        } ?? [])
        if num == 0 {
            if observe {
                options.append(CoAPMessage.MessageOption.observe(.isObserve))
            }
        }
        if payload.count > blockSize, payload.count > nextCut {
            let block1Payload = payload.subdata(in: lastCutPosition ..< nextCut)
            // Add block options.
            messageQueue.append(CoAPMessage(code: method, type: type, messageId: randomUnsigned(), token: token, options: options, payload: block1Payload))
            return
        }
        messageQueue.append(CoAPMessage(code: method, type: type, messageId: randomUnsigned(), token: token, options: options, payload: payload))
    }
    
    func dequeue(messageId: UInt16) {
        messageQueue.removeAll(where: { $0.messageId == messageId })
    }
    
    func enqueue(message: CoAPMessage) {
        messageQueue.append(message)
    }
    
    func inQueue(messageId: UInt16) -> Bool {
        messageQueue.map(\.messageId).contains(messageId)
    }
    
    func resetQueue() {
        lastCutPosition = 0
        messageQueue.removeAll()
    }
    
    
}
