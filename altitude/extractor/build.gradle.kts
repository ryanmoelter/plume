plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
    application
}

kotlin {
    jvmToolchain(21)
}

application {
    mainClass.set("com.ryanmoelter.altitude.extractor.MainKt")
}

dependencies {
    implementation(project(":manifest"))
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
}
