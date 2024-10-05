//
//  MessageSessionPublisher.swift
//
//
//  Created by Yachin Ilya on 14.05.2022.
//

import Combine
import Foundation

public typealias MessagePayloadRepublisher = AnyPublisher<Data, Error>
public typealias CastingResponsePayloadsRepublisher<T> = AnyPublisher<T, Error>

public struct CoAPMessagePublisher: Publisher {
    // TODO: need to introduce
    // internal init(connection: Tied.Connection, outgoingMessages: Data)
    // to do the dynamic message chunking based on szx returned from server.
    // MessageSubscription have to be inited with Data and not [CoAPMessage].
    
    internal init(connection: Tied.Connection, outgoingMessages: CoAPMessage...) {
        self.connection = connection
        messages = outgoingMessages
    }
    
    public typealias Output = CoAPMessage
    public typealias Failure = Error
    
    private let connection: Tied.Connection
    private let messages: [CoAPMessage]
    
    public func receive<S>(subscriber: S) where S: Subscriber, Failure == S.Failure, Output == S.Input {
        if let subscription = MessageSubscription(
            subscriber: subscriber,
            connection: connection,
            outgoingMessages: messages
        ) {
            subscriber.receive(
                subscription: subscription
            )
        } else {
            // If no messages to be sent complete immediately.
            subscriber.receive(completion: .finished)
        }
    }
    
    /// This method returning `MessagePayloadRepublisher` extracts payloads from `CoAPMessage`s
    /// and also removes the burden of joining block2 payloads by consumer.
    public func republishResponsePayloads() -> MessagePayloadRepublisher {
        filter {
            $0.payload.isEmpty == false
        }
        .scan(([CoAPMessage](), false)) { (partial: ([CoAPMessage], Bool), message: CoAPMessage) -> ([CoAPMessage], Bool) in
            var (acc, ready) = partial
            if ready { acc = [] }
            acc.append(message)
            ready = message.options.block2()?.moreBlocksExpected ?? false == false
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
    public func castingResponsePayloads<TargetType>(with handler: @escaping (Data) -> TargetType) -> CastingResponsePayloadsRepublisher<TargetType> {
        republishResponsePayloads()
            .map(handler)
            .eraseToAnyPublisher()
    }
}

private final class MessageSubscription<S: Subscriber>: Subscription where S.Input == CoAPMessagePublisher.Output, S.Failure == CoAPMessagePublisher.Failure {
    internal init?(subscriber: S, connection: Tied.Connection, outgoingMessages: [CoAPMessage]) {
        guard outgoingMessages.isEmpty == false else {
            return nil
        }
        let type = outgoingMessages.first!.type
        let token = outgoingMessages.first!.token
        let isObserve = outgoingMessages.first!.options.observe() == .isObserve
        
        self.isObserve = isObserve
        self.token = token
        self.subscriber = subscriber
        self.connection = connection
        
        // TODO: When (re-)chunking block1 messages read the SZX value from connection.block1Szx.
        var unsentMessages: [CoAPMessage] = outgoingMessages
        
        connection.messagePublisher
            .filter {
                $0.token == token ||
                unsentMessages.map(\.messageId).contains($0.messageId)
            }
            .removeDuplicates()
            .sink { [weak self] completion in
                self?.subscriber?.receive(completion: completion)
                self?.cancel()
            } receiveValue: { [weak self] message in
                // Send whatever we recieved to consumer if they want to sort all the messages out.
                // Correct responses to be done below.
                // If the consumer is only interested in 'stiched' payload
                // `CoAPMessagePublisher` methods `republishResponsePayloads()` and
                // `castingResponsePayloads<TargetType>(with handler: @escaping (Data) -> TargetType)`
                // would do the cleaning for consumer.
                _ = self?.subscriber?.receive(message)
                
                // If the message from server is CON we have to reply with ACK.
                if message.type == .confirmable {
                    self?.connection?.performMessageSend(message.prepareAcknowledgement())
                }
                // Remove from unsent messages the message just acknowledged.
                if type == .confirmable,
                   message.type == .acknowledgement {
                    unsentMessages.removeAll(where: { $0.messageId == message.messageId })
                    // If it is just acknowlidgement with no content
                    // we would wait for the message with content yet to come.
                    if message.code == CoAPMessage.Code.empty {
                        return
                    }
                }
                // Cancel observing or don't expect the meaningful response from server.
                if message.type == .reset {
                    self?.subscriber?.receive(completion: .finished)
                    self?.cancel()
                }
                // If M bit is not nil and set to true request next block.
                if message.options.block2()?.moreBlocksExpected ?? false,
                   let token = self?.token {
                    let num = message.options.block2()?.blockNumber ?? 0
                    let szx = message.options.block2()?.szx ?? 6
                    unsentMessages.append(
                        CoAPMessage(
                            code: .get,
                            type: .confirmable,
                            messageId: randomUnsigned(),
                            token: token,
                            options: [
                                CoAPMessage.MessageOption.block2(num: num + 1,
                                                                 more: false,
                                                                 szx: szx),
                            ]
                        )
                    )
                }
                // If message has no observe option it is meant to be replied once so
                // if no more blocks expected to be received or sent we could stop waiting for more messages.
                if isObserve == false &&
                    message.options.block2()?.moreBlocksExpected ?? false == false &&
                    unsentMessages.isEmpty
                {
                    self?.subscriber?.receive(completion: .finished)
                    self?.cancel()
                }
            }
            .store(in: &subscriptions)
        
        Timer.TimerPublisher(interval: 1, runLoop: .main, mode: .common).autoconnect()
            .sink { _ in
                if unsentMessages.first?.type == .confirmable, let next = unsentMessages.first {
                    connection.performMessageSend(next)
                }
                if unsentMessages.isEmpty == false, unsentMessages.first?.type != .confirmable {
                    connection.performMessageSend(unsentMessages.removeFirst())
                }
            }
            .store(in: &subscriptions)
    }
    
    private let isObserve: Bool
    private let token: UInt64
    private var subscriber: S?
    private var connection: Tied.Connection?
    private var subscriptions = Set<AnyCancellable>()
    
    func request(_: Subscribers.Demand) {}
    
    func cancel() {
        connection?.stopSession(for: self.token, observed: self.isObserve)
        subscriptions.forEach { subscription in
            subscription.cancel()
        }
        subscriptions.removeAll()
        connection = nil
        subscriber = nil
    }
}

