//
//  ChatModels.swift
//  TinfoilChat
//
//  Created on 04/10/24.
//  Copyright © 2024 Tinfoil. All rights reserved.


import Foundation
import UIKit
import Clerk
import NaturalLanguage

/// Represents a chat conversation
struct Chat: Identifiable, Codable {
    let id: String
    var title: String
    var messages: [Message]
    var hasActiveStream: Bool = false
    var createdAt: Date
    var modelType: ModelType
    var language: String?
    var userId: String?
    
    init(
        id: String = UUID().uuidString, 
        title: String = "New Chat", 
        messages: [Message] = [], 
        createdAt: Date = Date(),
        modelType: ModelType,
        language: String? = nil,
        userId: String? = nil) 
    {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.modelType = modelType
        self.language = language
        self.userId = userId
    }
    
    // MARK: - Factory Methods
    
    /// Creates a new chat with the current model from AppConfig
    @MainActor
    static func create(
        id: String = UUID().uuidString,
        title: String = "New Chat",
        messages: [Message] = [],
        createdAt: Date = Date(),
        modelType: ModelType? = nil,
        language: String? = nil,
        userId: String? = nil
    ) -> Chat {
        let model = modelType ?? AppConfig.shared.currentModel ?? AppConfig.shared.availableModels.first!
        return Chat(
            id: id,
            title: title,
            messages: messages,
            createdAt: createdAt,
            modelType: model,
            language: language,
            userId: userId
        )
    }
    
    // MARK: - Codable Implementation
    
    enum CodingKeys: String, CodingKey {
        case id, title, messages, hasActiveStream, createdAt, modelType, language, userId
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        messages = try container.decode([Message].self, forKey: .messages)
        hasActiveStream = try container.decodeIfPresent(Bool.self, forKey: .hasActiveStream) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modelType = try container.decode(ModelType.self, forKey: .modelType)
        language = try container.decodeIfPresent(String.self, forKey: .language)
        userId = try container.decodeIfPresent(String.self, forKey: .userId)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(messages, forKey: .messages)
        try container.encode(hasActiveStream, forKey: .hasActiveStream)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modelType, forKey: .modelType)
        try container.encodeIfPresent(language, forKey: .language)
        try container.encodeIfPresent(userId, forKey: .userId)
    }
    
    // MARK: - Haptic Feedback Methods
    
    /// Triggers haptic feedback when a chat is selected
    static func triggerSelectionFeedback() {
        HapticFeedback.trigger(.selection)
    }
    
    /// Triggers haptic feedback when a chat operation succeeds
    static func triggerSuccessFeedback() {
        HapticFeedback.trigger(.success)
    }
    
    /// Triggers haptic feedback when a chat operation encounters an error
    static func triggerErrorFeedback() {
        HapticFeedback.trigger(.error)
    }
    
    // MARK: - UserDefaults Methods
    
    static func saveToDefaults(_ chats: [Chat], userId: String?) {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(chats)
            if let userId = userId {
                // Store chats under user-specific key
                UserDefaults.standard.set(data, forKey: "savedChats_\(userId)")
            } else {
                // Store chats under anonymous key
                UserDefaults.standard.set(data, forKey: "savedChats_anonymous")
            }
        } catch {
            print("Error saving chats: \(error)")
        }
    }
    
    static func loadFromDefaults(userId: String?) -> [Chat] {
        let key = userId != nil ? "savedChats_\(userId!)" : "savedChats_anonymous"
        guard let data = UserDefaults.standard.data(forKey: key) else {
            // If no chats found for specific user, try loading from old generic key for migration
            if let oldData = UserDefaults.standard.data(forKey: "savedChats") {
                do {
                    let decoder = JSONDecoder()
                    var chats = try decoder.decode([Chat].self, from: oldData)
                    // Update chats with user ID
                    chats = chats.map { chat in
                        var updatedChat = chat
                        updatedChat.userId = userId
                        return updatedChat
                    }
                    // Save migrated chats to new user-specific key
                    saveToDefaults(chats, userId: userId)
                    // Remove old data
                    UserDefaults.standard.removeObject(forKey: "savedChats")
                    return chats.sorted { $0.createdAt > $1.createdAt }
                } catch {
                    print("Error migrating old chats: \(error)")
                    return []
                }
            }
            return []
        }
        
        do {
            let decoder = JSONDecoder()
            let chats = try decoder.decode([Chat].self, from: data)
            return chats.sorted { $0.createdAt > $1.createdAt }
        } catch {
            print("Error loading chats: \(error)")
            return []
        }
    }
    
    // MARK: - Title Generation
    
    /// Generates a title for a chat based on the first user message
    static func generateTitle(from text: String) -> String {
        // Use the TextRank algorithm to generate a title
        return TextRankTitleGenerator.shared.generateTitle(from: text)
    }
}

