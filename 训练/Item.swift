//
//  Item.swift
//  训练
//
//  Created by 范想佳 on 2026/5/8.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
