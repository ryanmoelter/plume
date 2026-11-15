@file:OptIn(KaIdeApi::class)

package com.ryanmoelter.altitude.extractor

import com.intellij.openapi.progress.ProcessCanceledException
import com.intellij.psi.PsiElement
import com.intellij.psi.PsiErrorElement
import com.intellij.psi.util.PsiTreeUtil
import com.ryanmoelter.altitude.facts.ActualForFact
import com.ryanmoelter.altitude.facts.AnnotationFact
import com.ryanmoelter.altitude.facts.AnnotationTypeArgFact
import com.ryanmoelter.altitude.facts.AnnotationValueFact
import com.ryanmoelter.altitude.facts.ArgFact
import com.ryanmoelter.altitude.facts.CallFact
import com.ryanmoelter.altitude.facts.DeclFact
import com.ryanmoelter.altitude.facts.Facts
import com.ryanmoelter.altitude.facts.FileFact
import com.ryanmoelter.altitude.facts.FlowFact
import com.ryanmoelter.altitude.facts.LambdaCallFact
import com.ryanmoelter.altitude.facts.ModuleFact
import com.ryanmoelter.altitude.facts.NodeFact
import com.ryanmoelter.altitude.facts.OverrideFact
import com.ryanmoelter.altitude.facts.SupertypeFact
import com.ryanmoelter.altitude.facts.UNRESOLVED_TARGET
import com.ryanmoelter.altitude.facts.UnresolvedFact
import java.util.IdentityHashMap
import org.jetbrains.kotlin.analysis.api.KaIdeApi
import org.jetbrains.kotlin.analysis.api.KaSession
import org.jetbrains.kotlin.analysis.api.analyze
import org.jetbrains.kotlin.analysis.api.annotations.KaAnnotated
import org.jetbrains.kotlin.analysis.api.annotations.KaAnnotation
import org.jetbrains.kotlin.analysis.api.annotations.KaAnnotationValue
import org.jetbrains.kotlin.analysis.api.renderer.types.KaExpandedTypeRenderingMode
import org.jetbrains.kotlin.analysis.api.projectStructure.KaSourceModule
import org.jetbrains.kotlin.analysis.api.renderer.types.impl.KaTypeRendererForSource
import org.jetbrains.kotlin.analysis.api.resolution.KaCall
import org.jetbrains.kotlin.analysis.api.resolution.KaCompoundAccessCall
import org.jetbrains.kotlin.analysis.api.resolution.KaDelegatedPropertyCall
import org.jetbrains.kotlin.analysis.api.resolution.KaErrorCallInfo
import org.jetbrains.kotlin.analysis.api.resolution.KaExplicitReceiverValue
import org.jetbrains.kotlin.analysis.api.resolution.KaForLoopCall
import org.jetbrains.kotlin.analysis.api.resolution.KaFunctionCall
import org.jetbrains.kotlin.analysis.api.resolution.KaImplicitInvokeCall
import org.jetbrains.kotlin.analysis.api.resolution.KaImplicitReceiverValue
import org.jetbrains.kotlin.analysis.api.resolution.KaReceiverValue
import org.jetbrains.kotlin.analysis.api.resolution.KaSimpleFunctionCall
import org.jetbrains.kotlin.analysis.api.resolution.KaSmartCastedReceiverValue
import org.jetbrains.kotlin.analysis.api.resolution.KaSuccessCallInfo
import org.jetbrains.kotlin.analysis.api.resolution.KaVariableAccessCall
import org.jetbrains.kotlin.analysis.api.resolution.symbol
import org.jetbrains.kotlin.analysis.api.symbols.KaAnonymousFunctionSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaAnonymousObjectSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaCallableSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaClassKind
import org.jetbrains.kotlin.analysis.api.symbols.KaClassSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaConstructorSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaDeclarationSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaFunctionSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaLocalVariableSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaNamedClassSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaNamedFunctionSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaPropertySymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaReceiverParameterSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaSamConstructorSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaSymbolModality
import org.jetbrains.kotlin.analysis.api.symbols.KaSymbolOrigin
import org.jetbrains.kotlin.analysis.api.symbols.KaSymbolVisibility
import org.jetbrains.kotlin.analysis.api.symbols.KaValueParameterSymbol
import org.jetbrains.kotlin.analysis.api.symbols.KaVariableSymbol
import org.jetbrains.kotlin.analysis.api.symbols.markers.KaNamedSymbol
import org.jetbrains.kotlin.analysis.api.types.KaErrorType
import org.jetbrains.kotlin.analysis.api.types.KaFunctionType
import org.jetbrains.kotlin.analysis.api.types.KaType
import org.jetbrains.kotlin.idea.references.mainReference
import org.jetbrains.kotlin.lexer.KtTokens
import org.jetbrains.kotlin.psi.KtAnnotatedExpression
import org.jetbrains.kotlin.psi.KtAnnotationEntry
import org.jetbrains.kotlin.psi.KtArrayAccessExpression
import org.jetbrains.kotlin.psi.KtBinaryExpression
import org.jetbrains.kotlin.psi.KtBinaryExpressionWithTypeRHS
import org.jetbrains.kotlin.psi.KtBlockExpression
import org.jetbrains.kotlin.psi.KtCallExpression
import org.jetbrains.kotlin.psi.KtCallableReferenceExpression
import org.jetbrains.kotlin.psi.KtClass
import org.jetbrains.kotlin.psi.KtClassBody
import org.jetbrains.kotlin.psi.KtClassInitializer
import org.jetbrains.kotlin.psi.KtClassLiteralExpression
import org.jetbrains.kotlin.psi.KtClassOrObject
import org.jetbrains.kotlin.psi.KtConstantExpression
import org.jetbrains.kotlin.psi.KtDeclaration
import org.jetbrains.kotlin.psi.KtDeclarationWithBody
import org.jetbrains.kotlin.psi.KtDelegatedSuperTypeEntry
import org.jetbrains.kotlin.psi.KtDestructuringDeclaration
import org.jetbrains.kotlin.psi.KtDoWhileExpression
import org.jetbrains.kotlin.psi.KtElement
import org.jetbrains.kotlin.psi.KtEnumEntry
import org.jetbrains.kotlin.psi.KtExpression
import org.jetbrains.kotlin.psi.KtFile
import org.jetbrains.kotlin.psi.KtForExpression
import org.jetbrains.kotlin.psi.KtFunction
import org.jetbrains.kotlin.psi.KtFunctionLiteral
import org.jetbrains.kotlin.psi.KtIfExpression
import org.jetbrains.kotlin.psi.KtIsExpression
import org.jetbrains.kotlin.psi.KtLabeledExpression
import org.jetbrains.kotlin.psi.KtLambdaArgument
import org.jetbrains.kotlin.psi.KtLambdaExpression
import org.jetbrains.kotlin.psi.KtNameReferenceExpression
import org.jetbrains.kotlin.psi.KtNamedFunction
import org.jetbrains.kotlin.psi.KtObjectDeclaration
import org.jetbrains.kotlin.psi.KtObjectLiteralExpression
import org.jetbrains.kotlin.psi.KtParameter
import org.jetbrains.kotlin.psi.KtParenthesizedExpression
import org.jetbrains.kotlin.psi.KtPrimaryConstructor
import org.jetbrains.kotlin.psi.KtProperty
import org.jetbrains.kotlin.psi.KtPropertyAccessor
import org.jetbrains.kotlin.psi.KtQualifiedExpression
import org.jetbrains.kotlin.psi.KtReturnExpression
import org.jetbrains.kotlin.psi.KtScript
import org.jetbrains.kotlin.psi.KtSecondaryConstructor
import org.jetbrains.kotlin.psi.KtStringTemplateExpression
import org.jetbrains.kotlin.psi.KtSuperExpression
import org.jetbrains.kotlin.psi.KtSuperTypeCallEntry
import org.jetbrains.kotlin.psi.KtThisExpression
import org.jetbrains.kotlin.psi.KtThrowExpression
import org.jetbrains.kotlin.psi.KtTryExpression
import org.jetbrains.kotlin.psi.KtTypeAlias
import org.jetbrains.kotlin.psi.KtTypeReference
import org.jetbrains.kotlin.psi.KtUnaryExpression
import org.jetbrains.kotlin.psi.KtValueArgument
import org.jetbrains.kotlin.psi.ValueArgument
import org.jetbrains.kotlin.psi.KtWhenConditionInRange
import org.jetbrains.kotlin.psi.KtWhenConditionWithExpression
import org.jetbrains.kotlin.psi.KtWhenExpression
import org.jetbrains.kotlin.psi.KtWhileExpression
import org.jetbrains.kotlin.psi.psiUtil.getStrictParentOfType
import org.jetbrains.kotlin.types.Variance

