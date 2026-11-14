package com.ryanmoelter.altitude.manifest

import kotlinx.serialization.Serializable

@Serializable
data class Manifest(val version: Int = 1)
