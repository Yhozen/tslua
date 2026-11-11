# `tslua.ast` contract

The contract between the AST package and everything that consumes it (scanner, parser, binder,
checker, printer, transformers). Go originals: `vendor/typescript-go/internal/ast/*.go`.
The ast agent implements it and keeps this file accurate; if reality has to deviate, update this
file in the same commit.

Most of the package is generated: `node scripts/gen/ast.mjs` reads
`vendor/typescript-go/_scripts/ast.json` (the schema Go's `ast_generated.go` comes from, through the
shared `_scripts/schema.ts`) and writes `src/tslua/ast/ast_generated.lua`. Constants (`Kind`,
`NodeFlags`, `ModifierFlags`, `SymbolFlags`, `TokenFlags`, `FlowFlags`, `CheckFlags`, `SubtreeFacts`,
`OperatorPrecedence`, `OuterExpressionKinds` (`OEKParentheses`, …), …) come from
`consts_generated.lua`. Do not edit generated files.

## Node

A node is a single flat Lua table:

```lua
{
    kind = ast.Kind.PropertyAccessExpression, -- never changes
    flags = 0,                                -- ast.NodeFlags
    loc = core.TextRange,                     -- immutable {pos=, end_=}; replace, never mutate
    parent = <node or nil>,
    id = <nil until ast.GetNodeId assigns it>,
    -- data fields of the Go data struct, flattened, lowerCamelCase of the Go field name:
    expression = <node>,
    questionDotToken = <node or nil>,
    name = <node>,
    facts = 0,                                -- CompositeBase subtree-facts cache
}
```

- Go `node.Kind` -> `node.kind`, `node.Flags` -> `node.flags`, `node.Loc` -> `node.loc`,
  `node.Parent` -> `node.parent`, `node.Pos()` -> `node:Pos()`, `node.End()` -> `node:End()`.
- Data struct fields are flattened onto the node. Go `node.AsPropertyAccessExpression().Expression`
  -> `node.expression` (or `node:AsPropertyAccessExpression().expression`). Embedded base structs
  (`DeclarationBase`, `LocalsContainerBase`, `FlowNodeBase`, `ExportableBase`, `ModifiersBase`,
  `FunctionLikeBase`, `BodyBase`, …) are flattened too: `node.symbol`, `node.localSymbol`,
  `node.locals`, `node.nextContainer`, `node.flowNode`, `node.endFlowNode`, `node.returnFlowNode`,
  `node.modifiers`, `node.typeParameters`, `node.parameters`, `node.type`, `node.body`,
  `node.asteriskToken`, … Go private fields keep their lowerCamel name (`name`, `modifiers`, `text`).
- Field names come from `ast.json` member names, lowerCamel-cased (see the naming rule in
  PORTING.md: `JSDocPropertyTags` -> `jsDocPropertyTags`). Data fields are never named like a Go
  method, because methods keep their capitalized Go names: `node.name` (field) vs `node:Name()`.
- Per-struct metatables: every Go data struct gets a Lua method table (`ast.Identifier`,
  `ast.ForInOrOfStatement`, `ast.SourceFile`, …) whose `__index` falls back to `ast.Node` (the
  generic `*Node` methods of `ast.go`). Methods Go defines on a data struct
  (`func (node *SourceFile) FileName()`) live in that struct's table, so they are callable on the
  node directly: `file:FileName()`. Kinds that share a Go struct (`ForInStatement`/`ForOfStatement`
  -> `ForInOrOfStatement`, `CaseClause`/`DefaultClause`, keyword tokens -> `Token`, …) share its
  metatable.
- Go embedding: the generated file declares every struct and its embedded bases with
  `ast.DefineStruct(name, embeds)`; `init.lua` calls `ast.FinalizeStructs()` after all files are
  loaded, which copies promoted methods of embedded bases into each struct table following Go's
  selector rule (the shallowest embedding depth wins). `NodeBase` embeds `NodeDefault`, which
  provides Go's `nodeData` defaults: `Name()`, `Modifiers()`, `DeclarationData()`, `FlowNodeData()`,
  `LocalsContainerData()`, … return nil, `ForEachChild` returns false, `VisitEachChild` returns the
  node, `Clone` returns nil. `XData()` accessors return the node itself when the struct embeds the
  base. Other packages must not add methods to ast struct tables (they would not propagate).
