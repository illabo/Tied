//
//  File.swift
//  
//
//  Created by Yachin Ilya on 29.09.2024.
//

import Foundation
import UInt4

protocol Into: Sendable {
    func into<T>() throws -> T
    func into<T>(type: T.Type) throws -> T
}

extension Into {
    func into<T>() throws -> T {
        try self.into(type: T.self)
    }
    
    func into<T>(type: T.Type) throws -> T {
        var mutSelf = self
        
        let result: T? = withUnsafePointer(to: &mutSelf) { pointer in
            var raw = UnsafeMutableRawPointer(mutating: pointer)
            return raw.bindMemory(to: type, capacity: MemoryLayout<T>.size).pointee
        }
        
        guard let result else {
                throw NSError(domain: "Into", code: 0)
            }
        return result
    }
}

extension UInt8: Into {}
extension UInt16: Into {}
extension UInt32: Into {}
