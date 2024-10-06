//
//  UnsignedInteger.swift
//  
//
//  Created by Yachin Ilya on 30.09.2024.
//

import Foundation

public func randomUnsigned<U>() -> U where U: UnsignedInteger, U: FixedWidthInteger {
    let byteCount = U.self.bitWidth / UInt8.bitWidth
    var randomBytes = Data(count: byteCount)
    
    withUnsafeMutableBytes(of: &randomBytes) { pointer in
        guard let baseAddress = pointer.baseAddress else { return }
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, baseAddress)
    }
    
    return randomBytes.withUnsafeBytes {
        $0.load(as: U.self)
    }
}

extension UnsignedInteger where Self: FixedWidthInteger {
    func into() -> Data {
        var be = self.bigEndian
        return Data(bytes: &be, count: MemoryLayout<Self>.size)
    }
}
