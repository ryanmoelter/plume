import Foundation
import FoundationModels
import Observation

protocol TaskTitleModel {
    var isAvailable: Bool { get }
    func summarize(chatTitles: [String]) async throws -> String
}

/// Apple's on-device model: free, private, and with no process to spawn.
struct OnDeviceTaskTitleModel: TaskTitleModel {
    private static let instructions = """
        You name tasks in a coding app. A task holds several chats with an AI coding agent. \
        Given the chats' titles, reply with one short title of two to six words, in sentence case, \
        that describes the work they share. Reply with the title only, with no quotes and no final period.
        """

    var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    func summarize(chatTitles: [String]) async throws -> String {
        let session = LanguageModelSession(instructions: Self.instructions)
        let prompt = "Chat titles:\n" + chatTitles.map { "- \($0)" }.joined(separator: "\n")
        let options = GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 32)
        return try await session.respond(to: prompt, options: options).content
    }
}

/// A title for a task with several top-level chats, summarized from their
/// titles, since no single chat's title describes the task.
///
/// Summaries are cached per task and keyed on the chat titles they were made
/// from. A task whose titles change keeps its old summary until the new one
/// arrives. One summary generates at a time, so a launch with many tasks
/// doesn't fan out into concurrent model sessions.
@MainActor
@Observable
final class TaskTitleSummarizer {
    static let shared = TaskTitleSummarizer(
        model: OnDeviceTaskTitleModel(),
        isEnabled: { AppSettings.shared.summarizesTaskTitles }
    )

    private struct Summary {
        let chatTitles: [String]
        /// Nil when the model failed or answered with nothing usable for these
        /// titles, so the task falls back instead of retrying on every render.
        let title: String?
        let madeAt: Date
    }

    /// How long a failed summary stands before the same titles are tried
    /// again, since a failure can be transient (model assets still loading).
    static let retryInterval: TimeInterval = 5 * 60

    private var summaries: [UUID: Summary] = [:]

    @ObservationIgnored private let model: TaskTitleModel
    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var pending: [UUID: [String]] = [:]
    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var inFlight: (taskID: UUID, chatTitles: [String])?
    @ObservationIgnored private var worker: Task<Void, Never>?

    init(model: TaskTitleModel, isEnabled: @escaping () -> Bool, now: @escaping () -> Date = Date.init) {
        self.model = model
        self.isEnabled = isEnabled
        self.now = now
    }

    var isModelAvailable: Bool { model.isAvailable }

    /// The summary for these chat titles, or nil while there is none yet, or
    /// when summarizing is off, the model is unavailable, or fewer than two
    /// chats have titles. Safe to call from a view body: it only schedules
    /// work, and the result lands later.
    func summary(forTask id: UUID, chatTitles: [String]) -> String? {
        guard chatTitles.count > 1, isEnabled(), model.isAvailable else { return nil }
        let key = chatTitles.sorted()
        let current = summaries[id]
        if current?.chatTitles != key || current.map(isRetryable) == true { request(id, chatTitles: key) }
        return current?.title
    }

    private func isRetryable(_ summary: Summary) -> Bool {
        summary.title == nil && now().timeIntervalSince(summary.madeAt) >= Self.retryInterval
    }

    /// Waits for every queued summary to finish.
    func idle() async {
        while let worker { await worker.value }
    }

    private func request(_ id: UUID, chatTitles: [String]) {
        guard pending[id] != chatTitles else { return }
        if let inFlight, inFlight.taskID == id, inFlight.chatTitles == chatTitles { return }
        pending[id] = chatTitles
        if !queue.contains(id) { queue.append(id) }
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
            self?.worker = nil
        }
    }

    private func drain() async {
        while !queue.isEmpty {
            let id = queue.removeFirst()
            guard let chatTitles = pending.removeValue(forKey: id) else { continue }
            inFlight = (id, chatTitles)
            let reply = try? await model.summarize(chatTitles: chatTitles)
            inFlight = nil
            summaries[id] = Summary(chatTitles: chatTitles, title: reply.flatMap(Self.cleaned), madeAt: now())
        }
    }

    /// The model's reply reduced to a sidebar-sized title: its first line,
    /// without a "Title:" lead-in, wrapping quotes or a final period.
    static func cleaned(_ reply: String) -> String? {
        guard var line = reply.split(whereSeparator: \.isNewline)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .first(where: { !$0.isEmpty })
        else { return nil }
        if line.lowercased().hasPrefix("title:") {
            line = line.dropFirst("title:".count).trimmingCharacters(in: .whitespaces)
        }
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”*`."))
            .trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return line.count > 60 ? String(line.prefix(60)).trimmingCharacters(in: .whitespaces) + "…" : line
    }
}
