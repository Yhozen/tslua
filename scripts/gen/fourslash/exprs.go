package main

import (
	"fmt"
	"go/ast"
	"go/constant"
	"go/token"
	"go/types"
	"path/filepath"
	"strconv"
	"strings"
)

func (g *gen) exprAs(e ast.Expr, _ types.Type) string {
	return g.expr(e)
}

func luaQuote(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"' || c == '\\':
			b.WriteByte('\\')
			b.WriteByte(c)
		case c == '\n':
			b.WriteString("\\n")
		case c == '\r':
			b.WriteString("\\r")
		case c == '\t':
			b.WriteString("\\t")
		case c < 0x20 || c == 0x7f:
			fmt.Fprintf(&b, "\\%03d", c)
		default:
			b.WriteByte(c)
		}
	}
	b.WriteByte('"')
	return b.String()
}

// luaString uses a long bracket for multi-line text when that represents it exactly.
func luaString(s string) string {
	if strings.Contains(s, "\n") && len(s) > 60 {
		ok := true
		for i := 0; i < len(s); i++ {
			c := s[i]
			if c == '\r' || (c < 0x20 && c != '\n' && c != '\t') || c == 0x7f {
				ok = false
				break
			}
		}
		if ok {
			level := ""
			for strings.Contains(s, "]"+level+"]") || strings.HasSuffix(s, "]"+level) {
				level += "="
			}
			return "[" + level + "[\n" + s + "]" + level + "]"
		}
	}
	return luaQuote(s)
}

func (g *gen) constValue(v constant.Value, t types.Type) string {
	switch v.Kind() {
	case constant.String:
		return luaString(constant.StringVal(v))
	case constant.Bool:
		return v.ExactString()
	case constant.Int:
		if b, ok := t.Underlying().(*types.Basic); ok && b.Info()&types.IsFloat != 0 {
			f, _ := constant.Float64Val(v)
			return floatLit(f)
		}
		if i, ok := constant.Int64Val(v); ok {
			return strconv.FormatInt(i, 10)
		}
		if u, ok := constant.Uint64Val(v); ok {
			return fmt.Sprintf("0x%x", u)
		}
	case constant.Float:
		f, _ := constant.Float64Val(v)
		if b, ok := t.Underlying().(*types.Basic); ok && b.Info()&types.IsInteger != 0 {
			return strconv.FormatInt(int64(f), 10)
		}
		return floatLit(f)
	}
	return "nil --[[ unsupported constant ]]"
}

func floatLit(f float64) string {
	s := strconv.FormatFloat(f, 'g', -1, 64)
	if !strings.ContainsAny(s, ".eIN") {
		s += ".0"
	}
	return s
}

// constRef converts a reference to a named constant, or returns "" for other constant expressions.
func (g *gen) constRef(e ast.Expr) string {
	var id *ast.Ident
	switch e := e.(type) {
	case *ast.Ident:
		id = e
	case *ast.SelectorExpr:
		id = e.Sel
	default:
		return ""
	}
	c, ok := g.info.Uses[id].(*types.Const)
	if !ok {
		return ""
	}
	if c.Pkg() == nil || c.Parent() == types.Universe {
		return ""
	}
	if _, ok := luaModule(c.Pkg().Path()); !ok {
		return ""
	}
	if c.Pkg() == g.pkg.Types {
		if g.isPkg && c.Parent() == g.pkg.Types.Scope() {
			return g.pkgName + "." + constLuaName(c)
		}
		if c.Parent() == g.pkg.Types.Scope() {
			if n, ok := g.names[c]; ok {
				return n
			}
			return ""
		}
		return g.localName(c)
	}
	return g.pkgAlias(c.Pkg()) + "." + constLuaName(c)
}

