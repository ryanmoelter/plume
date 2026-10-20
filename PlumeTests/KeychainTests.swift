import Testing
@testable import Plume

struct KeychainTests {
    @Test func readsBackWhatWasWritten() throws {
        let store = InMemorySecretStore()
        try store.write("secret", account: "org")
        #expect(store.read(account: "org") == "secret")
    }

    @Test func writeReplacesExistingSecret() throws {
        let store = InMemorySecretStore()
        try store.write("one", account: "org")
        try store.write("two", account: "org")
        #expect(store.read(account: "org") == "two")
    }

    @Test func unknownAccountReadsNil() {
        #expect(InMemorySecretStore().read(account: "missing") == nil)
    }

    @Test func deleteRemovesOnlyThatAccount() throws {
        let store = InMemorySecretStore()
        try store.write("a", account: "one")
        try store.write("b", account: "two")
        try store.delete(account: "one")
        try store.delete(account: "never-existed")
        #expect(store.read(account: "one") == nil)
        #expect(store.read(account: "two") == "b")
    }
}
