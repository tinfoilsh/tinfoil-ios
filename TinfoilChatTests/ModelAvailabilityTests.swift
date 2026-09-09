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

    @Test func offersOneAutoEntryAheadOfRealModelsWhenAnyChatModelExists() {
        let models = [
            config(id: "first"),
            config(id: "free", paid: false),
            config(id: "code", type: "code"),
            config(id: "title", type: "title"),
        ]
        let available = ModelAvailability.realModels(from: models)

        #expect(ModelAvailability.autoModel(from: available)?.id == AutoModel.id)
        #expect(ModelAvailability.selectableModels(from: available).map(\.id) == [
            AutoModel.id,
            "first",
            "code",
        ])
        #expect(ModelAvailability.autoModel(from: []) == nil)
        #expect(ModelAvailability.selectableModels(from: []).isEmpty)
    }

    @Test func autoEntryUnionsCapabilitiesAndUsesSmallestContextWindow() throws {
        let available = ModelAvailability.realModels(from: [
            config(id: "big", contextWindowTokens: 256_000),
            config(id: "small-vision", multimodal: true, contextWindowTokens: 32_000),
        ])

        let auto = try #require(ModelAvailability.autoModel(from: available))
        #expect(auto.isAuto)
        #expect(auto.isMultimodal)
        #expect(auto.contextWindowTokens == 32_000)
        #expect(auto.reasoningConfig == nil)
    }

    @Test func defaultsToAutoAndFallsBackToNothingWithoutChatModels() {
        let available = ModelAvailability.realModels(from: [config(id: "first"), config(id: "second")])

        #expect(ModelAvailability.defaultModel(from: available)?.id == AutoModel.id)
        #expect(ModelAvailability.defaultModel(from: []) == nil)
    }

    @Test func savedModelResolutionMapsLegacyAutoIdsOntoAuto() {
        let available = ModelAvailability.realModels(from: [config(id: "first")])

        for legacyId in AutoModel.legacyIds.union([AutoModel.id]) {
            #expect(ModelAvailability.resolveSavedModel(id: legacyId, from: available)?.id == AutoModel.id)
        }
        #expect(ModelAvailability.resolveSavedModel(id: "first", from: available)?.id == "first")
        #expect(ModelAvailability.resolveSavedModel(id: "removed", from: available)?.id == AutoModel.id)
        #expect(ModelAvailability.resolveSavedModel(id: nil, from: []) == nil)
    }

    @Test func intelligenceLevelsSpanTheRouterScaleInOrder() {
        let levels = AutoIntelligence.allCases.map(\.level)
        #expect(levels.first == 0)
        #expect(levels.last == 100)
        #expect(levels == levels.sorted())
        #expect(AutoIntelligence.allCases.map(\.displayName) == [
            "Auto · Instant", "Auto · Low", "Auto · Med", "Auto · High", "Auto · Extra", "Auto · Max",
        ])
        #expect(AutoIntelligence.at(index: -1) == .instant)
        #expect(AutoIntelligence.at(index: 99) == .max)
        #expect(AutoIntelligence.default == .high)
    }

    private static func config(
        id: String,
        type: String = "chat",
        chat: Bool? = true,
        paid: Bool = true,
        multimodal: Bool = false,
        contextWindowTokens: Int = 128_000
    ) -> AppModelConfig {
        AppModelConfig(
            modelName: id,
            image: "",
            name: id,
            nameShort: id,
            description: "",
            details: "",
            parameters: "",
            type: type,
            chat: chat,
            paid: paid,
            multimodal: multimodal,
            toolCalling: false,
            chatConfig: ChatModelConfig(
                contextWindowTokens: contextWindowTokens,
                attributes: nil,
                descriptionShort: nil,
                reasoningConfig: nil
            )
        )
    }
}