func (g *gen) expr(e ast.Expr) string {
	tv, hasTV := g.info.Types[e]
	if hasTV && tv.Value != nil {
		if r := g.constRef(ast.Unparen(e)); r != "" {
			return r
		}
		// conversion of a named constant: keep the name
		if call, ok := ast.Unparen(e).(*ast.CallExpr); ok && len(call.Args) == 1 && g.info.Types[call.Fun].IsType() {
			if r := g.constRef(ast.Unparen(call.Args[0])); r != "" {
				at := g.info.TypeOf(call.Args[0])
				if sameKind(at, tv.Type) {
					return r
				}
			}
		}
		return g.constValue(tv.Value, tv.Type)
	}
	switch e := e.(type) {
	case *ast.Ident:
		return g.ident(e)
	case *ast.ParenExpr:
		return "(" + g.expr(e.X) + ")"
	case *ast.SelectorExpr:
		return g.selector(e)
	case *ast.CallExpr:
		return g.call(e)
	case *ast.CompositeLit:
		return g.compositeLit(e, nil)
	case *ast.UnaryExpr:
		return g.unary(e)
	case *ast.BinaryExpr:
		return g.binary(e)
	case *ast.StarExpr:
		return g.expr(e.X)
	case *ast.IndexExpr:
		return g.index(e)
	case *ast.IndexListExpr:
		return g.expr(e.X)
	case *ast.SliceExpr:
		return g.sliceExpr(e)
	case *ast.FuncLit:
		return g.funcLit(e)
	case *ast.TypeAssertExpr:
		return g.typeAssert(e, false)
	}
	return g.fail(e, "expression %T", e)
}

func sameKind(a, b types.Type) bool {
	ab, ok1 := a.Underlying().(*types.Basic)
	bb, ok2 := b.Underlying().(*types.Basic)
	if !ok1 || !ok2 {
		return false
	}
	mask := types.IsString | types.IsInteger | types.IsFloat | types.IsBoolean
	return ab.Info()&mask == bb.Info()&mask
}

func (g *gen) ident(e *ast.Ident) string {
	obj := g.info.Uses[e]
	if obj == nil {
		obj = g.info.Defs[e]
	}
	switch o := obj.(type) {
	case nil:
		return g.fail(e, "unresolved identifier %s", e.Name)
	case *types.Nil:
		return "nil"
	case *types.Var, *types.Func, *types.Const:
		if o.Pkg() != nil && o.Parent() == o.Pkg().Scope() {
			if o.Pkg() == g.pkg.Types {
				if g.isPkg {
					if c, ok := o.(*types.Const); ok {
						return g.pkgName + "." + constLuaName(c)
					}
					return g.pkgName + "." + o.Name()
				}
				if n, ok := g.names[o]; ok {
					return n
				}
				return g.otherFileRef(o)
			}
			// dot import
			return g.pkgAlias(o.Pkg()) + "." + o.Name()
		}
		return g.localName(o)
	}
	return g.fail(e, "identifier %s (%T)", e.Name, obj)
}

func (g *gen) selector(e *ast.SelectorExpr) string {
	sel := g.info.Selections[e]
	if sel == nil {
		// qualified identifier
		obj := g.info.Uses[e.Sel]
		if obj == nil || obj.Pkg() == nil {
			return g.fail(e, "selector %s", e.Sel.Name)
		}
		return g.pkgAlias(obj.Pkg()) + "." + obj.Name()
	}
	switch sel.Kind() {
	case types.FieldVal:
		f := sel.Obj().(*types.Var)
		st := g.fieldOwner(sel)
		x := g.recvExpr(e.X)
		if st == nil {
			return x + "." + luaName(lowerCamel(f.Name()))
		}
		return x + "." + fieldLuaName(st, f)
	case types.MethodVal:
		recv := g.recvExpr(e.X)
		return "function(...) return " + g.methodCall(e, sel, recv, []string{"..."}) + " end"
	}
	return g.fail(e, "method expression")
}

// fieldOwner finds the struct type declaring the selected field.
func (g *gen) fieldOwner(sel *types.Selection) *types.Struct {
	t := sel.Recv()
	idx := sel.Index()
	for i, k := range idx {
		if p, ok := t.Underlying().(*types.Pointer); ok {
			t = p.Elem()
		}
		st, ok := t.Underlying().(*types.Struct)
		if !ok {
			return nil
		}
		if i == len(idx)-1 {
			return st
		}
		t = st.Field(k).Type()
	}
	return nil
}