/** Extracts the fact relations of `altitude/docs/facts.md` from every source file of a session. */
fun extractFacts(session: AltitudeSession): Facts {
  val out = FactSink()
  val relativePaths = HashMap<String, String>()
  for (module in session.modules) {
    for (file in module.files) {
      relativePaths[file.source.path.toAbsolutePath().normalize().toString()] =
        file.source.relativePath
    }
  }
  val ids = SymbolIds(relativePaths)
  for (module in session.modules) {
    out.modules +=
      ModuleFact(
        name = module.input.name,
        platform = module.input.platform.name.lowercase(),
        fragments = module.input.fragments.map { it.name },
        dependsOn = module.input.moduleDependencies.sorted(),
      )
    for (file in module.files) {
      val errors = PsiTreeUtil.findChildrenOfType(file.psi, PsiErrorElement::class.java)
      out.files +=
        FileFact(
          path = file.source.relativePath,
          module = module.input.name,
          generated = file.source.generated,
          sourceSet = file.source.sourceSet,
          syntaxErrors = errors.size,
        )
      for (error in errors) {
        out.unresolved +=
          UnresolvedFact(ids.location(error), "syntaxError", error.errorDescription.take(120))
      }
      analyze(file.psi) { with(FileExtractor(ids, out)) { extract(file.psi) } }
    }
  }
  return out.toFacts()
}

private class FactSink {
  val modules = ArrayList<ModuleFact>()
  val files = ArrayList<FileFact>()
  val decls = ArrayList<DeclFact>()
  val supertypes = ArrayList<SupertypeFact>()
  val overrides = ArrayList<OverrideFact>()
  val actuals = ArrayList<ActualForFact>()
  val annotations = ArrayList<AnnotationFact>()
  val nodes = ArrayList<NodeFact>()
  val calls = ArrayList<CallFact>()
  val args = ArrayList<ArgFact>()
  val flows = ArrayList<FlowFact>()
  val libraryLambdaCalls = ArrayList<LambdaCallFact>()
  val unresolved = ArrayList<UnresolvedFact>()

  fun toFacts() =
    Facts(
      modules,
      files,
      decls,
      supertypes,
      overrides,
      actuals,
      annotations,
      nodes,
      calls,
      args,
      flows,
      libraryLambdaCalls,
      unresolved,
    )
}

/** The declaration whose code is being walked, and where each enclosing class finds its `this`. */
private class Scope(val decl: String, val thisOf: List<Pair<PsiElement, String>>) {
  fun entering(decl: String, classPsi: PsiElement? = null): Scope =
    Scope(decl, if (classPsi != null) thisOf + (classPsi to decl + THIS) else thisOf)
}

private val NONE = emptyList<String>()

private val EXPANDED_TYPES =
  KaTypeRendererForSource.WITH_QUALIFIED_NAMES.with {
    expandedTypeRenderingMode = KaExpandedTypeRenderingMode.RENDER_EXPANDED_TYPE
  }

private val FUNCTION_CLASS = Regex("""kotlin/(coroutines/|reflect/)?K?(Suspend)?Function\d*""")

private class FileExtractor(private val ids: SymbolIds, private val out: FactSink) {
  /** Locals and parameters by ID, with the declaration that owns each; a read elsewhere captures. */
  private val ownerOfLocal = HashMap<String, String>()

  fun KaSession.extract(file: KtFile) {
    for (type in PsiTreeUtil.collectElementsOfType(file, KtTypeReference::class.java)) {
      if (type.getStrictParentOfType<KtTypeReference>() != null) continue
      if (attempt(type, false) { type.type is KaErrorType }) unresolved(type, "type", type.text)
    }
    val scope = Scope("file:${ids.relativePath(file)}", emptyList())
    for (declaration in file.declarations) declaration(declaration, scope)
  }

  // Declarations

  private fun KaSession.declaration(declaration: KtDeclaration, scope: Scope) {
    attempt(declaration, Unit) {
      when (declaration) {
        is KtClassOrObject -> classOrObject(declaration, scope)
        is KtNamedFunction -> function(declaration, scope)
        is KtProperty -> property(declaration, scope, scope)
        is KtDestructuringDeclaration -> destructuring(declaration, scope)
        is KtTypeAlias -> {}
        is KtScript -> {}
        else -> {}
      }
    }
  }

  private fun KaSession.enumEntry(entry: KtEnumEntry, scope: Scope): String {
    val id = id(entry.symbol)
    decl(id, "enumEntry", entry.name ?: "<entry>", entry, scope, emptyList())
    val init = scope.entering(id, entry)
    entry.initializerList?.initializers?.forEach { initializer ->
      if (initializer is KtSuperTypeCallEntry) {
        callLike(initializer, initializer.valueArguments, null, NONE, init)
      }
    }
    for (member in entry.declarations) declaration(member, init)
    return id
  }

  private fun KaSession.classOrObject(cls: KtClassOrObject, scope: Scope): String {
    if (cls is KtEnumEntry) return enumEntry(cls, scope)
    val symbol = cls.symbol as? KaClassSymbol ?: return positionalDecl(cls, "class", scope)
    val id = id(symbol)
    val kind =
      when (symbol.classKind) {
        KaClassKind.INTERFACE -> "interface"
        KaClassKind.OBJECT,
        KaClassKind.COMPANION_OBJECT,
        KaClassKind.ANONYMOUS_OBJECT -> "object"
        else -> "class"
      }
    val modifiers = buildList {
      addAll(commonModifiers(symbol))
      when (symbol.classKind) {
        KaClassKind.ENUM_CLASS -> add("enum")
        KaClassKind.ANNOTATION_CLASS -> add("annotation")
        KaClassKind.COMPANION_OBJECT -> add("companion")
        KaClassKind.ANONYMOUS_OBJECT -> add("anonymous")
        else -> {}
      }
      if (symbol is KaNamedClassSymbol) {
        if (symbol.isData) add("data")
        if (symbol.isFun) add("fun")
        if (symbol.isInner) add("inner")
        if (symbol.isInline) add("value")
      }
    }
    decl(id, kind, (symbol as? KaNamedSymbol)?.name?.asString() ?: "<object>", cls, scope, modifiers)
    annotations(id, symbol)
    actualFor(id, symbol)

    val primary =
      if (cls is KtClass && !cls.isInterface()) {
        cls.primaryConstructor?.symbol
          ?: symbol.declaredMemberScope.constructors.firstOrNull { it.isPrimary }
      } else {
        null
      }
    val initOwner = primary?.let { id(it) } ?: id
    val init = scope.entering(initOwner, cls)
    if (primary != null) constructorDecl(cls.primaryConstructor ?: cls, primary, initOwner, id, init)

    val delegated = HashMap<String, SupertypeFact>()
    for (entry in cls.superTypeListEntries) {
      when (entry) {
        is KtSuperTypeCallEntry -> callLike(entry, entry.valueArguments, null, NONE, init)
        is KtDelegatedSuperTypeEntry -> {
          val superId = ids.run { classOf(entry.typeReference?.type) } ?: continue
          val location = "$id#<delegate:${superId.removePrefix("class:")}>"
          val expression = entry.delegateExpression
          for (value in visit(expression, init)) flow(value, location, "delegate", entry)
          val type = expression?.let { ids.run { classOf(it.expressionType) } }
          delegated[superId] = SupertypeFact(id, superId, true, location, type)
        }
        else -> {}
      }
    }
    for (type in symbol.superTypes) {
      val superId = ids.run { classOf(type) } ?: continue
      if (superId == "class:kotlin/Any") continue
      out.supertypes += delegated[superId] ?: SupertypeFact(id, superId)
    }

    for (member in cls.declarations) {
      attempt(member, Unit) {
        when (member) {
          is KtClassInitializer -> visit(member.body, init)
          is KtSecondaryConstructor -> secondaryConstructor(member, id, primary != null, init)
          is KtProperty -> property(member, init, scope.entering(id, cls))
          is KtNamedFunction -> function(member, scope.entering(id, cls), cls)
          is KtClassOrObject -> classOrObject(member, scope.entering(id, cls))
          else -> {}
        }
      }
    }
    return id
  }

