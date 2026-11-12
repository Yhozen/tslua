// Command fourslash converts the Go fourslash tests of typescript-go
// (internal/fourslash/tests/{gen,manual,.}/*_test.go and the tests/util package)
// into Lua test files driving tslua.fourslash. It is a type-directed Go -> Lua
// translator for the (small) subset of Go used by those tests: go/types tells
// struct literals from maps and slices, constants from variables, methods on
// named scalar types, and so on, following docs/PORTING.md.
//
// Usage: go run . <typescript-go dir> <repo dir>
// (normally through scripts/gen/fourslash.mjs).
package main

import (
	"fmt"
	"go/ast"
	"go/token"
	"go/types"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"golang.org/x/tools/go/packages"
)

const modulePrefix = "github.com/microsoft/typescript-go/internal/"

var tsgoRoot, repoRoot string

// zeroTypes collects every struct type that needs a zero-value constructor in
// src/tslua/fourslash/tests/zero_generated.lua, keyed by its Lua function name.
var zeroTypes = map[string]*types.Named{}
var zeroAnon = map[string]*types.Struct{}

var failures []string

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: fourslash <typescript-go dir> <repo dir> [file filter]")
		os.Exit(2)
	}
	tsgoRoot, _ = filepath.Abs(os.Args[1])
	repoRoot, _ = filepath.Abs(os.Args[2])
	filter := ""
	if len(os.Args) > 3 {
		filter = os.Args[3]
	}
	if filter == "-pkg" {
		convertPackage(os.Args[4], os.Args[5])
		for _, f := range failures {
			fmt.Fprintln(os.Stderr, "unsupported:", f)
		}
		return
	}
	cfg := &packages.Config{
		Mode:  packages.NeedName | packages.NeedFiles | packages.NeedSyntax | packages.NeedTypes | packages.NeedTypesInfo,
		Dir:   tsgoRoot,
		Tests: true,
	}
	pkgs, err := packages.Load(cfg, "./internal/fourslash/tests/...")
	if err != nil {
		panic(err)
	}
	done := map[string]bool{}
	count := 0
	for _, p := range pkgs {
		for _, e := range p.Errors {
			fmt.Fprintln(os.Stderr, "load:", e)
		}
		for i, file := range p.Syntax {
			_ = i
			path := p.Fset.Position(file.Pos()).Filename
			if done[path] || !strings.HasSuffix(path, ".go") {
				continue
			}
			rel, _ := filepath.Rel(filepath.Join(tsgoRoot, "internal", "fourslash", "tests"), path)
			isUtil := strings.HasPrefix(rel, "util"+string(filepath.Separator))
			if !isUtil && !strings.HasSuffix(path, "_test.go") {
				continue
			}
			if strings.HasSuffix(path, "testmain_test.go") {
				done[path] = true
				continue
			}
			if filter != "" && !strings.Contains(rel, filter) {
				continue
			}
			done[path] = true
			var outPath string
			dir, base := filepath.Split(rel)
			lua := strings.TrimSuffix(base, ".go") + ".lua"
			switch filepath.Clean(dir) {
			case "gen":
				outPath = filepath.Join(repoRoot, "tests", "fourslash", "gen", lua)
			case "manual":
				outPath = filepath.Join(repoRoot, "tests", "fourslash", "manual", lua)
			case ".":
				outPath = filepath.Join(repoRoot, "tests", "fourslash", "tests", lua)
			case "util":
				outPath = filepath.Join(repoRoot, "src", "tslua", "fourslash", "tests", "util", lua)
			default:
				continue
			}
			goRel, _ := filepath.Rel(tsgoRoot, path)
			g := newGen(p, file, filepath.ToSlash(goRel), isUtil)
			text := g.convertFile()
			if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
				panic(err)
			}
			if err := os.WriteFile(outPath, []byte(text), 0o644); err != nil {
				panic(err)
			}
			count++
		}
	}
	if filter == "" {
		writeZeroModule()
		writeUtilInit()
	}
	fmt.Fprintf(os.Stderr, "converted %d files\n", count)
	if len(failures) > 0 {
		sort.Strings(failures)
		for _, f := range failures {
			fmt.Fprintln(os.Stderr, "unsupported:", f)
		}
		fmt.Fprintf(os.Stderr, "%d unsupported constructs\n", len(failures))
	}
}

