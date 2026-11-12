package main

import (
	"go/ast"
	"go/token"
	"go/types"
	"strings"
)

func (g *gen) namedResults(ft *ast.FuncType) []string {
	var res []string
	if ft.Results == nil {
		return nil
	}
	for _, f := range ft.Results.List {
		for _, n := range f.Names {
			res = append(res, g.localName(g.info.Defs[n]))
		}
	}
	return res
}

// funcBody converts the statements of a function body. A `defer` wraps the rest of the body in a
// closure that runs before the deferred call (testutil.RecoverAndFail takes the closure as its
// last argument, like the rest of the Lua test harness).
func (g *gen) funcBody(list []ast.Stmt) {
	for i, s := range list {
		ds, ok := s.(*ast.DeferStmt)
		if !ok {
			if rs, isRet := s.(*ast.ReturnStmt); isRet && i == len(list)-1 {
				g.lastReturn = true
				g.returnStmt(rs)
				g.lastReturn = false
				continue
			}
			g.stmt(s)
			continue
		}
		ret := ""
		if g.hasResults {
			ret = "return "
		}
		call := ds.Call
		isRecover := false
		if sel, ok := call.Fun.(*ast.SelectorExpr); ok && g.isPkgFunc(sel, "testutil", "RecoverAndFail") {
			isRecover = true
		}
		if g.deferStack != "" && !isRecover {
			fn := g.deferredFunc(call)
			g.line("%s[#%s + 1] = %s", g.deferStack, g.deferStack, fn)
			continue
		}
		if isRecover {
			args := g.args(call)
			g.line("%s%s.RecoverAndFail(%s, function()", ret, g.require("tslua.testutil", "testutil"), strings.Join(args, ", "))
		} else {
			fn := g.deferredFunc(call)
			g.line("%s%s.Defer(%s, function()", ret, g.gort(), fn)
		}
		g.ind++
		g.funcBody(list[i+1:])
		g.ind--
		g.line("end)")
		return
	}
}

func (g *gen) isPkgFunc(sel *ast.SelectorExpr, pkgName, name string) bool {
	id, ok := sel.X.(*ast.Ident)
	if !ok || sel.Sel.Name != name {
		return false
	}
	pn, ok := g.info.Uses[id].(*types.PkgName)
	return ok && pn.Imported().Name() == pkgName
}

// deferredFunc evaluates the deferred function value and its arguments now (like Go) and returns
// a Lua expression for a closure calling it.
func (g *gen) deferredFunc(call *ast.CallExpr) string {
	if len(call.Args) == 0 {
		if _, isCall := call.Fun.(*ast.CallExpr); isCall {
			tmp := g.newTmp("deferred")
			g.line("local %s = %s", tmp, g.expr(call.Fun))
			return tmp
		}
		if id, ok := call.Fun.(*ast.Ident); ok {
			if _, isVar := g.info.Uses[id].(*types.Var); isVar {
				return g.expr(id)
			}
		}
	}
	var args []string
	for _, a := range g.args(call) {
		tmp := g.newTmp("deferArg")
		g.line("local %s = %s", tmp, a)
		args = append(args, tmp)
	}
	fn := g.expr(call.Fun)
	if _, isCall := call.Fun.(*ast.CallExpr); isCall {
		tmp := g.newTmp("deferred")
		g.line("local %s = %s", tmp, fn)
		fn = tmp
		return "function() " + fn + "(" + strings.Join(args, ", ") + ") end"
	}
	return "function() " + g.callString(call, args) + " end"
}

// withDeferStack converts a function body that has defers in nested blocks: deferred calls are
// pushed on a stack that gort.WithDefers runs (LIFO) when the body returns or raises.
func (g *gen) withDeferStack(body []ast.Stmt) bool {
	if !hasNestedDefer(body) {
		return false
	}
	saved := g.deferStack
	g.deferStack = g.newTmp("defers")
	ret := ""
	if g.hasResults {
		ret = "return "
	}
	g.line("local %s = {}", g.deferStack)
	g.line("%s%s.WithDefers(%s, function()", ret, g.gort(), g.deferStack)
	g.ind++
	g.funcBody(body)
	g.ind--
	g.line("end)")
	g.deferStack = saved
	return true
}