func (g *gen) recvExpr(x ast.Expr) string {
	s := g.expr(x)
	if isSimpleLua(s) {
		return s
	}
	return "(" + s + ")"
}

// isSimpleLua reports whether s can be used directly before `.name`, `:m()` or `[k]`.
func isSimpleLua(s string) bool {
	if s == "" {
		return false
	}
	if strings.HasPrefix(s, "\"") || strings.HasPrefix(s, "[") || strings.HasPrefix(s, "{") || strings.HasPrefix(s, "function") {
		return false
	}
	c := s[0]
	if !(c == '_' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c == '(') {
		return false
	}
	// identifiers, field chains and calls: no top-level operators or spaces outside brackets
	depth := 0
	inStr := byte(0)
	for i := 0; i < len(s); i++ {
		ch := s[i]
		if inStr != 0 {
			if ch == '\\' {
				i++
			} else if ch == inStr {
				inStr = 0
			}
			continue
		}
		switch ch {
		case '"', '\'':
			inStr = ch
		case '(', '[', '{':
			depth++
		case ')', ']', '}':
			depth--
		case ' ', '+', '-', '*', '/', '%', '<', '>', '=', '~', '#', '^', '&', '|', ',':
			if depth == 0 {
				return false
			}
		}
	}
	return true
}

func (g *gen) methodCall(e *ast.SelectorExpr, sel *types.Selection, recv string, args []string) string {
	fn := sel.Obj().(*types.Func)
	sig := fn.Type().(*types.Signature)
	rt := sig.Recv().Type()
	if p, ok := rt.(*types.Pointer); ok {
		rt = p.Elem()
	}
	named, _ := rt.(*types.Named)
	if named == nil {
		// interface method (embedded interfaces) or similar
		return recv + ":" + fn.Name() + "(" + strings.Join(args, ", ") + ")"
	}
	switch named.Underlying().(type) {
	case *types.Struct, *types.Interface:
		return recv + ":" + fn.Name() + "(" + strings.Join(args, ", ") + ")"
	}
	// method on a named scalar/slice/map type: package function <Type>_<Method>
	alias := g.pkgAlias(named.Obj().Pkg())
	all := append([]string{recv}, args...)
	if strings.HasPrefix(recv, "(") && strings.HasSuffix(recv, ")") {
		all[0] = recv[1 : len(recv)-1]
	}
	return alias + "." + named.Obj().Name() + "_" + fn.Name() + "(" + strings.Join(all, ", ") + ")"
}

func (g *gen) unary(e *ast.UnaryExpr) string {
	switch e.Op {
	case token.AND:
		return g.expr(e.X)
	case token.SUB:
		return "-" + g.operand(e.X)
	case token.ADD:
		return g.expr(e.X)
	case token.NOT:
		return "not " + g.operand(e.X)
	case token.XOR:
		return "~" + g.operand(e.X)
	}
	return g.fail(e, "unary %s", e.Op)
}

func (g *gen) operand(e ast.Expr) string {
	s := g.expr(e)
	switch ast.Unparen(e).(type) {
	case *ast.BinaryExpr:
		return "(" + s + ")"
	case *ast.UnaryExpr:
		if !strings.HasPrefix(s, "not ") && !strings.HasPrefix(s, "-") && !strings.HasPrefix(s, "~") {
			return s
		}
		return "(" + s + ")"
	}
	return s
}

func isStringType(t types.Type) bool {
	b, ok := t.Underlying().(*types.Basic)
	return ok && b.Info()&types.IsString != 0
}

func isIntegerType(t types.Type) bool {
	b, ok := t.Underlying().(*types.Basic)
	return ok && b.Info()&types.IsInteger != 0
}

