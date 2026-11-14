plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

kotlin {
    jvmToolchain(21)
}

// The model files of `altitude/models` ship inside the jar, with an index a class loader can read.
val bundleModels = tasks.register<Sync>("bundleModels") {
    val models = rootProject.layout.projectDirectory.dir("models")
    val out = layout.buildDirectory.dir("generated/models")
    from(models) { include("*.yaml") }
    into(out.map { it.dir("altitude-models") })
    val names = models.asFileTree.matching { include("*.yaml") }.elements.map { files ->
        files.map { it.asFile.name }.sorted()
    }
    inputs.property("names", names)
    doLast {
        out.get().file("altitude-models/index.txt").asFile.writeText(names.get().joinToString("") { it + "\n" })
    }
}

sourceSets.main {
    resources.srcDir(bundleModels.map { layout.buildDirectory.dir("generated/models").get() })
}

dependencies {
    api(libs.kotlinx.serialization.json)
    implementation(libs.snakeyaml)
    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
}
