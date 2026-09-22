import Foundation
import Testing
@testable import TinfoilChat

private func chatModel(_ name: String) -> ModelType {
    ModelType(
        from: AppModelConfig(
            modelName: name,
            image: "",
            name: name,
            nameShort: name,
            description: "",
            details: "",
            parameters: "",
            type: "chat",
            chat: true,
            paid: true,
            multimodal: false,
            toolCalling: nil,
            chatConfig: nil
        )
    )
}

private func preset(
    id: String,
    model: String? = nil,
    webSearchEnabled: Bool? = nil
) -> SyncedPromptPreset {
    SyncedPromptPreset(
        id: id,
        name: "Proofreader",
        description: "",
        systemPrompt: "<system>\nFix typos.\n</system>",
        createdAt: 1,
        updatedAt: 1,
        model: model,
        webSearchEnabled: webSearchEnabled
    )
}

struct PromptPresetSettingsTests {
    private let catalog = [chatModel("gpt-oss-120b")]

    // MARK: Wire format

    @Test
    func encodingOmitsUnsetSettings() throws {
        let data = try JSONEncoder().encode(preset(id: "user:plain"))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["model"] == nil)
        #expect(json["webSearchEnabled"] == nil)
    }

    @Test
    func encodingWritesSetSettings() throws {
        let data = try JSONEncoder().encode(
            preset(id: "user:p", model: "gpt-oss-120b", webSearchEnabled: false)
        )
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(json["model"] as? String == "gpt-oss-120b")
        #expect(json["webSearchEnabled"] as? Bool == false)
    }

    @Test
    func decodesPresetsWrittenBeforeSettingsExisted() throws {
        let legacy = """
        {"id":"user:old","name":"Old","description":"","systemPrompt":"<system>\\nHi\\n</system>","createdAt":1,"updatedAt":2}
        """
        let decoded = try JSONDecoder().decode(SyncedPromptPreset.self, from: Data(legacy.utf8))

        #expect(decoded.model == nil)
        #expect(decoded.webSearchEnabled == nil)
        #expect(PromptPreset(from: decoded).model == nil)
    }

    @Test
    func libraryPresetCarriesSettingsFromStorage() {
        let stored = preset(id: "user:p", model: AutoModel.id, webSearchEnabled: true)
        let library = PromptPreset(from: stored)

        #expect(library.model == AutoModel.id)
        #expect(library.webSearchEnabled == true)
    }

    // MARK: Model resolution

    @Test
    func resolvesAutoAndCatalogModelsOnly() {
        #expect(PromptPresetSettings.resolveModel(nil, available: catalog) == nil)
        #expect(PromptPresetSettings.resolveModel("gpt-oss-120b", available: catalog)?.id == "gpt-oss-120b")
        #expect(PromptPresetSettings.resolveModel(AutoModel.id, available: catalog)?.isAuto == true)
        #expect(PromptPresetSettings.resolveModel("auto-smart", available: catalog)?.isAuto == true)
        #expect(PromptPresetSettings.resolveModel("retired-model", available: catalog) == nil)
    }

    @Test
    func autoIsUnavailableWithoutRealModels() {
        #expect(PromptPresetSettings.resolveModel(AutoModel.id, available: []) == nil)
    }

    // MARK: Pruning

    @Test
    func pruneClearsRetiredModelsAndBumpsUpdatedAt() {
        let now = Date(timeIntervalSince1970: 100)
        let result = PromptPresetSettings.pruningUnavailableModels(
            in: [
                preset(id: "user:stale", model: "retired-model", webSearchEnabled: false),
                preset(id: "user:fresh", model: "gpt-oss-120b"),
            ],
            available: catalog,
            now: now
        )

        #expect(result.changedIds == ["user:stale"])
        let stale = result.presets[0]
        #expect(stale.model == nil)
        #expect(stale.webSearchEnabled == false)
        #expect(stale.updatedAt == 100_000)
        let fresh = result.presets[1]
        #expect(fresh.model == "gpt-oss-120b")
        #expect(fresh.updatedAt == 1)
    }

    @Test
    func pruneLeavesAutoAndUnsetModelsAlone() {
        let presets = [
            preset(id: "user:auto", model: AutoModel.id),
            preset(id: "user:none", webSearchEnabled: true),
        ]
        let result = PromptPresetSettings.pruningUnavailableModels(in: presets, available: catalog)

        #expect(result.changedIds.isEmpty)
        #expect(result.presets == presets)
    }
}