func hasNestedDefer(body []ast.Stmt) bool {
	found := false
	for _, s := range body {
		if _, ok := s.(*ast.DeferStmt); ok {
			continue
		}
		ast.Inspect(s, func(n ast.Node) bool {
			switch n.(type) {
			case *ast.FuncLit:
				return false
			case *ast.DeferStmt:
				found = true
			}
			return !found
		})
	}
	return found
}

// stmts converts a nested block. A defer in a nested block wraps the rest of that block (Go runs it
// at function exit; the tests that do this only create a fourslash instance per block).
func (g *gen) stmts(list []ast.Stmt) {
	g.funcBody(list)
}

func (g *gen) stmt(s ast.Stmt) {
	switch s := s.(type) {
	case *ast.ExprStmt:
		g.line("%s", g.exprStmt(s.X))
	case *ast.AssignStmt:
		g.assign(s)
	case *ast.IncDecStmt:
		x := g.expr(s.X)
		op := "+"
		if s.Tok == token.DEC {
			op = "-"
		}
		g.line("%s = %s %s 1", g.lvalue(s.X), x, op)
	case *ast.DeclStmt:
		g.declStmt(s.Decl.(*ast.GenDecl))
	case *ast.IfStmt:
		g.ifStmt(s, false)
	case *ast.ForStmt:
		g.forStmt(s, "")
	case *ast.RangeStmt:
		g.rangeStmt(s, "")
	case *ast.SwitchStmt:
		g.switchStmt(s, "")
	case *ast.TypeSwitchStmt:
		g.typeSwitchStmt(s)
	case *ast.ReturnStmt:
		g.returnStmt(s)
	case *ast.BlockStmt:
		g.line("do")
		g.ind++
		g.stmts(s.List)
		g.ind--
		g.line("end")
	case *ast.BranchStmt:
		g.branch(s)
	case *ast.LabeledStmt:
		switch inner := s.Stmt.(type) {
		case *ast.ForStmt:
			g.forStmt(inner, s.Label.Name)
		case *ast.RangeStmt:
			g.rangeStmt(inner, s.Label.Name)
		case *ast.SwitchStmt:
			g.switchStmt(inner, s.Label.Name)
		default:
			g.line("::%s::", s.Label.Name)
			g.stmt(s.Stmt)
		}
	case *ast.EmptyStmt:
	default:
		g.line("%s", g.fail(s, "statement %T", s))
	}
}

func (g *gen) exprStmt(e ast.Expr) string {
	s := g.expr(e)
	if strings.HasPrefix(s, "(") || !strings.HasSuffix(s, ")") {
		return "local _ = " + s
	}
	return s
}

func (g *gen) returnStmt(s *ast.ReturnStmt) {
	if len(s.Results) == 0 {
		if len(g.results) > 0 {
			g.line("do return %s end", strings.Join(g.results, ", "))
		} else if g.lastReturn {
			g.line("return")
		} else {
			g.line("do return end")
		}
		return
	}
	var parts []string
	sig := g.currentResultTypes()
	for i, r := range s.Results {
		var t types.Type
		if sig != nil && i < sig.Len() && len(s.Results) == sig.Len() {
			t = sig.At(i).Type()
		}
		parts = append(parts, g.exprAs(r, t))
	}
	if g.lastReturn {
		g.line("return %s", strings.Join(parts, ", "))
		return
	}
	g.line("do return %s end", strings.Join(parts, ", "))
}

// currentResultTypes is filled while converting a function.
func (g *gen) currentResultTypes() *types.Tuple {
	if len(g.sigStack) == 0 {
		return nil
	}
	return g.sigStack[len(g.sigStack)-1].Results()
}