/// Represents a message role
enum MessageRole: String, Codable {
    case user
    case assistant
}

/// Represents a single message in a chat
struct Message: Identifiable, Codable, Equatable {
    let id: String
    let role: MessageRole
    var content: String
    var timestamp: Date
    var isCollapsed: Bool = false
    var isStreaming: Bool = false
    var streamError: String? = nil
    var generationTimeSeconds: Double? = nil
    
    init(id: String = UUID().uuidString, role: MessageRole, content: String, timestamp: Date = Date(), isCollapsed: Bool = false, generationTimeSeconds: Double? = nil) {
        self.id = id
        self.role = role
        self.content = content
        self.timestamp = timestamp
        self.isCollapsed = isCollapsed
        self.generationTimeSeconds = generationTimeSeconds
    }
    
    // MARK: - Codable Implementation
    
    enum CodingKeys: String, CodingKey {
        case id, role, content, timestamp, isCollapsed, isStreaming, streamError, generationTimeSeconds
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        id = try container.decode(String.self, forKey: .id)
        role = try container.decode(MessageRole.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        isCollapsed = try container.decode(Bool.self, forKey: .isCollapsed)
        isStreaming = try container.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        streamError = try container.decodeIfPresent(String.self, forKey: .streamError)
        generationTimeSeconds = try container.decodeIfPresent(Double.self, forKey: .generationTimeSeconds)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role.rawValue, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encode(isCollapsed, forKey: .isCollapsed)
        try container.encode(isStreaming, forKey: .isStreaming)
        try container.encodeIfPresent(streamError, forKey: .streamError)
        try container.encodeIfPresent(generationTimeSeconds, forKey: .generationTimeSeconds)
    }
    
    // MARK: - Haptic Feedback Methods
    
    /// Triggers haptic feedback when a message is sent
    static func triggerSentFeedback() {
        HapticFeedback.trigger(.messageSent)
    }
    
    /// Triggers haptic feedback when a message is received
    static func triggerReceivedFeedback() {
        HapticFeedback.trigger(.messageReceived)
    }
    
    /// Triggers haptic feedback when a message encounters an error
    static func triggerErrorFeedback() {
        HapticFeedback.trigger(.error)
    }
}

// MARK: - Haptic Feedback

/// Utility for handling haptic feedback in chat interactions
enum HapticFeedback {
    /// Available haptic feedback types for chat interactions
    enum FeedbackType {
        case messageSent
        case messageReceived
        case error
        case success
        case selection
    }
    