  private fun KaSession.constructorDecl(
    psi: PsiElement,
    symbol: KaConstructorSymbol,
    id: String,
    classId: String,
    init: Scope,
  ) {
    val modifiers =
      commonModifiers(symbol) + if (psi is KtClassOrObject) listOf("implicit") else emptyList()
    decl(id, "ctor", "<init>", psi, Scope(classId, emptyList()), modifiers)
    annotations(id, symbol)
    actualFor(id, symbol)
    val parameters = (psi as? KtFunction)?.valueParameters.orEmpty()
    parameters(symbol, id, parameters, init)
    for (parameter in parameters) {
      if (!parameter.hasValOrVar()) continue
      val property = (parameter.symbol as? KaValueParameterSymbol)?.generatedPrimaryConstructorProperty
      property ?: continue
      val propertyId = id(property)
      propertyDecl(propertyId, property, parameter, Scope(classId, emptyList()))
      flow("$id#${parameter.name}", propertyId, "init", parameter)
    }
  }

  private fun KaSession.secondaryConstructor(
    constructor: KtSecondaryConstructor,
    classId: String,
    hasPrimary: Boolean,
    init: Scope,
  ) {
    val symbol = constructor.symbol
    val id = id(symbol)
    decl(id, "ctor", "<init>", constructor, Scope(classId, emptyList()), commonModifiers(symbol))
    annotations(id, symbol)
    val scope = Scope(id, init.thisOf.dropLast(1) + (init.thisOf.last().first to id + THIS))
    parameters(symbol, id, constructor.valueParameters, scope)
    val delegation = constructor.getDelegationCall()
    if (!delegation.isImplicit) {
      callLike(delegation, delegation.valueArguments, null, NONE, scope)
    }
    if (!hasPrimary && !delegation.isCallToThis) {
      out.calls +=
        CallFact(
          id = ids.positional(constructor, "initCall"),
          callerDecl = id,
          target = classId,
          dispatch = "init",
          targetInSource = true,
        )
    }
    visit(constructor.bodyExpression, scope)
  }

  private fun KaSession.parameters(
    symbol: KaFunctionSymbol,
    ownerId: String,
    psi: List<KtParameter>,
    scope: Scope,
  ) {
    symbol.valueParameters.forEachIndexed { index, parameter ->
      val id = "$ownerId#${parameter.name.asString()}"
      val parameterPsi = psi.getOrNull(index)
      val modifiers = buildList {
        if (parameter.isVararg) add("vararg")
        if (parameter.hasDefaultValue) add("default")
        if (parameter.isNoinline) add("noinline")
        if (parameter.isCrossinline) add("crossinline")
        if (parameter.isImplicitLambdaParameter) add("implicit")
        addAll(typeModifiers(parameter.returnType))
      }
      out.decls +=
        DeclFact(
          sym = id,
          kind = "param",
          name = parameter.name.asString(),
          owner = ownerId,
          file = parameterPsi?.let { ids.relativePath(it.containingFile) },
          span = parameterPsi?.let { ids.span(it) },
          type = render(parameter.returnType),
          modifiers = modifiers,
          fnTyped = isFunctionTyped(parameter.returnType),
          index = index,
          typeExpanded = renderExpanded(parameter.returnType),
        )
      ownerOfLocal[id] = ownerId
      annotations(id, parameter)
      annotations(id + TYPE, parameter.returnType)
      val default = parameterPsi?.defaultValue ?: return@forEachIndexed
      for (value in visit(default, scope)) flow(value, id, "default", default)
    }
    psi.forEachIndexed { index, parameter ->
      val destructured = parameter.destructuringDeclaration ?: return@forEachIndexed
      val source = symbol.valueParameters.getOrNull(index)?.let { "$ownerId#${it.name.asString()}" }
      destructuring(destructured, scope, listOfNotNull(source))
    }
  }

  private fun KaSession.function(
    function: KtNamedFunction,
    scope: Scope,
    memberOf: KtClassOrObject? = null,
  ): String {
    val symbol = function.symbol
    val id = id(symbol)
    val anonymous = symbol is KaAnonymousFunctionSymbol
    val modifiers = buildList {
      addAll(commonModifiers(symbol))
      if (symbol is KaNamedFunctionSymbol) {
        if (symbol.isSuspend) add("suspend")
        if (symbol.isInline) add("inline")
        if (symbol.isOperator) add("operator")
        if (symbol.isInfix) add("infix")
        if (symbol.isOverride) add("override")
        if (symbol.isTailRec) add("tailrec")
      }
      if (symbol.isExtension) add("receiver")
      if (!function.hasBody()) add("noBody")
      if (memberOf != null) add("member")
    }
    decl(
      id,
      if (anonymous) "lambda" else "fun",
      function.name ?: "<anonymous>",
      function,
      scope,
      modifiers,
      symbol.returnType,
    )
    annotations(id, symbol)
    annotations(id + TYPE, symbol.returnType)
    symbol.receiverParameter?.let { annotations(id + RECEIVER, it) }
    actualFor(id, symbol)
    overrides(id, symbol)
    val inner = scope.entering(id, memberOf)
    parameters(symbol, id, function.valueParameters, inner)
    body(function, id, inner)
    return id
  }

  private fun KaSession.body(function: KtDeclarationWithBody, id: String, scope: Scope) {
    val body = function.bodyExpression ?: return
    val values = visit(body, scope)
    if (!function.hasBlockBody()) for (value in values) flow(value, id + RETURN, "return", body)
  }

  private fun KaSession.property(property: KtProperty, init: Scope, declared: Scope) {
    val symbol = property.symbol
    val id = id(symbol)
    if (symbol is KaLocalVariableSymbol || symbol !is KaPropertySymbol) {
      localDecl(id, property.name ?: "<local>", property, init, symbol.returnType, symbol.isVal)
      for (value in visit(property.initializer, init)) flow(value, id, "init", property)
      property.delegate?.let { delegate ->
        for (value in visit(delegate.expression, init)) flow(value, id + DELEGATE, "delegate", delegate)
        delegateAccessors(property, id, init, init)
      }
      return
    }
    propertyDecl(id, symbol, property, declared)
    val memberOf = (property.parent as? KtClassBody)?.parent as? KtClassOrObject
    val initScope = if (memberOf != null) init else Scope(id, declared.thisOf)
    for (value in visit(property.initializer, initScope)) flow(value, id, "init", property)
    property.delegate?.let { delegate ->
      for (value in visit(delegate.expression, initScope)) {
        flow(value, id + DELEGATE, "delegate", delegate)
      }
      delegateAccessors(property, id, declared, initScope)
    }
    for (accessor in property.accessors) accessor(accessor, id, declared, memberOf)
  }

  private fun KaSession.accessor(
    accessor: KtPropertyAccessor,
    propertyId: String,
    declared: Scope,
    memberOf: KtClassOrObject?,
  ) {
    if (!accessor.hasBody()) return
    val id = propertyId + if (accessor.isGetter) GETTER else SETTER
    out.decls +=
      DeclFact(
        sym = id,
        kind = if (accessor.isGetter) "getter" else "setter",
        name = if (accessor.isGetter) "<get>" else "<set>",
        owner = propertyId,
        file = ids.relativePath(accessor.containingFile),
        span = ids.span(accessor),
      )
    val scope = Scope(id, declared.thisOf).let { if (memberOf != null) it.entering(id, memberOf) else it }
    parameters(accessor.symbol, id, accessor.valueParameters, scope)
    body(accessor, id, scope)
    if (accessor.isGetter) flow(id + RETURN, propertyId, "return", accessor)
  }

