package com.ryanmoelter.altitude.extractor

import com.intellij.openapi.Disposable
import com.intellij.openapi.util.Disposer
import java.io.File
import java.nio.file.Path
import kotlin.io.path.exists
import org.jetbrains.kotlin.analysis.api.platform.projectStructure.KotlinCompilerPluginsProvider
import org.jetbrains.kotlin.analysis.api.projectStructure.KaLibraryModule
import org.jetbrains.kotlin.analysis.api.projectStructure.KaSourceModule
import org.jetbrains.kotlin.analysis.api.standalone.StandaloneAnalysisAPISession
import org.jetbrains.kotlin.analysis.api.standalone.base.declarations.KotlinStandaloneFirCompilerPluginsProvider
import org.jetbrains.kotlin.analysis.api.standalone.buildStandaloneAnalysisAPISession
import org.jetbrains.kotlin.analysis.project.structure.builder.KaModuleContainerBuilder
import org.jetbrains.kotlin.analysis.project.structure.builder.buildKtLibraryModule
import org.jetbrains.kotlin.analysis.project.structure.builder.buildKtSdkModule
import org.jetbrains.kotlin.analysis.project.structure.builder.buildKtSourceModule
import org.jetbrains.kotlin.cli.common.ExitCode
import org.jetbrains.kotlin.cli.common.arguments.K2JVMCompilerArguments
import org.jetbrains.kotlin.cli.common.arguments.parseCommandLineArguments
import org.jetbrains.kotlin.cli.common.setupLanguageVersionSettings
import org.jetbrains.kotlin.cli.create
import org.jetbrains.kotlin.cli.jvm.plugins.PluginCliParser
import org.jetbrains.kotlin.config.CompilerConfiguration
import org.jetbrains.kotlin.config.JvmTarget
import org.jetbrains.kotlin.config.LanguageVersionSettings
import org.jetbrains.kotlin.config.languageVersionSettings
import org.jetbrains.kotlin.platform.TargetPlatform
import org.jetbrains.kotlin.platform.jvm.JvmPlatforms
import org.jetbrains.kotlin.psi.KtFile

class LoadedModule(
  val input: ModuleInput,
  /** One per fragment, or a single module when the input has none. */
  val modules: List<KaSourceModule>,
  /** Sorted by [LoadedFile.source]'s relative path. */
  val files: List<LoadedFile>,
)

class LoadedFile(val source: SourceInput, val psi: KtFile)

/** A standalone Analysis API session holding every module of an [AnalysisInput]. */
class AltitudeSession
private constructor(private val disposable: Disposable, val modules: List<LoadedModule>) :
  AutoCloseable {

  override fun close() = Disposer.dispose(disposable)

  companion object {
    fun open(input: AnalysisInput): AltitudeSession {
      val disposable = Disposer.newDisposable("altitude")
      try {
        val ordered = dependenciesFirst(input.modules)
        val built = LinkedHashMap<String, List<KaSourceModule>>()
        val session =
          buildStandaloneAnalysisAPISession(disposable) {
            pluginConfiguration(ordered, disposable)?.let { configuration ->
              registerProjectService(
                KotlinCompilerPluginsProvider::class.java,
                KotlinStandaloneFirCompilerPluginsProvider(configuration),
              )
            }
            buildKtModuleProvider {
              platform = JvmPlatforms.defaultJvmPlatform
              val libraries = LibraryModules(this)
              for (module in ordered) {
                built[module.name] = sourceModules(module, libraries, built).map(::addModule)
              }
            }
          }
        return AltitudeSession(disposable, ordered.map { load(it, built.getValue(it.name), session) })
      } catch (e: Throwable) {
        Disposer.dispose(disposable)
        throw e
      }
    }

    private fun KaModuleContainerBuilder.sourceModules(
      input: ModuleInput,
      libraries: LibraryModules,
      built: Map<String, List<KaSourceModule>>,
    ): List<KaSourceModule> {
      val targetPlatform = input.targetPlatform()
      val settings = input.languageVersionSettings()
      val fragments = input.fragments.ifEmpty { listOf(FragmentInput(name = "")) }
      val byFragment = LinkedHashMap<String, KaSourceModule>()
      for (fragment in fragments) {
        val isLast = fragment == fragments.last()
        byFragment[fragment.name] = buildKtSourceModule {
          moduleName = listOf(input.name, fragment.name).filter { it.isNotEmpty() }.joinToString("/")
          platform = targetPlatform
          languageVersionSettings = settings
          addSourceRoots(
            input.sources
              .filter {
                input.fragments.isEmpty() ||
                  it.fragment == fragment.name ||
                  (it.fragment == null && isLast)
              }
              .map { it.path }
          )
          addRegularDependency(libraries.sdk(input, targetPlatform))
          for (name in fragment.dependsOn) {
            addDependsOnDependency(
              byFragment[name] ?: error("${input.name}: $name must come before ${fragment.name}")
            )
          }
          for (dependency in input.moduleDependencies) {
            built.getValue(dependency).forEach(::addRegularDependency)
          }
          libraries.classpath(input, targetPlatform)?.let(::addRegularDependency)
        }
      }
      return byFragment.values.toList()
    }

    private fun load(
      input: ModuleInput,
      modules: List<KaSourceModule>,
      session: StandaloneAnalysisAPISession,
    ): LoadedModule {
      val byPath = input.sources.associateBy { it.path.toAbsolutePath().normalize().toString() }
      val files =
        modules
          .flatMap { session.modulesWithFiles[it].orEmpty() }
          .filterIsInstance<KtFile>()
          .map { psi ->
            val source =
              byPath[Path.of(psi.virtualFile.path).toAbsolutePath().normalize().toString()]
                ?: error("${psi.virtualFile.path} is not a source of ${input.name}")
            LoadedFile(source, psi)
          }
      val expected = input.sources.filter { it.path.toString().endsWith(".kt") }
      val missing =
        expected.map { it.relativePath }.toSet() - files.map { it.source.relativePath }.toSet()
      check(missing.isEmpty() && files.size == expected.size) {
        "${input.name}: the input names ${expected.size} Kotlin files but the session loaded " +
          "${files.size}; missing: ${missing.sorted().take(10)}"
      }
      return LoadedModule(input, modules, files.sortedBy { it.source.relativePath })
    }

    private fun dependenciesFirst(modules: List<ModuleInput>): List<ModuleInput> {
      val byName = modules.associateBy { it.name }
      val ordered = LinkedHashMap<String, ModuleInput>()
      val visiting = HashSet<String>()
      fun visit(module: ModuleInput) {
        if (module.name in ordered) return
        check(visiting.add(module.name)) { "Module dependency cycle at ${module.name}" }
        module.moduleDependencies.sorted().forEach { name ->
          visit(byName[name] ?: error("${module.name} depends on unknown module $name"))
        }
        ordered[module.name] = module
      }
      modules.sortedBy { it.name }.forEach(::visit)
      return ordered.values.toList()
    }
  }
}

