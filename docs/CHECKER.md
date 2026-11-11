# `tslua.checker` layout and data contract

Go originals: `vendor/typescript-go/internal/checker/*.go`. This file is binding for everyone
porting checker code. It complements [PORTING.md](PORTING.md) and [AST.md](AST.md).

## Files

`src/tslua/checker/init.lua` creates the package table, registers it in `package.loaded`,
merges `consts_generated.lua`, creates the `checker.Checker` class table (so every file can
cache it at load time), then requires the files in the order below. Every file starts with

```lua
local checker = require("tslua.checker")
local Checker = checker.Checker
```

and then requires the other packages it needs (`tslua.ast`, `tslua.core`, ...).

### `checker.go` (32296 lines) split by line range

Split points are top-level declaration boundaries (leading doc comments belong to the
declaration that follows them). Port each Go range into the Lua file, keeping Go order.

| Lua file | Go lines | Go line count | first func | last func |
| --- | --- | --- | --- | --- |
| `checker_1.lua` | 1–3476 | 3476 | `NewChecker` | `checkFunctionOrConstructorSymbol` |
| `checker_2.lua` | 3477–7180 | 3704 | `checkFunctionOrConstructorSymbolWorker` | `reportUnusedVariable` |
| `checker_3.lua` | 7181–10749 | 3569 | `reportUnused` | `checkExpressionWithTypeArguments` |
| `checker_4.lua` | 10750–14357 | 3608 | `getInstantiationExpressionType` | `addDuplicateDeclarationError` |
| `checker_5.lua` | 14358–17947 | 3590 | `createDiagnosticForNode` | `getRestType` |
| `checker_6.lua` | 17948–21536 | 3589 | `getFlowTypeOfDestructuring` | `getPropertyOfUnionOrIntersectionType` |
| `checker_7.lua` | 21537–25121 | 3585 | `getUnionOrIntersectionProperty` | `getImpliedConstraint` |
| `checker_8.lua` | 25122–28698 | 3577 | `isUnaryTupleTypeNode` | `markExportSpecifierAliasReferenced` |
| `checker_9.lua` | 28699–32296 | 3598 | `checkExternalEmitHelpers` | `GetAliasedSymbol` |

`checker_1.lua` also holds the type declarations at the top of `checker.go` (struct classes,
map-key functions, `SignatureKey*`, `intrinsicTypeKinds`, ...).

### Other Go files

| Go file | Lines | Lua file(s) | Notes |
| --- | --- | --- | --- |
| `types.go` | 1474 | `types.lua` | `Type`, type data classes, `Signature`, `IndexInfo`, ... |
| `links.go` | 50 | `links.lua` | also hosts `checker.LinkStore` (stand-in for `core.LinkStore`) |
| `mapper.go` | 326 | `mapper.lua` | |
| `stringer_generated.go` | 25 | `stringer_generated.lua` | `checker.SignatureKind_String` |
| `utilities.go` | 1868 | `utilities.lua` | |
| `relater.go` | 5044 | `relater_1.lua` (1–2530, `asRecursionId` … `isValidTypeForTemplateLiteralPlaceholder`), `relater_2.lua` (2531–5044, `isMemberOfStringMapping` … `traceUnionsOrIntersectionsTooLarge`) | |
| `flow.go` | 2764 | `flow.lua` | |
| `inference.go` | 1684 | `inference.lua` | |
| `grammarchecks.go` | 2185 | `grammarchecks.lua` | |
| `jsx.go` | 1488 | `jsx.lua` | |
| `emitresolver.go` | 1330 | `emitresolver.lua` | |
| `services.go` | 1140 | `services.lua` | |
| `exports.go` | 373 | `exports.lua` | |
| `printer.go` | 356 | `printer.lua` | |
| `nodebuilder.go` | 302 | `nodebuilder.lua` | |
| `nodebuilderimpl.go` | 3637 | `nodebuilderimpl.lua` | split into `_1`/`_2` if the Lua exceeds ~4000 lines |
| `nodebuilderscopes.go` | 251 | `nodebuilderscopes.lua` | |
| `nodebuilder_hover.go` | 597 | `nodebuilder_hover.lua` | `isExpanding` is used by nodebuilderimpl |
| `nodecopy.go` | 900 | `nodecopy.lua` | |
| `pseudotypenodebuilder.go` | 765 | `pseudotypenodebuilder.lua` | |
| `symbolaccessibility.go` | 876 | `symbolaccessibility.lua` | |
| `symboltracker.go` | 129 | `symboltracker.lua` | |
| `jsdoc.go` | 100 | `jsdoc.lua` | |
| `tracer.go` | 366 | — | out of scope (`--generateTrace`); `c.tracer` is always `nil` |
| `*_test.go` | | — | not ported |

