package com.ryanmoelter.altitude.extractor

import com.intellij.openapi.util.text.StringUtil
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiFile
import java.nio.file.Path
import org.jetbrains.kotlin.analysis.api.KaSession
import org.jetbrains.kotlin.analysis.api.symbols.KaAnonymousFunctionSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaBackingFieldSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaCallableSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaClassLikeSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaConstructorSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaContextParameterSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaDeclarationSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaEnumEntrySymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaFunctionSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaJavaFieldSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaLocalVariableSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaNamedFunctionSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaPropertyAccessorSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaPropertyGetterSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaPropertySymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaReceiverParameterSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaSamConstructorSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaSymbolOrigin
import org.jetbrains.kotlin.analysis.api.symbols.KaSymbolVisibility
import org.jetbrains.kotlin.analysis.api.symbols.KaValueParameterSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaVariableSymbol
import org.jetbrains.kotlin.analysis.api.symbols.markers.KaNamedSymbol
import org.jetbrains.kotlin.analysis.api.types.KaClassType
import org.jetbrains.kotlin.analysis.api.types.KaDefinitelyNotNullType
import org.jetbrains.kotlin.analysis.api.types.KaErrorType
import org.jetbrains.kotlin.analysis.api.types.KaFlexibleType
import org.jetbrains.kotlin.analysis.api.types.KaType
import org.jetbrains.kotlin.analysis.api.types.KaTypeParameterType

const val THIS = "#<this>"
const val RECEIVER = "#<recv>"
const val RETURN = "#<ret>"
const val GETTER = "#<get>"
const val SETTER = "#<set>"
const val DELEGATE = "#<delegate>"
const val EXPECT = "|expect"

/**
 * Stable identifiers. A declaration with a qualified name is named by kind, owner, name and erased
 * parameter types, so the same symbol gets the same ID from every file that refers to it. A local
 * declaration is named by its position.
 */
class SymbolIds(private val relativePaths: Map<String, String>) {
  private val lineStarts = HashMap<PsiFile, IntArray>()

  fun relativePath(file: PsiFile): String? =
    file.virtualFile?.path?.let { relativePaths[Path.of(it).toAbsolutePath().normalize().toString()] }

  fun span(element: PsiElement): String {
    val starts =
      lineStarts.getOrPut(element.containingFile) {
        val text = element.containingFile.text
        val offsets = arrayListOf(0)
        text.forEachIndexed { index, char -> if (char == '\n') offsets += index + 1 }
        offsets.toIntArray()
      }
    fun position(offset: Int): String {
      val line = starts.binarySearch(offset).let { if (it >= 0) it else -it - 2 }
      return "${line + 1}:${offset - starts[line] + 1}"
    }
    val range = element.textRange
    return "${position(range.startOffset)}-${position(range.endOffset)}"
  }

  /** `relpath:startLine:startCol-endLine:endCol`. */
  fun location(element: PsiElement): String =
    "${relativePath(element.containingFile) ?: "<external>"}:${span(element)}"

  fun positional(element: PsiElement, kind: String): String = "${location(element)}:$kind"