  /** A delegated property reads and writes through accessors that call the delegate's operators. */
  private fun KaSession.delegateAccessors(
    property: KtProperty,
    propertyId: String,
    declared: Scope,
    init: Scope,
  ) {
    val delegate = property.delegate ?: return
    val call =
      attempt(delegate, null) {
        (delegate.resolveToCall() as? KaSuccessCallInfo)?.call as? KaDelegatedPropertyCall
      }
    if (call == null) {
      unresolved(delegate, "delegate", delegate.text)
      return
    }
    fun accessor(operator: KaFunctionCall<*>, suffix: String, kind: String) {
      val id = propertyId + suffix
      out.decls +=
        DeclFact(
          sym = id,
          kind = kind,
          name = if (suffix == GETTER) "<get>" else "<set>",
          owner = propertyId,
          file = ids.relativePath(delegate.containingFile),
          span = ids.span(delegate),
          modifiers = listOf("delegated"),
        )
      val target = original(operator.partiallyAppliedSymbol.symbol)
      val targetId = id(target)
      val inSource = isSource(target)
      val result = if (suffix == GETTER) ids.positional(delegate, "callResult") else null
      val callId = ids.positional(delegate, if (suffix == GETTER) "getValue" else "setValue")
      out.calls +=
        CallFact(
          id = callId,
          callerDecl = id,
          target = targetId,
          dispatch = "delegateAccessor",
          targetInSource = inSource,
          receiver = listOf(propertyId + DELEGATE),
          result = result,
        )
      if (suffix == SETTER && !inSource) {
        target.valueParameters.lastOrNull()?.let {
          out.args +=
            ArgFact(callId, "$targetId#${it.name.asString()}", target.valueParameters.lastIndex, propertyId, "operand")
        }
      }
      if (inSource) {
        val receiver = if (target.isExtension) RECEIVER else THIS
        flow(propertyId + DELEGATE, targetId + receiver, "receiver", delegate)
        if (suffix == SETTER) {
          target.valueParameters.lastOrNull()?.let {
            flow(propertyId, "$targetId#${it.name.asString()}", "arg", delegate)
          }
        }
      }
      if (result != null) {
        out.nodes += NodeFact(result, "callResult", id, render(operator.partiallyAppliedSymbol.signature.returnType))
        if (inSource) flow(targetId + RETURN, result, "return", delegate)
        flow(result, propertyId, "return", delegate)
      }
    }
    accessor(call.valueGetterCall, GETTER, "getter")
    call.valueSetterCall?.let { accessor(it, SETTER, "setter") }
    call.provideDelegateCall?.let { provide ->
      val target = original(provide.partiallyAppliedSymbol.symbol)
      out.calls +=
        CallFact(
          id = ids.positional(delegate, "provideDelegate"),
          callerDecl = init.decl,
          target = id(target),
          dispatch = "delegateAccessor",
          targetInSource = isSource(target),
          receiver = listOf(propertyId + DELEGATE),
        )
    }
  }

  private fun KaSession.propertyDecl(
    id: String,
    symbol: KaPropertySymbol,
    psi: PsiElement,
    scope: Scope,
  ) {
    val modifiers = buildList {
      addAll(commonModifiers(symbol))
      add(if (symbol.isVal) "val" else "var")
      if (symbol.isOverride) add("override")
      if (symbol.isDelegatedProperty) add("delegated")
      if (symbol.isExtension) add("receiver")
      if (symbol.isFromPrimaryConstructor) add("ctorParam")
      addAll(typeModifiers(symbol.returnType))
    }
    decl(id, "prop", symbol.name.asString(), psi, scope, modifiers, symbol.returnType)
    annotations(id, symbol)
    annotations(id + TYPE, symbol.returnType)
    symbol.getter?.let { annotations(id + GETTER, it) }
    symbol.setter?.let { annotations(id + SETTER, it) }
    symbol.backingFieldSymbol?.let { annotations(id + FIELD, it) }
    symbol.receiverParameter?.let { annotations(id + RECEIVER, it) }
    actualFor(id, symbol)
    overrides(id, symbol)
  }

  private fun KaSession.localDecl(
    id: String,
    name: String,
    psi: PsiElement,
    scope: Scope,
    type: KaType,
    isVal: Boolean = true,
  ) {
    ownerOfLocal[id] = scope.decl
    decl(id, "local", name, psi, scope, listOf(if (isVal) "val" else "var"), type)
  }

  /** [source] is what a destructured lambda or loop parameter takes apart. */
  private fun KaSession.destructuring(
    declaration: KtDestructuringDeclaration,
    scope: Scope,
    source: List<String> = NONE,
  ) {
    val values = visit(declaration.initializer, scope) + source
    for (entry in declaration.entries) {
      val symbol = entry.symbol
      val id = id(symbol)
      localDecl(id, entry.name ?: "_", entry, scope, symbol.returnType)
      val component =
        attempt(entry, null) {
          (entry.resolveToCall() as? KaSuccessCallInfo)?.call as? KaFunctionCall<*>
        } ?: continue
      val target = original(component.partiallyAppliedSymbol.symbol)
      val targetId = id(target)
      val inSource = isSource(target)
      out.calls +=
        CallFact(
          id = ids.positional(entry, "call"),
          callerDecl = scope.decl,
          target = targetId,
          dispatch = "static",
          targetInSource = inSource,
          receiver = if (target.isExtension) NONE else values,
          extReceiver = if (target.isExtension) values else NONE,
          result = if (inSource) null else id,
        )
      // A data class's componentN is generated from the constructor property it returns.
      val parameter = target.psi as? KtParameter
      val property =
        (parameter?.symbol as? KaValueParameterSymbol)?.generatedPrimaryConstructorProperty
      when {
        property != null -> flow(id(property), id, "destructure", entry)
        inSource -> flow(targetId + RETURN, id, "destructure", entry)
      }
    }
  }

  // Expressions

  /** Records what [element] does and returns the locations whose value it evaluates to. */
  private fun KaSession.visit(element: PsiElement?, scope: Scope): List<String> =
    when (element) {
      null -> NONE
      is KtParenthesizedExpression -> visit(element.expression, scope)
      is KtLabeledExpression -> visit(element.baseExpression, scope)
      is KtAnnotatedExpression -> visit(element.baseExpression, scope)
      is KtBlockExpression -> {
        var last = NONE
        for (statement in element.statements) last = visit(statement, scope)
        last
      }
      is KtLambdaExpression -> attempt(element, NONE) { listOf(lambda(element, scope)) }
      is KtNamedFunction ->
        attempt(element, NONE) {
          val id = function(element, scope)
          if (element.name != null) {
            NONE
          } else {
            val node = ids.positional(element, "lambdaExpr")
            out.nodes +=
              NodeFact(node, "lambdaExpr", scope.decl, render(element.expressionType), true, id)
            listOf(node)
          }
        }
      is KtProperty -> {
        attempt(element, Unit) { property(element, scope, scope) }
        NONE
      }
      is KtDestructuringDeclaration -> {
        attempt(element, Unit) { destructuring(element, scope) }
        NONE
      }
      is KtObjectLiteralExpression ->
        attempt(element, NONE) {
          val id = classOrObject(element.objectDeclaration, scope)
          val node = ids.positional(element, "objectCreation")
          out.nodes += NodeFact(node, "objectCreation", scope.decl, render(element.expressionType), target = id)
          listOf(node)
        }
      is KtClassOrObject -> {
        attempt(element, Unit) { classOrObject(element, scope) }
        NONE
      }
      is KtTypeAlias -> NONE
      is KtReturnExpression -> {
        val values = visit(element.returnedExpression, scope)
        val target = attempt(element, null) { element.targetSymbol }
        if (target != null) {
          for (value in values) flow(value, id(target) + RETURN, "return", element)
        }
        NONE
      }
      is KtIfExpression -> {
        visit(element.condition, scope)
        visit(element.then, scope) + visit(element.`else`, scope)
      }
      is KtWhenExpression -> {
        element.subjectVariable?.let { visit(it, scope) } ?: visit(element.subjectExpression, scope)
        element.entries.flatMap { entry ->
          for (condition in entry.conditions) {
            when (condition) {
              is KtWhenConditionWithExpression -> visit(condition.expression, scope)
              is KtWhenConditionInRange -> visit(condition.rangeExpression, scope)
              else -> {}
            }
          }
          entry.guard?.let { visit(it.getExpression(), scope) }
          visit(entry.expression, scope)
        }
      }
      is KtTryExpression -> {
        val values = ArrayList(visit(element.tryBlock, scope))
        for (clause in element.catchClauses) {
          clause.catchParameter?.let { parameter ->
            attempt(parameter, Unit) {
              val symbol = parameter.symbol
              localDecl(id(symbol), parameter.name ?: "_", parameter, scope, symbol.returnType)
            }
          }
          values += visit(clause.catchBody, scope)
        }
        visit(element.finallyBlock?.finalExpression, scope)
        values
      }
      is KtBinaryExpressionWithTypeRHS -> visit(element.left, scope)
      is KtIsExpression -> {
        visit(element.leftHandSide, scope)
        NONE
      }
      is KtBinaryExpression -> binary(element, scope)
      is KtUnaryExpression ->
        if (element.operationToken == KtTokens.EXCLEXCL) {
          visit(element.baseExpression, scope)
        } else {
          operator(element, listOf(element.baseExpression), scope)
        }
      is KtQualifiedExpression -> qualified(element, scope)
      is KtCallExpression -> call(element, null, NONE, scope)
      is KtNameReferenceExpression -> name(element, null, NONE, scope)
      is KtThisExpression -> thisReference(element, scope)
      is KtSuperExpression -> NONE
      is KtConstantExpression -> listOf(literal(element, scope))
      is KtStringTemplateExpression -> {
        for (entry in element.entries) visit(entry.expression, scope)
        listOf(literal(element, scope))
      }
      is KtCallableReferenceExpression -> callableReference(element, scope)
      is KtArrayAccessExpression ->
        operator(element, listOf(element.arrayExpression) + element.indexExpressions, scope)
      is KtForExpression -> {
        forLoop(element, scope)
        NONE
      }
      is KtWhileExpression -> {
        visit(element.condition, scope)
        visit(element.body, scope)
        NONE
      }
      is KtDoWhileExpression -> {
        visit(element.body, scope)
        visit(element.condition, scope)
        NONE
      }
      is KtThrowExpression -> {
        visit(element.thrownExpression, scope)
        NONE
      }
      is KtClassLiteralExpression -> NONE
      is KtTypeReference -> NONE
      else -> {
        var child = element.firstChild
        while (child != null) {
          if (child is KtElement) visit(child, scope)
          child = child.nextSibling
        }
        NONE
      }
    }