- Generic accessors on `ast.Node` keep the Go names: `node:Name()`, `node:Expression()`,
  `node:Type()`, `node:Initializer()`, `node:Body()`, `node:Parameters()`, `node:TypeParameters()`,
  `node:Modifiers()`, `node:ModifierFlags()`, `node:Arguments()`, `node:Statements()`,
  `node:Members()`, `node:Text()`, `node:Symbol()`, `node:Locals()`, `node:FlowNodeData()`, …
  They behave exactly as the Go ones: they return `nil` where Go returns nil and `error(...)` where
  Go panics ("Unhandled case in Node.X"). Node-slice accessors (`Arguments()`, `TypeArguments()`,
  `TypeParameters()`, `Statements()`, `Members()`, `Elements()`, `Comments()`, `Decorators()`,
  `ModifierNodes()`, …) return `list.nodes`, or `nil` when the Go list is nil (Go code sometimes
  tests `TypeParameters() == nil`). `ipairs(nil)` errors in Lua, so iterate possibly-nil slices with
  `ipairs(xs or {})` / `core.Len(xs)`.
- `AsX()` returns the node itself and errors unless the node's struct metatable is `ast.X` (Go's
  type assertion `n.data.(*X)`). `node:AsMutable()` returns the node; `SetModifiers`,
  `SetExpression`, `SetType`, `SetInitializer` are `ast.Node` methods.
- Methods whose Go receiver may be nil are also callable as plain functions:
  `ast.Node.GetResolutionModeOverride(node)` handles `node == nil` and returns `mode, ok`.
- Go functions returning `(T, bool)` return two Lua values
  (`local text, ok = ast.TryGetTextOfPropertyName(n)`).
- `file:Text()` on a SourceFile returns the source text (Go's generic `(*Node).Text()` would panic
  on a SourceFile; this is the only name shared by a `*Node` method and a node data method).
