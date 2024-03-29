//
//  MessageSessionPublisher.swift
//
//
//  Created by Yachin Ilya on 14.05.2022.
//

import Combine
import Foundation

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
}

private final class MessageSubscription<S: Subscriber>: Subscription where S.Input == CoAPMessagePublisher.Output, S.Failure == CoAPMessagePublisher.Failure {
    internal init(subscriber: S, connection: Tied.Connection, outgoingMessage: CoAPMessage) {
        self.subscriber = subscriber
        self.connection = connection
        token = outgoingMessage.token
        connection.messagePublisher
            .filter { $0.token == self.token }
            .sink { [weak self] completion in
                self?.subscriber?.receive(completion: completion)
            } receiveValue: { [weak self] message in
                _ = self?.subscriber?.receive(message)
                // If message has no observe option it is meant to be replied once.
                if outgoingMessage.options.contains(where: { $0.key == .observe }) == false {
                    self?.subscriber?.receive(completion: .finished)
                    self?.cancel()
                }
            }
            .store(in: &subscriptions)
        connection.performMessageSend(outgoingMessage)
    }

    private let token: UInt64
    private var subscriber: S?
    private var connection: Tied.Connection?
    private var subscriptions = Set<AnyCancellable>()

    func request(_: Subscribers.Demand) {}

    func cancel() {
        connection?.stopSession(for: token)
        connection = nil
        subscriber = nil
    }
}

extension MessageSubscription {
    static func isObserve(outgoingMessage: CoAPMessage)->Bool{
        guard let observeOption = outgoingMessage.options.first(where: { $0.key == .observe })?.value else { return false }
        return true
    }
    static func areMoreBlocksExpected(incomingMessage: CoAPMessage)->Bool{
        guard let block2Option = incomingMessage.options.first(where: {$0.key == .block2})?.value,
              let lastByte = block2Option.withUnsafeBytes({$0.last}) else { return false }
        return (lastByte >> 3) & 0b1 == 1
    }
}
