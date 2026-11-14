package com.ryanmoelter.altitude.extractor

import com.intellij.openapi.progress.ProcessCanceledException
import com.intellij.psi.PsiElement
import org.jetbrains.kotlin.analysis.api.KaSession
import org.jetbrains.kotlin.analysis.api.analyze
import org.jetbrains.kotlin.analysis.api.projectStructure.KaSourceModule
import org.jetbrains.kotlin.analysis.api.resolution.KaCall
import org.jetbrains.kotlin.analysis.api.resolution.KaCallInfo
import org.jetbrains.kotlin.analysis.api.resolution.KaCallableMemberCall
import org.jetbrains.kotlin.analysis.api.resolution.KaCompoundAccessCall
import org.jetbrains.kotlin.analysis.api.resolution.KaErrorCallInfo
import org.jetbrains.kotlin.analysis.api.resolution.KaFunctionCall
import org.jetbrains.kotlin.analysis.api.resolution.KaImplicitInvokeCall
import org.jetbrains.kotlin.analysis.api.resolution.KaSimpleFunctionCall
import org.jetbrains.kotlin.analysis.api.resolution.KaSuccessCallInfo
import org.jetbrains.kotlin.analysis.api.resolution.symbol
import org.jetbrains.kotlin.analysis.api.symbols.KaCallableSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaConstructorSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaFunctionSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaJavaFieldSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaNamedFunctionSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaPropertySymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaVariableSymbol
import org.jetbrains.kotlin.analysis.api.types.KaErrorType
import org.jetbrains.kotlin.idea.references.mainReference
import org.jetbrains.kotlin.kdoc.psi.api.KDoc
import org.jetbrains.kotlin.lexer.KtTokens
import org.jetbrains.kotlin.psi.KtAnnotationEntry
import org.jetbrains.kotlin.psi.KtArrayAccessExpression
import org.jetbrains.kotlin.psi.KtBinaryExpression
import org.jetbrains.kotlin.psi.KtCallExpression
import org.jetbrains.kotlin.psi.KtCallableReferenceExpression
import org.jetbrains.kotlin.psi.KtConstructorDelegationCall
import org.jetbrains.kotlin.psi.KtDotQualifiedExpression
import org.jetbrains.kotlin.psi.KtElement
import org.jetbrains.kotlin.psi.KtImportDirective
import org.jetbrains.kotlin.psi.KtImportList
import org.jetbrains.kotlin.psi.KtInstanceExpressionWithLabel
import org.jetbrains.kotlin.psi.KtNameReferenceExpression
import org.jetbrains.kotlin.psi.KtPackageDirective
import org.jetbrains.kotlin.psi.KtPropertyDelegate
import org.jetbrains.kotlin.psi.KtSuperTypeCallEntry
import org.jetbrains.kotlin.psi.KtTypeReference
import org.jetbrains.kotlin.psi.KtUnaryExpression
import org.jetbrains.kotlin.psi.KtValueArgumentName

/** The syntactic shape of a resolved element. */
enum class Site(val callLike: Boolean) {
  CALL(true),
  SUPER_CONSTRUCTOR_CALL(true),
  OPERATOR(true),
  ARRAY_ACCESS(true),
  NAME(true),
  CALLABLE_REFERENCE(true),
  DELEGATE(true),
  ANNOTATION(false),
  TYPE(false),
  IMPORT(false),
}

enum class Target(val resolved: Boolean) {
  SOURCE_FUNCTION(true),
  LIBRARY_FUNCTION(true),
  SOURCE_CONSTRUCTOR(true),
  LIBRARY_CONSTRUCTOR(true),
  SOURCE_PROPERTY(true),
  LIBRARY_PROPERTY(true),
  /** A call of a function-typed variable, property or parameter through `invoke`. */
  VARIABLE_INVOKE(true),
  /** A callable reference to a local variable or parameter. */
  LOCAL_VARIABLE(true),
  TYPE(true),
  /** Candidates exist, but none applies; [CallSite.diagnostic] says why. */
  ERROR(false),
  UNRESOLVED(false),
}

data class CallSite(
  val module: String,
  val path: String,
  val generated: Boolean,
  val line: Int,
  val column: Int,
  val site: Site,
  /** The callee name, operator or type text; what unresolved sites group by. */
  val text: String,
  val target: Target,
  /** The callable id, or the class id plus `.<init>` for a constructor. */
  val symbol: String? = null,
  /** For [Target.VARIABLE_INVOKE] the `invoke` it calls; otherwise null. */
  val via: String? = null,
  val diagnostic: String? = null,
)

