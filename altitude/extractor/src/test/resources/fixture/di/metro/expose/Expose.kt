package fixture.di.metro.expose

import dev.zacsweers.metro.ContributesBinding
import dev.zacsweers.metro.DependencyGraph
import dev.zacsweers.metro.ExposeImplBinding
import dev.zacsweers.metro.Inject

abstract class ExposeScope private constructor()

interface Prefs

interface Tokens

@ExposeImplBinding @ContributesBinding(ExposeScope::class) @Inject class RealPrefs : Prefs

@ContributesBinding(ExposeScope::class) @Inject class RealTokens : Tokens

@Inject class NeedsImpls(val prefs: RealPrefs, val tokens: RealTokens, val p: Prefs, val t: Tokens)

@DependencyGraph(ExposeScope::class)
interface ExposeGraph {
  val needs: NeedsImpls
}
