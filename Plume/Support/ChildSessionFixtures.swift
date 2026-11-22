#if DEBUG
import Foundation
import os // Logger string interpolation
import SwiftData

/// `PLUME_SEED_CHILD_SESSIONS`: one task per case of child sessions nested in
/// a sidebar row, each looking like real work. Folders live under
/// `/tmp/plume-fixtures/child-sessions` and never exist; their git, checkout,
/// pull request and Linear states are seeded into the stores the way
/// `SidebarFixtures` seeds its own, so nothing reads a repository or the
/// network. No tab has a session ID, so none launches `claude` before the
/// user sends it a message. Task titles stay empty, so each row's title
/// comes from its agents.
///
/// - `nested`: "Plan the refactor" on worktree `ryanm/plume-123-refactor`
///   with open PR #1231 and PLUME-123 In Progress. "Survey call sites" shares
///   its folder (wants permission). "Update the models" sits in worktree
///   `ryanm/refactor-models` with draft PR #1232 (awaiting reply, unread),
///   and "Migrate the store tests" shares that folder.
/// - `two-top`: "Fix the login bug" on worktree `ryanm/plume-140-login-crash`
///   with open PR #1401, and "Write release notes" in the `plume-site`
///   checkout on `main` with no PR; each has a child in its folder. The task
///   pins PR #1388 and links PLUME-141, beside PLUME-140 from the branch.
/// - `cap`: "Audit the docs" on worktree `ryanm/plume-150-docs-audit`, not
///   yet pushed, with PLUME-150 In Progress, and six children in its folder.
/// - `detached`: "Start the review" on worktree `ryanm/plume-160-review` with
///   PR #1601 and PLUME-160 In Review; "Review the diff", its child in another
///   task, shares the folder, with a child of its own.
/// - `lone`: "Plan the migration" on worktree `ryanm/plume-170-migration` with
///   PR #1701, and in a second task its child "Write the migration", that
///   task's only agent, in the same folder.
@MainActor
enum ChildSessionFixtures {
    private static let root = "/tmp/plume-fixtures/child-sessions"
    private static let project = "\(root)/Plume"

    private struct Folder {
        let path: String
        let projectRoot: String
        let branch: String
        let pullRequest: PullRequestFetchState
    }

    static func seed(_ spec: String, in context: ModelContext) -> [WorkTask] {
        var cases = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if cases.contains("all") { cases = ["nested", "two-top", "cap", "detached", "lone"] }
        let existing = (try? context.fetch(FetchDescriptor<WorkTask>())) ?? []
        var tasks: [WorkTask] = []
        seedLinearIssues()

        func place(_ tab: TaskTab, _ title: String, in folder: Folder) {
            tab.transport = .headless
            tab.workspace = .directory(folder.path, branchName: folder.branch)
            TabDirectoryStore.shared.setDirectory(folder.path, forTab: tab)
            tab.title = title
            TitleStore.shared.setTitle(title, forTab: tab.id, source: .reply)
        }
        func newTask(_ agent: String, in folder: Folder) -> (WorkTask, TaskTab) {
            let task = TaskStore.createTask(in: context, siblings: existing + tasks)
            tasks.append(task)
            let tab = task.orderedTabs[0]
            place(tab, agent, in: folder)
            return (task, tab)
        }
        func child(_ title: String, of parent: TaskTab, in task: WorkTask, folder: Folder) -> TaskTab {
            let tab = TaskStore.addChildTab(to: task, parent: parent, in: context)
            place(tab, title, in: folder)
            return tab
        }
        func set(_ status: TaskStatus, on tab: TaskTab, in task: WorkTask) {
            tab.lastStatus = status
            StatusEngine.shared.setStatus(status, taskID: task.id, tabID: tab.id, notifiable: false)
        }

        for seedCase in cases {
            switch seedCase {
            case "nested":
                let parentFolder = worktree("plume-123-refactor", branch: "ryanm/plume-123-refactor",
                                            pullRequest: pullRequest(1231, "Split the session store"))
                let modelsFolder = worktree("refactor-models", branch: "ryanm/refactor-models",
                                            pullRequest: pullRequest(1232, "Move models into the store", isDraft: true))
                let (task, parent) = newTask("Plan the refactor", in: parentFolder)
                set(.working, on: parent, in: task)
                let survey = child("Survey call sites", of: parent, in: task, folder: parentFolder)
                let models = child("Update the models", of: parent, in: task, folder: modelsFolder)
                _ = child("Migrate the store tests", of: models, in: task, folder: modelsFolder)
                set(.permissionNeeded, on: survey, in: task)
                set(.awaitingReply, on: models, in: task)
                UnreadStore.shared.markUnread([models.id])
            case "two-top":
                let loginFolder = worktree("plume-140-login-crash", branch: "ryanm/plume-140-login-crash",
                                           pullRequest: pullRequest(1401, "Fix the crash on login"))
                let siteFolder = seedFolder(Folder(
                    path: "\(root)/plume-site", projectRoot: "\(root)/plume-site", branch: "main", pullRequest: .noPR
                ))
                let (task, login) = newTask("Fix the login bug", in: loginFolder)
                let notes = TaskStore.addTab(to: task, kind: .agent, selecting: false, in: context)
                place(notes, "Write release notes", in: siteFolder)
                let repro = child("Reproduce the crash", of: login, in: task, folder: loginFolder)
                _ = child("Collect merged PRs", of: notes, in: task, folder: siteFolder)
                set(.questionAsked, on: repro, in: task)
                pin(1388, "Bump Sparkle to 2.7", to: task)
                _ = TaskStore.linkLinearIssue("PLUME-141", to: task)
            case "cap":
                let folder = worktree("plume-150-docs-audit", branch: "ryanm/plume-150-docs-audit", pullRequest: .localOnly)
                let (task, parent) = newTask("Audit the docs", in: folder)
                let pages = ["cli", "releasing", "testing", "chat-list", "child-sessions", "control-server"]
                let children = pages.map { child("Check docs/\($0).md", of: parent, in: task, folder: folder) }
                set(.planApproval, on: children[1], in: task)
            case "detached":
                let folder = worktree("plume-160-review", branch: "ryanm/plume-160-review",
                                      pullRequest: pullRequest(1601, "Stack the review fixes"))
                let (_, parent) = newTask("Start the review", in: folder)
                let (task, detached) = newTask("Review the diff", in: folder)
                detached.parentTabID = parent.id
                ChildSessionIndex.shared.record(child: detached, parent: parent)
                _ = child("Check the tests", of: detached, in: task, folder: folder)
            case "lone":
                let folder = worktree("plume-170-migration", branch: "ryanm/plume-170-migration",
                                      pullRequest: pullRequest(1701, "Migrate the task store"))
                let (_, parent) = newTask("Plan the migration", in: folder)
                let (_, lone) = newTask("Write the migration", in: folder)
                lone.parentTabID = parent.id
                ChildSessionIndex.shared.record(child: lone, parent: parent)
            default:
                Log.app.error("Unknown PLUME_SEED_CHILD_SESSIONS case \(seedCase, privacy: .public)")
            }
        }
        Log.app.info("Smoke harness seeded \(tasks.count) child-session task(s)")
        return tasks
    }