Load order in `init.lua`: `types`, `links`, `mapper`, `stringer_generated`, `utilities`,
`checker_1` … `checker_9`, `relater_1`, `relater_2`, `flow`, `inference`, `grammarchecks`,
`jsx`, `emitresolver`, `services`, `exports`, `printer`, `nodebuilder`, `nodebuilderimpl`,
`nodebuilderscopes`, `nodebuilder_hover`, `nodecopy`, `pseudotypenodebuilder`,
`symbolaccessibility`, `symboltracker`, `jsdoc`. Class tables defined in `types.lua`,
`links.lua` and `mapper.lua` may be cached in file-level locals (they load first); anything
else must be accessed through `checker.X` at call time.

## Checker

```lua
local Checker = checker.Checker          -- class table, created in init.lua
function checker.NewChecker(program, tracer) ... return c, c.mu end
function Checker:getTypeOfSymbol(symbol) ... end
```

- All fields of the Go `Checker` struct are initialized in `checker.NewChecker` (numbers `0`,
  bools `false`, strings `""`, maps `{}` where Go `make`s them or where Go relies on a zero-value
  map being writable). Exported fields are lowerCamel: `TypeCount` -> `typeCount`,
  `SymbolCount` -> `symbolCount`, `SignatureCount` -> `signatureCount`,
  `TotalInstantiationCount` -> `totalInstantiationCount`,
  `ReverseMappedSymbolLinks` -> `reverseMappedSymbolLinks`. `_jsxNamespace` keeps its name.
- **Function-valued fields are called with a dot**: Go `c.getGlobalPromiseType()` ->
  `c.getGlobalPromiseType()`, `c.resolveName(...)` -> `c.resolveName(...)`,
  `c.compareTypesAssignable(s, t, r)`, `c.isPrimitiveOrObjectOrEmptyType(t)`. Methods are called
  with a colon. Go never has a field and a method of the same name, so there is no clash.
- **Go method values** (`c.getTypeOfSymbol` passed as a func, `core.Map(xs, c.getTypeOfSymbol)`)
  become closures: `function(s) return c:getTypeOfSymbol(s) end`.
- `c.mu` is a no-op mutex (`Lock`, `Unlock`, `TryLock`) returned as NewChecker's second result.
- `c.diagnostics` / `c.suggestionDiagnostics` are `ast.DiagnosticsCollection` values;
  `c.factory` is an `ast.NodeFactory`.

## Structs: classes and `X_new`

Every Go struct `X` of the checker that has methods or is instantiated gets a class table
`checker.X` (`X.__index = X`) and a constructor `checker.X_new(init)`:

```lua
-- Go: &TypePredicate{kind: k, parameterIndex: i, parameterName: n, t: t}
checker.TypePredicate_new({ kind = k, parameterIndex = i, parameterName = n, t = t })
-- Go: &IntrinsicType{}
checker.IntrinsicType_new()
```

