import Testing
@testable import TinfoilChat

struct PremiumProjectPolicyTests {
    @Test
    func projectAccessRequiresAuthenticationAndPremium() {
        #expect(PremiumProjectPolicy.hasAccess(isAuthenticated: true, hasActiveSubscription: true))
        #expect(!PremiumProjectPolicy.hasAccess(isAuthenticated: true, hasActiveSubscription: false))
        #expect(!PremiumProjectPolicy.hasAccess(isAuthenticated: false, hasActiveSubscription: true))
    }

    @Test
    func projectNavigationRequiresPremium() {
        #expect(PremiumProjectPolicy.allowsNavigation(to: .projects, hasPremiumAccess: true))
        #expect(!PremiumProjectPolicy.allowsNavigation(to: .projects, hasPremiumAccess: false))
        #expect(PremiumProjectPolicy.allowsNavigation(to: .chat, hasPremiumAccess: false))
        #expect(PremiumProjectPolicy.allowsNavigation(to: .favorites, hasPremiumAccess: false))
    }

    @Test
    func projectChatsRequirePremium() {
        #expect(PremiumProjectPolicy.includesChat(projectId: "project-1", hasPremiumAccess: true))
        #expect(!PremiumProjectPolicy.includesChat(projectId: "project-1", hasPremiumAccess: false))
        #expect(PremiumProjectPolicy.includesChat(projectId: nil, hasPremiumAccess: false))
    }

    @Test
    func accessRevocationLeavesOnlyProjectChats() {
        #expect(PremiumProjectPolicy.shouldLeaveChatOnAccessRevocation(projectId: "project-1"))
        #expect(!PremiumProjectPolicy.shouldLeaveChatOnAccessRevocation(projectId: nil))
    }

    @Test(arguments: [
        PremiumProjectPolicy.Mutation.createProject,
        .editProject,
        .manageDocuments,
        .moveChat,
        .deleteProject,
        .createProjectChat,
        .sendProjectChat,
    ])
    func projectMutationsRequirePremium(_ mutation: PremiumProjectPolicy.Mutation) {
        #expect(PremiumProjectPolicy.allowsMutation(mutation, hasPremiumAccess: true))
        #expect(!PremiumProjectPolicy.allowsMutation(mutation, hasPremiumAccess: false))
    }

    @Test
    func bulkProjectDeletionRemainsAvailableWithoutPremium() {
        #expect(PremiumProjectPolicy.allowsMutation(.deleteAllProjects, hasPremiumAccess: true))
        #expect(PremiumProjectPolicy.allowsMutation(.deleteAllProjects, hasPremiumAccess: false))
    }
}