- `ast.Kind_String(kind)` is Go's `kind.String()` (`"KindIdentifier"`); `node:KindString()` too.
- `node:ForEachChild(v)`: `v(child) -> bool`, stop and return `true` when `v` returns true;
  same child order as Go (generated per struct; Go's Kind-switch dispatch is the metatable lookup).
  `ast.Visitor` is a plain function. `node:IterChildren()` returns a Lua iterator
  (`for child in node:IterChildren() do`). `ast.visit`, `ast.visitNodes`, `ast.visitNodeList`,
  `ast.visitModifiers` mirror Go's helpers.
- Node ids: `ast.GetNodeId(node)` (lazily assigned, monotonically increasing), `ast.GetSymbolId(symbol)`.
- Node identity: Lua table identity (`a == b`), usable as table keys.
- `ast.SetParseJSDocForNode(fn)` registers the parser's lazy JSDoc parser (`ast.parseJSDocForNode`);
  `node:JSDoc(file)` returns the cached/parsed JSDoc array or nil.
- Kind sets: `ast.kindSet(k1, k2, …)` builds a `{ [kind] = true }` lookup table (Lua helper used for
  Go `switch` statements over many kinds).

## NodeList / ModifierList

```lua
{ loc = core.TextRange, nodes = { n1, n2, ... } }                  -- ast.NodeList metatable
{ loc = core.TextRange, nodes = { ... }, modifierFlags = 0 }       -- ast.ModifierList metatable
```

Go `list.Nodes` -> `list.nodes` (a Lua array; nil if the factory was given nil), `list.Loc` ->
`list.loc`, `list.Pos()`/`End()` -> `list:Pos()`/`list:End()`, `list:HasTrailingComma()`,
`list:Clone(f)`. A nil Go `*NodeList` is `nil`. `ModifierList` inherits `NodeList` methods.

## Factory

`ast.NewNodeFactory(hooks)` returns a `NodeFactory` (`{ hooks, nodeCount, textCount }`).
Constructors and updaters keep Go names and parameter order exactly as in `ast_generated.go`
(Update takes every non-kind member, including data members such as `flags`):
`f:NewIdentifier(text)`, `f:NewPropertyAccessExpression(expression, questionDotToken, name, flags)`,
`f:UpdatePropertyAccessExpression(node, expression, questionDotToken, name, flags)`,
`f:NewNodeList(nodes)`, `f:NewModifierList(nodes)`, `f:NewToken(kind)`, `f:NewModifier(kind)`,
`f:NewSourceFile(opts, text, statements, endOfFileToken)`, … New nodes get `flags = 0` (plus masked
flag parameters, e.g. `flags & NodeFlags.OptionalChain`), `loc = core.UndefinedTextRange()`,
`parent = nil`, and Go zero values for primitive fields the factory does not set (`facts = 0`).
Pass Go zero values for unused parameters (`false`, `0`, `""`, or `nil` for pointers/lists).

`NodeFactoryHooks` is a plain table with lowerCamel Go field names:
`{ onCreate = fn(node), onUpdate = fn(node, original), onClone = fn(node, original) }` (each
optional); they are called like in Go (`ast.updateNode`, `ast.cloneNode`). Anything with an
`AsNodeFactory()` method is a `NodeFactoryCoercible` (`node:Clone(f)` calls
`f:AsNodeFactory():NewX(...)`). A derived factory that embeds `ast.NodeFactory` through its metatable
chain answers `AsNodeFactory()` with itself.

Visitors (`visitor.go`): `ast.NewNodeVisitor(visit, factory, hooks)` -> `{ visit, factory, hooks }`
(`ast.NodeVisitor` metatable) with `v:VisitNode`, `v:VisitNodes`, `v:VisitModifiers`, `v:VisitSlice`
(returns `result, changed`), `v:VisitEmbeddedStatement`, `v:VisitEachChild`, `v:VisitSourceFile`.
`NodeVisitorHooks` fields are lowerCamel Go names (`visitNode`, `visitToken`, `visitNodes`,
`visitModifiers`, `visitEmbeddedStatement`, `visitIterationBody`, `visitParameters`,
`visitFunctionBody`, `visitTopLevelStatements`), each `fn(nodeOrList, v)`. Generated
`node:VisitEachChild(v)` calls `v.factory:UpdateX(...)`. Deep clone (`deepclone.go`):
`f:DeepCloneNode(node)`, `f:DeepCloneReparse(node)`, `f:DeepCloneReparseModifiers(mods)`.

## SourceFile

`SourceFile` is a node (`kind = Kind.SourceFile`, metatable `ast.SourceFile`) whose table also
carries the Go `SourceFile` fields (`text`, `fileName`, `parseOptions`, `languageVariant`,
`scriptKind`, `isDeclarationFile`, `statements`, `endOfFileToken`, `diagnostics`, `jsDiagnostics`,
`bindDiagnostics`, `jsdocDiagnostics`, `externalModuleIndicator`, `commonJSModuleIndicator`,
`imports`, `moduleAugmentations`, `ambientModuleNames`, `commentDirectives`, `pragmas`,
`referencedFiles`, `typeReferenceDirectives`, `libReferenceDirectives`, `checkJsDirective`,
`reparsedClones`, `patternAmbientModules`, `globalExports`, `nodeCount`, `textCount`,
`identifierCount`, `symbolCount`, `usesUriStyleNodeCoreModules`, `isBound`, `hasLazyJSDoc`,
`jsdocCache` (table keyed by node), `symbol`, `locals`, …) and methods (`file:FileName()`,
`file:Path()`, `file:Text()`, `file:ECMALineMap()`, `file:Diagnostics()`, `file:SetDiagnostics(d)`,
`file:BindOnce(fn)`, `file:IsBound()`, `file:GetOrCreateToken(...)`, `file:GetNameTable()`, …).
Go `sync.Once` fields are booleans; mutexes/atomics are dropped.

- `SourceFileParseOptions` is `{ fileName, path, externalModuleIndicatorOptions = { jsx, force } }`
  (`ast.NewSourceFileParseOptions(fileName, path, emio)`, `ast.NewExternalModuleIndicatorOptions`).
- `SourceFileMetaData`: `{ packageJsonType, packageJsonDirectory, impliedNodeFormat }`.
- `FileReference`, `CommentRange`, `PragmaArgument`, `Pragma` embed `core.TextRange` (`pos`, `end_`
  plus their fields; TextRange methods via the metatable): `ast.NewFileReference(pos, end_, fileName,
  resolutionMode, preserve)`, `ast.NewCommentRangeValue(kind, pos, end_, hasTrailingNewLine)` (= Go
  `f.NewCommentRange`), `ast.NewPragmaArgument(pos, end_, name, value)`,
  `ast.NewPragma(commentRange, name, args)` (`args` is a table name -> PragmaArgument).
- `CommentDirective`: `{ loc, kind }`; `CheckJsDirective`: `{ enabled, range }`.
- `ast.NewSourceFileDataKey()` / `ast.GetOrComputeSourceFileData(file, key, compute)` as in Go.

## Symbol, SymbolTable, flow nodes, diagnostics

- `ast.Symbol` (`symbol.go`): fields `flags`, `checkFlags`, `name`, `declarations` (array or nil),
  `valueDeclaration`, `members`, `exports`, `id`, `parent`, `exportSymbol` (exactly Go's fields).
  Constructed with `ast.NewSymbol(flags, name)` (zero values filled in; Go's `&ast.Symbol{...}`).
  Packages that need more per-symbol state keep it in their own tables.
- `ast.SymbolTable` = Go `map[string]*Symbol` = a plain Lua table `name -> symbol`
  (`ast.NewSymbolTable()` returns `{}`). Iteration order must not matter (Go's doesn't).
  Go's pointer-taking `GetSymbolTable(&x.Members)` is `ast.GetSymbolTable(owner, "members")`;
  `ast.GetMembers(s)`, `ast.GetExports(s)`, `ast.GetLocals(container)` are as in Go.
- `ast.FlowNode` (`flow.go`): `{ flags, node, antecedent, antecedents }` (plain table or
  `ast.NewFlowNode(flags, node, antecedent, antecedents)`); `ast.FlowList`: `{ flow, next }`.
  `ast.NewFlowSwitchClauseData(switchStatement, clauseStart, clauseEnd)` and
  `ast.NewFlowReduceLabelData(target, antecedents)` are synthetic nodes as in Go.
- `ast.Diagnostic` (`diagnostic.go`): constructed with `ast.NewDiagnostic(file, loc, message,
  args...)` (also `NewDiagnosticChain`, `NewCompilerDiagnostic`, `NewExternalDiagnostic`,
  `NewDiagnosticFromSerialized`), methods `d:Code()`, `d:Category()`, `d:Loc()`, `d:Pos()`,
  `d:End()`, `d:Len()`, `d:File()`, `d:MessageKey()`, `d:MessageArgs()`, `d:MessageChain()`,
  `d:RelatedInformation()`, `d:Localize(locale)`, `d:String()`, `d:AddMessageChain(c)`,
  `d:AddRelatedInfo(r)`, … same as Go (Go has no `Message()` accessor; the field is `d.message`).
  `ast.NewDiagnosticsCollection()` is Go's zero `DiagnosticsCollection{}`;
  `ast.CompareDiagnostics`, `ast.EqualDiagnostics` as in Go.
- `ast.PositionMap` (`positionmap.go`): `ast.ComputePositionMap(text)`, `pm:UTF8ToUTF16(n)`,
  `pm:UTF16ToUTF8(n)`.
- `core.TextRange`: immutable `{ pos = 0, end_ = 0 }` with `Pos()`, `End()`, `Len()`,
  `ContainsInclusive(pos)`, … `core.NewTextRange(pos, end_)`, `core.UndefinedTextRange()`
  (`-1, -1`).
