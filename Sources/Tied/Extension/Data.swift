//
//  File.swift
//  
//
//  Created by Yachin Ilya on 29.09.2024.
//

import Foundation

extension Data {
    func into<T>() -> T? {
        let targetSize = MemoryLayout<T>.size

        var paddedData = self
        if count < targetSize {
            let padding = Data(count: targetSize - count)
            paddedData.append(padding)
        }

        guard paddedData.count >= targetSize else {
            return nil
        }

        return paddedData.withUnsafeBytes {
            $0.load(as: T.self)
        }
    }
}