  private fun KaSession.lambda(lambda: KtLambdaExpression, scope: Scope): String {
    val literal = lambda.functionLiteral
    val symbol = literal.symbol
    val id = id(symbol)
    val type = lambda.expressionType
    val modifiers = buildList {
      if (symbol.receiverParameter != null) add("receiver")
      if (type is KaFunctionType && type.isSuspend) add("suspend")
      if (type != null) addAll(typeModifiers(type))
    }
    out.decls +=
      DeclFact(
        sym = id,
        kind = "lambda",
        name = "<lambda>",
        owner = scope.decl,
        file = ids.relativePath(literal.containingFile),
        span = ids.span(literal),
        type = render(type),
        modifiers = modifiers,
        fnTyped = true,
      )
    val inner = Scope(id, scope.thisOf)
    parameters(symbol, id, literal.valueParameters, inner)
    val statements = literal.bodyExpression?.statements.orEmpty()
    statements.forEachIndexed { index, statement ->
      val values = visit(statement, inner)
      if (index == statements.lastIndex) {
        for (value in values) flow(value, id + RETURN, "return", statement)
      }
    }
    val node = ids.positional(literal, "lambdaExpr")
    out.nodes += NodeFact(node, "lambdaExpr", scope.decl, render(type), true, id)
    return node
  }

  private fun KaSession.literal(element: KtExpression, scope: Scope): String {
    val node = ids.positional(element, "literal")
    out.nodes +=
      NodeFact(
        id = node,
        kind = "literal",
        enclosingDecl = scope.decl,
        type = attempt(element, null) { render(element.expressionType) },
        text = element.text.takeIf { it.length <= 200 },
      )
    return node
  }

  private fun KaSession.thisReference(element: KtThisExpression, scope: Scope): List<String> {
    val symbol =
      attempt(element, null) { element.instanceReference.mainReference.resolveToSymbols().firstOrNull() }
    val location = symbol?.let { receiverLocation(it, scope) } ?: return NONE
    val node = ids.positional(element, "thisRef")
    out.nodes += NodeFact(node, "thisRef", scope.decl, render(element.expressionType), target = location)
    flow(location, node, "read", element)
    return listOf(node)
  }

  private fun KaSession.receiverLocation(symbol: KaSymbol, scope: Scope): String? =
    when (symbol) {
      is KaReceiverParameterSymbol -> id(symbol.owningCallableSymbol) + RECEIVER
      is KaClassSymbol ->
        scope.thisOf.lastOrNull { it.first == symbol.psi }?.second ?: (id(symbol) + THIS)
      is KaCallableSymbol -> id(symbol) + RECEIVER
      else -> null
    }

  private fun KaSession.binary(element: KtBinaryExpression, scope: Scope): List<String> =
    when (element.operationToken) {
      KtTokens.EQ -> {
        assignment(element, scope)
        NONE
      }
      KtTokens.ELVIS -> visit(element.left, scope) + visit(element.right, scope)
      KtTokens.ANDAND,
      KtTokens.OROR,
      KtTokens.EQEQEQ,
      KtTokens.EXCLEQEQEQ -> {
        visit(element.left, scope)
        visit(element.right, scope)
        NONE
      }
      else -> operator(element, listOf(element.left, element.right), scope)
    }

  private fun KaSession.assignment(element: KtBinaryExpression, scope: Scope) {
    var left = element.left
    while (left is KtParenthesizedExpression) left = left.expression
    if (left is KtArrayAccessExpression) {
      val operands = listOf(left.arrayExpression) + left.indexExpressions + element.right
      operator(left, operands, scope)
      return
    }
    val receiver = (left as? KtQualifiedExpression)?.receiverExpression
    val receiverValues = visit(receiver, scope)
    val name = (left as? KtQualifiedExpression)?.selectorExpression ?: left
    val values = visit(element.right, scope)
    if (name !is KtNameReferenceExpression) {
      visit(name, scope)
      return
    }
    val variable = variable(name)
    if (variable == null) {
      unresolved(name, "name", name.getReferencedName())
      return
    }
    val id = id(variable)
    val kind = if (variable is KaLocalVariableSymbol || variable is KaValueParameterSymbol) "assign" else "fieldWrite"
    if (!libraryAccess(name, variable, id, SETTER, receiverValues, values, scope)) {
      for (value in values) flow(value, id, kind, element)
    }
    accessorCall(name, variable, id, SETTER, receiver, receiverValues, scope)
  }

  private fun KaSession.variable(name: KtNameReferenceExpression): KaVariableSymbol? {
    val call = attempt(name, null) { (name.resolveToCall() as? KaSuccessCallInfo)?.call }
    val symbol =
      when (call) {
        is KaVariableAccessCall -> call.partiallyAppliedSymbol.symbol
        is KaCompoundAccessCall -> null
        else -> null
      }
        ?: attempt(name, null) {
          name.mainReference.resolveToSymbols().firstNotNullOfOrNull { it as? KaVariableSymbol }
        }
    return symbol?.let { original(it) as? KaVariableSymbol }
  }

  private fun KaSession.qualified(element: KtQualifiedExpression, scope: Scope): List<String> {
    val receiver = element.receiverExpression
    val values = visit(receiver, scope)
    if (attempt(receiver, false) { receiver.expressionType is KaErrorType }) {
      unresolved(element.selectorExpression ?: element, "errorReceiver", element.text)
    }
    return when (val selector = element.selectorExpression) {
      is KtCallExpression -> call(selector, receiver, values, scope)
      is KtNameReferenceExpression -> name(selector, receiver, values, scope)
      else -> visit(selector, scope)
    }
  }

  private fun KaSession.name(
    name: KtNameReferenceExpression,
    receiver: KtExpression?,
    receiverValues: List<String>,
    scope: Scope,
  ): List<String> {
    val variable = variable(name)
    if (variable == null) {
      val symbols = attempt(name, emptyList()) { name.mainReference.resolveToSymbols().toList() }
      if (symbols.isEmpty()) unresolved(name, "name", name.getReferencedName())
      val singleton =
        symbols.firstNotNullOfOrNull { symbol ->
          (symbol as? KaClassSymbol)?.takeIf {
            it.classKind == KaClassKind.OBJECT || it.classKind == KaClassKind.COMPANION_OBJECT
          }
        }
      return singleton?.let { listOf(id(it) + THIS) } ?: NONE
    }
    val id = id(variable)
    val isLocal = variable is KaLocalVariableSymbol || variable is KaValueParameterSymbol
    val kind =
      when (variable) {
        is KaValueParameterSymbol -> "paramRef"
        is KaLocalVariableSymbol -> "localRef"
        else -> "propRef"
      }
    val type = attempt(name, null) { name.expressionType }
    val node = ids.positional(name, kind)
    out.nodes += NodeFact(node, kind, scope.decl, render(type), isFunctionTyped(type), id)
    val flowKind =
      when {
        !isLocal -> "fieldRead"
        ownerOfLocal[id]?.let { it != scope.decl } == true -> "capture"
        else -> "read"
      }
    if (!libraryAccess(name, variable, id, GETTER, receiverValues, listOf(node), scope)) {
      flow(id, node, flowKind, name)
      if (variable is KaPropertySymbol && !isLocalProperty(variable)) {
        val receivers = accessReceivers(name, variable, receiverValues, scope)
        for (value in receivers.dispatch + receivers.extension) flow(value, node, "memberOf", name)
      }
    }
    accessorCall(name, variable, id, GETTER, receiver, receiverValues, scope)
    return listOf(node)
  }