    private static func worktree(_ name: String, branch: String, pullRequest: PullRequestFetchState) -> Folder {
        seedFolder(Folder(path: "\(root)/worktrees/\(name)", projectRoot: project, branch: branch, pullRequest: pullRequest))
    }

    /// Seeded before any row watches the folder, which keeps the stubbed
    /// branch from being raced by a real lookup.
    private static func seedFolder(_ folder: Folder) -> Folder {
        GitStateStore.shared.seedFixture(directory: folder.path, state: GitState(
            branch: folder.branch,
            upstream: folder.pullRequest == .localOnly ? nil : "origin/\(folder.branch)",
            ahead: 0,
            behind: 0,
            isDirty: false
        ))
        CheckoutFactsStore.shared.seedFixture(
            directory: folder.path,
            facts: CheckoutFacts(projectRoot: folder.projectRoot, checkoutRoot: folder.path)
        )
        PullRequestStore.shared.seedFixture(directory: folder.path, state: folder.pullRequest)
        return folder
    }

    private static func pullRequest(_ number: Int, _ title: String, isDraft: Bool = false) -> PullRequestFetchState {
        .pullRequest(PullRequest(
            number: number,
            state: .open,
            isDraft: isDraft,
            url: "https://github.com/ryanmoelter/plume/pull/\(number)",
            title: title,
            hasReviewers: true,
            checkContexts: [
                CheckContext(name: "build", conclusion: "SUCCESS"),
                CheckContext(name: "test", conclusion: "SUCCESS"),
            ]
        ))
    }

    private static func pin(_ number: Int, _ title: String, to task: WorkTask) {
        let reference = PullRequestReference(owner: "ryanmoelter", repo: "plume", number: number)
        TaskStore.pinPullRequest(reference, to: task)
        var entry = MentionCandidate.PullRequestEntry(
            number: number, title: title, url: reference.url, state: .open, isDraft: false, updatedAt: nil
        )
        entry.checkContexts = [CheckContext(name: "build", conclusion: "SUCCESS")]
        LinkedPullRequestStore.shared.seedFixture(reference, detail: .pullRequest(entry), forTask: task.id)
    }

    private static func seedLinearIssues() {
        LinearStore.shared.seedFixtureTeamKeys(["PLUME"])
        func issue(_ identifier: String, _ title: String, _ name: String, _ type: LinearStateType, _ color: String) {
            LinearStore.shared.seedFixture(identifier: identifier, state: .issue(LinearIssue(
                identifier: identifier,
                title: title,
                url: "https://linear.app/fixture/issue/\(identifier)",
                stateName: name,
                stateType: type,
                stateColor: color,
                assigneeName: nil,
                teamKey: "PLUME"
            )))
        }
        issue("PLUME-123", "Split the session store", "In Progress", .started, "#f2c94c")
        issue("PLUME-140", "Fix the crash on login", "In Progress", .started, "#f2c94c")
        issue("PLUME-141", "Write the 0.21 release notes", "Todo", .unstarted, "#e2e2e2")
        issue("PLUME-150", "Audit the docs", "In Progress", .started, "#f2c94c")
        issue("PLUME-160", "Review the stack fixes", "In Review", .started, "#0f783c")
    }
}
#endif