/** Builds each distinct SDK and classpath once, so modules that share one share its module. */
private class LibraryModules(private val container: KaModuleContainerBuilder) {
  private val sdks = HashMap<Any, KaLibraryModule>()
  private val classpaths = HashMap<Any, KaLibraryModule>()

  fun sdk(input: ModuleInput, targetPlatform: TargetPlatform): KaLibraryModule =
    when (input.platform) {
      Platform.JVM -> {
        val home = input.jdkHome ?: Path.of(System.getProperty("java.home"))
        sdks.getOrPut(targetPlatform to home) {
          container.buildKtSdkModule {
            platform = targetPlatform
            libraryName = "jdk"
            addBinaryRootsFromJdkHome(home, isJre = false)
          }
        }
      }
      Platform.ANDROID ->
        sdks.getOrPut(targetPlatform to input.bootClasspath) {
          container.buildKtLibraryModule {
            platform = targetPlatform
            libraryName = "android-sdk"
            addBinaryRoots(input.bootClasspath.filter { it.exists() })
          }
        }
    }

  fun classpath(input: ModuleInput, targetPlatform: TargetPlatform): KaLibraryModule? {
    val roots = input.classpath.filter { it.exists() }
    if (roots.isEmpty()) return null
    return classpaths.getOrPut(targetPlatform to roots) {
      container.buildKtLibraryModule {
        platform = targetPlatform
        libraryName = "classpath-of-${input.name}"
        addBinaryRoots(roots)
      }
    }
  }
}

private fun ModuleInput.targetPlatform(): TargetPlatform =
  JvmPlatforms.jvmPlatformByTargetVersion(
    jvmTarget?.let(JvmTarget::fromString) ?: JvmTarget.DEFAULT
  )

private fun ModuleInput.languageVersionSettings(): LanguageVersionSettings {
  val arguments = K2JVMCompilerArguments()
  parseCommandLineArguments(
    buildList {
      languageVersion?.let { add("-language-version=$it") }
      apiVersion?.let { add("-api-version=$it") }
      if (fragments.isNotEmpty()) add("-Xmulti-platform")
      addAll(compilerArgs)
    },
    arguments,
  )
  return CompilerConfiguration.create()
    .apply { setupLanguageVersionSettings(arguments) }
    .languageVersionSettings
}

/**
 * The session takes one set of compiler plugins for every module, so this is the union of what the
 * modules name. Null when none names any.
 */
private fun pluginConfiguration(
  modules: List<ModuleInput>,
  disposable: Disposable,
): CompilerConfiguration? {
  val classpath =
    modules
      .flatMap { it.compilerPluginClasspath }
      .filter { it.exists() }
      .map { bundledPlugin(it) ?: it }
      .distinct()
  if (classpath.isEmpty()) return null
  val options = modules.flatMap { it.compilerPluginOptions }.distinct()
  return CompilerConfiguration.create().apply {
    val exit =
      PluginCliParser.loadPluginsSafe(
        classpath.map { it.toString() },
        options,
        emptyList(),
        this,
        disposable,
      )
    check(exit == ExitCode.OK) { "Compiler plugins failed to load: $exit" }
  }
}

private val EMBEDDABLE_PLUGIN = Regex("""(kotlin-.+-compiler-plugin)-embeddable-\d.*\.jar""")

/**
 * A build names the `-embeddable` plugin jars, which refer to IntelliJ classes under the package
 * kotlin-compiler-embeddable relocates them to. This session runs the unrelocated compiler, so it
 * swaps in the unrelocated jar of the same plugin from its own classpath.
 */
private fun bundledPlugin(jar: Path): Path? {
  val artifact = EMBEDDABLE_PLUGIN.matchEntire(jar.fileName.toString())?.groupValues?.get(1)
  val bundled = Regex(Regex.escape(artifact ?: return null) + """-\d.*\.jar""")
  return System.getProperty("java.class.path")
    .split(File.pathSeparator)
    .map(Path::of)
    .firstOrNull { bundled.matches(it.fileName.toString()) }
}