    /// Triggers haptic feedback of specified type if enabled in settings
    static func trigger(_ type: FeedbackType) {
        // Check if haptic feedback is enabled in settings via UserDefaults
        let hapticEnabled = UserDefaults.standard.object(forKey: "hapticFeedbackEnabled") as? Bool ?? true
        
        // Return early if haptic feedback is disabled
        guard hapticEnabled else { return }
        
        // Determine feedback style based on type
        let generator: Any
        switch type {
        case .messageSent, .messageReceived:
            generator = UIImpactFeedbackGenerator(style: .medium)
            (generator as! UIImpactFeedbackGenerator).impactOccurred()
        case .error:
            generator = UINotificationFeedbackGenerator()
            (generator as! UINotificationFeedbackGenerator).notificationOccurred(.error)
        case .success:
            generator = UINotificationFeedbackGenerator()
            (generator as! UINotificationFeedbackGenerator).notificationOccurred(.success)
        case .selection:
            generator = UISelectionFeedbackGenerator()
            (generator as! UISelectionFeedbackGenerator).selectionChanged()
        }
    }
}

// MARK: - API Key Management

/// Manages API key retrieval for premium models
class APIKeyManager {
    static let shared = APIKeyManager()
    
    private var apiKey: String?
    private let apiKeyEndpoint = "\(Constants.API.baseURL)/api/keys/chat"
    private let userDefaultsKey = "tinfoil_premium_api_key"
    
    private init() {
        // Load cached API key from UserDefaults on init
        self.apiKey = UserDefaults.standard.string(forKey: userDefaultsKey)
    }
    
