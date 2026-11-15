import org.jetbrains.kotlin.gradle.plugin.KotlinPlatformType

plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
    application
}

kotlin {
    jvmToolchain(21)
    compilerOptions {
        optIn.add("org.jetbrains.kotlin.analysis.api.KaExperimentalApi")
        // Registering compiler plugins has no public entry point outside a single-module session.
        optIn.add("org.jetbrains.kotlin.analysis.api.KaPlatformInterface")
        optIn.add("org.jetbrains.kotlin.analysis.api.KaImplementationDetail")
    }
}

application {
    mainClass.set("com.ryanmoelter.altitude.extractor.MainKt")
    applicationDefaultJvmArgs = listOf("-Xmx4g", "-Djava.awt.headless=true")
}

val fixtureClasspath = configurations.dependencyScope("fixtureClasspath")
val fixtureClasspathFiles = configurations.resolvable("fixtureClasspathFiles") {
    extendsFrom(fixtureClasspath.get())
    attributes {
        attribute(Usage.USAGE_ATTRIBUTE, objects.named(Usage.JAVA_API))
        attribute(KotlinPlatformType.attribute, KotlinPlatformType.jvm)
    }
}

// kotlin-compiler ships these classes with members stripped that the decompiler classes in
// kotlin-compiler-common-for-ide call, so the full copies go ahead of it on every classpath.
val intellijCore = configurations.dependencyScope("intellijCore")
val intellijCoreFiles = configurations.resolvable("intellijCoreFiles") {
    extendsFrom(intellijCore.get())
}

sourceSets {
    main { runtimeClasspath = intellijCoreFiles.get() + runtimeClasspath }
    test { runtimeClasspath = intellijCoreFiles.get() + runtimeClasspath }
}

configurations.runtimeClasspath {
    // The Analysis API needs IntelliJ's fork of coroutines, which holds the same classes.
    exclude(group = "org.jetbrains.kotlinx", module = "kotlinx-coroutines-core-jvm")
}

dependencies {
    implementation(project(":manifest"))
    implementation(project(":solver"))
    intellijCore(libs.intellij.platform.core) { isTransitive = false }
    implementation(libs.kotlin.compiler)
    // The *-for-ide poms name dependencies that are not published (KT-61639).
    // Since 2.4.20 this one holds the decompiler classes the standalone session needs.
    implementation(libs.kotlin.compiler.common) { isTransitive = false }
    implementation(libs.kotlin.analysis.api) { isTransitive = false }
    implementation(libs.kotlin.analysis.api.k2) { isTransitive = false }
    implementation(libs.kotlin.analysis.api.impl.base) { isTransitive = false }
    implementation(libs.kotlin.analysis.api.platform.`interface`) { isTransitive = false }
    implementation(libs.kotlin.analysis.api.standalone) { isTransitive = false }
    implementation(libs.kotlin.low.level.api.fir) { isTransitive = false }
    implementation(libs.kotlin.symbol.light.classes) { isTransitive = false }
    // Stand in for the -embeddable plugin jars a target build names; see bundledPlugin.
    runtimeOnly(libs.kotlin.compose.compiler.plugin) { isTransitive = false }
    runtimeOnly(libs.kotlin.serialization.compiler.plugin) { isTransitive = false }
    runtimeOnly(libs.caffeine)
    runtimeOnly(libs.kotlinx.serialization.core)
    runtimeOnly(libs.kotlinx.coroutines.core.intellij)

    fixtureClasspath(kotlin("stdlib"))
    fixtureClasspath(libs.kotlinx.coroutines.core)
    fixtureClasspath(libs.kotlinx.serialization.core)
    fixtureClasspath(libs.compose.runtime.desktop)
    fixtureClasspath(libs.metro.runtime)
    fixtureClasspath(libs.kotlin.inject.runtime)

    testImplementation(kotlin("test"))
}

tasks.test {
    useJUnitPlatform()
    maxHeapSize = "2g"
    val fixtureJars = fixtureClasspathFiles.get()
    inputs.files(fixtureJars).withNormalizer(ClasspathNormalizer::class)
    jvmArgumentProviders.add(
        CommandLineArgumentProvider { listOf("-Daltitude.fixtureClasspath=${fixtureJars.asPath}") },
    )
}

tasks.startScripts {
    classpath = intellijCoreFiles.get() + classpath!!
}

distributions.main {
    contents { from(intellijCoreFiles) { into("lib") } }
}

tasks.named<JavaExec>("run") {
    workingDir = rootProject.projectDir
}
