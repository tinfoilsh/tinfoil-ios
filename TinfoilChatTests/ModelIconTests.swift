import Testing
@testable import TinfoilChat

struct ModelIconTests {
    @Test
    func thinkingMachinesIconMapsToItsAsset() {
        let model = ModelType(Components.Schemas.SessionModel(
            id: "inkling-2-small",
            label: "Inkling 2 Small",
            shortLabel: "Inkling 2 Small",
            icon: "thinkingmachines.png",
            description: "",
            badges: [],
            deprecated: false
        ))

        #expect(model.iconName == "thinkingmachines-icon")
    }
}
