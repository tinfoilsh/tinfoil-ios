//
//  Authentication.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.

import Network
import SwiftUI

@MainActor
class NetworkMonitor: ObservableObject {
    @Published private(set) var isConnected = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }
    
    deinit {
        monitor.cancel()
    }
} 