// ---------------------------------------------------------------------------
// naming

var luaKeywords = map[string]bool{
	"and": true, "break": true, "do": true, "else": true, "elseif": true, "end": true,
	"false": true, "for": true, "function": true, "goto": true, "if": true, "in": true,
	"local": true, "nil": true, "not": true, "or": true, "repeat": true, "return": true,
	"then": true, "true": true, "until": true, "while": true,
}

// Lua globals the generated code relies on; Go locals with these names are renamed.
var reservedLocals = map[string]bool{
	"gort": true, "zero": true, "string": true, "table": true, "ipairs": true, "pairs": true,
	"select": true, "error": true, "setmetatable": true, "getmetatable": true, "type": true,
	"next": true, "print": true, "require": true, "math": true, "utf8": true, "tostring": true,
	"tonumber": true, "rawget": true, "rawset": true, "rawequal": true, "pcall": true, "xpcall": true,
	"tests": true, "P": true,
}

func luaName(s string) string {
	if luaKeywords[s] {
		return s + "_"
	}
	return s
}

// lowerCamel of a Go field name: the leading run of capitals is lowered
// (Text -> text, ID -> id, JSDoc -> jsDoc, URLPath -> urlPath).
func lowerCamel(name string) string {
	n := 0
	for n < len(name) && name[n] >= 'A' && name[n] <= 'Z' {
		n++
	}
	if n == 0 {
		return name
	}
	if n == len(name) {
		return strings.ToLower(name)
	}
	if n == 1 {
		return strings.ToLower(name[:1]) + name[1:]
	}
	return strings.ToLower(name[:n-1]) + name[n-1:]
}

// fieldLuaName gives the Lua name of field f of struct st.
func fieldLuaName(st *types.Struct, f *types.Var) string {
	name := lowerCamel(f.Name())
	if !f.Exported() {
		for i := 0; i < st.NumFields(); i++ {
			o := st.Field(i)
			if o != f && o.Exported() && lowerCamel(o.Name()) == f.Name() {
				return luaName(name + "_")
			}
		}
	}
	return luaName(name)
}

// luaModule maps a Go import path to a Lua module and the alias used for it.
func luaModule(path string) (string, bool) {
	if !strings.HasPrefix(path, modulePrefix) {
		return "", false
	}
	rel := strings.TrimPrefix(path, modulePrefix)
	return "tslua." + strings.ReplaceAll(rel, "/", "."), true
}

// constant naming rule of scripts/gen/goconsts.
func constLuaName(c *types.Const) string {
	typ := ""
	if named, ok := c.Type().(*types.Named); ok && named.Obj().Pkg() == c.Pkg() {
		typ = named.Obj().Name()
	}
	if typ == "" {
		return c.Name()
	}
	key := strings.TrimPrefix(c.Name(), typ)
	if key == "" || !(key[0] >= 'A' && key[0] <= 'Z' || key[0] == '_') {
		key = c.Name()
	}
	return typ + "." + key
}

// ---------------------------------------------------------------------------
// writer

type gen struct {
	pkg      *packages.Package
	info     *types.Info
	file     *ast.File
	goPath   string
	isUtil   bool
	ind      int
	lines    []string
	aliases  map[string]string // lua module -> alias
	aliasOf  map[string]string // alias -> lua module
	names    map[types.Object]string
	tmp      int
	usesGort bool
	usesZero bool
	// per function: labels of loops that need a continue label
	loopStack []*loopInfo
	// named results of the function being converted (for bare returns)
	results    []string
	hasResults bool
	sigStack   []*types.Signature
	lastReturn bool
	deferStack string
	isPkg      bool
	pkgName    string
}

