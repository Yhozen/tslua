package main

import (
	"fmt"
	"go/ast"
	"go/types"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type fieldEntry struct {
	key   string
	value string
}

func (g *gen) table(entries []string) string {
	total := 0
	multi := false
	for _, e := range entries {
		total += len(e) + 2
		if strings.Contains(e, "\n") {
			multi = true
		}
	}
	if len(entries) == 0 {
		return "{}"
	}
	if !multi && total+g.ind*4 < 110 {
		return "{ " + strings.Join(entries, ", ") + " }"
	}
	inner := strings.Repeat("    ", g.ind+1)
	var b strings.Builder
	b.WriteString("{\n")
	for _, e := range entries {
		b.WriteString(inner)
		b.WriteString(e)
		b.WriteString(",\n")
	}
	b.WriteString(g.indent())
	b.WriteString("}")
	return b.String()
}

func (g *gen) compositeLit(e *ast.CompositeLit, _ types.Type) string {
	t := g.info.TypeOf(e)
	if p, ok := t.Underlying().(*types.Pointer); ok {
		t = p.Elem()
	}
	if named, ok := t.(*types.Named); ok && named.Obj().Pkg() != nil && named.Obj().Pkg().Path() == "strings" && named.Obj().Name() == "Builder" {
		return g.gort() + ".NewBuilder()"
	}
	switch u := t.Underlying().(type) {
	case *types.Struct:
		if _, isNamed := t.(*types.Named); u.NumFields() == 0 && !isNamed {
			if g.isPkg {
				return g.pkgName + ".Ignored"
			}
			return g.require("tslua.fourslash", "fourslash") + ".Ignored"
		}
		g.ind++
		entries := g.structEntries(e, u)
		g.ind--
		return g.structLit(t, u, entries, e)
	case *types.Slice, *types.Array:
		var elems []string
		g.ind++
		for _, el := range e.Elts {
			if _, ok := el.(*ast.KeyValueExpr); ok {
				elems = append(elems, g.fail(el, "keyed slice literal"))
				continue
			}
			s := g.expr(el)
			if s == "nil" {
				s = g.fail(el, "nil element in slice literal")
			}
			elems = append(elems, s)
		}
		g.ind--
		return g.table(elems)
	case *types.Map:
		var elems []string
		g.ind++
		for _, el := range e.Elts {
			kv := el.(*ast.KeyValueExpr)
			elems = append(elems, "["+g.mapKey(u, kv.Key)+"] = "+g.expr(kv.Value))
		}
		g.ind--
		return g.table(elems)
	}
	return g.fail(e, "composite literal of %s", t)
}

func (g *gen) structEntries(e *ast.CompositeLit, st *types.Struct) []fieldEntry {
	var entries []fieldEntry
	for i, el := range e.Elts {
		var f *types.Var
		var val ast.Expr
		if kv, ok := el.(*ast.KeyValueExpr); ok {
			name := kv.Key.(*ast.Ident).Name
			for j := 0; j < st.NumFields(); j++ {
				if st.Field(j).Name() == name {
					f = st.Field(j)
				}
			}
			val = kv.Value
		} else {
			f = st.Field(i)
			val = el
		}
		if f == nil {
			entries = append(entries, fieldEntry{"_", g.fail(el, "unknown field")})
			continue
		}
		if f.Embedded() {
			inner, ok := ast.Unparen(val).(*ast.CompositeLit)
			ist, ok2 := derefStruct(f.Type())
			if ok && ok2 {
				entries = append(entries, g.structEntries(inner, ist)...)
				continue
			}
			// flattened embedded struct given as a value: its fields are copied in (gort.Embed)
			entries = append(entries, fieldEntry{"__embed", g.expr(val)})
			if ok2 {
				for j := 0; j < ist.NumFields(); j++ {
					entries = append(entries, fieldEntry{"__embedField", fieldLuaName(ist, ist.Field(j))})
				}
			}
			continue
		}
		v := g.expr(val)
		if v == "nil" {
			continue
		}
		entries = append(entries, fieldEntry{fieldLuaName(st, f), v})
	}
	return entries
}

func derefStruct(t types.Type) (*types.Struct, bool) {
	if p, ok := t.Underlying().(*types.Pointer); ok {
		t = p.Elem()
	}
	st, ok := t.Underlying().(*types.Struct)
	return st, ok
}

func hasMethods(named *types.Named) bool {
	return types.NewMethodSet(types.NewPointer(named)).Len() > 0
}

// needsZeroFill: the struct has fields whose Go zero value is not nil in Lua.
func needsZeroFill(st *types.Struct, seen map[*types.Struct]bool) bool {
	if seen[st] {
		return false
	}
	seen[st] = true
	for i := 0; i < st.NumFields(); i++ {
		ft := st.Field(i).Type()
		switch u := ft.Underlying().(type) {
		case *types.Basic:
			return true
		case *types.Struct:
			if st.Field(i).Embedded() {
				if needsZeroFill(u, seen) {
					return true
				}
			} else {
				return true
			}
		case *types.Array:
			return true
		}
	}
	return false
}

func zeroKey(named *types.Named) string {
	p := named.Obj().Pkg().Path()
	rel := strings.TrimPrefix(p, modulePrefix)
	return strings.ReplaceAll(strings.ReplaceAll(rel, "/", "_"), ".", "_") + "_" + named.Obj().Name()
}

func isExternalNamed(t types.Type, testPkg *types.Package) (*types.Named, bool) {
	named, ok := t.(*types.Named)
	if !ok || named.Obj().Pkg() == nil || named.Obj().Pkg() == testPkg {
		return nil, false
	}
	if _, ok := luaModule(named.Obj().Pkg().Path()); !ok {
		return nil, false
	}
	if named.Obj().Parent() != named.Obj().Pkg().Scope() {
		return nil, false
	}
	if named.TypeArgs().Len() > 0 {
		return nil, false
	}
	return named, true
}

func (g *gen) structLit(t types.Type, st *types.Struct, entries []fieldEntry, at ast.Node) string {
	var embeds []string
	var kept []fieldEntry
	for _, e := range entries {
		switch e.key {
		case "__embed":
			embeds = append(embeds, e.value)
		case "__embedField":
			kept = append(kept, fieldEntry{e.value, ""})
		default:
			kept = append(kept, e)
		}
	}
	if len(embeds) > 0 {
		// embedded fields come from the values: keep them out of the zero fill
		var real []fieldEntry
		set := map[string]bool{}
		for _, e := range kept {
			if e.value == "" {
				set[e.key] = true
			} else {
				real = append(real, e)
			}
		}
		g.ind++
		inner := g.structLitNoEmbed(t, st, real, at, set)
		g.ind--
		return g.gort() + ".Embed(" + inner + ", " + strings.Join(embeds, ", ") + ")"
	}
	return g.structLitNoEmbed(t, st, kept, at, nil)
}

func (g *gen) structLitNoEmbed(t types.Type, st *types.Struct, entries []fieldEntry, at ast.Node, skip map[string]bool) string {
	var parts []string
	for _, e := range entries {
		parts = append(parts, e.key+" = "+e.value)
	}
	for k := range skip {
		entries = append(entries, fieldEntry{k, ""})
	}
	if named, ok := isExternalNamed(t, g.pkg.Types); ok && named.Obj().Pkg().Path() == modulePrefix+"lsp/lsproto" {
		// lsproto structs and unions: the class call fills zero values and sets the metatable
		alias := g.pkgAlias(named.Obj().Pkg())
		if st.NumFields() == 0 {
			return alias + "." + named.Obj().Name()
		}
		return alias + "." + named.Obj().Name() + "(" + g.table(parts) + ")"
	}
	if named, ok := t.(*types.Named); ok && g.isPkg && named.Obj().Pkg() == g.pkg.Types && hasMethods(named) {
		defer func() {}()
		return "setmetatable(" + g.table(g.fillZero(st, parts, entries, at)) + ", " + g.pkgName + "." + named.Obj().Name() + ")"
	}
	if named, ok := isExternalNamed(t, g.pkg.Types); ok && !g.isPkg {
		if needsZeroFill(st, map[*types.Struct]bool{}) || hasMethods(named) {
			key := zeroKey(named)
			zeroTypes[key] = named
			g.usesZero = true
			if len(parts) == 0 {
				return "zero." + key + "()"
			}
			return "zero." + key + "(" + g.table(parts) + ")"
		}
		return g.table(parts)
	}
	if named, ok := isExternalNamed(t, g.pkg.Types); ok && g.isPkg && hasMethods(named) {
		return "setmetatable(" + g.table(g.fillZero(st, parts, entries, at)) + ", " + g.pkgAlias(named.Obj().Pkg()) + "." + named.Obj().Name() + ")"
	}
	return g.table(g.fillZero(st, parts, entries, at))
}

func (g *gen) fillZero(st *types.Struct, parts []string, entries []fieldEntry, at ast.Node) []string {
	// test-local or anonymous struct: fill zero fields inline
	set := map[string]bool{}
	for _, e := range entries {
		set[e.key] = true
	}
	var fill func(st *types.Struct)
	fill = func(st *types.Struct) {
		for i := 0; i < st.NumFields(); i++ {
			f := st.Field(i)
			if f.Embedded() {
				if est, ok := f.Type().Underlying().(*types.Struct); ok {
					fill(est)
				}
				continue
			}
			name := fieldLuaName(st, f)
			if set[name] {
				continue
			}
			z := g.zeroValue(f.Type(), at)
			if z != "nil" {
				parts = append(parts, name+" = "+z)
			}
		}
	}
	fill(st)
	return parts
}

// ---------------------------------------------------------------------------
// zero_generated.lua

func writeZeroModule() {
	if len(zeroTypes) == 0 {
		return
	}
	// close over struct-valued fields
	work := make([]*types.Named, 0, len(zeroTypes))
	for _, n := range zeroTypes {
		work = append(work, n)
	}
	for len(work) > 0 {
		n := work[len(work)-1]
		work = work[:len(work)-1]
		st := n.Underlying().(*types.Struct)
		var visit func(st *types.Struct)
		visit = func(st *types.Struct) {
			for i := 0; i < st.NumFields(); i++ {
				f := st.Field(i)
				if _, ok := f.Type().Underlying().(*types.Struct); !ok {
					continue
				}
				if f.Embedded() {
					visit(f.Type().Underlying().(*types.Struct))
					continue
				}
				if fn, ok := isExternalNamed(f.Type(), nil); ok {
					key := zeroKey(fn)
					if _, done := zeroTypes[key]; !done {
						zeroTypes[key] = fn
						work = append(work, fn)
					}
				}
			}
		}
		visit(st)
	}
	keys := make([]string, 0, len(zeroTypes))
	for k := range zeroTypes {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var b strings.Builder
	b.WriteString("-- Code generated by scripts/gen/fourslash.mjs. DO NOT EDIT.\n")
	b.WriteString("-- Zero-value constructors for the Go struct types the converted fourslash tests build with\n")
	b.WriteString("-- composite literals: M.<pkg>_<Type>(fields) fills every field whose Go zero value is not nil\n")
	b.WriteString("-- (numbers, strings, bools, nested value structs; embedded structs are flattened) and sets the\n")
	b.WriteString("-- Lua class of the type as metatable when the Go type has methods.\n")
	b.WriteString("local M = {}\n\n")
	b.WriteString("-- A Lua constructor <Type>_new(init) of the package takes precedence.\n")
	b.WriteString("local function ctor(mod, name)\n")
	b.WriteString("    return require(mod)[name .. \"_new\"]\n")
	b.WriteString("end\n\n")
	b.WriteString("local function mt(v, mod, name)\n")
	b.WriteString("    local class = require(mod)[name]\n")
	b.WriteString("    if type(class) == \"table\" and getmetatable(v) == nil then\n")
	b.WriteString("        setmetatable(v, class)\n")
	b.WriteString("    end\n")
	b.WriteString("    return v\n")
	b.WriteString("end\n")
	for _, k := range keys {
		n := zeroTypes[k]
		st := n.Underlying().(*types.Struct)
		fmt.Fprintf(&b, "\nfunction M.%s(v)\n", k)
		mod, _ := luaModule(n.Obj().Pkg().Path())
		fmt.Fprintf(&b, "    local new = ctor(%q, %q)\n", mod, n.Obj().Name())
		b.WriteString("    if new ~= nil then\n        return new(v or {})\n    end\n")
		b.WriteString("    v = v or {}\n")
		var fill func(st *types.Struct)
		fill = func(st *types.Struct) {
			for i := 0; i < st.NumFields(); i++ {
				f := st.Field(i)
				name := fieldLuaName(st, f)
				switch u := f.Type().Underlying().(type) {
				case *types.Basic:
					z := (&gen{}).scalarZero(f.Type())
					if z != "" {
						fmt.Fprintf(&b, "    if v.%s == nil then v.%s = %s end\n", name, name, z)
					}
				case *types.Struct:
					if f.Embedded() {
						fill(u)
						continue
					}
					if fn, ok := isExternalNamed(f.Type(), nil); ok {
						fmt.Fprintf(&b, "    if v.%s == nil then v.%s = M.%s() end\n", name, name, zeroKey(fn))
					} else if u.NumFields() == 0 {
						fmt.Fprintf(&b, "    if v.%s == nil then v.%s = {} end\n", name, name)
					}
				}
			}
		}
		fill(st)
		if hasMethods(n) {
			fmt.Fprintf(&b, "    return mt(v, %q, %q)\n", mod, n.Obj().Name())
		} else {
			b.WriteString("    return v\n")
		}
		b.WriteString("end\n")
	}
	b.WriteString("\nreturn M\n")
	out := filepath.Join(repoRoot, "src", "tslua", "fourslash", "tests", "zero_generated.lua")
	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		panic(err)
	}
	if err := os.WriteFile(out, []byte(b.String()), 0o644); err != nil {
		panic(err)
	}
}