func (g *gen) declStmt(d *ast.GenDecl) {
	switch d.Tok {
	case token.TYPE:
		return
	case token.CONST:
		for _, spec := range d.Specs {
			vs := spec.(*ast.ValueSpec)
			for _, n := range vs.Names {
				c := g.info.Defs[n].(*types.Const)
				g.line("local %s = %s", g.localName(c), g.constValue(c.Val(), c.Type()))
			}
		}
	case token.VAR:
		for _, spec := range d.Specs {
			vs := spec.(*ast.ValueSpec)
			var names []string
			for _, n := range vs.Names {
				names = append(names, g.localName(g.info.Defs[n]))
			}
			if len(vs.Values) == 0 {
				var zeros []string
				for _, n := range vs.Names {
					zeros = append(zeros, g.zeroValue(g.info.Defs[n].Type(), n))
				}
				g.line("local %s = %s", strings.Join(names, ", "), strings.Join(zeros, ", "))
				continue
			}
			var vals []string
			for i, v := range vs.Values {
				var t types.Type
				if len(vs.Values) == len(vs.Names) {
					t = g.info.Defs[vs.Names[i]].Type()
				}
				vals = append(vals, g.copyIfStruct(v, g.exprAs(v, t)))
			}
			g.line("local %s = %s", strings.Join(names, ", "), strings.Join(vals, ", "))
		}
	}
}

func (g *gen) assign(s *ast.AssignStmt) {
	if s.Tok != token.ASSIGN && s.Tok != token.DEFINE {
		// op-assign
		op := s.Tok.String()
		op = op[:len(op)-1]
		lhs := g.lvalue(s.Lhs[0])
		bin := &ast.BinaryExpr{X: s.Lhs[0], Op: binaryTok(op), Y: s.Rhs[0], OpPos: s.TokPos}
		g.info.Types[bin] = types.TypeAndValue{Type: g.info.TypeOf(s.Lhs[0])}
		g.line("%s = %s", lhs, g.expr(bin))
		return
	}
	// comma-ok forms
	if len(s.Lhs) == 2 && len(s.Rhs) == 1 {
		switch rhs := ast.Unparen(s.Rhs[0]).(type) {
		case *ast.IndexExpr:
			if m, ok := g.info.TypeOf(rhs.X).Underlying().(*types.Map); ok {
				val := g.lookupCall(rhs, m)
				g.assignTo(s, val)
				return
			}
		case *ast.TypeAssertExpr:
			val := g.typeAssert(rhs, true)
			g.assignTo(s, val)
			return
		}
	}
	if len(s.Lhs) == len(s.Rhs) {
		var vals []string
		for i, r := range s.Rhs {
			vals = append(vals, g.copyIfStruct(r, g.exprAs(r, g.info.TypeOf(s.Lhs[i]))))
		}
		g.assignTo(s, strings.Join(vals, ", "))
		return
	}
	g.assignTo(s, g.expr(s.Rhs[0]))
}

func (g *gen) assignTo(s *ast.AssignStmt, rhs string) {
	var lhs []string
	allNew := true
	anyNew := false
	for _, l := range s.Lhs {
		if id, ok := l.(*ast.Ident); ok && s.Tok == token.DEFINE {
			if id.Name == "_" {
				lhs = append(lhs, "_")
				continue
			}
			if obj := g.info.Defs[id]; obj != nil {
				anyNew = true
				lhs = append(lhs, g.localName(obj))
				continue
			}
		}
		allNew = false
		if id, ok := l.(*ast.Ident); ok && id.Name == "_" {
			lhs = append(lhs, "_")
			continue
		}
		lhs = append(lhs, g.lvalue(l))
	}
	if s.Tok == token.DEFINE && allNew {
		g.line("local %s = %s", strings.Join(lhs, ", "), rhs)
		return
	}
	if anyNew {
		var news []string
		for _, l := range s.Lhs {
			if id, ok := l.(*ast.Ident); ok && g.info.Defs[id] != nil {
				news = append(news, g.localName(g.info.Defs[id]))
			}
		}
		g.line("local %s", strings.Join(news, ", "))
	}
	allBlank := true
	for _, l := range lhs {
		if l != "_" {
			allBlank = false
		}
	}
	if allBlank {
		g.line("local _ = %s", rhs)
		return
	}
	g.line("%s = %s", strings.Join(lhs, ", "), rhs)
}

