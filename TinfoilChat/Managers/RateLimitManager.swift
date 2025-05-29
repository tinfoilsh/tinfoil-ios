//
//  RateLimitManager.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.

import Foundation

/// Manages rate limiting for free users
class RateLimitManager {
    static let shared = RateLimitManager()
    
    private init() {
        // Check if we need to reset the counter based on time window
        checkAndResetCounter()
    }
    
    /// The current message count for the free user
    var messageCount: Int {
        get {
            UserDefaults.standard.integer(forKey: Constants.RateLimits.userDefaultsCountKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.RateLimits.userDefaultsCountKey)
        }
    }
    
    /// Timestamp when the counter was last reset
    private var lastResetTime: Date? {
        get {
            UserDefaults.standard.object(forKey: Constants.RateLimits.userDefaultsTimeKey) as? Date
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Constants.RateLimits.userDefaultsTimeKey)
        }
    }
    
    /// Increment the message count and return if the user is rate limited
    func incrementAndCheckLimit() -> Bool {
        checkAndResetCounter()
        
        // Increment the counter
        messageCount += 1
        
        // Check if user has exceeded the limit
        return messageCount > Constants.RateLimits.freeUserMaxMessages
    }
    
    /// Check if the user is currently rate limited
    var isRateLimited: Bool {
        checkAndResetCounter()
        return messageCount >= Constants.RateLimits.freeUserMaxMessages
    }
    
    /// Returns the number of messages remaining before hitting the limit
    var messagesRemaining: Int {
        let remaining = Constants.RateLimits.freeUserMaxMessages - messageCount
        return max(0, remaining)
    }
    
    /// Returns a formatted string showing when the rate limit will reset
    var timeUntilReset: String {
        guard let resetTime = lastResetTime else { return "Unknown" }
        
        let resetDate = resetTime.addingTimeInterval(TimeInterval(Constants.RateLimits.freeUserTimeWindowHours * 3600))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        
        return formatter.localizedString(for: resetDate, relativeTo: Date())
    }
    
    /// Reset the counter to zero and update the reset timestamp
    func resetCounter() {
        messageCount = 0
        lastResetTime = Date()
    }
    
    /// Checks if the time window has elapsed and resets the counter if needed
    private func checkAndResetCounter() {
        guard let resetTime = lastResetTime else {
            // If no reset time is recorded, set it now
            lastResetTime = Date()
            messageCount = 0
            return
        }
        
        // Calculate time since last reset
        let timeWindowInSeconds = TimeInterval(Constants.RateLimits.freeUserTimeWindowHours * 3600)
        let timeSinceReset = Date().timeIntervalSince(resetTime)
        
        // If more time has passed than our window, reset the counter
        if timeSinceReset >= timeWindowInSeconds {
            resetCounter()
        }
    }
} 