  /**
   * A property of an object declared outside the sources is read and written through a call a
   * model can match, and is not one field shared by every object of its class. [values] is the
   * node of a read, or what a write assigns. Returns whether the access is such a call.
   */
  private fun KaSession.libraryAccess(
    name: KtNameReferenceExpression,
    variable: KaVariableSymbol,
    id: String,
    suffix: String,
    receiverValues: List<String>,
    values: List<String>,
    scope: Scope,
  ): Boolean {
    if (variable !is KaPropertySymbol || isSource(variable)) return false
    val receivers = accessReceivers(name, variable, receiverValues, scope)
    val dispatch = receivers.dispatch
    val extension = receivers.extension
    val implicit = receivers.implicit
    if (dispatch.isEmpty() && extension.isEmpty()) return false
    val callId = ids.positional(name, if (suffix == GETTER) "get" else "set")
    out.calls +=
      CallFact(
        id = callId,
        callerDecl = scope.decl,
        target = id + suffix,
        dispatch = "static",
        receiver = dispatch,
        extReceiver = extension,
        implicit = implicit,
        result = if (suffix == GETTER) values.single() else null,
      )
    if (suffix == GETTER) {
      for (receiver in dispatch + extension) flow(receiver, values.single(), "memberOf", name)
    } else {
      for (value in values) out.args += ArgFact(callId, "$id$suffix#value", 0, value, "operand")
    }
    return true
  }

  /** A read or write runs code when the property has an accessor body, a delegate or overriders. */
  private fun KaSession.accessorCall(
    name: KtNameReferenceExpression,
    variable: KaVariableSymbol,
    id: String,
    suffix: String,
    receiver: KtExpression?,
    receiverValues: List<String>,
    scope: Scope,
  ) {
    if (variable !is KaPropertySymbol || !isSource(variable)) return
    val psi = variable.psi as? KtProperty
    val accessor = if (suffix == GETTER) psi?.getter else psi?.setter
    val virtual = variable.modality != KaSymbolModality.FINAL && receiver !is KtSuperExpression
    if (accessor?.hasBody() != true && psi?.hasDelegate() != true && !virtual) return
    if (suffix == SETTER && variable.isVal) return
    val access =
      attempt(name, null) { (name.resolveToCall() as? KaSuccessCallInfo)?.call as? KaVariableAccessCall }
    val dispatch = access?.partiallyAppliedSymbol?.dispatchReceiver
    val implicit = dispatch.unwrapped() is KaImplicitReceiverValue
    val values =
      when (val value = dispatch.unwrapped()) {
        is KaImplicitReceiverValue -> listOfNotNull(receiverLocation(value.symbol, scope))
        null -> NONE
        else -> receiverValues
      }
    out.calls +=
      CallFact(
        id = ids.positional(name, if (suffix == GETTER) "get" else "set"),
        callerDecl = scope.decl,
        target = id + suffix,
        dispatch = if (virtual) "virtual" else "static",
        targetInSource = true,
        receiver = values,
        implicit = if (implicit) listOf("dispatch") else emptyList(),
        receiverType = if (virtual) ids.run { classOf(dispatch?.type) } else null,
      )
  }

  private class Receivers(val dispatch: List<String>, val extension: List<String>, val implicit: List<String>)

  /** The objects a property access reads from or writes to, written or implicit. */
  private fun KaSession.accessReceivers(
    name: KtNameReferenceExpression,
    variable: KaPropertySymbol,
    receiverValues: List<String>,
    scope: Scope,
  ): Receivers {
    val access =
      attempt(name, null) { (name.resolveToCall() as? KaSuccessCallInfo)?.call as? KaVariableAccessCall }
    // The name on the left of an assignment may not resolve to an access by itself.
    if (access == null) {
      return if (variable.isExtension) Receivers(NONE, receiverValues, NONE) else Receivers(receiverValues, NONE, NONE)
    }
    val implicit = ArrayList<String>()
    fun receivers(value: KaReceiverValue?, role: String): List<String> =
      when (val unwrapped = value.unwrapped()) {
        null -> NONE
        is KaImplicitReceiverValue -> {
          implicit += role
          listOfNotNull(receiverLocation(unwrapped.symbol, scope))
        }
        else -> receiverValues
      }
    return Receivers(
      receivers(access.partiallyAppliedSymbol.dispatchReceiver, "dispatch"),
      receivers(access.partiallyAppliedSymbol.extensionReceiver, "extension"),
      implicit,
    )
  }

  private fun KaReceiverValue?.unwrapped(): KaReceiverValue? {
    var value = this
    while (value is KaSmartCastedReceiverValue) value = value.original
    return value
  }

  private fun KaSession.callableReference(
    element: KtCallableReferenceExpression,
    scope: Scope,
  ): List<String> {
    val receiver = element.receiverExpression
    val receiverValues = visit(receiver, scope)
    val symbol =
      attempt(element, null) {
        element.callableReference.mainReference.resolveToSymbols().firstNotNullOfOrNull {
          it as? KaCallableSymbol
        }
      }
    if (symbol == null) {
      unresolved(element, "callableReference", element.text)
      return NONE
    }
    val target = original(symbol)
    val id = id(target)
    val bound = receiver == null || receiverValues.isNotEmpty()
    if (isSource(target)) {
      val location = id + if (target.isExtension) RECEIVER else THIS
      for (value in receiverValues) flow(value, location, "receiver", element)
    }
    val node = ids.positional(element, "callableRef")
    out.nodes +=
      NodeFact(node, "callableRef", scope.decl, render(element.expressionType), true, id, bound)
    return listOf(node)
  }

  private fun KaSession.forLoop(loop: KtForExpression, scope: Scope) {
    val range = loop.loopRange
    val values = visit(range, scope)
    val call =
      attempt(loop, null) { (loop.resolveToCall() as? KaSuccessCallInfo)?.call as? KaForLoopCall }
    var element: String? = null
    if (call != null && range != null) {
      // The iterator and each element are nodes, so a model can carry the range's elements over.
      val iterator = ids.positional(range, "iteratorResult")
      val next = ids.positional(range, "nextResult")
      for ((kind, operator) in
        listOf("iterator" to call.iteratorCall, "hasNext" to call.hasNextCall, "next" to call.nextCall)) {
        val target = original(operator.partiallyAppliedSymbol.symbol)
        val inSource = isSource(target)
        val receiver = if (kind == "iterator") values else listOf(iterator)
        val result =
          when (kind) {
            "iterator" -> iterator
            "next" -> next
            else -> null
          }
        out.calls +=
          CallFact(
            id = ids.positional(range, kind),
            callerDecl = scope.decl,
            target = id(target),
            dispatch = dispatch(target, operator, null),
            targetInSource = inSource,
            receiver = if (target.isExtension) NONE else receiver,
            extReceiver = if (target.isExtension) receiver else NONE,
            result = result,
          )
        if (result != null) {
          val type = render(operator.partiallyAppliedSymbol.signature.returnType)
          out.nodes += NodeFact(result, "callResult", scope.decl, type)
        }
        if (kind == "next") element = if (inSource) id(target) + RETURN else next
      }
    }
    loop.loopParameter?.let { parameter ->
      attempt(parameter, Unit) {
        val destructured = parameter.destructuringDeclaration
        if (destructured != null) {
          destructuring(destructured, scope, listOfNotNull(element))
        } else {
          val symbol = parameter.symbol
          val id = id(symbol)
          localDecl(id, parameter.name ?: "_", parameter, scope, symbol.returnType)
          element?.let { flow(it, id, "iteration", parameter) }
        }
      }
    }
    visit(loop.body, scope)
  }

  // Calls

  private fun KaSession.call(
    call: KtCallExpression,
    receiver: KtExpression?,
    receiverValues: List<String>,
    scope: Scope,
  ): List<String> = callLike(call, call.valueArguments, receiver, receiverValues, scope)

  private fun KaSession.operator(
    element: KtElement,
    operands: List<KtExpression?>,
    scope: Scope,
  ): List<String> {
    val values = IdentityHashMap<PsiElement, List<String>>()
    for (operand in operands) operand?.let { values[it] = visit(it, scope) }
    return emit(element, values, null, scope)
  }

  private fun KaSession.callLike(
    element: KtElement,
    arguments: List<ValueArgument>,
    receiver: KtExpression?,
    receiverValues: List<String>,
    scope: Scope,
  ): List<String> {
    val values = IdentityHashMap<PsiElement, List<String>>()
    if (receiver != null) values[receiver] = receiverValues
    for (argument in arguments) {
      argument.getArgumentExpression()?.let { values[it] = visit(it, scope) }
    }
    return emit(element, values, receiver, scope)
  }

  private fun KaSession.resolved(element: KtElement): KaCall? =
    when (val info = attempt(element, null) { element.resolveToCall() }) {
      is KaSuccessCallInfo -> info.call
      is KaErrorCallInfo -> {
        unresolved(element, "call", calleeText(element), info.diagnostic.factoryName)
        null
      }
      else -> {
        unresolved(element, "call", calleeText(element))
        null
      }
    }