// lvalue converts an assignable expression.
func (g *gen) lvalue(e ast.Expr) string {
	switch e := ast.Unparen(e).(type) {
	case *ast.Ident:
		if e.Name == "_" {
			return "_"
		}
		return g.expr(e)
	case *ast.IndexExpr:
		x := g.expr(e.X)
		switch g.info.TypeOf(e.X).Underlying().(type) {
		case *types.Map:
			return x + "[" + g.expr(e.Index) + "]"
		default:
			return x + "[" + g.plusOne(e.Index) + "]"
		}
	case *ast.SelectorExpr:
		return g.expr(e)
	case *ast.StarExpr:
		return g.lvalue(e.X)
	}
	return g.fail(e, "lvalue %T", e)
}

func (g *gen) ifStmt(s *ast.IfStmt, isElse bool) {
	if s.Init != nil {
		if isElse {
			g.line("else")
			g.ind++
		}
		g.line("do")
		g.ind++
		g.stmt(s.Init)
		g.ifStmt(&ast.IfStmt{If: s.If, Cond: s.Cond, Body: s.Body, Else: s.Else}, false)
		g.ind--
		g.line("end")
		if isElse {
			g.ind--
		}
		return
	}
	kw := "if"
	if isElse {
		kw = "elseif"
	}
	g.line("%s %s then", kw, g.cond(s.Cond))
	g.ind++
	g.stmts(s.Body.List)
	g.ind--
	switch e := s.Else.(type) {
	case nil:
	case *ast.IfStmt:
		if e.Init != nil {
			g.line("else")
			g.ind++
			g.ifStmt(e, false)
			g.ind--
		} else {
			g.ifStmt(e, true)
		}
	case *ast.BlockStmt:
		g.line("else")
		g.ind++
		g.stmts(e.List)
		g.ind--
	}
	// the first if of an if/elseif chain closes it
	if !isElse {
		g.line("end")
	}
}

func (g *gen) cond(e ast.Expr) string {
	return g.expr(e)
}

func (g *gen) pushLoop(label string, isSwitch bool) *loopInfo {
	li := &loopInfo{label: label, isSwitch: isSwitch}
	g.loopStack = append(g.loopStack, li)
	return li
}

func (g *gen) popLoop() {
	g.loopStack = g.loopStack[:len(g.loopStack)-1]
}

// loopBody converts a loop body with a `continue` label, and the post statement of a 3-clause for.
func (g *gen) loopBody(li *loopInfo, body []ast.Stmt, post ast.Stmt) {
	li.contLabel = g.newTmp("continue")
	start := len(g.lines)
	g.line("do")
	g.ind++
	g.stmts(body)
	g.ind--
	g.line("end")
	if li.needCont {
		g.line("::%s::", li.contLabel)
	} else {
		// no continue: drop the do ... end wrapper
		inner := append([]string(nil), g.lines[start+1:len(g.lines)-1]...)
		for i, l := range inner {
			inner[i] = strings.TrimPrefix(l, "    ")
		}
		g.lines = append(g.lines[:start], inner...)
	}
	if post != nil {
		g.stmt(post)
	}
}

func (g *gen) forStmt(s *ast.ForStmt, label string) {
	if s.Init != nil {
		g.line("do")
		g.ind++
		g.stmt(s.Init)
	}
	cond := "true"
	if s.Cond != nil {
		cond = g.cond(s.Cond)
	}
	li := g.pushLoop(label, false)
	g.line("while %s do", cond)
	g.ind++
	g.loopBody(li, s.Body.List, s.Post)
	g.ind--
	g.line("end")
	g.popLoop()
	if label != "" {
		g.line("::%s_break::", label)
	}
	if s.Init != nil {
		g.ind--
		g.line("end")
	}
}

