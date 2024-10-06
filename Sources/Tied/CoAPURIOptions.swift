//
//  URIOptions.swift
//
//
//  Created by Yachin Ilya on 06.10.2024.
//

import Foundation
import Network

public struct CoAPURIOptions {
    enum URIError: Error {
        case hostTooShort
        case hostTooLong
        case pathIllegal([String])
        case queryTooLong([String])
    }
    let host: String?
    let port: UInt16?
    let paths: [String]
    let queries: [String]
    
    public init(host: String? = nil, port: UInt16? = nil, paths: [String] = [], queries: [String] = []) throws {
        if let host {
            if host.count > 255 {
                throw URIError.hostTooLong
            }
            if host.count < 1 {
                throw URIError.hostTooShort
            }
        }
        let illegalPaths = paths.filter{ $0.count > 255 || $0 == "." || $0 == ".."  }
        guard illegalPaths.isEmpty else {
            throw URIError.pathIllegal(illegalPaths)
        }
        let illegalQueries = queries.filter{ $0.count > 255 }
        guard illegalQueries.isEmpty else {
            throw URIError.queryTooLong(illegalQueries)
        }
        self.host = host
        self.port = port
        self.paths = paths
        self.queries = queries
    }
}