type loopInfo struct {
	label       string
	needCont    bool
	contLabel   string
	isSwitch    bool
	needBreakSw bool
}

func newGen(p *packages.Package, file *ast.File, goPath string, isUtil bool) *gen {
	return &gen{
		pkg:     p,
		info:    p.TypesInfo,
		file:    file,
		goPath:  goPath,
		isUtil:  isUtil,
		aliases: map[string]string{},
		aliasOf: map[string]string{},
		names:   map[types.Object]string{},
	}
}

func (g *gen) fail(n ast.Node, format string, args ...any) string {
	pos := g.pkg.Fset.Position(n.Pos())
	msg := fmt.Sprintf("%s:%d: %s", g.goPath, pos.Line, fmt.Sprintf(format, args...))
	failures = append(failures, msg)
	return fmt.Sprintf("gort.Unsupported(%s)", luaQuote(msg))
}

func (g *gen) indent() string {
	return strings.Repeat("    ", g.ind)
}

func (g *gen) line(format string, args ...any) {
	s := format
	if len(args) > 0 {
		s = fmt.Sprintf(format, args...)
	}
	if s == "" {
		g.lines = append(g.lines, "")
		return
	}
	g.lines = append(g.lines, g.indent()+s)
}

func (g *gen) gort() string {
	g.usesGort = true
	return "gort"
}

func (g *gen) require(mod string, preferred string) string {
	if a, ok := g.aliases[mod]; ok {
		return a
	}
	alias := preferred
	for i := 2; ; i++ {
		if _, taken := g.aliasOf[alias]; !taken && !reservedLocals[alias] && !luaKeywords[alias] {
			break
		}
		alias = fmt.Sprintf("%s%d", preferred, i)
	}
	g.aliases[mod] = alias
	g.aliasOf[alias] = mod
	return alias
}

func (g *gen) pkgAlias(p *types.Package) string {
	mod, ok := luaModule(p.Path())
	if !ok {
		return g.gort() + "." + p.Name()
	}
	return g.require(mod, mod[strings.LastIndex(mod, ".")+1:])
}

func (g *gen) newTmp(prefix string) string {
	g.tmp++
	return fmt.Sprintf("%s%d", prefix, g.tmp)
}

// localName gives the Lua name of a local Go object (renaming reserved names).
func (g *gen) localName(obj types.Object) string {
	if n, ok := g.names[obj]; ok {
		return n
	}
	name := obj.Name()
	if name == "_" {
		return "_"
	}
	name = luaName(name)
	if reservedLocals[name] {
		name = name + "_"
	}
	if _, isAlias := g.aliasOf[name]; isAlias {
		name = name + "_"
	}
	for _, imp := range g.file.Imports {
		p := ""
		if imp.Name != nil {
			p = imp.Name.Name
		} else {
			path := strings.Trim(imp.Path.Value, `"`)
			p = path[strings.LastIndex(path, "/")+1:]
		}
		if p == name {
			name = name + "_"
		}
	}
	g.names[obj] = name
	return name
}

func (g *gen) convertFile() string {
	var body []string
	header := []string{
		"-- Code generated by scripts/gen/fourslash.mjs from typescript-go " + g.goPath + ". DO NOT EDIT.",
		"-- luacheck: ignore 211 4 6",
	}
	if g.isUtil {
		g.aliases["tslua.fourslash.tests.util"] = "util"
		g.aliasOf["util"] = "tslua.fourslash.tests.util"
		g.convertPackageFile()
	} else {
		g.convertTestFile()
	}
	body = g.lines
	var reqs []string
	if g.usesGort {
		reqs = append(reqs, `local gort = require("tslua.fourslash.goruntime")`)
	}
	if g.usesZero {
		reqs = append(reqs, `local zero = require("tslua.fourslash.tests.zero_generated")`)
	}
	mods := make([]string, 0, len(g.aliases))
	for m := range g.aliases {
		mods = append(mods, m)
	}
	sort.Strings(mods)
	for _, m := range mods {
		reqs = append(reqs, fmt.Sprintf("local %s = require(%q)", g.aliases[m], m))
	}
	out := append(header, reqs...)
	out = append(out, "")
	out = append(out, body...)
	return strings.Join(out, "\n") + "\n"
}