func (g *gen) binary(e *ast.BinaryExpr) string {
	xt := g.info.TypeOf(e.X)
	x, y := g.operand(e.X), g.operand(e.Y)
	switch e.Op {
	case token.ADD:
		if isStringType(xt) {
			return x + " .. " + y
		}
		return x + " + " + y
	case token.EQL, token.NEQ:
		if _, isStruct := xt.Underlying().(*types.Struct); isStruct {
			eq := g.gort() + ".StructEqual(" + g.expr(e.X) + ", " + g.expr(e.Y) + ")"
			if e.Op == token.NEQ {
				return "not " + eq
			}
			return eq
		}
		if e.Op == token.NEQ {
			return x + " ~= " + y
		}
		return x + " == " + y
	case token.SUB, token.MUL, token.LSS, token.GTR, token.LEQ, token.GEQ:
		return x + " " + e.Op.String() + " " + y
	case token.QUO:
		if isIntegerType(xt) {
			return g.gort() + ".idiv(" + g.expr(e.X) + ", " + g.expr(e.Y) + ")"
		}
		return x + " / " + y
	case token.REM:
		return g.gort() + ".imod(" + g.expr(e.X) + ", " + g.expr(e.Y) + ")"
	case token.LAND:
		return x + " and " + y
	case token.LOR:
		return x + " or " + y
	case token.AND, token.OR, token.SHL, token.SHR:
		return x + " " + e.Op.String() + " " + y
	case token.XOR:
		return x + " ~ " + y
	case token.AND_NOT:
		return x + " & ~" + y
	}
	return g.fail(e, "binary %s", e.Op)
}

func (g *gen) plusOne(e ast.Expr) string {
	if tv, ok := g.info.Types[e]; ok && tv.Value != nil {
		if i, ok := constant.Int64Val(tv.Value); ok {
			return strconv.FormatInt(i+1, 10)
		}
	}
	return g.operand(e) + " + 1"
}

func (g *gen) index(e *ast.IndexExpr) string {
	if tv, ok := g.info.Types[e.X]; ok && !tv.IsValue() {
		return g.fail(e, "index of non-value")
	}
	if _, isGenericFunc := g.info.TypeOf(e.X).(*types.Signature); isGenericFunc {
		return g.expr(e.X)
	}
	xt := g.info.TypeOf(e.X)
	switch u := xt.Underlying().(type) {
	case *types.Map:
		v := g.recvExpr(e.X) + "[" + g.expr(e.Index) + "]"
		if z := g.scalarZero(u.Elem()); z != "" {
			return "(" + v + " or " + z + ")"
		}
		return v
	case *types.Basic:
		return "string.byte(" + g.expr(e.X) + ", " + g.plusOne(e.Index) + ")"
	case *types.Pointer:
		return g.recvExpr(e.X) + "[" + g.plusOne(e.Index) + "]"
	}
	return g.recvExpr(e.X) + "[" + g.plusOne(e.Index) + "]"
}

func (g *gen) lookupCall(e *ast.IndexExpr, m *types.Map) string {
	z := g.scalarZero(m.Elem())
	if z == "" {
		z = "nil"
	}
	return g.gort() + ".MapLookup(" + g.expr(e.X) + ", " + g.expr(e.Index) + ", " + z + ")"
}

// scalarZero returns the Lua zero value of a basic type, or "" for types whose zero is nil.
func (g *gen) scalarZero(t types.Type) string {
	b, ok := t.Underlying().(*types.Basic)
	if !ok {
		return ""
	}
	switch {
	case b.Info()&types.IsString != 0:
		return `""`
	case b.Info()&types.IsBoolean != 0:
		return "false"
	case b.Info()&types.IsFloat != 0:
		return "0.0"
	case b.Info()&types.IsNumeric != 0:
		return "0"
	}
	return ""
}

