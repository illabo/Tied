//
//  MessageSessionPublisher.swift
//
//
//  Created by Yachin Ilya on 14.05.2022.
//

import Combine
import Foundation

public typealias MessagePayloadRepublisher = AnyPublisher<Data, Error>
public typealias castingResponsePayloadsRepublisher<T> = AnyPublisher<T, Error>

public struct CoAPMessagePublisher: Publisher {
    internal init(connection: Tied.Connection, outgoingMessage: CoAPMessage) {
        self.connection = connection
        message = outgoingMessage
    }

    public typealias Output = CoAPMessage
    public typealias Failure = Error

    private let connection: Tied.Connection
    private let message: CoAPMessage

    public func receive<S>(subscriber: S) where S: Subscriber, Failure == S.Failure, Output == S.Input {
        subscriber.receive(
            subscription: MessageSubscription(
                subscriber: subscriber,
                connection: connection,
                outgoingMessage: message
            )
        )
    }
    
    /// This method returning `MessagePayloadRepublisher` extracts payloads from `CoAPMessage`s
    /// and also removes the burden of joining block2 payloads by consumer.
    public func republishResponsePayloads() -> MessagePayloadRepublisher {
        scan(([CoAPMessage](), false)) { (partial: ([CoAPMessage], Bool), message: CoAPMessage) -> ([CoAPMessage], Bool) in
            var (acc, ready) = partial
            if ready { acc = [] }
            acc.append(message)
            ready = message.areMoreBlocksExpected == false
            return (acc.sorted(by: { $0.blockNumber < $1.blockNumber }), ready)
        }
        .filter { (_: [CoAPMessage], ready: Bool) -> Bool in
            ready
        }
        .map { (messages: [CoAPMessage], ready: _) -> Data in
            messages.map(\.payload).reduce(into: Data(), +=)
        }
        .eraseToAnyPublisher()
    }
    
    /// To directly cast the messages into consumer target type use this method.
    public func castingResponsePayloads<TargetType>(with handler: @escaping (Data) -> TargetType) -> castingResponsePayloadsRepublisher<TargetType> {
        republishResponsePayloads()
            .map(handler)
            .eraseToAnyPublisher()
    }
}

private final class MessageSubscription<S: Subscriber>: Subscription where S.Input == CoAPMessagePublisher.Output, S.Failure == CoAPMessagePublisher.Failure {
    internal init(subscriber: S, connection: Tied.Connection, outgoingMessage: CoAPMessage) {
        self.outgoingMessage = outgoingMessage
        self.subscriber = subscriber
        self.connection = connection
        connection.messagePublisher
            .filter { $0.token == outgoingMessage.token }
            .removeDuplicates()
            .sink { [weak self] completion in
                self?.subscriber?.receive(completion: completion)
            } receiveValue: { [weak self] message in
                _ = self?.subscriber?.receive(message)
                // If the message from server is CON we have to reply with ACK.
                if message.type == .confirmable {
                    self?.connection?.performMessageSend(message.prepareAcknowledgement())
                }
                // If message has no observe option it is meant to be replied once so
                // if no more blocks expected we could stop waiting for more messages.
                if outgoingMessage.isObserve == false && message.areMoreBlocksExpected == false {
                    self?.subscriber?.receive(completion: .finished)
                    self?.cancel()
                }
            }
            .store(in: &subscriptions)
        connection.performMessageSend(outgoingMessage)
    }

    private let outgoingMessage: CoAPMessage
    private var subscriber: S?
    private var connection: Tied.Connection?
    private var subscriptions = Set<AnyCancellable>()

    func request(_: Subscribers.Demand) {}

    func cancel() {
        if outgoingMessage.isObserve {
            connection?.stopSession(for: outgoingMessage.token)
        }
        connection = nil
        subscriber = nil
    }
}

private extension CoAPMessage {
    /// Only applies to outgoing messages.
    var isObserve: Bool {
        self.options.contains(where: { $0.key == .observe && $0.value.into() == 0 })
    }
    
    /// Only applies to incoming messages.
    var areMoreBlocksExpected: Bool {
        guard let block2Option = self.options.first(where: {$0.key == .block2})?.value,
              let lastByte = block2Option.withUnsafeBytes({$0.last}) else { return false }
        return (lastByte >> 3) & 0b1 == 1
    }
    
    var blockNumber: Int {
        guard let block2Option: Int = self.options.first(where: {$0.key == .block2})?.value.into() else { return 0 }
        return block2Option >> 4
    }
    
    /// Create an ACK with original mesage ID.
    func prepareAcknowledgement() -> CoAPMessage {
        CoAPMessage(code: Code.empty, type: .acknowledgement, messageId: self.messageId, token: 0, options: [], payload: Data())
    }
}