// convertTestFile: every func TestXxx(t *testing.T) becomes an entry of the returned tests
// list (in source order); other package-level declarations become file locals.
func (g *gen) convertTestFile() {
	var tests []string
	g.line("local P = {}")
	g.line("")
	g.convertPackageDecls(func(fd *ast.FuncDecl) bool {
		name := fd.Name.Name
		if strings.HasPrefix(name, "Test") && fd.Recv == nil && fd.Type.Params.NumFields() == 1 {
			tests = append(tests, name)
			return true
		}
		return false
	}, "P")
	g.line("return {")
	g.ind++
	g.line("source = %s,", luaQuote(g.goPath))
	g.line("P = P,")
	g.line("tests = {")
	g.ind++
	for _, name := range tests {
		g.line("{ name = %s, fn = P.%s },", luaQuote(name), name)
	}
	g.ind--
	g.line("},")
	g.ind--
	g.line("}")
}

func (g *gen) convertPackageFile() {
	g.convertPackageDecls(func(*ast.FuncDecl) bool { return false }, "util")
	g.line("return util")
}

// convertPackageDecls emits functions first (as fields of tbl), then package vars and consts in
// Go initialization order.
func (g *gen) convertPackageDecls(isTest func(*ast.FuncDecl) bool, tbl string) {
	for _, d := range g.file.Decls {
		if fd, ok := d.(*ast.FuncDecl); ok {
			isTest(fd)
		}
	}
	for _, d := range g.file.Decls {
		fd, ok := d.(*ast.FuncDecl)
		if !ok {
			continue
		}
		if fd.Recv != nil {
			g.fail(fd, "method declaration")
			continue
		}
		obj := g.info.Defs[fd.Name]
		g.names[obj] = tbl + "." + fd.Name.Name
	}
	for _, d := range g.file.Decls {
		gd, ok := d.(*ast.GenDecl)
		if !ok {
			continue
		}
		for _, spec := range gd.Specs {
			if vs, ok := spec.(*ast.ValueSpec); ok {
				for _, n := range vs.Names {
					if obj := g.info.Defs[n]; obj != nil && n.Name != "_" {
						g.names[obj] = tbl + "." + n.Name
					}
				}
			}
		}
	}
	for _, d := range g.file.Decls {
		fd, ok := d.(*ast.FuncDecl)
		if !ok || fd.Recv != nil {
			continue
		}
		g.funcDecl(tbl+"."+fd.Name.Name, fd.Type, fd.Body, g.info.Defs[fd.Name].Type().(*types.Signature))
		g.line("")
	}
	// consts first (they are compile-time), then vars in init order
	for _, d := range g.file.Decls {
		gd, ok := d.(*ast.GenDecl)
		if !ok || gd.Tok != token.CONST {
			continue
		}
		for _, spec := range gd.Specs {
			vs := spec.(*ast.ValueSpec)
			for _, n := range vs.Names {
				c := g.info.Defs[n].(*types.Const)
				g.line("%s.%s = %s", tbl, n.Name, g.constValue(c.Val(), c.Type()))
			}
		}
	}
	fileStart, fileEnd := g.file.Pos(), g.file.End()
	for _, init := range g.info.InitOrder {
		if len(init.Lhs) == 0 || init.Lhs[0].Pos() < fileStart || init.Lhs[0].Pos() > fileEnd {
			continue
		}
		var lhs []string
		for _, v := range init.Lhs {
			if v.Name() == "_" {
				lhs = append(lhs, "_")
			} else {
				lhs = append(lhs, tbl+"."+v.Name())
			}
		}
		g.line("%s = %s", strings.Join(lhs, ", "), g.exprAs(init.Rhs, init.Lhs[0].Type()))
	}
	// vars without initializer
	for _, d := range g.file.Decls {
		gd, ok := d.(*ast.GenDecl)
		if !ok || gd.Tok != token.VAR {
			continue
		}
		for _, spec := range gd.Specs {
			vs := spec.(*ast.ValueSpec)
			if len(vs.Values) == 0 {
				for _, n := range vs.Names {
					obj := g.info.Defs[n]
					g.line("%s.%s = %s", tbl, n.Name, g.zeroValue(obj.Type(), n))
				}
			}
		}
	}
	g.line("")
}

