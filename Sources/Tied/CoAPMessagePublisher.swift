//
//  MessageSessionPublisher.swift
//
//
//  Created by Yachin Ilya on 14.05.2022.
//

import Combine
import Foundation

public struct CoAPMessagePublisher: Publisher {
    internal init(connection: CoAPClient.Connection, outgoingMessage: CoAPMessage) {
        self.connection = connection
        message = outgoingMessage
    }

    public typealias Output = CoAPMessage
    public typealias Failure = Error

    private let connection: CoAPClient.Connection
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
    internal init(subscriber: S, connection: CoAPClient.Connection, outgoingMessage: CoAPMessage) {
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
                if outgoingMessage.options.contains(where: {$0.key == .observe}) == false {
                    self?.subscriber?.receive(completion: .finished)
                    self?.cancel()
                }
            }
            .store(in: &subscriptions)
    }

    private let token: UInt64
    private var subscriber: S?
    private var connection: CoAPClient.Connection?
    private var subscriptions = Set<AnyCancellable>()

    func request(_: Subscribers.Demand) {}

    func cancel() {
        connection?.stopSession(for: token)
        connection = nil
        subscriber = nil
    }
}
