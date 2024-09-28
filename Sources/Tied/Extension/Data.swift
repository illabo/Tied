//
//  File.swift
//  
//
//  Created by Yachin Ilya on 29.09.2024.
//

import Foundation

extension Data {
    func into<T>() -> T {
        withUnsafeBytes {
            $0.load(as: T.self)
        }
    }
}