func (g *gen) funcDecl(name string, ft *ast.FuncType, body *ast.BlockStmt, sig *types.Signature) {
	params := g.params(ft)
	g.line("function %s(%s)", name, strings.Join(params, ", "))
	g.ind++
	g.funcPrologue(ft)
	saved := g.loopStack
	savedRes, savedHas := g.results, g.hasResults
	g.loopStack = nil
	g.results, g.hasResults = g.namedResults(ft), ft.Results != nil && ft.Results.NumFields() > 0
	g.sigStack = append(g.sigStack, sig)
	defer func() { g.sigStack = g.sigStack[:len(g.sigStack)-1] }()
	savedDefer := g.deferStack
	g.deferStack = ""
	if !g.withDeferStack(body.List) {
		g.funcBody(body.List)
	}
	g.deferStack = savedDefer
	g.loopStack = saved
	g.results, g.hasResults = savedRes, savedHas
	g.ind--
	g.line("end")
}

func (g *gen) params(ft *ast.FuncType) []string {
	var params []string
	if ft.Params == nil {
		return params
	}
	for _, f := range ft.Params.List {
		if _, ok := f.Type.(*ast.Ellipsis); ok {
			params = append(params, "...")
			continue
		}
		if len(f.Names) == 0 {
			params = append(params, g.newTmp("_p"))
			continue
		}
		for _, n := range f.Names {
			if n.Name == "_" {
				params = append(params, g.newTmp("_p"))
			} else {
				params = append(params, g.localName(g.info.Defs[n]))
			}
		}
	}
	return params
}

// funcPrologue materializes a variadic parameter as an array, and declares named results.
func (g *gen) funcPrologue(ft *ast.FuncType) {
	if ft.Params != nil {
		for _, f := range ft.Params.List {
			if _, ok := f.Type.(*ast.Ellipsis); ok {
				for _, n := range f.Names {
					g.line("local %s = { ... }", g.localName(g.info.Defs[n]))
				}
			}
		}
	}
	if ft.Results != nil {
		for _, f := range ft.Results.List {
			for _, n := range f.Names {
				obj := g.info.Defs[n]
				g.line("local %s = %s", g.localName(obj), g.zeroValue(obj.Type(), n))
			}
		}
	}
}

func writeUtilInit() {
	text := "-- Code generated by scripts/gen/fourslash.mjs. DO NOT EDIT.\n" +
		"-- Go package internal/fourslash/tests/util (shared expectations of the fourslash tests).\n" +
		"local util = {}\n" +
		"package.loaded[\"tslua.fourslash.tests.util\"] = util\n" +
		"require(\"tslua.fourslash.tests.util.util\")\n" +
		"return util\n"
	out := filepath.Join(repoRoot, "src", "tslua", "fourslash", "tests", "util", "init.lua")
	if err := os.WriteFile(out, []byte(text), 0o644); err != nil {
		panic(err)
	}
}
