import Foundation

/// What a `plume` command line asks for. Parsing lives here rather than in
/// the tool so PlumeTests can reach it.
nonisolated enum CLIInvocation: Equatable, Sendable {
    case help
    case version
    case notify(title: String, body: String)
    case notifyHelp
    case presence(json: Bool)
    case newTab(directory: String?, taskID: String?, select: Bool)
    case shellInit(aliases: Bool)
}

nonisolated struct CLIUsageError: Error, Equatable, Sendable {
    var message: String
    var usage: String
}

nonisolated enum CLIExitCode {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
}

nonisolated enum CLICommandLine {
    /// The legacy name, still linked, which skips straight to `notify`.
    static let notifyAlias = "plume-notify"

    static let usage = """
        usage: plume <command> [options]

        Commands:
          notify <title> [body]     Send a desktop notification for this tab
          presence [--json]         Print whether the Mac is awake, asleep or locked
          tab new [--cwd DIR] [--task ID] [--select]
                                    Open a terminal tab in this task, print its ID
          init zsh [--aliases]      Print zsh integration, for `eval "$(plume init zsh)"`
          help                      Show this help
          --version                 Print Plume's version
        """

    static let notifyUsage = """
        usage: plume notify <title> [body]
               plume notify --title <title> [--body <body>]
        """

    static let tabUsage = "usage: plume tab new [--cwd DIR] [--task ID] [--select]"
    static let initUsage = "usage: plume init zsh [--aliases]"

    /// `arguments` excludes argv[0]; `executableName` is its basename.
    static func parse(_ arguments: [String], executableName: String) throws -> CLIInvocation {
        if executableName == notifyAlias {
            return try parseNotify(arguments)
        }
        guard let command = arguments.first else { return .help }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "help", "-h", "--help":
            return .help
        case "--version", "version":
            return .version
        case "notify":
            return try parseNotify(rest)
        case "presence":
            return try parsePresence(rest)
        case "tab":
            return try parseTab(rest)
        case "init":
            return try parseInit(rest)
        default:
            throw CLIUsageError(message: "unknown command '\(command)'", usage: usage)
        }
    }

    static func parseNotify(_ arguments: [String]) throws -> CLIInvocation {
        var title: String?
        var body: String?
        var positional: [String] = []
        var index = 0
        var optionsEnded = false

        func value(after flag: String) throws -> String {
            guard index + 1 < arguments.count else {
                throw CLIUsageError(message: "\(flag) needs a value", usage: notifyUsage)
            }
            index += 1
            return arguments[index]
        }

        while index < arguments.count {
            let argument = arguments[index]
            if optionsEnded {
                positional.append(argument)
            } else {
                switch argument {
                case "--title": title = try value(after: argument)
                case "--body", "--message": body = try value(after: argument)
                case "-h", "--help": return .notifyHelp
                case "--": optionsEnded = true
                default: positional.append(argument)
                }
            }
            index += 1
        }

        guard positional.count <= 2 else {
            throw CLIUsageError(message: "too many arguments", usage: notifyUsage)
        }
        title = title ?? positional.first
        if positional.count == 2 { body = body ?? positional[1] }
        guard let title, !title.isEmpty else {
            throw CLIUsageError(message: "a title is required", usage: notifyUsage)
        }
        return .notify(title: title, body: body ?? "")
    }

    static func parsePresence(_ arguments: [String]) throws -> CLIInvocation {
        switch arguments {
        case []: return .presence(json: false)
        case ["--json"]: return .presence(json: true)
        default: throw CLIUsageError(message: "unexpected argument '\(arguments[0])'", usage: "usage: plume presence [--json]")
        }
    }

    static func parseTab(_ arguments: [String]) throws -> CLIInvocation {
        guard arguments.first == "new" else {
            throw CLIUsageError(message: "expected 'tab new'", usage: tabUsage)
        }
        var directory: String?
        var taskID: String?
        var select = false
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--cwd", "--task":
                guard index + 1 < arguments.count else {
                    throw CLIUsageError(message: "\(argument) needs a value", usage: tabUsage)
                }
                index += 1
                if argument == "--cwd" { directory = arguments[index] } else { taskID = arguments[index] }
            case "--select":
                select = true
            default:
                throw CLIUsageError(message: "unexpected argument '\(argument)'", usage: tabUsage)
            }
            index += 1
        }
        return .newTab(directory: directory, taskID: taskID, select: select)
    }

    static func parseInit(_ arguments: [String]) throws -> CLIInvocation {
        guard arguments.first == "zsh" else {
            throw CLIUsageError(message: "only zsh is supported", usage: initUsage)
        }
        switch Array(arguments.dropFirst()) {
        case []: return .shellInit(aliases: false)
        case ["--aliases"]: return .shellInit(aliases: true)
        case let extra: throw CLIUsageError(message: "unexpected argument '\(extra[0])'", usage: initUsage)
        }
    }

    // MARK: Notify fallback

    /// OSC 777 delimits its fields with semicolons and ends at BEL, so either
    /// inside the text would truncate the payload or split it into the wrong
    /// fields. Other control characters become spaces for the same reason.
    static func sanitize(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3B: scalars.append(",")
            case 0x07: continue
            case 0x00...0x1F: scalars.append(" ")
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    static func osc777(title: String, body: String) -> String {
        "\u{1B}]777;notify;\(sanitize(title));\(sanitize(body))\u{07}"
    }
}
