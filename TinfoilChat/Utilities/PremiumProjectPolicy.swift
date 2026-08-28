enum PremiumProjectPolicy {
    enum Mutation: Equatable, Sendable {
        case createProject
        case editProject
        case manageDocuments
        case moveChat
        case deleteProject
        case createProjectChat
        case sendProjectChat
        case deleteAllProjects
    }

    static func hasAccess(isAuthenticated: Bool, hasActiveSubscription: Bool) -> Bool {
        isAuthenticated && hasActiveSubscription
    }

    static func allowsNavigation(
        to destination: ChatNavigationDestination,
        hasPremiumAccess: Bool
    ) -> Bool {
        destination != .projects || hasPremiumAccess
    }

    static func includesChat(projectId: String?, hasPremiumAccess: Bool) -> Bool {
        projectId == nil || hasPremiumAccess
    }

    static func shouldLeaveChatOnAccessRevocation(projectId: String?) -> Bool {
        projectId != nil
    }

    static func allowsMutation(_ mutation: Mutation, hasPremiumAccess: Bool) -> Bool {
        mutation == .deleteAllProjects || hasPremiumAccess
    }
}