`X_new(init)` returns a fresh table with metatable `checker.X`, every numeric / bool / string
field (including those of embedded structs) set to its Go zero value, then the fields of `init`
(optional) copied over. Classes are created with `checker.defineStruct(name, base, zeroFields)`
(in `types.lua`); `base` is the embedded struct class (method lookup falls back to it, like Go
embedding), and the zero fields of `base` are inherited. Use this for new structs in other
files as well (e.g. `Relation`, `InferenceState`, `FlowState`, `NodeBuilderContext`).

Go value structs that are copied (`TupleElementInfo`, `IterationTypes`, `ContextualInfo`, ...)
are treated as immutable tables: build a new one instead of mutating.

## Type

A type is **one flat Lua table**: the fields of Go's `Type` plus the fields of its data struct
(and the data struct's embedded structs), lowerCamelCase as in Go:

```lua
{
    flags = TypeFlags...,        -- checker.TypeFlags
    objectFlags = 0,             -- checker.ObjectFlags (and the top-level ObjectFlagsXxx consts)
    id = 17,                     -- TypeId (1, 2, ... per checker)
    symbol = <ast.Symbol or nil>,
    alias = <TypeAlias or nil>,
    checker = <Checker>,
    data = <the table itself>,   -- Go t.data; kept so `t.data` reads work
    -- data struct fields, e.g. for an InterfaceType (embeds TypeReference > ObjectType >
    -- StructuredType > ConstrainedType > TypeBase):
    resolvedBaseConstraint = nil,
    members = nil, properties = nil, signatures = nil, callSignatureCount = 0, indexInfos = nil,
    objectTypeWithoutAbstractConstructSignatures = nil,
    target = nil, mapper = nil, instantiations = nil,
    node = nil, resolvedTypeArguments = nil,
    allTypeParameters = nil, outerTypeParameterCount = 0, thisType = nil,
    baseTypesResolved = false, declaredMembersResolved = false, ...
}
```

- The metatable of a type is the class of its Go data struct: `checker.IntrinsicType`,
  `LiteralType`, `UniqueESSymbolType`, `ObjectType`, `TypeReference`, `InterfaceType`,
  `TupleType`, `InstantiationExpressionType`, `MappedType`, `ReverseMappedType`,
  `EvolvingArrayType`, `UnionType`, `IntersectionType`, `TypeParameter`, `IndexType`,
  `IndexedAccessType`, `TemplateLiteralType`, `StringMappingType`, `SubstitutionType`,
  `ConditionalType`. Abstract bases: `checker.TypeBase` (whose `__index` falls back to
  `checker.Type`, the `*Type` methods), `ConstrainedType`, `StructuredType`,
  `UnionOrIntersectionType`. The class chain mirrors Go embedding exactly.
- Types are created only through `c:newType(flags, objectFlags, data)` with
  `data = checker.XxxType_new()`; `newType` fills in the `Type` fields and returns `data`.
- Go `t.flags`, `t.objectFlags`, `t.id`, `t.symbol`, `t.alias` -> same names.
- Concrete casts return the table itself and assert the class: `t:AsUnionType()`,
  `t:AsLiteralType()`, `t:AsTypeParameter()`, ... Field access through a cast or directly is
  equivalent: Go `t.AsLiteralType().value` -> `t:AsLiteralType().value` or `t.value`.
- Embedded casts behave like Go (return the table or `nil`): `t:AsObjectType()`,
  `t:AsStructuredType()`, `t:AsConstrainedType()`, `t:AsTypeReference()`,
  `t:AsInterfaceType()`, `t:AsUnionOrIntersectionType()`. So Go
  `if d := t.AsStructuredType(); d != nil` ports directly.
- Methods keep Go names: `t:Id()`, `t:Flags()`, `t:ObjectFlags()`, `t:Target()`, `t:Mapper()`,
  `t:Types()`, `t:Symbol()`, `t:Alias()`, `t:Distributed()`, `t:IsUnion()`, ...,
  `t:IntrinsicName()`, `t:Value()`, `t:FreshType()`, `t:RegularType()`, `t:CallSignatures()`,
  `t:ConstructSignatures()`, `t:Properties()`, `t:OuterTypeParameters()`,
  `t:LocalTypeParameters()`, `t:TypeParameters()`, `t:FixedLength()`, `t:IsReadonly()`,
  `t:ElementFlags()`, `t:ElementInfos()`, `t:IsThisType()`, `t:ObjectType()`, `t:IndexType()`,
  `t:Texts()`, `t:BaseType()`, `t:SubstConstraint()`, `t:CheckType()`, `t:ExtendsType()`.
- No field name of a data struct collides with a `Type` field. Field names that exist in
  several data structs (`target`, `mapper`, `types`, `constraint`, `resolvedApparentType`,
  `node`, `declaration`) are distinct per class, a type only ever has one data struct.
- `LiteralType.value`: Lua string (string literal), Lua **float** (jsnum.Number; use
  `jsnum` helpers), boolean, `jsnum.PseudoBigInt` table, or `nil` (computed enum).
  Type switches on the value use `type(v)` (`"string"`, `"number"`, `"boolean"`) and
  `getmetatable(v) == jsnum.PseudoBigInt` (or `jsnum`'s own predicate).
- `TupleType.elementInfos`: array of `TupleElementInfo` tables `{ flags = ElementFlags,
  labeledDeclaration = node or nil }` (class `checker.TupleElementInfo`).
- `StructuredType.signatures` holds call then construct signatures; `callSignatureCount` is the
  0-based split point, as in Go.
- `InterfaceType.allTypeParameters` = outer + local + `thisType`, as in Go.

## Signature, IndexInfo, TypePredicate, TypeAlias, ...

```lua
-- checker.Signature
{ id = 0, flags = 0, minArgumentCount = 0, resolvedMinArgumentCount = 0, declaration = nil,
  typeParameters = nil, parameters = nil, thisParameter = nil, resolvedReturnType = nil,
  resolvedTypePredicate = nil, target = nil, mapper = nil, isolatedSignatureType = nil,
  composite = nil }
-- checker.CompositeSignature  { isUnion = false, signatures = {...} }
-- checker.TypePredicate       { kind = TypePredicateKind, parameterIndex = 0, parameterName = "", t = type }
-- checker.IndexInfo           { keyType, valueType, isReadonly = false, declaration, indexSymbol, components }
-- checker.TypeAlias           { symbol, typeArguments }
-- checker.ConditionalRoot     { node, checkType, extendsType, isDistributive = false,
--                               inferTypeParameters, outerTypeParameters, instantiations, alias }
```

Go `c.signatureArena.New()` / `c.indexInfoArena.New()` -> `checker.Signature_new()` /
`checker.IndexInfo_new()`. Methods: `sig:Id()`, `sig:Flags()`, `sig:TypeParameters()`,
`sig:Declaration()`, `sig:Target()`, `sig:ThisParameter()`, `sig:Parameters()`,
`sig:HasRestParameter()`, `sig:MinArgumentCount()`; `info:KeyType()`, `info:ValueType()`,
`info:IsReadonly()`, `info:Declaration()`; `pred:Type()`, `pred:Kind()`,
`pred:ParameterIndex()`, `pred:ParameterName()`; nil-safe `checker.TypeAlias.Symbol(a)` /
`checker.TypeAlias.TypeArguments(a)` (Go allows calling them on a nil `*TypeAlias`; in Lua call
them through the class: `checker.TypeAlias.Symbol(t.alias)`).

## TypeMapper

A mapper is one flat table whose class is the concrete Go mapper struct
(`checker.SimpleTypeMapper`, `ArrayTypeMapper`, `ArrayToSingleTypeMapper`,
`DeferredTypeMapper`, `FunctionTypeMapper`, `MergedTypeMapper`, `CompositeTypeMapper`,
`InferenceTypeMapper`), all based on `checker.TypeMapperBase` -> `checker.TypeMapper`.
`m.data == m` (so Go `m.data.(*SimpleTypeMapper)` -> `m.data`). Methods: `m:Map(t)`,
`m:Kind()`, `m:MapsThisOnly()`. Fields as in Go (`source`, `target`, `sources`, `targets`,
`fn`, `m1`, `m2`, `c`, `n`, `fixing`). `DeferredTypeMapper.targets` is an array of functions.

## Links

`links.lua` defines `checker.LinkStore` (Lua stand-in for `core.LinkStore[K, V]`,
`nodeLinkStore[V]` and `symbolArenaLinkStore[V]`): a store keyed by the node / symbol /
source file table itself.

```lua
c.nodeLinks = checker.NewLinkStore(checker.NodeLinks_new)
local links = c.nodeLinks:Get(node)   -- get-or-create (zero-valued via the factory)
c.nodeLinks:TryGet(node)              -- nil if absent
c.nodeLinks:Has(node)
```

`MembersAndExportsLinks` (Go `[2]ast.SymbolTable` indexed by `MembersOrExportsResolutionKind`)
is a table `{ [1] = resolvedExports, [2] = resolvedMembers }`: Go `links[kind]` ->
`links[kind + 1]`. `ComputedNameNodeLinks.hasName` (`*bool`) is `nil` / `true` / `false`.
Link structs live in `types.lua` with `X_new` constructors (`checker.ValueSymbolLinks_new`, ...).

## Map keys

- Go maps keyed by pointers (`map[*ast.Symbol]*Type`, `map[*Type]*Type`, `map[*ast.Node]...`)
  use the table itself as key.
- Go maps keyed by a **struct** use a string built by a key function named like the Go struct,
  with the fields in Go declaration order: `c.cachedTypes[checker.CachedTypeKey(kind, t.id)]`,
  `checker.NarrowedTypeKey(t, candidate, assumeTrue, checkDerived)`, ... Pointer fields are
  encoded by id (`t.id`, `sig.id`, `ast.GetNodeId(n)`, `ast.GetSymbolId(s)`, or
  `checker.getObjectKeyId(x)` for objects without an id such as flow nodes). The key functions
  for the key structs at the top of `checker.go` are in `checker_1.lua`; write the others
  (`InferenceKey`, `accessibleChainCacheKey`, ...) the same way next to their Go declaration.
- `CacheHashKey` (Go: xxh3 128-bit hash of the bytes written by a `keyBuilder`) is in Lua the
  **unhashed** byte string, prefixed with `"h"`: `keyBuilder:hash()` returns `"h" .. bytes`,
  `SignatureKeyErased == "h-"`, `SignatureKeyCanonical == "h*"`, `SignatureKeyBase == "h#"`,
  `SignatureKeyInner == "h<"`, `SignatureKeyOuter == "h>"`. The zero `CacheHashKey` is `""`;
  `checker.CacheHashKey_IsZero(k)` returns `k == nil or k == ""`.
- `map[jsnum.Number]*Type`: float keys (Lua folds `-0.0`/`0.0` like Go). NaN is never used as
  a key (Lua raises on NaN keys; Go code already handles NaN through `nanType` /
  `enumNaNLiteralTypes`).

## Scalar-type methods

Per PORTING.md: `checker.TypeFlags_String(f)`, `checker.FormatTypeFlags(f)`,
`checker.VarianceFlags_String(v)`, `checker.SignatureKind_String(k)`,
`checker.CacheHashKey_IsZero(k)`. Constants: `checker.TypeFlags.Object`,
`checker.ObjectFlags.Reference`, top-level `checker.ObjectFlagsContainsSpread` etc. (untyped
Go constants), `checker.Ternary.True` (= -1), `checker.TypeFormatFlags.NodeBuilderFlagsMask`.