  private fun calleeText(element: KtElement): String =
    when (element) {
      is KtCallExpression -> element.calleeExpression?.text ?: element.text
      is KtBinaryExpression -> element.operationReference.text
      is KtUnaryExpression -> element.operationReference.text
      is KtArrayAccessExpression -> "[]"
      else -> element.text
    }

  private fun KaSession.emit(
    element: KtElement,
    values: IdentityHashMap<PsiElement, List<String>>,
    receiver: KtExpression?,
    scope: Scope,
  ): List<String> {
    val callId = ids.positional(element, "call")
    val resolved = resolved(element)
    val call =
      when (resolved) {
        is KaFunctionCall<*> -> resolved
        is KaCompoundAccessCall -> resolved.compoundOperation.operationCall
        else -> null
      }
    val callee = (element as? KtCallExpression)?.calleeExpression
    if (call == null) {
      if (callee != null && callee !is KtNameReferenceExpression) visit(callee, scope)
      if (resolved == null) {
        out.calls += CallFact(callId, scope.decl, UNRESOLVED_TARGET, "static")
      }
      return NONE
    }
    val applied = call.partiallyAppliedSymbol
    val target = original(applied.symbol)
    val targetId = id(target)
    val inSource = isSource(target)
    // `palette { }` may call a declared `operator fun invoke`, which is an ordinary call.
    val isInvoke = isFunctionInvoke(target)
    val implicitInvoke =
      call is KaImplicitInvokeCall || (call as? KaSimpleFunctionCall)?.isImplicitInvoke == true

    fun lookup(expression: KtExpression): List<String>? {
      var current: PsiElement? = expression
      while (current != null) {
        values[current]?.let { return it }
        current =
          when (current) {
            is KtParenthesizedExpression -> current.expression
            is KtLabeledExpression -> current.baseExpression
            is KtAnnotatedExpression -> current.baseExpression
            else -> null
          }
      }
      return null
    }

    val implicit = ArrayList<String>()
    fun receiverValues(value: KaReceiverValue?, role: String): List<String> =
      when (val unwrapped = value.unwrapped()) {
        null -> NONE
        is KaImplicitReceiverValue -> {
          implicit += role
          listOfNotNull(receiverLocation(unwrapped.symbol, scope))
        }
        is KaExplicitReceiverValue -> lookup(unwrapped.expression) ?: NONE
        else -> NONE
      }

    var invokeTakesReceiver = false
    var dispatchValues = receiverValues(applied.dispatchReceiver, "dispatch")
    var extensionValues = receiverValues(applied.extensionReceiver, "extension")
    if (implicitInvoke && callee != null) {
      // `a.f(x)` reads the property `f` of `a`; `x.block()` passes `x` to a local `block`.
      val calleeName = callee as? KtNameReferenceExpression
      val variable = calleeName?.let { variable(it) }
      val receiverBelongsToCallee =
        receiver != null && variable is KaPropertySymbol && !isLocalProperty(variable)
      dispatchValues =
        when {
          calleeName != null && receiverBelongsToCallee ->
            name(calleeName, receiver, values[receiver] ?: NONE, scope)
          calleeName != null -> name(calleeName, null, NONE, scope)
          else -> visit(callee, scope)
        }
      val implicitExtension = extensionValues.takeIf { "extension" in implicit }
      extensionValues =
        if (receiver != null && !receiverBelongsToCallee) values[receiver] ?: NONE
        else implicitExtension ?: NONE
      implicit.clear()
      // `menu { }` inside a `ColumnScope.() -> Unit` lambda passes that scope without naming it.
      if (implicitExtension != null && extensionValues === implicitExtension) {
        implicit += "extension"
        invokeTakesReceiver = true
      }
      if (!isInvoke && target.isExtension) {
        extensionValues = dispatchValues
        dispatchValues = NONE
      }
    }

    val isConstructor = target is KaConstructorSymbol
    val returnType = applied.signature.returnType
    val result =
      when {
        element is KtSuperTypeCallEntry -> null
        isConstructor -> ids.positional(element, "objectCreation")
        returnType.isUnitType || returnType.isNothingType -> null
        else -> ids.positional(element, "callResult")
      }
    if (result != null) {
      out.nodes +=
        NodeFact(
          id = result,
          kind = if (isConstructor) "objectCreation" else "callResult",
          enclosingDecl = scope.decl,
          type = render(returnType),
          fnTyped = isFunctionTyped(returnType),
          target = if (isConstructor) ids.run { classOf(returnType) } else callId,
        )
    }

    val dispatch = if (isInvoke) "invokeFnValue" else dispatch(target, call, receiver)
    out.calls +=
      CallFact(
        id = callId,
        callerDecl = scope.decl,
        target = targetId,
        dispatch = dispatch,
        targetInSource = inSource,
        receiver = dispatchValues,
        extReceiver = extensionValues,
        implicit = implicit,
        receiverType =
          if (dispatch == "virtual") ids.run { classOf(applied.dispatchReceiver?.type) } else null,
        result = result,
      )

    if (inSource && !isInvoke && !isConstructor) {
      for (value in dispatchValues) flow(value, targetId + THIS, "receiver", element)
      for (value in extensionValues) flow(value, targetId + RECEIVER, "receiver", element)
      if (result != null) flow(targetId + RETURN, result, "return", element)
    }
    // A data class's `copy` has no body in the sources: the result is the receiver with the
    // arguments stored in the properties they are named after.
    val copiedClass =
      targetId.takeIf {
        inSource && target.origin == KaSymbolOrigin.SOURCE_MEMBER_GENERATED &&
          (target as? KaNamedFunctionSymbol)?.name?.asString() == "copy"
      }?.removePrefix("fun:")?.substringBefore('(')?.removeSuffix(".copy")
    if (copiedClass != null && result != null) {
      for (value in dispatchValues) flow(value, result, "copy", element)
    }

    val parameterNames = target.valueParameters.map { it.name }
    var takesFunction = false
    val invokeArguments = ArrayList<Triple<Int, KtExpression, String>>()
    for ((expression, signature) in call.argumentMapping) {
      val parameter = signature.symbol
      val index = parameterNames.indexOf(parameter.name)
      val argument = expression.getStrictParentOfType<KtValueArgument>()?.takeIf { it.getArgumentExpression() == expression }
      val form =
        when {
          argument is KtLambdaArgument -> "trailingLambda"
          argument?.getSpreadElement() != null -> "spread"
          argument?.isNamed() == true -> "named"
          parameter.isVararg -> "vararg"
          argument == null -> "operand"
          else -> "positional"
        }
      if (isFunctionLike(expression) || isFunctionTyped(parameter.returnType)) takesFunction = true
      if (isInvoke) {
        invokeArguments += Triple(index, expression, form)
        continue
      }
      val parameterId = "$targetId#${parameter.name.asString()}"
      val typeAnnotations = typeAnnotations(parameter.returnType)
      for (value in lookup(expression) ?: NONE) {
        out.args += ArgFact(callId, parameterId, index, value, form, typeAnnotations)
        if (inSource) flow(value, parameterId, "arg", expression)
        if (copiedClass != null) flow(value, "prop:$copiedClass.${parameter.name.asString()}", "copy", expression)
        if ((isConstructor || copiedClass != null) && result != null) flow(value, result, "partOf", expression)
        if (target is KaSamConstructorSymbol && result != null) flow(value, result, "sam", expression)
      }
    }
    if (isInvoke) {
      // An invoke's arguments are positional, with the function type's receiver first.
      var index = 0
      if (extensionValues.isNotEmpty() || invokeTakesReceiver) {
        for (value in extensionValues) out.args += ArgFact(callId, "$targetId#<recv>", index, value, "receiver")
        index++
      }
      for ((_, expression, form) in invokeArguments.sortedBy { it.first }) {
        for (value in lookup(expression) ?: NONE) {
          out.args += ArgFact(callId, "$targetId#p${index + 1}", index, value, form)
        }
        index++
      }
    }
    if (!inSource && !isInvoke && takesFunction) {
      out.libraryLambdaCalls += LambdaCallFact(callId, targetId)
    }
    return listOfNotNull(result)
  }

  private fun KaSession.dispatch(
    target: KaFunctionSymbol,
    call: KaFunctionCall<*>,
    receiver: KtExpression?,
  ): String {
    if (target !is KaNamedFunctionSymbol) return "static"
    if (call.partiallyAppliedSymbol.dispatchReceiver == null) return "static"
    if (receiver is KtSuperExpression) return "static"
    return if (target.modality == KaSymbolModality.FINAL) "static" else "virtual"
  }

