import Testing
@testable import TinfoilChat

struct ModelAvailabilityTests {
    @Test func filtersSelectableModelsUsingBackendAvailabilityMatrix() {
        let models = [
            config(id: "paid-chat", type: "chat", chat: true, paid: true),
            config(id: "paid-code", type: "code", chat: true, paid: true),
            config(id: "free-chat", type: "chat", chat: true, paid: false),
            config(id: "free-code", type: "code", chat: true, paid: false),
            config(id: "chat-disabled", type: "chat", chat: false, paid: true),
            config(id: "chat-unspecified", type: "chat", chat: nil, paid: true),
            config(id: "title", type: "title", chat: true, paid: true),
            config(id: "audio", type: "audio", chat: true, paid: true),
            config(id: "document", type: "document", chat: true, paid: true),
        ]

        let available = ModelAvailability.realModels(from: models)

        #expect(available.map(\.id) == ["paid-chat", "paid-code"])
    }

    @Test func derivesAutoTiersOnlyFromEligibleModelsInServerOrder() {
        let models = [
            config(id: "smart-first", attributes: [AutoModel.smartTier]),
            config(id: "free-fast", paid: false, attributes: [AutoModel.fastTier]),
            config(id: "fast-first", type: "code", attributes: [AutoModel.fastTier]),
            config(id: "smart-second", attributes: [AutoModel.smartTier]),
        ]
        let available = ModelAvailability.realModels(from: models)

        #expect(ModelAvailability.autoModels(from: available).map(\.id) == [
            AutoModel.smartId,
            AutoModel.fastId,
        ])
        #expect(ModelAvailability.tierModels(AutoModel.smartTier, from: available).map(\.id) == [
            "smart-first",
            "smart-second",
        ])
        #expect(ModelAvailability.tierModels(AutoModel.fastTier, from: available).map(\.id) == [
            "fast-first",
        ])
        #expect(ModelAvailability.selectableModels(from: available).map(\.id) == [
            AutoModel.smartId,
            AutoModel.fastId,
            "smart-first",
            "fast-first",
            "smart-second",
        ])
    }

    @Test func omitsAutoTierWithoutEligibleMembers() {
        let available = ModelAvailability.realModels(from: [
            config(id: "smart", attributes: [AutoModel.smartTier]),
            config(id: "free-fast", paid: false, attributes: [AutoModel.fastTier]),
        ])

        #expect(ModelAvailability.autoModels(from: available).map(\.id) == [AutoModel.smartId])
    }

    @Test func defaultsToAutoFastAndFallsBackToFirstRealModel() {
        let withFast = ModelAvailability.realModels(from: [
            config(id: "first"),
            config(id: "fast", attributes: [AutoModel.fastTier]),
        ])
        let withoutFast = ModelAvailability.realModels(from: [
            config(id: "first"),
            config(id: "second"),
        ])

        #expect(ModelAvailability.defaultModel(from: withFast)?.id == AutoModel.fastId)
        #expect(ModelAvailability.defaultModel(from: withoutFast)?.id == "first")
    }

    @Test func missingSavedModelUsesNormalDefaultResolver() {
        let available = ModelAvailability.realModels(from: [
            config(id: "first"),
            config(id: "fast", attributes: [AutoModel.fastTier]),
        ])

        #expect(ModelAvailability.resolveSavedModel(id: "removed", from: available)?.id == AutoModel.fastId)
        #expect(ModelAvailability.resolveSavedModel(id: "first", from: available)?.id == "first")
        #expect(ModelAvailability.resolveSavedModel(id: nil, from: []) == nil)
    }

    private static func config(
        id: String,
        type: String = "chat",
        chat: Bool? = true,
        paid: Bool = true,
        attributes: [String] = []
    ) -> AppModelConfig {
        AppModelConfig(
            modelName: id,
            image: "",
            name: id,
            nameShort: id,
            description: "",
            details: "",
            parameters: "",
            contextWindow: "128k tokens",
            contextWindowTokens: 128_000,
            type: type,
            chat: chat,
            paid: paid,
            multimodal: false,
            toolCalling: false,
            attributes: attributes,
            reasoningConfig: nil
        )
    }
}