    /// Retrieves the API key for premium models
    /// - Returns: API key string or empty string if unavailable
    func getApiKey() async -> String {
        // Return cached key if available
        if let existingKey = apiKey {
            return existingKey
        }
        
        do {
            // Try to load Clerk if it's not loaded
            let isLoaded = await Clerk.shared.isLoaded
            if !isLoaded {
                try await Clerk.shared.load()
            }
            
            // Try a few times with a small delay for the session to be available
            for attempt in 1...3 {
                let session = await Clerk.shared.session
                if let session = session,
                   let tokenResource = session.lastActiveToken {
                    
                    // Create URL request with auth header
                    var request = URLRequest(url: URL(string: apiKeyEndpoint)!)
                    request.httpMethod = "GET"
                    request.addValue("Bearer \(tokenResource.jwt)", forHTTPHeaderField: "Authorization")
                    
                    // Fetch API key from server
                    let (data, response) = try await URLSession.shared.data(for: request)
                    
                    guard let httpResponse = response as? HTTPURLResponse, 
                          httpResponse.statusCode == 200 else {
                        print("API key fetch failed with status: \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                        return ""
                    }
                    
                    // Parse response
                    if let responseDict = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let key = responseDict["key"] as? String {
                        // Cache key in memory and UserDefaults
                        self.apiKey = key
                        UserDefaults.standard.set(key, forKey: userDefaultsKey)
                        return key
                    }
                    
                    return ""
                }
                
                // Wait a bit before trying again (only for first 2 attempts)
                if attempt < 3 {
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                }
            }
            
            print("Clerk session not available after 3 attempts")
            return ""
        } catch {
            print("Error fetching API key: \(error)")
            return ""
        }
    }
    
    /// Clears the cached API key
    func clearApiKey() {
        apiKey = nil
        UserDefaults.standard.removeObject(forKey: userDefaultsKey)
    }
}

// MARK: - Title Generation

/// A class that implements the TextRank algorithm for generating titles from text
/// 
/// TextRank is a graph-based ranking algorithm inspired by Google's PageRank. It works by:
/// 1. Building a graph where nodes are words and edges represent co-occurrence
/// 2. Running PageRank to identify the most important words
/// 3. Extracting the top-ranked words as keywords for the title
///
/// This implementation filters out common words and uses a sliding window approach
/// to determine word co-occurrence relationships.
class TextRankTitleGenerator {
    // Common words to exclude from titles
    private static let commonWords: Set<String> = [
        // Articles
        "the", "a", "an",
        
        // Conjunctions
        "and", "or", "but", "nor", "yet", "so", "for", "as", "if", "although",
        "because", "since", "unless", "while", "whereas", "whether", "though",
        
        // Prepositions
        "in", "on", "at", "to", "for", "of", "with", "by", "from", "up",
        "about", "into", "over", "after", "beneath", "under", "above", "across",
        "against", "along", "among", "around", "before", "behind", "below",
        "beside", "between", "beyond", "during", "except", "inside", "near",
        "off", "onto", "outside", "through", "throughout", "toward", "towards",
        "until", "upon", "within", "without",
        
        // Pronouns
        "i", "you", "he", "she", "it", "we", "they", "me", "him", "her",
        "us", "them", "my", "your", "his", "her", "its", "our", "their",
        "mine", "yours", "hers", "ours", "theirs", "this", "that", "these",
        "those", "who", "whom", "whose", "which", "what", "myself", "yourself",
        "himself", "herself", "itself", "ourselves", "themselves", "anybody",
        "anyone", "anything", "each", "either", "everybody", "everyone",
        "everything", "neither", "nobody", "nothing", "one", "other", "somebody",
        "someone", "something", "whatever", "whichever", "whoever", "whomever",
        
        // Auxiliary verbs
        "am", "is", "are", "was", "were", "be", "been", "being", "have",
        "has", "had", "do", "does", "did", "can", "could", "will", "would",
        "shall", "should", "may", "might", "must", "ought", "used", "dare",
        "need", "going",
        
        // Common adverbs
        "very", "really", "just", "now", "then", "here", "there", "when",
        "where", "why", "how", "all", "any", "both", "each", "few", "more",
        "most", "other", "some", "such", "again", "almost", "already", "always",
        "ever", "far", "fast", "hard", "hardly", "later", "nearly", "never",
        "not", "often", "only", "perhaps", "quickly", "quite", "rather", "sometimes",
        "soon", "too", "usually", "yet", "afterward", "eventually", "finally",
        "immediately", "lately", "occasionally", "once", "presently", "previously",
        "rarely", "recently", "seldom", "suddenly", "tomorrow", "yesterday",
        "together", "apart", "away", "certainly", "definitely", "maybe", "possibly",
        "probably", "absolutely", "completely", "entirely", "fully", "mostly",
        "partially", "simply", "somewhat", "totally", "well", "almost", "barely",
        "exactly", "nearly", "practically", "virtually", "specifically", "generally",
        
        // Common adjectives
        "new", "good", "high", "old", "great", "big", "small", "many",
        "own", "same", "few", "much", "able", "bad", "best", "better", "certain",
        "clear", "different", "early", "easy", "economic", "federal", "free", "full",
        "hard", "important", "international", "large", "late", "little", "local", "long",
        "low", "major", "military", "national", "open", "political", "possible", "present",
        "public", "real", "recent", "right", "second", "social", "special", "strong",
        "sure", "true", "white", "whole", "young", "common", "poor", "happy", "sad",
        "significant", "similar", "simple", "specific", "total", "various", "close",
        "deep", "due", "far", "fine", "foreign", "heavy", "hot", "main", "necessary",
        "past", "personal", "ready", "short", "sorry", "unable", "usual", "wrong",
        "broad", "central", "current", "entire", "extra", "general", "global", "huge",
        "less", "normal", "perfect", "wide", "dark", "difficult", "enough", "flat",
        "fresh", "likely", "positive", "private", "proper", "serious", "thin", "warm",
        
        // Numbers and time words
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
        "eighteen", "nineteen", "twenty", "thirty", "forty", "fifty", "sixty", "seventy",
        "eighty", "ninety", "hundred", "thousand", "million", "billion", "trillion",
        "first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth",
        "tenth", "last", "next", "time", "year", "day", "week", "month", "hour", "minute",
        "second", "morning", "afternoon", "evening", "night", "today", "tomorrow", "yesterday",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december", "annual", "daily", "hourly",
        "monthly", "weekly", "yearly", "decade", "century", "millennium",
        
        // Verbs
        "like", "get", "go", "make", "know", "will", "think", "take", "see",
        "come", "want", "look", "use", "find", "give", "tell", "work", "call", "try",
        "ask", "need", "feel", "become", "leave", "put", "mean", "keep", "let",
        "begin", "seem", "help", "talk", "turn", "start", "show", "hear", "play",
        "run", "move", "live", "believe", "bring", "happen", "write", "provide", "sit",
        "stand", "lose", "pay", "meet", "include", "continue", "set", "learn", "change",
        "lead", "understand", "watch", "follow", "stop", "create", "speak", "read",
        "allow", "add", "spend", "grow", "open", "walk", "win", "offer", "remember",
        "love", "consider", "appear", "buy", "wait", "serve", "die", "send", "expect",
        "build", "stay", "fall", "cut", "reach", "kill", "remain", "suggest", "raise",
        "pass", "sell", "require", "agree", "report", "decide", "pull", "rise",
        
        // Other common words
        "way", "also", "back", "even", "still", "way", "take", "every", "since",
        "please", "much", "want", "need", "right", "left", "part", "point", "place",
        "group", "world", "case", "company", "system", "end", "fact", "word", "example",
        "home", "side", "business", "area", "kind", "type", "life", "hand", "line",
        "name", "office", "face", "level", "head", "car", "water", "thing", "study",
        "air", "food", "plan", "book", "room", "idea", "power", "form", "job", "eye",
        "issue", "lot", "number", "person", "program", "problem", "reason", "question",
        "result", "service", "story", "cause", "act", "cost", "term", "view", "member",
        "matter", "center", "mind", "money", "rate", "field", "care", "order", "process",
        "team", "detail", "body", "tax", "range", "experience", "role", "table", "sign",
        "figure", "size", "account", "sort", "step", "action", "age", "amount", "approach",
        "series", "value", "class", "list", "try", "quality", "piece", "page", "subject",
        "title", "date", "state", "school", "case", "half", "moment", "sense", "degree",
        "effect", "rate", "key", "yeah", "okay", "ok", "hi", "hello", "bye", "goodbye",
        "maybe", "no", "yes", "sure", "thanks", "thank", "welcome", "sorry", "please",
        "let", "shall", "might", "can", "could"
    ]
    
