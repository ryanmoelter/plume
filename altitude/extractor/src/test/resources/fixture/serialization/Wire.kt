package fixture.serialization

import kotlinx.serialization.Serializable

@Serializable
class Wire(val volts: Int)

fun describe(): String = Wire.serializer().descriptor.serialName