func (g *gen) sliceExpr(e *ast.SliceExpr) string {
	if e.Slice3 {
		return g.fail(e, "3-index slice")
	}
	x := g.expr(e.X)
	if isStringType(g.info.TypeOf(e.X)) {
		lo := "1"
		if e.Low != nil {
			lo = g.plusOne(e.Low)
		}
		if e.High != nil {
			return "string.sub(" + x + ", " + lo + ", " + g.expr(e.High) + ")"
		}
		return "string.sub(" + x + ", " + lo + ")"
	}
	lo, hi := "0", "nil"
	if e.Low != nil {
		lo = g.expr(e.Low)
	}
	if e.High != nil {
		hi = g.expr(e.High)
	}
	return g.gort() + ".slice(" + x + ", " + lo + ", " + hi + ")"
}

func (g *gen) typeAssert(e *ast.TypeAssertExpr, commaOk bool) string {
	if !commaOk {
		return g.expr(e.X)
	}
	return g.fail(e, "comma-ok type assertion")
}

func (g *gen) funcLit(e *ast.FuncLit) string {
	sig := g.info.TypeOf(e).(*types.Signature)
	savedLines := g.lines
	g.lines = nil
	params := g.params(e.Type)
	g.ind++
	g.funcPrologue(e.Type)
	saved := g.loopStack
	savedRes, savedHas := g.results, g.hasResults
	g.loopStack = nil
	g.results, g.hasResults = g.namedResults(e.Type), sig.Results().Len() > 0
	g.sigStack = append(g.sigStack, sig)
	savedDefer := g.deferStack
	g.deferStack = ""
	if !g.withDeferStack(e.Body.List) {
		g.funcBody(e.Body.List)
	}
	g.deferStack = savedDefer
	g.sigStack = g.sigStack[:len(g.sigStack)-1]
	g.loopStack = saved
	g.results, g.hasResults = savedRes, savedHas
	g.ind--
	body := g.lines
	g.lines = savedLines
	if len(body) == 0 {
		return "function(" + strings.Join(params, ", ") + ") end"
	}
	return "function(" + strings.Join(params, ", ") + ")\n" + strings.Join(body, "\n") + "\n" + g.indent() + "end"
}

func (g *gen) args(call *ast.CallExpr) []string {
	var args []string
	for i, a := range call.Args {
		s := g.expr(a)
		if call.Ellipsis.IsValid() && i == len(call.Args)-1 {
			s = g.gort() + ".unpack(" + s + ")"
		}
		args = append(args, s)
	}
	return args
}

func (g *gen) callString(call *ast.CallExpr, args []string) string {
	fun := ast.Unparen(call.Fun)
	if sel, ok := fun.(*ast.SelectorExpr); ok {
		if s := g.info.Selections[sel]; s != nil && s.Kind() == types.MethodVal {
			return g.methodCall(sel, s, g.recvExpr(sel.X), args)
		}
	}
	f := g.expr(fun)
	if !isSimpleLua(f) {
		f = "(" + f + ")"
	}
	return f + "(" + strings.Join(args, ", ") + ")"
}

func (g *gen) call(e *ast.CallExpr) string {
	fun := ast.Unparen(e.Fun)
	if tv, ok := g.info.Types[fun]; ok && tv.IsType() {
		return g.conversion(e, tv.Type)
	}
	if id, ok := fun.(*ast.Ident); ok {
		if b, ok := g.info.Uses[id].(*types.Builtin); ok {
			return g.builtin(e, b.Name())
		}
	}
	return g.callString(e, g.args(e))
}

func (g *gen) conversion(e *ast.CallExpr, to types.Type) string {
	arg := e.Args[0]
	from := g.info.TypeOf(arg)
	x := g.expr(arg)
	tb, tok := to.Underlying().(*types.Basic)
	fb, fok := from.Underlying().(*types.Basic)
	if tok && fok {
		switch {
		case tb.Info()&types.IsString != 0 && fb.Info()&types.IsInteger != 0:
			return "utf8.char(" + x + ")"
		case tb.Info()&types.IsFloat != 0 && fb.Info()&types.IsInteger != 0:
			return "(" + x + " + 0.0)"
		case tb.Info()&types.IsInteger != 0 && fb.Info()&types.IsFloat != 0:
			return g.gort() + ".toInt(" + x + ")"
		}
		return x
	}
	if tok && tb.Info()&types.IsString != 0 {
		if _, isSlice := from.Underlying().(*types.Slice); isSlice {
			return g.gort() + ".bytesToString(" + x + ")"
		}
	}
	return x
}

