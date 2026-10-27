import Testing
@testable import TinfoilChat

@MainActor
struct ChatSearchControllerTests {
    @Test
    func searchResultFilterHidesProjectChatsWithoutPremium() {
        let root = makeChat(id: "root", title: "Root")
        var project = makeChat(id: "project", title: "Project")
        project.projectId = "project-1"
        var temporary = makeChat(id: "temp", title: "Temp")
        temporary.isTemporary = true
        let blank = makeChat(id: "blank", title: "New Chat")

        let summaries = [root, project, temporary, blank]
            .map { ChatListSummary(from: $0) }
        let premiumVisible = summaries
            .filter { isSearchResultSidebarChat($0, hasPremiumAccess: true) }
            .map(\.id)
        let freeVisible = summaries
            .filter { isSearchResultSidebarChat($0, hasPremiumAccess: false) }
            .map(\.id)
        #expect(premiumVisible == ["root", "project", "blank"])
        #expect(freeVisible == ["root", "blank"])

        // The root chat list itself still excludes project chats.
        #expect(summaries.filter(isRootSidebarChat).map(\.id) == ["root", "blank"])
        #expect(summaries.first(where: { $0.id == "blank" })?.isBlankChat == true)
    }

    @Test
    func sidebarSearchSelectionPrefersRemoteResultsThenLoadedChats() {
        let loaded = makeChat(id: "loaded", title: "Loaded")
        let remote = makeChat(id: "remote", title: "Remote")
        let staleLoadedCopy = makeChat(id: "remote", title: "Stale")

        #expect(
            resolveSidebarSearchChat(
                id: "remote",
                remoteResults: [remote],
                loadedChats: [loaded, staleLoadedCopy]
            )?.title == "Remote"
        )
        #expect(
            resolveSidebarSearchChat(
                id: "loaded",
                remoteResults: [],
                loadedChats: [loaded]
            )?.title == "Loaded"
        )
        #expect(
            resolveSidebarSearchChat(
                id: "missing",
                remoteResults: [remote],
                loadedChats: [loaded]
            ) == nil
        )
    }

    @Test
    func sidebarSearchIsOnlyEnabledForCloudChats() {
        #expect(
            isSidebarChatSearchEnabled(
                isAuthenticated: true,
                isCloudSyncEnabled: true,
                activeTab: .cloud
            )
        )
        #expect(
            !isSidebarChatSearchEnabled(
                isAuthenticated: true,
                isCloudSyncEnabled: true,
                activeTab: .local
            )
        )
    }

    private func makeChat(id: String, title: String) -> Chat {
        var chat = Chat(id: id, title: title)
        if title != "New Chat" { chat.messageCount = 1 }
        return chat
    }
}