/** Resolves every call-like element, type reference and import of a session's source files. */
fun collectCallSites(session: AltitudeSession): List<CallSite> =
  session.modules.flatMap { module ->
    module.files.flatMap { file ->
      analyze(file.psi) { FileCollector(this, module.input.name, file).collect() }
    }
  }

private class Resolution(
  val target: Target,
  val symbol: String? = null,
  val via: String? = null,
  val diagnostic: String? = null,
)

private val unresolved = Resolution(Target.UNRESOLVED)

private val operatorsWithoutCall =
  setOf(
    KtTokens.EQ,
    KtTokens.ELVIS,
    KtTokens.ANDAND,
    KtTokens.OROR,
    KtTokens.EQEQEQ,
    KtTokens.EXCLEQEQEQ,
    KtTokens.EXCLEXCL,
  )

private class FileCollector(
  private val session: KaSession,
  private val module: String,
  private val file: LoadedFile,
) {
  private val sites = ArrayList<CallSite>()
  private val lineStarts: IntArray =
    file.psi.text.let { text ->
      val starts = arrayListOf(0)
      text.forEachIndexed { index, char -> if (char == '\n') starts += index + 1 }
      starts.toIntArray()
    }

  fun collect(): List<CallSite> {
    visit(file.psi, inType = false)
    return sites
  }

  private fun visit(element: PsiElement, inType: Boolean) {
    var childrenInType = inType
    when (element) {
      is KtPackageDirective,
      is KDoc -> return
      is KtImportList -> {
        element.imports.forEach(::recordImport)
        return
      }
      is KtTypeReference -> {
        if (!inType) recordType(element)
        childrenInType = true
      }
      is KtAnnotationEntry -> record(element, Site.ANNOTATION, element.shortName?.asString())
      is KtCallExpression -> record(element, Site.CALL, element.calleeExpression?.text)
      is KtSuperTypeCallEntry ->
        record(element, Site.SUPER_CONSTRUCTOR_CALL, element.calleeExpression.text)
      is KtConstructorDelegationCall ->
        if (!element.isImplicit) {
          record(element, Site.SUPER_CONSTRUCTOR_CALL, element.calleeExpression?.text)
        }
      is KtBinaryExpression ->
        if (element.operationToken !in operatorsWithoutCall) {
          record(element, Site.OPERATOR, element.operationReference.text, element.operationReference)
        }
      is KtUnaryExpression ->
        if (element.operationToken !in operatorsWithoutCall) {
          record(element, Site.OPERATOR, element.operationReference.text, element.operationReference)
        }
      is KtArrayAccessExpression -> record(element, Site.ARRAY_ACCESS, "[]")
      is KtPropertyDelegate -> recordDelegate(element)
      is KtNameReferenceExpression -> if (!inType) recordName(element)
    }
    var child = element.firstChild
    while (child != null) {
      visit(child, childrenInType)
      child = child.nextSibling
    }
  }

  private fun record(
    element: KtElement,
    site: Site,
    text: String?,
    anchor: PsiElement = element,
  ) = add(anchor, site, text ?: element.text, attempt { resolveCall(element) })

  private fun resolveCall(element: KtElement): Resolution =
    with(session) {
      when (val info: KaCallInfo? = element.resolveToCall()) {
        null -> unresolved
        is KaSuccessCallInfo -> describe(info.call, element)
        is KaErrorCallInfo -> {
          val candidate = info.candidateCalls.firstNotNullOfOrNull { describe(it, element).symbol }
          Resolution(
            if (candidate == null) Target.UNRESOLVED else Target.ERROR,
            symbol = candidate,
            diagnostic = info.diagnostic.factoryName,
          )
        }
        else -> unresolved
      }
    }

  private fun describe(call: KaCall, element: KtElement): Resolution =
    when {
      call is KaImplicitInvokeCall || (call is KaSimpleFunctionCall && call.isImplicitInvoke) -> {
        val invoke = (call as KaFunctionCall<*>).symbol
        val callee = (element as? KtCallExpression)?.calleeExpression as? KtNameReferenceExpression
        val variable = callee?.let { referencedSymbols(it).firstOrNull() as? KaCallableSymbol }
        Resolution(Target.VARIABLE_INVOKE, variable?.let(::render) ?: callee?.text, render(invoke))
      }
      call is KaCompoundAccessCall -> describe(call.compoundOperation.operationCall.symbol)
      call is KaCallableMemberCall<*, *> -> describe(call.symbol)
      else -> unresolved
    }

  private fun describe(symbol: KaCallableSymbol): Resolution {
    val inSource = with(session) { symbol.containingModule } is KaSourceModule
    val target =
      when (symbol) {
        is KaConstructorSymbol ->
          if (inSource) Target.SOURCE_CONSTRUCTOR else Target.LIBRARY_CONSTRUCTOR
        is KaFunctionSymbol -> if (inSource) Target.SOURCE_FUNCTION else Target.LIBRARY_FUNCTION
        is KaPropertySymbol,
        is KaJavaFieldSymbol -> if (inSource) Target.SOURCE_PROPERTY else Target.LIBRARY_PROPERTY
        else -> Target.LOCAL_VARIABLE
      }
    return Resolution(target, render(symbol))
  }

  private fun render(symbol: KaCallableSymbol): String =
    when (symbol) {
      is KaConstructorSymbol -> "${symbol.containingClassId?.asString() ?: "<local>"}.<init>"
      else ->
        symbol.callableId?.toString()
          ?: (symbol as? KaVariableSymbol)?.name?.asString()
          ?: (symbol as? KaNamedFunctionSymbol)?.name?.asString()
          ?: "<anonymous>"
    }

  private fun referencedSymbols(name: KtNameReferenceExpression): Collection<KaSymbol> =
    with(session) { name.mainReference.resolveToSymbols() }

  private fun recordName(name: KtNameReferenceExpression) {
    val parent = name.parent
    if (parent is KtValueArgumentName || parent is KtInstanceExpressionWithLabel) return
    if (parent is KtCallExpression && parent.calleeExpression == name) return
    if (parent is KtCallableReferenceExpression && parent.callableReference == name) {
      add(name, Site.CALLABLE_REFERENCE, name.getReferencedName(), attempt { describeName(name) })
      return
    }
    val resolution = attempt { describeName(name) }
    // A resolved name that is not a property is a local, a parameter, a class or a package.
    val isProperty =
      resolution.target == Target.SOURCE_PROPERTY || resolution.target == Target.LIBRARY_PROPERTY
    if (resolution.target.resolved && !isProperty) return
    add(name, Site.NAME, name.getReferencedName(), resolution)
  }

  private fun describeName(name: KtNameReferenceExpression): Resolution {
    val symbols = referencedSymbols(name)
    val callable = symbols.firstNotNullOfOrNull { it as? KaCallableSymbol }
    return when {
      symbols.isEmpty() -> unresolved
      callable != null -> describe(callable)
      else -> Resolution(Target.TYPE)
    }
  }

  private fun recordDelegate(delegate: KtPropertyDelegate) {
    val text = "by ${delegateName(delegate)}"
    val resolution = attempt {
      with(session) {
        val call = delegate.resolveCall()
        when (val getter = call?.valueGetterCall) {
          null -> unresolved
          else -> describe(getter.symbol)
        }
      }
    }
    add(delegate, Site.DELEGATE, text, resolution)
  }

  private fun delegateName(delegate: KtPropertyDelegate): String =
    when (val expression = delegate.expression) {
      is KtCallExpression -> expression.calleeExpression?.text ?: expression.text
      null -> ""
      else -> expression.text
    }

  private fun recordType(type: KtTypeReference) {
    val resolution = attempt {
      with(session) {
        if (type.type is KaErrorType) unresolved else Resolution(Target.TYPE)
      }
    }
    add(type, Site.TYPE, type.text, resolution)
  }

  private fun recordImport(directive: KtImportDirective) {
    val reference = directive.importedReference ?: return
    val name =
      (reference as? KtDotQualifiedExpression)?.selectorExpression as? KtNameReferenceExpression
        ?: reference as? KtNameReferenceExpression
        ?: return
    val resolution = attempt {
      if (referencedSymbols(name).isEmpty()) unresolved else Resolution(Target.TYPE)
    }
    add(directive, Site.IMPORT, directive.importedFqName?.asString() ?: reference.text, resolution)
  }

  private fun attempt(resolve: () -> Resolution): Resolution =
    try {
      resolve()
    } catch (e: ProcessCanceledException) {
      throw e
    } catch (e: Exception) {
      Resolution(Target.UNRESOLVED, diagnostic = "exception:${e::class.java.simpleName}")
    }

  private fun add(anchor: PsiElement, site: Site, text: String, resolution: Resolution) {
    val offset = anchor.textRange.startOffset
    val line = lineStarts.binarySearch(offset).let { if (it >= 0) it else -it - 2 }
    sites +=
      CallSite(
        module = module,
        path = file.source.relativePath,
        generated = file.source.generated,
        line = line + 1,
        column = offset - lineStarts[line] + 1,
        site = site,
        text = text.lineSequence().first().take(120),
        target = resolution.target,
        symbol = resolution.symbol,
        via = resolution.via,
        diagnostic = resolution.diagnostic,
      )
  }
}
