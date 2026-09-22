import os
import OSLog

enum Log {
    private static let subsystem = "com.ryanmoelter.Plume"

    static let ghostty = Logger(subsystem: subsystem, category: "ghostty")
    static let app = Logger(subsystem: subsystem, category: "app")
    static let agent = Logger(subsystem: subsystem, category: "agent")
    static let chatList = Logger(subsystem: subsystem, category: "chat-list")
    static let control = Logger(subsystem: subsystem, category: "control")
}
