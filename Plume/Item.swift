//
//  Item.swift
//  Plume
//
//  Created by Ryan Moelter on 8/31/26.
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