  private fun isFunctionInvoke(target: KaFunctionSymbol): Boolean {
    if (target !is KaNamedFunctionSymbol || target.name.asString() != "invoke") return false
    val owner = target.callableId?.classId?.asString() ?: return false
    return FUNCTION_CLASS.matches(owner)
  }

  private fun isFunctionLike(expression: KtExpression): Boolean {
    var current: KtExpression? = expression
    while (true) {
      current =
        when (current) {
          is KtParenthesizedExpression -> current.expression
          is KtLabeledExpression -> current.baseExpression
          is KtAnnotatedExpression -> current.baseExpression
          else -> break
        }
    }
    return current is KtLambdaExpression ||
      current is KtCallableReferenceExpression ||
      (current is KtNamedFunction && current.name == null)
  }

  // Helpers

  private fun KaSession.id(symbol: KaSymbol): String = ids.run { symbolId(symbol) }

  private fun isLocalProperty(symbol: KaPropertySymbol): Boolean = symbol.callableId == null && symbol.psi?.parent !is KtClassBody

  /** The declaration a call runs: not a fake override, and the interface member behind `by`. */
  private fun KaSession.original(symbol: KaCallableSymbol): KaCallableSymbol {
    val current = symbol.fakeOverrideOriginal
    if (current.origin != KaSymbolOrigin.DELEGATED) return current
    return current.directlyOverriddenSymbols.firstOrNull()?.let { original(it) } ?: current
  }

  private fun KaSession.original(symbol: KaFunctionSymbol): KaFunctionSymbol =
    original(symbol as KaCallableSymbol) as? KaFunctionSymbol ?: symbol

  private fun KaSession.isSource(symbol: KaSymbol): Boolean =
    attempt(null, false) { symbol.containingModule is KaSourceModule }

  private fun KaSession.isFunctionTyped(type: KaType?): Boolean =
    type != null && type.fullyExpandedType is KaFunctionType

  private fun KaSession.render(type: KaType?): String? =
    type?.render(KaTypeRendererForSource.WITH_QUALIFIED_NAMES, Variance.INVARIANT)

  /** The type with aliases expanded, or null when the source writes it that way already. */
  private fun KaSession.renderExpanded(type: KaType?): String? =
    type?.render(EXPANDED_TYPES, Variance.INVARIANT)?.takeIf { it != render(type) }

  /** Annotations on a type, which is where `@Composable` sits on a function type. */
  private fun typeModifiers(type: KaType): List<String> = typeAnnotations(type).map { "typeAnnotation:$it" }

  private fun typeAnnotations(type: KaType): List<String> =
    type.annotations.mapNotNull { it.classId?.asString() }.distinct().sorted()

  private fun commonModifiers(symbol: KaDeclarationSymbol): List<String> = buildList {
    when (symbol.visibility) {
      KaSymbolVisibility.PRIVATE -> add("private")
      KaSymbolVisibility.INTERNAL -> add("internal")
      KaSymbolVisibility.PROTECTED -> add("protected")
      else -> {}
    }
    when (symbol.modality) {
      KaSymbolModality.ABSTRACT -> add("abstract")
      KaSymbolModality.OPEN -> add("open")
      KaSymbolModality.SEALED -> add("sealed")
      else -> {}
    }
    if (symbol.isExpect) add("expect")
    if (symbol.isActual) add("actual")
  }

  private fun KaSession.decl(
    id: String,
    kind: String,
    name: String,
    psi: PsiElement,
    scope: Scope,
    modifiers: List<String>,
    type: KaType? = null,
  ) {
    out.decls +=
      DeclFact(
        sym = id,
        kind = kind,
        name = name,
        owner = scope.decl,
        file = ids.relativePath(psi.containingFile),
        span = ids.span(psi),
        type = render(type),
        modifiers = modifiers,
        fnTyped = isFunctionTyped(type),
        typeExpanded = renderExpanded(type),
      )
  }

  private fun KaSession.positionalDecl(psi: PsiElement, kind: String, scope: Scope): String {
    val id = ids.positional(psi, kind)
    decl(id, kind, "<unknown>", psi, scope, emptyList())
    return id
  }

  private fun KaSession.annotations(id: String, symbol: KaAnnotated) {
    for (annotation in symbol.annotations) {
      val fqName = annotation.classId?.asString() ?: continue
      val arguments = annotation.psi?.valueArguments.orEmpty().map { (it as? KtValueArgument)?.text ?: "" }
      out.annotations +=
        AnnotationFact(id, fqName, arguments, annotationValues(annotation), metaAnnotations(annotation))
    }
  }

  private fun KaSession.annotationValues(annotation: KaAnnotation): List<AnnotationValueFact> =
    annotation.arguments.map { annotationValue(it.name.asString(), it.expression) }

  private fun KaSession.metaAnnotations(annotation: KaAnnotation): List<String> {
    val classId = annotation.classId ?: return emptyList()
    return attempt(null, emptyList()) {
      findClass(classId)
        ?.annotations
        ?.mapNotNull { it.classId?.asString() }
        ?.filterNot { it.startsWith("kotlin/annotation/") || it.startsWith("java/lang/annotation/") }
        ?.distinct()
        ?.sorted()
        .orEmpty()
    }
  }

  private fun KaSession.annotationValue(name: String?, value: KaAnnotationValue): AnnotationValueFact =
    when (value) {
      is KaAnnotationValue.ConstantValue -> AnnotationValueFact(name, "const", value.value.render())
      is KaAnnotationValue.EnumEntryValue ->
        AnnotationValueFact(name, "enum", value.callableId?.let { "enumEntry:$it" })
      is KaAnnotationValue.ClassLiteralValue ->
        AnnotationValueFact(name, "class", renderExpanded(value.type) ?: render(value.type), ids.run { classOf(value.type) })
      is KaAnnotationValue.ArrayValue ->
        AnnotationValueFact(name, "array", elements = value.values.map { annotationValue(null, it) })
      is KaAnnotationValue.NestedAnnotationValue ->
        nestedAnnotation(name, value.annotation, value.sourcePsi)
      else -> AnnotationValueFact(name, "unsupported", value.sourcePsi?.text?.take(120))
    }

  private fun KaSession.nestedAnnotation(
    name: String?,
    annotation: KaAnnotation,
    psi: PsiElement?,
  ): AnnotationValueFact {
    val typeArguments =
      when (psi) {
        is KtCallExpression -> psi.typeArguments
        is KtAnnotationEntry -> psi.typeArguments
        else -> emptyList()
      }
    return AnnotationValueFact(
      name = name,
      kind = "annotation",
      value = annotation.classId?.asString(),
      elements = annotationValues(annotation),
      typeArgs =
        typeArguments.mapNotNull { argument ->
          val type = argument.typeReference?.type ?: return@mapNotNull null
          AnnotationTypeArgFact(
            type = renderExpanded(type) ?: render(type).orEmpty(),
            cls = ids.run { classOf(type) },
            annotations = type.annotations.map { nestedAnnotation(null, it, it.psi) },
          )
        },
      meta = metaAnnotations(annotation),
    )
  }

  private fun KaSession.actualFor(id: String, symbol: KaDeclarationSymbol) {
    if (!symbol.isActual) return
    for (expect in attempt(null, emptyList()) { symbol.getExpectsForActual() }) {
      out.actuals += ActualForFact(id, id(expect))
    }
  }

  private fun KaSession.overrides(id: String, symbol: KaCallableSymbol) {
    val isOverride =
      (symbol as? KaNamedFunctionSymbol)?.isOverride ?: (symbol as? KaPropertySymbol)?.isOverride
    if (isOverride != true) return
    for (overridden in symbol.directlyOverriddenSymbols) {
      out.overrides += OverrideFact(id, id(original(overridden)))
    }
  }

  private fun flow(from: String, to: String, kind: String, evidence: PsiElement) {
    out.flows += FlowFact(from, to, kind, ids.location(evidence))
  }

  private fun unresolved(element: PsiElement, kind: String, text: String, diagnostic: String? = null) {
    out.unresolved +=
      UnresolvedFact(ids.location(element), kind, text.lineSequence().first().take(120), diagnostic)
  }

  private inline fun <T> attempt(element: PsiElement?, fallback: T, block: () -> T): T =
    try {
      block()
    } catch (e: ProcessCanceledException) {
      throw e
    } catch (e: Exception) {
      if (element != null) unresolved(element, "exception", element.text, e::class.java.simpleName)
      fallback
    }
}
