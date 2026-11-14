package fixture.core

actual fun platformName(): String = "jvm"

actual class Clock actual constructor() {
  actual fun now(): Long = System.currentTimeMillis()
}
