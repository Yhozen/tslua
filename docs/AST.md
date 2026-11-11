# `tslua.ast` contract

The contract between the AST package and everything that consumes it (scanner, parser, binder,
checker, printer, transformers). Go originals: `vendor/typescript-go/internal/ast/*.go`.
The ast agent implements it and keeps this file accurate; if reality has to deviate, update this
file in the same commit.

Most of the package is generated: `node scripts/gen/ast.mjs` reads
`vendor/typescript-go/_scripts/ast.json` (the schema Go's `ast_generated.go` comes from) and
writes `src/tslua/ast/ast_generated.lua`. Constants (`Kind`, `NodeFlags`, `ModifierFlags`,
`SymbolFlags`, `TokenFlags`, `FlowFlags`, `CheckFlags`, `SubtreeFacts`, `OperatorPrecedence`, …)
come from `consts_generated.lua`. Do not edit generated files.

## Node

A node is a single flat Lua table:

```lua
{
    kind = ast.Kind.PropertyAccessExpression, -- never changes
    flags = 0,                                -- ast.NodeFlags
    loc = core.TextRange,                     -- immutable {pos=, end_=}; replace, never mutate
    parent = <node or nil>,
    id = <lazily assigned by ast.GetNodeId>,
    -- data fields of the Go data struct, flattened, lowerCamelCase of the Go field name:
    expression = <node>,
    questionDotToken = <node or nil>,
    name = <node>,
}
```

- Go `node.Kind` -> `node.kind`, `node.Flags` -> `node.flags`, `node.Loc` -> `node.loc`,
  `node.Parent` -> `node.parent`, `node.Pos()` -> `node:Pos()`, `node.End()` -> `node:End()`.
- Data struct fields are flattened onto the node. Go `node.AsPropertyAccessExpression().Expression`
  -> `node.expression` (or `node:AsPropertyAccessExpression().expression`; `AsX()` returns the
  node itself and asserts the kind). Embedded base structs (`DeclarationBase`, `LocalsContainerBase`,
  `FlowNodeBase`, `ExportableBase`, `ModifiersBase`, `FunctionLikeBase`, `BodyBase`, …) are flattened
  too: `node.symbol`, `node.localSymbol`, `node.locals`, `node.nextContainer`, `node.flowNode`,
  `node.endFlowNode`, `node.modifiers`, `node.typeParameters`, `node.parameters`, `node.type`,
  `node.body`, `node.asteriskToken`, … Go private fields keep their lowerCamel name (`name`,
  `modifiers`).
- Field names come from `ast.json` member names, lowerCamel-cased (see the naming rule in
  PORTING.md). Data fields are never named like a Go method, because methods keep their
  capitalized Go names: `node.name` (field) vs `node:Name()` (generic accessor).
- Per-struct metatables: every Go data struct gets a Lua method table whose `__index` falls back to
  `ast.Node` (the generic `*Node` methods of `ast.go`). Methods Go defines on a data struct
  (`func (node *SourceFile) FileName()`) live in that struct's table (`ast.SourceFile`), so they are
  callable on the node directly: `file:FileName()`. Kinds that share a Go struct
  (`ForInStatement`/`ForOfStatement` -> `ForInOrOfStatement`, `CaseClause`/`DefaultClause`,
  keyword tokens -> `Token`, …) share its metatable.
- Generic accessors on `ast.Node` keep the Go names: `node:Name()`, `node:Expression()`,
  `node:Type()`, `node:Initializer()`, `node:Body()`, `node:Parameters()`, `node:TypeParameters()`,
  `node:Modifiers()`, `node:ModifierFlags()`, `node:Arguments()`, `node:Statements()`,
  `node:Members()`, `node:Text()`, `node:Symbol()`, `node:Locals()`, `node:FlowNodeData()`, …
  They behave exactly as the Go ones (return `nil` where Go returns nil; node-slice accessors
  return an array, possibly empty, never nil — check each one against Go).
- `node:ForEachChild(v)`: `v(child) -> bool`, stop and return `true` when `v` returns true;
  same child order as Go. `ast.Visitor` is a plain function.
- Node ids: `ast.GetNodeId(node)` (lazily assigned, monotonically increasing), `ast.GetSymbolId(symbol)`.
- Node identity: Lua table identity (`a == b`), usable as table keys.

## NodeList / ModifierList

```lua
{ loc = core.TextRange, nodes = { n1, n2, ... } }                  -- ast.NodeList metatable
{ loc = core.TextRange, nodes = { ... }, modifierFlags = 0 }       -- ast.ModifierList metatable
```

Go `list.Nodes` -> `list.nodes` (a Lua array), `list.Loc` -> `list.loc`, `list.Pos()`/`End()`
-> `list:Pos()`/`list:End()`. A nil Go `*NodeList` is `nil`.

## Factory

`ast.NewNodeFactory(hooks)` returns a `NodeFactory`. Constructors and updaters keep Go names
and parameter order: `f:NewIdentifier(text)`, `f:NewPropertyAccessExpression(expression,
questionDotToken, name, flags)`, `f:UpdatePropertyAccessExpression(node, expression,
questionDotToken, name)`, `f:NewNodeList(nodes)`, `f:NewModifierList(nodes)`, `f:NewToken(kind)`,
… New nodes get `flags = 0`, `loc = core.UndefinedTextRange()`, `parent = nil`. Hooks
(`OnCreate`, `OnUpdate`, `OnClone`) are called like in Go. Deep clone / update helpers
(`DeepCloneNode`, `f:UpdateNode`…) and visitors (`ast.NodeVisitor`, `VisitNode`, `VisitNodes`,
`VisitEachChild`) mirror `deepclone.go` / `visitor.go` / the generated `VisitEachChild` code.

## SourceFile

`SourceFile` is a node (`kind = Kind.SourceFile`) whose table also carries the Go `SourceFile`
fields (`text`, `fileName`, `path`, `languageVariant`, `scriptKind`, `isDeclarationFile`,
`statements`, `endOfFileToken`, `diagnostics`, `bindDiagnostics`, `jsdocDiagnostics`,
`externalModuleIndicator`, `commonJSModuleIndicator`, `imports`, `moduleAugmentations`,
`pragmas`, `referencedFiles`, `typeReferenceDirectives`, `libReferenceDirectives`,
`identifiers`, `nodeCount`, `identifierCount`, `symbolCount`, `classifiableNames`,
`endFlowNode`, `symbol`, `locals`, …) and methods (`file:FileName()`, `file:Path()`,
`file:Text()`, `file:ECMALineMap()`, `file:Diagnostics()`, …).

## Symbol, SymbolTable, flow nodes, diagnostics

- `ast.Symbol` (`symbol.go`): fields `flags`, `checkFlags`, `name`, `declarations` (array or nil),
  `valueDeclaration`, `members`, `exports`, `id`, `mergeId`, `parent`, `exportSymbol`,
  `constEnumOnlyModule`, `isReplaceableByMethod`, `globalExports`. Constructed with
  `ast.NewSymbol(flags, name)` (zero values filled in).
- `ast.SymbolTable` = Go `map[string]*Symbol` = a plain Lua table `name -> symbol`
  (`ast.NewSymbolTable()` returns `{}`). Iteration order must not matter (Go's doesn't).
- `ast.FlowNode` (`flow.go`): `{ flags, node, antecedent, antecedents }`; `ast.FlowList`:
  `{ flow, next }`.
- `ast.Diagnostic` (`diagnostic.go`): constructed with `ast.NewDiagnostic(file, loc, message,
  args...)`, methods `d:Code()`, `d:Category()`, `d:Message()`, `d:Loc()`, `d:Pos()`, `d:End()`,
  `d:Len()`, `d:File()`, `d:MessageChain()`, `d:RelatedInformation()`, …, same as Go.
- `core.TextRange`: immutable `{ pos = 0, end_ = 0 }` with `Pos()`, `End()`, `Len()`,
  `ContainsInclusive(pos)`, … `core.NewTextRange(pos, end_)`, `core.UndefinedTextRange()`
  (`-1, -1`).
