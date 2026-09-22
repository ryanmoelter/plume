import Testing
@testable import Plume

/// The scan matches on Plume's own settings path, which is what separates its
/// agents from a `claude` the user runs themselves and from the Claude desktop
/// app's helper processes.
struct ClaudeProcessScannerTests {
    private let settings = "/Users/x/Library/Application Support/Plume/hooks/settings.json"

    @Test func findsAgentsCarryingPlumesSettingsPath() {
        let output = """
          53166 claude -p --output-format stream-json --settings \(settings)
          88219 claude -p --settings \(settings) --resume abc123
        """
        #expect(ClaudeProcessScanner.parse(psOutput: output, settingsPath: settings) == [53166, 88219])
    }

    @Test func ignoresAgentsFromAnotherInstallation() {
        let output = "  4242 claude -p --settings /Users/x/Library/Application Support/Plume.debug/hooks/settings.json"
        #expect(ClaudeProcessScanner.parse(psOutput: output, settingsPath: settings).isEmpty)
    }

    @Test func ignoresUnrelatedProcesses() {
        let output = """
          2475 /Applications/Claude.app/Contents/MacOS/Claude
          9001 claude -p --output-format stream-json
          9002 /bin/zsh -lic 'exec claude'
        """
        #expect(ClaudeProcessScanner.parse(psOutput: output, settingsPath: settings).isEmpty)
    }

    @Test func ignoresAHeaderOrMalformedLine() {
        let output = """
          PID COMMAND
          notapid claude --settings \(settings)
        """
        #expect(ClaudeProcessScanner.parse(psOutput: output, settingsPath: settings).isEmpty)
    }
}
