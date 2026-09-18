import Testing
import Foundation
@testable import Plume

struct CmuxParsingTests {
    private static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Cmux/\(name).json")
        return try Data(contentsOf: url)
    }

    private static func decodeSession(_ name: String) throws -> CmuxSessionFile {
        try JSONDecoder().decode(CmuxSessionFile.self, from: try fixture(name))
    }

    private static func decodeHooks(_ name: String) throws -> CmuxHookSessions {
        try JSONDecoder().decode(CmuxHookSessions.self, from: try fixture(name))
    }

    @Test func theBasicSessionFileDecodes() throws {
        let file = try Self.decodeSession("session-basic")
        #expect(file.windows.count == 1)
        let window = try #require(file.windows.first)
        let tabManager = try #require(window.tabManager)
        #expect(tabManager.workspaces.count == 3)
        #expect(tabManager.workspaceGroups?.first?.name == "Widgets")
    }

    @Test func unknownKeysAndPanelTypesSurviveDecoding() throws {
        let file = try Self.decodeSession("session-basic")
        let workspace3 = try #require(file.windows.first?.tabManager?.workspaces.first { $0.stableId == "33333333-3333-3333-3333-333333333333" })
        let browserPanel = try #require(workspace3.panels.first { $0.type == "browser" })
        #expect(browserPanel.type == "browser")
    }

    @Test func aMalformedWindowIsSkippedWithoutLosingTheGoodOne() throws {
        let file = try Self.decodeSession("session-malformed")
        #expect(file.windows.count == 1)
        let workspaces = try #require(file.windows.first?.tabManager?.workspaces)
        #expect(workspaces.contains { $0.stableId == "11111111-1111-1111-1111-111111111111" })
    }

    @Test func aWorkspaceWithoutAStableIDStillDecodes() throws {
        let file = try Self.decodeSession("session-malformed")
        let workspaces = try #require(file.windows.first?.tabManager?.workspaces)
        let noStableID = try #require(workspaces.first { $0.workspaceId == "workspace-no-stable-id" })
        #expect(noStableID.stableId == nil)
    }

    @Test func groupMembershipIsADirectLookup() throws {
        let file = try Self.decodeSession("session-basic")
        let workspaces = try #require(file.windows.first?.tabManager?.workspaces)
        let group = try #require(file.windows.first?.tabManager?.workspaceGroups?.first)

        let workspace1 = try #require(workspaces.first { $0.stableId == "11111111-1111-1111-1111-111111111111" })
        let workspace2 = try #require(workspaces.first { $0.stableId == "22222222-2222-2222-2222-222222222222" })
        let workspace3 = try #require(workspaces.first { $0.stableId == "33333333-3333-3333-3333-333333333333" })

        #expect(workspace1.groupId == group.id)
        #expect(workspace2.groupId == nil)
        #expect(workspace3.groupId == group.id)
    }

    @Test func hookSessionsDecodeTheirSurfaceMap() throws {
        let hooks = try Self.decodeHooks("hook-sessions")
        let surfaceMap = try #require(hooks.activeSessionsBySurface)
        #expect(surfaceMap["aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"] != nil)
        #expect(surfaceMap["cccccccc-cccc-cccc-cccc-cccccccccccc"] != nil)
        #expect(hooks.sessions?.count == 3)
    }

    @Test func anEmptyHookSessionsFileDecodes() throws {
        let hooks = try Self.decodeHooks("hook-sessions-empty")
        #expect(hooks.activeSessionsBySurface == nil)
        #expect(hooks.activeSessionsByWorkspace == nil)
        #expect(hooks.sessions == nil)
    }

    @Test func aWorkspaceKeyedHookFileDecodes() throws {
        let hooks = try Self.decodeHooks("hook-sessions-workspace-keyed")
        let workspaceMap = try #require(hooks.activeSessionsByWorkspace)
        #expect(workspaceMap["workspace-1111-1111-1111-111111111111"]?.sessionId == "55555555-5555-5555-5555-aaaaaaaaaaaa")
        #expect(hooks.sessions?.count == 3)
    }
}