    // Tags we want to keep for title generation
    private static let relevantTags: Set<String> = ["NN", "NNS", "NNP", "NNPS", "JJ", "VB", "VBD", "VBG", "VBN", "VBP", "VBZ"]
    
    static let shared = TextRankTitleGenerator()
    
    private init() {}
    
    // MARK: - TextRank Algorithm
    
    /// Generate a title from the given text using TextRank algorithm
    /// - Parameters:
    ///   - text: The input text to generate a title from
    ///   - maxWords: Maximum number of words in the title
    /// - Returns: A generated title
    func generateTitle(from text: String, maxWords: Int = 6) -> String {
        // 1. Extract sentences and tokenize
        let sentences = extractSentences(from: text)
        
        // Early return for empty text
        if sentences.isEmpty {
            return "New Chat"
        }
        
        // 2. Extract keywords using TextRank
        let keywords = extractKeywords(from: sentences, maxKeywords: 10)
        
        // 3. Generate title from keywords
        return createTitle(from: keywords, maxWords: maxWords)
    }
    
    // MARK: - Text Processing
    
    /// Extract and tokenize sentences from text
    private func extractSentences(from text: String) -> [[String]] {
        var sentences: [[String]] = []
        
        let tokenizer = NLTokenizer(unit: .word)
        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        
        sentenceTokenizer.string = text
        sentenceTokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { sentenceRange, _ in
            let sentence = String(text[sentenceRange])
            
            tokenizer.string = sentence
            var tokens: [String] = []
            
            tokenizer.enumerateTokens(in: sentence.startIndex..<sentence.endIndex) { tokenRange, _ in
                let token = String(sentence[tokenRange]).lowercased()
                // Filter out common words and very short words
                if !TextRankTitleGenerator.commonWords.contains(token) && token.count > 2 {
                    tokens.append(token)
                }
                return true
            }
            
            sentences.append(tokens)
            return true
        }
        
        return sentences
    }
    
