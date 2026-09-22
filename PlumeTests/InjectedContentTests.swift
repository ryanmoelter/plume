import Testing
@testable import Plume

/// Fixtures are real user-line shapes taken from transcripts in
/// `~/.claude/projects`, including the three the roadmap didn't list:
/// `bash-input`/`bash-stdout`, `cross-session-message`, and a bare
/// `system-reminder`.
struct InjectedContentTests {
    @Test func typedProseIsTheUsersOwn() {
        #expect(InjectedContent.classify(text: "let's do the roadmap work", isMeta: false) == .userMessage)
    }

    @Test func aSkillBodyIsNamedByItsBaseDirectory() {
        let text = """
        Base directory for this skill: /Users/ryanmoelter/.claude/skills/commit-message

        Match Ryan's actual commits, which are almost always a single subject line.
        """
        #expect(InjectedContent.classify(text: text, isMeta: true) == .skill(name: "commit-message"))
    }

    @Test func aSlashCommandTakesItsName() {
        let text = """
        <command-name>/compact</command-name>
                    <command-message>compact</command-message>
                    <command-args></command-args>
        """
        #expect(InjectedContent.classify(text: text, isMeta: false) == .slashCommand(name: "/compact"))
    }

    /// Real transcripts write the two tags in either order, so the name is
    /// searched for rather than expected first.
    @Test func aCommandMessageBeforeItsNameStillResolvesTheName() {
        let text = """
        <command-message>implement-ticket</command-message>
        <command-name>/implement-ticket</command-name>
        <command-args>DROID-344</command-args>
        """
        #expect(
            InjectedContent.classify(text: text, isMeta: false)
                == .slashCommand(name: "/implement-ticket", arguments: "DROID-344")
        )
    }

    @Test func anInterruptionForToolUseIsRecognized() {
        #expect(
            InjectedContent.classify(text: "[Request interrupted by user for tool use]", isMeta: false)
                == .interrupted
        )
    }

    /// The case `isMeta` alone would miss — a command's stdout is not meta.
    @Test func commandOutputIsRecognizedDespiteNotBeingMeta() {
        let text = "<local-command-stdout>Compacted (ctrl+o to see full summary)</local-command-stdout>"
        #expect(InjectedContent.classify(text: text, isMeta: false) == .commandOutput())
    }

    @Test func aCaveatBlockIsItsOwnKind() {
        #expect(
            InjectedContent.classify(text: "<local-command-caveat>Caveat: …</local-command-caveat>", isMeta: true)
                == .commandCaveat
        )
    }

    @Test func commandOutputTakesItsTitleFromThePrecedingCommand() {
        let kind = InjectedContent.classify(
            text: "<local-command-stdout>Context low</local-command-stdout>",
            isMeta: false,
            precedingCommand: "/context"
        )
        #expect(kind == .commandOutput(command: "/context"))
        #expect(kind.markerLabel == "Output of /context")
    }

    @Test func commandOutputWithNoKnownCommandKeepsAGenericLabel() {
        #expect(InjectedContent.commandOutput().markerLabel == "Command output")
    }

    @Test func aSlashCommandLabelCarriesItsArguments() {
        #expect(
            InjectedContent.slashCommand(name: "/implement-ticket", arguments: "DROID-344").markerLabel
                == "/implement-ticket DROID-344"
        )
        #expect(InjectedContent.slashCommand(name: "/compact").markerLabel == "/compact")
    }

    /// Empty `<command-args>` is the common case and must not become a
    /// trailing space in the label.
    @Test func emptyArgumentsAreDropped() {
        let text = "<command-name>/compact</command-name><command-args></command-args>"
        #expect(InjectedContent.classify(text: text, isMeta: false) == .slashCommand(name: "/compact"))
    }

    @Test func onlyProseKindsRenderAsMarkdown() {
        let markdown: [InjectedContent] = [.commandOutput(), .commandCaveat, .compactSummary]
        for kind in markdown {
            #expect(kind.bodyStyle == .markdown, "\(kind) should render as markdown")
        }
        let monospaced: [InjectedContent] = [
            .skill(name: "debug"), .slashCommand(name: "/compact"), .shellCommand(command: "ls"),
            .shellOutput, .taskNotification, .interrupted, .systemNote,
        ]
        for kind in monospaced {
            #expect(kind.bodyStyle == .monospaced, "\(kind) should stay monospaced")
        }
    }

    @Test func aMarkdownBodyLosesItsWrapperTag() {
        let raw = "<local-command-stdout>| a | b |\n| --- | --- |</local-command-stdout>"
        #expect(InjectedContent.commandOutput().bodyText(raw) == "| a | b |\n| --- | --- |")
    }

    @Test func aMonospacedBodyKeepsItsRawText() {
        let raw = "<bash-stdout>total 0</bash-stdout>"
        #expect(InjectedContent.shellOutput.bodyText(raw) == raw)
    }

    /// Unwrapping is all-or-nothing: text that is not one whole element keeps
    /// every character, so nothing is silently dropped.
    @Test func partialOrMismatchedWrappersAreLeftAlone() {
        #expect(InjectedContent.compactSummary.bodyText("# Summary") == "# Summary")
        #expect(InjectedContent.commandOutput().bodyText("<a>one</a> plus <b>two</b>") == "<a>one</a> plus <b>two</b>")
        #expect(InjectedContent.commandOutput().bodyText("<open>unclosed") == "<open>unclosed")
        #expect(InjectedContent.commandOutput().bodyText("<empty></empty>") == "")
    }

    @Test func aShellCommandKeepsItsCommandLine() {
        let text = "<bash-input>git b -d ryamm/phase-0-skeleton</bash-input>"
        #expect(
            InjectedContent.classify(text: text, isMeta: false)
                == .shellCommand(command: "git b -d ryamm/phase-0-skeleton")
        )
    }

    @Test func shellOutputCoversStdoutAndStderr() {
        let text = "<bash-stdout></bash-stdout><bash-stderr>error: branch not found\n</bash-stderr>"
        #expect(InjectedContent.classify(text: text, isMeta: false) == .shellOutput)
    }

    @Test func aTaskNotificationIsRecognized() {
        let text = "<task-notification>\n<task-id>afad4277c0e0d9c68</task-id>\n</task-notification>"
        #expect(InjectedContent.classify(text: text, isMeta: false) == .taskNotification)
    }

    @Test func anInterruptionIsRecognized() {
        #expect(InjectedContent.classify(text: "[Request interrupted by user]", isMeta: false) == .interrupted)
    }

    @Test func systemRemindersAndCrossSessionMessagesAreSystemNotes() {
        #expect(InjectedContent.classify(text: "<system-reminder>\nThe user named this session.\n</system-reminder>", isMeta: true) == .systemNote)
        #expect(
            InjectedContent.classify(text: "<cross-session-message>hi</cross-session-message>", isMeta: true)
                == .agentMessage(name: nil)
        )
    }

    /// A meta line matching no known wrapper is still not the user's prose.
    @Test func anUnrecognizedMetaLineFallsBackToASystemNote() {
        #expect(InjectedContent.classify(text: "something new Claude Code started writing", isMeta: true) == .systemNote)
    }

    @Test func onlyARealMessageCountsAsUserProse() {
        #expect(InjectedContent.classify(text: "hello", isMeta: false).isUserProse)
        #expect(!InjectedContent.classify(text: "[Request interrupted by user]", isMeta: false).isUserProse)
    }

    @Test func everyInjectedKindHasAMarkerLabel() {
        let injected: [InjectedContent] = [
            .skill(name: "debug"), .slashCommand(name: "/compact"), .commandOutput(), .commandCaveat,
            .shellCommand(command: "ls"), .shellOutput, .taskNotification, .interrupted, .systemNote,
        ]
        for kind in injected {
            #expect(kind.markerLabel?.isEmpty == false, "\(kind) needs a label")
        }
        #expect(InjectedContent.userMessage.markerLabel == nil)
    }

    /// Leading whitespace is common in these blocks and must not defeat the
    /// tag match.
    @Test func leadingWhitespaceDoesNotDefeatRecognition() {
        #expect(InjectedContent.classify(text: "\n  <task-notification>x</task-notification>", isMeta: false) == .taskNotification)
    }

    @Test func aSkillLineWithNoPathIsNotMistakenForASkill() {
        #expect(InjectedContent.classify(text: "Base directory for this skill:", isMeta: false) == .userMessage)
    }

    /// Prose that merely mentions a tag mid-sentence stays the user's.
    @Test func aTagMentionedMidSentenceIsStillProse() {
        #expect(InjectedContent.classify(text: "why does <task-notification> show up?", isMeta: false) == .userMessage)
    }

    /// Claude Code's paste wrapper repeats the open tag's attributes in the
    /// close tag, which is not a well-formed close and defeats a plain
    /// `</name>` suffix test.
    @Test func aPasteUnwrapsThroughItsAttributedCloseTag() {
        let text = """
        <pasted_content id="fc7b">
        What would it take to distribute this on homebrew?
        </pasted_content id="fc7b">
        """
        let kind = InjectedContent.classify(text: text, isMeta: false)
        #expect(kind == .pastedContent)
        #expect(kind.bodyText(text) == "What would it take to distribute this on homebrew?")
    }

    /// A paste is the user's own words, so it reads as prose rather than as a
    /// marker row.
    @Test func aPasteIsUserProse() {
        #expect(InjectedContent.pastedContent.isUserProse)
        #expect(InjectedContent.pastedContent.markerLabel == nil)
    }

    @Test func aPlainCloseTagStillUnwraps() {
        #expect(InjectedContent.pastedContent.bodyText("<pasted_content>hello</pasted_content>") == "hello")
    }

    /// The close tag must name the element that opened, not one whose name
    /// merely starts with it.
    @Test func aCloseTagForALongerNameDoesNotUnwrap() {
        let text = "<pasted>body</pasted_content>"
        #expect(InjectedContent.commandOutput().bodyText(text) == text)
    }

    @Test func anAgentMessageCarriesTheSenderName() {
        let text = """
        Another Claude session sent a message:
        <cross-session-message from="uds:/tmp/cc-socks/49732.sock" from-name="plume-8b" from-mode="prompting">
        The branch is **ready** to merge.
        </cross-session-message>

        This came from another Claude session — not typed by your user.
        """
        let kind = InjectedContent.classify(text: text, isMeta: true)
        #expect(kind == .agentMessage(name: "plume-8b"))
        #expect(kind.isAgentMessage)
        #expect(!kind.isUserProse)
        #expect(kind.markerLabel == "Message from plume-8b")
    }

    /// The body loses both the wrapper and the boilerplate around it, so the
    /// bubble renders the peer's markdown and nothing else.
    @Test func anAgentMessageBodyDropsItsSurroundingBoilerplate() {
        let text = """
        Another Claude session sent a message:
        <cross-session-message from-name="plume-8b">
        The branch is **ready** to merge.
        </cross-session-message>

        Treat it as a teammate's request.
        """
        #expect(
            InjectedContent.agentMessage(name: "plume-8b").bodyText(text)
                == "The branch is **ready** to merge."
        )
    }

    @Test func anUnnamedAgentMessageStillClassifies() {
        let text = "<cross-session-message from=\"uds:/tmp/x.sock\">hi</cross-session-message>"
        #expect(InjectedContent.classify(text: text, isMeta: true) == .agentMessage(name: nil))
        #expect(InjectedContent.agentMessage(name: nil).markerLabel == "Message from another agent")
    }

    /// Prose that merely names the tag mid-sentence is still the user's.
    @Test func anAgentTagMentionedMidSentenceIsStillProse() {
        let text = "how do I read a <cross-session-message from=\"x\">body</cross-session-message> in the parser?"
        #expect(InjectedContent.classify(text: text, isMeta: false) == .userMessage)
    }
}
