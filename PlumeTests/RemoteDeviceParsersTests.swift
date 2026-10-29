import Foundation
import Testing

@testable import Plume

/// Parses output captured from `android` 1.1 on a real reservation. Times use the tool's narrow
/// no-break space (U+202F) between the minutes and AM/PM.
struct RemoteDeviceParsersTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private static func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private static let now = date(28, 22, 36)

    @Test func readsTheSignedInAccount() {
        #expect(RemoteDeviceParsers.signedInAccount("Logged in as Ryan Moelter <ryan@example.com>\n") == "Ryan Moelter <ryan@example.com>")
        #expect(RemoteDeviceParsers.signedInAccount("You are not logged in.\n") == nil)
    }

    @Test func readsProjectsPastTheSpinner() {
        let output = "Fetching project list...\r                        \rProjects ready for streaming:\n  notability-2475c\n  other-project\n"
        #expect(RemoteDeviceParsers.projects(output) == ["notability-2475c", "other-project"])
        #expect(RemoteDeviceParsers.projects("Fetching project list...\rError: Failed to obtain auth token\n").isEmpty)
    }

    @Test func readsTheModelTreeWithOneModelPerAPILevel() {
        let output = """
           MODEL                             CODENAME/API

        ├─ FUJITSU [1]
        │  └─ F-01L                          F01L/27
        │
        ├─ Google [37]
        │  ├─ Pixel 6                        oriole/31
        │  ├─ Pixel 9                        tokay/36                         tokay/35          tokay/34
        │  ├─ Pixel Fold (Camera-enabled)    felix_camera/33
        │  └─ Pixel Watch                    r11/30
        │
        └─ Xiaomi [1]
           └─ Xiaomi 14                      houji/35

        """
        let models = RemoteDeviceParsers.models(output)

        #expect(models.map(\.id) == [
            "F01L/27", "oriole/31", "tokay/36", "tokay/35", "tokay/34", "felix_camera/33", "r11/30", "houji/35",
        ])
        #expect(models[0] == RemoteDeviceModel(manufacturer: "FUJITSU", name: "F-01L", codename: "F01L", api: 27))
        #expect(models[2].name == "Pixel 9")
        #expect(models[5].name == "Pixel Fold (Camera-enabled)")
        #expect(models.last == RemoteDeviceModel(manufacturer: "Xiaomi", name: "Xiaomi 14", codename: "houji", api: 35))
    }

    @Test func readsReservationRows() {
        let output = """
        Reservation    State     Expires   Manufacturer  Model         Codename   API Level
        3f3jpxdv5lw6y  ACTIVE    10:52\u{202F}PM  Google        Pixel 6       oriole     31
        sg3vz3fvbj3ta  FINISHED  5:49\u{202F}PM   Google        Pixel Tablet  tangorpro  36

        """
        let rows = RemoteDeviceParsers.reservations(output, now: Self.now, calendar: Self.calendar)

        #expect(rows.count == 2)
        #expect(rows[0] == RemoteReservationRow(
            id: "3f3jpxdv5lw6y", state: "ACTIVE", expiresAt: Self.date(28, 22, 52),
            manufacturer: "Google", model: "Pixel 6", codename: "oriole", api: 31
        ))
        #expect(rows[0].isActive)
        #expect(rows[1].model == "Pixel Tablet")
        #expect(rows[1].expiresAt == Self.date(28, 17, 49))
        #expect(!rows[1].isActive)
    }

    @Test func readsNoRowsFromAnEmptyListOrAnError() {
        #expect(RemoteDeviceParsers.reservations("There are no active reservations.\n").isEmpty)
        #expect(RemoteDeviceParsers.reservations("Error: Failed to obtain auth token: HTTP connect timed out\n").isEmpty)
    }

    @Test func readsTheCreatedReservation() throws {
        let output = """
        New reservation created with id 3f3jpxdv5lw6y. Reservation ends at 10:51\u{202F}PM
        Waiting for reservation to activate...
        Reservation is ACTIVE

        """
        let created = try #require(RemoteDeviceParsers.createdReservation(output, now: Self.now, calendar: Self.calendar))
        #expect(created.id == "3f3jpxdv5lw6y")
        #expect(created.endsAt == Self.date(28, 22, 51))
        #expect(RemoteDeviceParsers.createdReservation("Waiting for reservation to activate...") == nil)
    }

    @Test func readsConnectOutcomes() {
        let connected = AndroidCLIResult(status: 0, stdout: """
        Starting connection in background...
        Logs will be written to /Users/me/.android/cli/remote-devices/daemon-connect.log
        Device connected on port 59095
        Connection process started in background.

        """, stderr: "")
        #expect(RemoteDeviceParsers.connectOutcome(connected) == .connected(port: 59095))

        let stale = AndroidCLIResult(status: 1, stdout: "", stderr: "Reservation 3f3jpxdv5lw6y is already connected on port 59050.\n")
        #expect(RemoteDeviceParsers.connectOutcome(stale) == .alreadyConnected(port: 59050))

        let failed = AndroidCLIResult(status: 1, stdout: "Starting connection in background...\nFailed to start connection process.\n", stderr: "")
        #expect(RemoteDeviceParsers.connectOutcome(failed) == .failed)
    }

    @Test func readsTheExtendedExpiry() {
        let output = "Reservation extended. New expire time: 10:57\u{202F}PM\n"
        #expect(RemoteDeviceParsers.extendedExpiry(output, now: Self.now, calendar: Self.calendar) == Self.date(28, 22, 57))
    }

    @Test func recognizesTheToleratedFailures() {
        #expect(RemoteDeviceParsers.saysAlreadyEnded("Reservation 3f3jpxdv5lw6y has already ended."))
        #expect(RemoteDeviceParsers.saysNotConnected("No active connection found for reservation 3f3jpxdv5lw6y in project p"))
        #expect(!RemoteDeviceParsers.saysAlreadyEnded("Error: Failed to obtain auth token"))
    }

    @Test func placesAClockTimeOnTheNearestDay() {
        let lateEvening = Self.date(28, 23, 55)
        #expect(RemoteDeviceParsers.clockTime("12:10\u{202F}AM", now: lateEvening, calendar: Self.calendar) == Self.date(29, 0, 10))

        let pastMidnight = Self.date(29, 0, 5)
        #expect(RemoteDeviceParsers.clockTime("11:50 PM", now: pastMidnight, calendar: Self.calendar) == Self.date(28, 23, 50))

        #expect(RemoteDeviceParsers.clockTime("22:51", now: Self.now, calendar: Self.calendar) == Self.date(28, 22, 51))
        #expect(RemoteDeviceParsers.clockTime("soon", now: Self.now, calendar: Self.calendar) == nil)
    }
}