    /// Extract keywords using TextRank algorithm
    private func extractKeywords(from sentences: [[String]], maxKeywords: Int) -> [String] {
        // 1. Create the graph
        var graph: [String: [String: Double]] = [:]
        let windowSize = 4
        
        // Collect all unique tokens
        var allTokens = Set<String>()
        for sentence in sentences {
            for token in sentence {
                allTokens.insert(token)
            }
        }
        
        // Initialize graph with all tokens
        for token in allTokens {
            graph[token] = [:]
        }
        
        // 2. Build graph edges based on co-occurrence within a window
        for sentence in sentences {
            if sentence.count < 2 { continue }
            
            for i in 0..<sentence.count {
                let token = sentence[i]
                
                // Consider a window of tokens after the current one
                let windowEnd = min(i + windowSize, sentence.count)
                for j in (i + 1)..<windowEnd {
                    let coOccurringToken = sentence[j]
                    
                    // Avoid self-loops
                    if token == coOccurringToken { continue }
                    
                    // Add/update edge weight
                    if var edges = graph[token] {
                        edges[coOccurringToken] = (edges[coOccurringToken] ?? 0) + 1.0
                        graph[token] = edges
                    }
                    
                    // Add/update reverse edge (undirected graph)
                    if var edges = graph[coOccurringToken] {
                        edges[token] = (edges[token] ?? 0) + 1.0
                        graph[coOccurringToken] = edges
                    }
                }
            }
        }
        
        // 3. Apply PageRank algorithm
        let scores = pageRank(graph: graph, iterations: 30, dampingFactor: 0.85)
        
        // 4. Sort by score and take top keywords
        let sortedKeywords = scores.sorted { $0.value > $1.value }
        let topKeywords = sortedKeywords.prefix(maxKeywords).map { $0.key }
        
        return Array(topKeywords)
    }
    
    /// Implementation of PageRank algorithm
    private func pageRank(graph: [String: [String: Double]], iterations: Int = 30, dampingFactor: Double = 0.85) -> [String: Double] {
        let nodes = Array(graph.keys)
        var scores = Dictionary(uniqueKeysWithValues: nodes.map { ($0, 1.0 / Double(nodes.count)) })
        
        for _ in 0..<iterations {
            var newScores = Dictionary(uniqueKeysWithValues: nodes.map { ($0, 1.0 - dampingFactor) })
            
            for (node, edges) in graph {
                if edges.isEmpty { continue }
                
                // Calculate total weight of outgoing edges
                let totalWeight = edges.values.reduce(0, +)
                
                // Distribute score to neighbors
                let currentScore = scores[node] ?? 0
                for (neighbor, weight) in edges {
                    if totalWeight > 0 {
                        newScores[neighbor] = (newScores[neighbor] ?? 0) + dampingFactor * currentScore * (weight / totalWeight)
                    }
                }
            }
            
            scores = newScores
        }
        
        return scores
    }
    
    // MARK: - Title Creation
    
    /// Create a title from the extracted keywords
    private func createTitle(from keywords: [String], maxWords: Int) -> String {
        // Take top keywords within word limit
        let titleKeywords = Array(keywords.prefix(maxWords))
        
        // Ensure there's at least one keyword
        if titleKeywords.isEmpty {
            return "New Chat"
        }
        
        // Format the title
        let titleText = titleKeywords
            .map { capitalizeFirstLetter($0) }
            .joined(separator: " ")
        
        return titleText
    }
    
    /// Capitalize the first letter of a word
    private func capitalizeFirstLetter(_ word: String) -> String {
        guard !word.isEmpty else { return word }
        return word.prefix(1).uppercased() + word.dropFirst()
    }
} 