func (g *gen) rangeVar(e ast.Expr, define bool) (string, bool) {
	if e == nil {
		return "_", false
	}
	id, ok := e.(*ast.Ident)
	if !ok {
		return g.fail(e, "range target %T", e), false
	}
	if id.Name == "_" {
		return "_", false
	}
	if define {
		return g.localName(g.info.Defs[id]), false
	}
	return g.expr(id), true
}

func (g *gen) rangeStmt(s *ast.RangeStmt, label string) {
	define := s.Tok == token.DEFINE
	key, keyAssign := g.rangeVar(s.Key, define)
	val, valAssign := g.rangeVar(s.Value, define)
	li := g.pushLoop(label, false)
	xt := g.info.TypeOf(s.X)
	var pre []string
	switch u := xt.Underlying().(type) {
	case *types.Slice, *types.Array, *types.Pointer:
		_ = u
		idx := g.newTmp("i")
		if key != "_" {
			if keyAssign {
				pre = append(pre, key+" = "+idx+" - 1")
			} else {
				pre = append(pre, "local "+key+" = "+idx+" - 1")
			}
		}
		v := "_"
		if val != "_" {
			if valAssign {
				v = g.newTmp("v")
				pre = append(pre, val+" = "+v)
			} else {
				v = val
			}
		}
		g.line("for %s, %s in %s.ipairs(%s) do", idx, v, g.gort(), g.expr(s.X))
	case *types.Map:
		k, v := key, val
		if keyAssign {
			k = g.newTmp("k")
			pre = append(pre, key+" = "+k)
		}
		if valAssign {
			v = g.newTmp("v")
			pre = append(pre, val+" = "+v)
		}
		g.line("for %s, %s in %s.pairs(%s) do", k, v, g.gort(), g.expr(s.X))
	case *types.Basic:
		if u.Info()&types.IsString != 0 {
			g.line("for %s, %s in %s.runes(%s) do", key, val, g.gort(), g.expr(s.X))
		} else {
			// range over int
			if keyAssign {
				g.line("%s", g.fail(s, "range over int with assignment"))
			}
			g.line("for %s = 0, %s - 1 do", key, g.expr(s.X))
		}
	case *types.Signature:
		g.line("for %s, %s in %s do", key, val, g.expr(s.X))
	default:
		g.line("%s", g.fail(s, "range over %s", xt))
		g.line("do")
	}
	g.ind++
	for _, p := range pre {
		g.line("%s", p)
	}
	g.loopBody(li, s.Body.List, nil)
	g.ind--
	g.line("end")
	g.popLoop()
	if label != "" {
		g.line("::%s_break::", label)
	}
}

func (g *gen) switchStmt(s *ast.SwitchStmt, label string) {
	if s.Init != nil {
		g.line("do")
		g.ind++
		g.stmt(s.Init)
	}
	tag := ""
	if s.Tag != nil {
		tag = g.newTmp("sw")
		g.line("local %s = %s", tag, g.expr(s.Tag))
	}
	li := g.pushLoop(label, true)
	start := len(g.lines)
	g.line("repeat")
	g.ind++
	first := true
	var deflt *ast.CaseClause
	for _, c := range s.Body.List {
		cc := c.(*ast.CaseClause)
		if cc.List == nil {
			deflt = cc
			continue
		}
		var conds []string
		for _, e := range cc.List {
			if tag != "" {
				conds = append(conds, tag+" == "+g.expr(e))
			} else {
				conds = append(conds, g.expr(e))
			}
		}
		kw := "elseif"
		if first {
			kw = "if"
		}
		first = false
		g.line("%s %s then", kw, strings.Join(conds, " or "))
		g.ind++
		g.caseBody(cc)
		g.ind--
	}
	if deflt != nil {
		if first {
			g.line("do")
		} else {
			g.line("else")
		}
		g.ind++
		g.caseBody(deflt)
		g.ind--
		first = false
	}
	if !first {
		g.line("end")
	}
	g.ind--
	g.line("until true")
	g.popLoop()
	if !li.needBreakSw {
		inner := append([]string(nil), g.lines[start+1:len(g.lines)-1]...)
		for i, l := range inner {
			inner[i] = strings.TrimPrefix(l, "    ")
		}
		g.lines = append(g.lines[:start], inner...)
	}
	if label != "" {
		g.line("::%s_break::", label)
	}
	if s.Init != nil {
		g.ind--
		g.line("end")
	}
}

