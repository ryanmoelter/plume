import AppKit
import Foundation
import Testing
@testable import Plume

@MainActor
struct ComposerSendabilityTests {
    private static let style = ComposerTextStyle(bodySize: 14)

    private func visibleText(ofMarkdown markdown: String) -> String {
        ComposerDocument.attributedString(markdown: markdown, style: Self.style).string
    }

    @Test func emptyHeadingIsNotSendable() {
        #expect(!ComposerSendability.hasText(visibleText(ofMarkdown: "# ")))
    }

    @Test func emptyListItemIsNotSendable() {
        let storage = NSMutableAttributedString(string: "\n", attributes: Self.style.attributes(for: .bullet(depth: 0)))
        #expect(!ComposerDocument.markdown(from: storage).isEmpty)
        #expect(!ComposerSendability.hasText(storage.string))
    }

    @Test func whitespaceOnlyIsNotSendable() {
        #expect(!ComposerSendability.hasText("  \n\t "))
        #expect(!ComposerSendability.canSend(hasText: ComposerSendability.hasText("  \n"), hasAttachments: false))
    }

    @Test func textIsSendable() {
        #expect(ComposerSendability.hasText(visibleText(ofMarkdown: "# Title")))
    }

    @Test func imageOnlyIsSendable() {
        #expect(ComposerSendability.canSend(hasText: ComposerSendability.hasText(""), hasAttachments: true))
    }

    /// In command mode the visible text is the command, with the `!` already
    /// taken out, so sendability agrees with whether there is a command to run.
    @Test(arguments: ["ls -la", "  git status\n"])
    func commandModeTextIsSendable(command: String) {
        #expect(ComposerSendability.hasText(command))
        #expect(CommandModeMatcher.parse(command) != nil)
    }

    @Test(arguments: ["", "   ", "\n"])
    func emptyCommandModeIsNotSendable(command: String) {
        #expect(!ComposerSendability.hasText(command))
        #expect(CommandModeMatcher.parse(command) == nil)
    }

    /// The plan feedback field reads as filled exactly when its reject button
    /// offers to send the feedback.
    @Test(arguments: ["", "  \n ", "tighten step 2"])
    func feedbackFieldFillsWhenItsFeedbackWouldSend(feedback: String) {
        let isFilled = ComposerSendability.hasText(feedback)
        #expect(isFilled == (PlanRejectionLabel.label(forReason: feedback) == PlanRejectionLabel.giveFeedback))
        #expect(isFilled == (feedback == "tighten step 2"))
    }
}
