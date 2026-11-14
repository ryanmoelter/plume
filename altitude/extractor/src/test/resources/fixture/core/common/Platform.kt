package fixture.core

expect fun platformName(): String

expect class Clock() {
  fun now(): Long
}

fun describe(): String = platformName() + Clock().now()