func (g *gen) caseBody(cc *ast.CaseClause) {
	for _, st := range cc.Body {
		if b, ok := st.(*ast.BranchStmt); ok && b.Tok == token.FALLTHROUGH {
			g.line("%s", g.fail(b, "fallthrough"))
			continue
		}
		g.stmt(st)
	}
}

func (g *gen) branch(s *ast.BranchStmt) {
	switch s.Tok {
	case token.BREAK:
		if s.Label != nil {
			g.line("goto %s_break", s.Label.Name)
			return
		}
		if len(g.loopStack) == 0 {
			g.line("%s", g.fail(s, "break outside loop"))
			return
		}
		top := g.loopStack[len(g.loopStack)-1]
		if top.isSwitch {
			top.needBreakSw = true
		}
		g.line("break")
	case token.CONTINUE:
		for i := len(g.loopStack) - 1; i >= 0; i-- {
			li := g.loopStack[i]
			if li.isSwitch {
				continue
			}
			if s.Label != nil && li.label != s.Label.Name {
				continue
			}
			li.needCont = true
			g.line("goto %s", li.contLabel)
			return
		}
		g.line("%s", g.fail(s, "continue outside loop"))
	default:
		g.line("%s", g.fail(s, "branch %s", s.Tok))
	}
}

func binaryTok(op string) token.Token {
	switch op {
	case "+":
		return token.ADD
	case "-":
		return token.SUB
	case "*":
		return token.MUL
	case "/":
		return token.QUO
	case "%":
		return token.REM
	case "|":
		return token.OR
	case "&":
		return token.AND
	case "^":
		return token.XOR
	case "<<":
		return token.SHL
	case ">>":
		return token.SHR
	case "&^":
		return token.AND_NOT
	}
	panic("op " + op)
}

// typeSwitchStmt: case types are checked at run time (gort.IsStruct etc., see goruntime.lua).
func (g *gen) typeSwitchStmt(s *ast.TypeSwitchStmt) {
	if s.Init != nil {
		g.line("do")
		g.ind++
		g.stmt(s.Init)
	}
	var x ast.Expr
	var bind *ast.Ident
	switch a := s.Assign.(type) {
	case *ast.AssignStmt:
		bind = a.Lhs[0].(*ast.Ident)
		x = a.Rhs[0].(*ast.TypeAssertExpr).X
	case *ast.ExprStmt:
		x = a.X.(*ast.TypeAssertExpr).X
	}
	tag := g.newTmp("ts")
	g.line("local %s = %s", tag, g.expr(x))
	li := g.pushLoop("", true)
	start := len(g.lines)
	g.line("repeat")
	g.ind++
	first := true
	var deflt *ast.CaseClause
	for _, c := range s.Body.List {
		cc := c.(*ast.CaseClause)
		if cc.List == nil {
			deflt = cc
			continue
		}
		var conds []string
		for _, e := range cc.List {
			conds = append(conds, g.typeCheck(tag, g.info.TypeOf(e), e))
		}
		kw := "elseif"
		if first {
			kw = "if"
		}
		first = false
		g.line("%s %s then", kw, strings.Join(conds, " or "))
		g.ind++
		g.bindTypeSwitch(cc, bind, tag)
		g.caseBody(cc)
		g.ind--
	}
	if deflt != nil {
		if first {
			g.line("do")
		} else {
			g.line("else")
		}
		g.ind++
		g.bindTypeSwitch(deflt, bind, tag)
		g.caseBody(deflt)
		g.ind--
		first = false
	}
	if !first {
		g.line("end")
	}
	g.ind--
	g.line("until true")
	g.popLoop()
	if !li.needBreakSw {
		inner := append([]string(nil), g.lines[start+1:len(g.lines)-1]...)
		for i, l := range inner {
			inner[i] = strings.TrimPrefix(l, "    ")
		}
		g.lines = append(g.lines[:start], inner...)
	}
	if s.Init != nil {
		g.ind--
		g.line("end")
	}
}