func (g *gen) builtin(e *ast.CallExpr, name string) string {
	switch name {
	case "len":
		if isStringType(g.info.TypeOf(e.Args[0])) {
			return "#" + g.operand(e.Args[0])
		}
		return g.gort() + ".len(" + g.expr(e.Args[0]) + ")"
	case "append":
		args := g.args(e)
		if e.Ellipsis.IsValid() {
			return g.gort() + ".appendSlice(" + g.expr(e.Args[0]) + ", " + g.expr(e.Args[1]) + ")"
		}
		return g.gort() + ".append(" + strings.Join(args, ", ") + ")"
	case "make":
		t := g.info.TypeOf(e)
		switch u := t.Underlying().(type) {
		case *types.Map:
			return "{}"
		case *types.Slice:
			if len(e.Args) >= 2 {
				z := g.zeroValue(u.Elem(), e)
				return g.gort() + ".makeSlice(" + g.expr(e.Args[1]) + ", function() return " + z + " end)"
			}
			return "{}"
		}
		return g.fail(e, "make of %s", t)
	case "new":
		if tv := g.info.Types[e.Args[0]]; tv.IsType() {
			return g.zeroValue(tv.Type, e)
		}
		return g.expr(e.Args[0])
	case "panic":
		return "error(" + g.expr(e.Args[0]) + ", 0)"
	case "min", "max":
		return "math." + name + "(" + strings.Join(g.args(e), ", ") + ")"
	case "delete":
		return g.gort() + ".delete(" + strings.Join(g.args(e), ", ") + ")"
	case "copy":
		if se, ok := ast.Unparen(e.Args[0]).(*ast.SliceExpr); ok && se.High == nil && !isStringType(g.info.TypeOf(se.X)) {
			lo := "0"
			if se.Low != nil {
				lo = g.expr(se.Low)
			}
			return g.gort() + ".copyInto(" + g.expr(se.X) + ", " + lo + ", " + g.expr(e.Args[1]) + ")"
		}
		return g.gort() + ".copyInto(" + g.expr(e.Args[0]) + ", 0, " + g.expr(e.Args[1]) + ")"
	case "cap":
		return g.gort() + ".len(" + g.expr(e.Args[0]) + ")"
	}
	return g.fail(e, "builtin %s", name)
}

// zeroValue gives the Lua zero value of a Go type.
func (g *gen) zeroValue(t types.Type, at ast.Node) string {
	if z := g.scalarZero(t); z != "" {
		return z
	}
	switch u := t.Underlying().(type) {
	case *types.Struct:
		if named, ok := t.(*types.Named); ok {
			if named.Obj().Pkg() != nil && named.Obj().Pkg().Path() == "strings" && named.Obj().Name() == "Builder" {
				return g.gort() + ".NewBuilder()"
			}
		}
		return g.structLit(t, u, nil, at)
	case *types.Array:
		return g.fail(at, "zero array")
	}
	return "nil"
}

// otherFileRef refers to a package-level declaration of another file of the same Go test package:
// converted test files export their declarations as the `P` field of the returned table.
func (g *gen) otherFileRef(o types.Object) string {
	path := g.pkg.Fset.Position(o.Pos()).Filename
	rel, _ := filepath.Rel(filepath.Join(tsgoRoot, "internal", "fourslash", "tests"), path)
	dir, base := filepath.Split(rel)
	lua := strings.TrimSuffix(base, ".go") + ".lua"
	var out string
	switch filepath.Clean(dir) {
	case "gen":
		out = "tests/fourslash/gen/" + lua
	case "manual":
		out = "tests/fourslash/manual/" + lua
	default:
		out = "tests/fourslash/tests/" + lua
	}
	return g.gort() + ".TestFile(" + luaQuote(out) + ").P." + o.Name()
}