  fun KaSession.symbolId(symbol: KaSymbol): String =
    when (symbol) {
      is KaClassLikeSymbol ->
        symbol.classId?.let { "class:${it.asString()}" + fileScope(symbol) + expect(symbol) }
          ?: positionalOr(symbol, "class")
      is KaConstructorSymbol -> {
        val owner = symbol.containingClassId
        if (owner != null) {
          "ctor:${owner.asString()}(${parameters(symbol)})" + expect(symbol)
        } else {
          val container = symbol.containingDeclaration
          if (container != null) "${symbolId(container)}#<init>(${parameters(symbol)})"
          else positionalOr(symbol, "ctor")
        }
      }
      is KaPropertyAccessorSymbol -> {
        val property = symbol.containingDeclaration
        val suffix = if (symbol is KaPropertyGetterSymbol) GETTER else SETTER
        if (property != null) symbolId(property) + suffix else positionalOr(symbol, "accessor")
      }
      is KaSamConstructorSymbol -> "fun:${symbol.callableId ?: symbol.name.asString()}(<sam>)"
      is KaNamedFunctionSymbol ->
        symbol.callableId?.let {
          "fun:$it${receiver(symbol)}(${parameters(symbol)})" + fileScope(symbol) + expect(symbol)
        } ?: positionalOr(symbol, "fun")
      is KaAnonymousFunctionSymbol -> positionalOr(symbol, "lambda")
      is KaFunctionSymbol -> positionalOr(symbol, "fun")
      is KaValueParameterSymbol -> parameterId(symbol, symbol.name.asString())
      is KaContextParameterSymbol -> parameterId(symbol, symbol.name.asString())
      is KaReceiverParameterSymbol -> symbolId(symbol.owningCallableSymbol) + RECEIVER
      is KaBackingFieldSymbol -> symbolId(symbol.owningProperty)
      is KaEnumEntrySymbol ->
        symbol.callableId?.let { "enumEntry:$it" } ?: positionalOr(symbol, "enumEntry")
      is KaPropertySymbol ->
        symbol.callableId?.let { "prop:$it${receiver(symbol)}" + fileScope(symbol) + expect(symbol) }
          ?: positionalOr(symbol, "prop")
      is KaJavaFieldSymbol ->
        symbol.callableId?.let { "prop:$it" } ?: positionalOr(symbol, "prop")
      is KaLocalVariableSymbol -> positionalOr(symbol, "local")
      is KaVariableSymbol -> positionalOr(symbol, "local")
      else -> positionalOr(symbol, "symbol")
    }

  fun KaSession.erased(type: KaType): String =
    when (val expanded = type.fullyExpandedType) {
      is KaClassType ->
        (expanded.classId.takeUnless { it.isLocal }?.asString() ?: "<local>") +
          if (expanded.isMarkedNullable) "?" else ""
      is KaTypeParameterType ->
        expanded.symbol.upperBounds.firstOrNull()?.let { erased(it) } ?: "kotlin/Any?"
      is KaFlexibleType -> erased(expanded.lowerBound).removeSuffix("?")
      is KaDefinitelyNotNullType -> erased(expanded.original).removeSuffix("?")
      is KaErrorType -> "<error>"
      else -> "<other>"
    }

  /** The class of a type, or null when it has none in a qualified position. */
  fun KaSession.classOf(type: KaType?): String? =
    when (val expanded = type?.fullyExpandedType) {
      is KaClassType -> expanded.symbol.let { symbolId(it) }
      is KaTypeParameterType -> expanded.symbol.upperBounds.firstOrNull()?.let { classOf(it) }
      is KaFlexibleType -> classOf(expanded.lowerBound)
      is KaDefinitelyNotNullType -> classOf(expanded.original)
      else -> null
    }

  private fun KaSession.parameterId(symbol: KaSymbol, name: String): String {
    val owner = symbol.containingDeclaration
    return if (owner != null) "${symbolId(owner)}#$name" else positionalOr(symbol, "param")
  }

  private fun KaSession.parameters(symbol: KaFunctionSymbol): String =
    symbol.valueParameters.joinToString(",") {
      erased(it.returnType) + if (it.isVararg) "..." else ""
    }

  private fun KaSession.receiver(symbol: KaCallableSymbol): String =
    symbol.receiverParameter?.let { "@" + erased(it.returnType) }.orEmpty()

  private fun expect(symbol: KaDeclarationSymbol): String = if (symbol.isExpect) EXPECT else ""

  /** Two files of one package may each declare a private top-level symbol of the same name. */
  private fun fileScope(symbol: KaDeclarationSymbol): String {
    if (symbol.visibility != KaSymbolVisibility.PRIVATE) return ""
    val topLevel =
      when (symbol) {
        is KaClassLikeSymbol -> symbol.classId?.outerClassId == null
        is KaCallableSymbol -> symbol.callableId?.classId == null
        else -> false
      }
    if (!topLevel) return ""
    return symbol.psi?.containingFile?.name?.let { "@$it" }.orEmpty()
  }

  private fun positionalOr(symbol: KaSymbol, kind: String): String {
    val psi = symbol.psi
    val isSource =
      symbol.origin == KaSymbolOrigin.SOURCE || symbol.origin == KaSymbolOrigin.SOURCE_MEMBER_GENERATED
    if (psi != null && (isSource || relativePath(psi.containingFile) != null)) {
      return positional(psi, kind)
    }
    val name = (symbol as? KaNamedSymbol)?.name?.asString() ?: "anonymous"
    return "external:$kind:${StringUtil.escapeStringCharacters(name)}"
  }
}
