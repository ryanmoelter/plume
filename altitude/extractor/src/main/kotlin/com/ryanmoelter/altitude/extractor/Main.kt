package com.ryanmoelter.altitude.extractor

import com.ryanmoelter.altitude.manifest.Manifest

fun main(args: Array<String>) {
    println("Usage: altitude-extractor <source-root> (manifest v${Manifest().version})")
}