func (g *gen) bindTypeSwitch(cc *ast.CaseClause, bind *ast.Ident, tag string) {
	if bind == nil {
		return
	}
	if obj := g.info.Implicits[cc]; obj != nil {
		g.line("local %s = %s", g.localName(obj), tag)
	}
}

func (g *gen) typeCheck(x string, t types.Type, at ast.Node) string {
	if b, ok := t.(*types.Basic); ok && b.Kind() == types.UntypedNil {
		return x + " == nil"
	}
	switch u := t.Underlying().(type) {
	case *types.Basic:
		switch {
		case u.Info()&types.IsString != 0:
			return "type(" + x + ") == \"string\""
		case u.Info()&types.IsBoolean != 0:
			return "type(" + x + ") == \"boolean\""
		case u.Info()&types.IsNumeric != 0:
			return "type(" + x + ") == \"number\""
		}
	case *types.Pointer:
		if named, ok := u.Elem().(*types.Named); ok {
			if mod, ok := luaModule(named.Obj().Pkg().Path()); ok {
				return g.gort() + ".IsStruct(" + x + ", " + luaQuote(mod) + ", " + luaQuote(named.Obj().Name()) + ")"
			}
		}
	case *types.Struct:
		if u.NumFields() == 0 {
			return x + " == " + g.require("tslua.fourslash", "fourslash") + ".Ignored"
		}
		if named, ok := t.(*types.Named); ok {
			if mod, ok := luaModule(named.Obj().Pkg().Path()); ok {
				return g.gort() + ".IsStruct(" + x + ", " + luaQuote(mod) + ", " + luaQuote(named.Obj().Name()) + ")"
			}
		}
	case *types.Slice:
		if _, isIface := u.Elem().Underlying().(*types.Interface); !isIface {
			return g.gort() + ".IsSlice(" + x + ", function(e) return " + g.typeCheck("e", u.Elem(), at) + " end)"
		}
		return g.gort() + ".IsSlice(" + x + ")"
	case *types.Map:
		return g.gort() + ".IsMap(" + x + ")"
	}
	return g.fail(at, "type switch case %s", t)
}

// copyIfStruct gives Go's copy semantics to assignments of addressable struct values (Lua tables
// are references): a shallow copy keeping the metatable.
func (g *gen) copyIfStruct(e ast.Expr, s string) string {
	t := g.info.TypeOf(e)
	if t == nil {
		return s
	}
	if _, ok := t.Underlying().(*types.Struct); !ok {
		return s
	}
	switch x := ast.Unparen(e).(type) {
	case *ast.Ident:
		if _, isVar := g.info.Uses[x].(*types.Var); !isVar {
			return s
		}
	case *ast.SelectorExpr:
		if sel := g.info.Selections[x]; sel == nil || sel.Kind() != types.FieldVal {
			if _, isVar := g.info.Uses[x.Sel].(*types.Var); !isVar {
				return s
			}
		}
	case *ast.IndexExpr, *ast.StarExpr:
	default:
		return s
	}
	return g.gort() + ".CloneStruct(" + s + ")"
}
