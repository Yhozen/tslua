package main

import (
	"fmt"
	"go/ast"
	"go/token"
	"go/types"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/tools/go/packages"
)

// Package mode: draft translation of a non-test Go package (used to start the hand-written
// tslua.fourslash port; its output goes to a scratch directory and is edited by hand).
func convertPackage(pattern, outDir string) {
	cfg := &packages.Config{
		Mode: packages.NeedName | packages.NeedFiles | packages.NeedSyntax | packages.NeedTypes | packages.NeedTypesInfo,
		Dir:  tsgoRoot,
	}
	pkgs, err := packages.Load(cfg, pattern)
	if err != nil {
		panic(err)
	}
	for _, p := range pkgs {
		for _, e := range p.Errors {
			fmt.Fprintln(os.Stderr, "load:", e)
		}
		for _, file := range p.Syntax {
			path := p.Fset.Position(file.Pos()).Filename
			goRel, _ := filepath.Rel(tsgoRoot, path)
			g := newGen(p, file, filepath.ToSlash(goRel), false)
			g.isPkg = true
			mod, _ := luaModule(p.PkgPath)
			g.pkgName = mod[strings.LastIndex(mod, ".")+1:]
			g.aliases[mod] = g.pkgName
			g.aliasOf[g.pkgName] = mod
			text := g.convertPkgFile()
			out := filepath.Join(outDir, strings.TrimSuffix(filepath.Base(path), ".go")+".lua")
			if err := os.WriteFile(out, []byte(text), 0o644); err != nil {
				panic(err)
			}
		}
	}
}

func (g *gen) convertPkgFile() string {
	tbl := g.pkgName
	// classes declared in this file
	for _, d := range g.file.Decls {
		gd, ok := d.(*ast.GenDecl)
		if !ok || gd.Tok != token.TYPE {
			continue
		}
		for _, spec := range gd.Specs {
			ts := spec.(*ast.TypeSpec)
			obj := g.info.Defs[ts.Name].(*types.TypeName)
			named, ok := obj.Type().(*types.Named)
			if !ok {
				continue
			}
			if _, isStruct := named.Underlying().(*types.Struct); !isStruct || !hasMethods(named) {
				continue
			}
			g.line("local %s = {}", ts.Name.Name)
			g.line("%s.__index = %s", ts.Name.Name, ts.Name.Name)
			g.line("%s.%s = %s", tbl, ts.Name.Name, ts.Name.Name)
			g.line("")
		}
	}
	// classes declared in other files that this file adds methods to
	declared := map[string]bool{}
	for _, d := range g.file.Decls {
		if gd, ok := d.(*ast.GenDecl); ok && gd.Tok == token.TYPE {
			for _, spec := range gd.Specs {
				declared[spec.(*ast.TypeSpec).Name.Name] = true
			}
		}
	}
	for _, d := range g.file.Decls {
		fd, ok := d.(*ast.FuncDecl)
		if !ok || fd.Recv == nil {
			continue
		}
		rt := g.info.Defs[fd.Name].Type().(*types.Signature).Recv().Type()
		if p, ok := rt.(*types.Pointer); ok {
			rt = p.Elem()
		}
		name := rt.(*types.Named).Obj().Name()
		if _, isStruct := rt.Underlying().(*types.Struct); isStruct && !declared[name] {
			declared[name] = true
			g.line("local %s = %s.%s", name, tbl, name)
			g.line("")
		}
	}
	// constants
	for _, d := range g.file.Decls {
		gd, ok := d.(*ast.GenDecl)
		if !ok || gd.Tok != token.CONST {
			continue
		}
		groups := map[string]bool{}
		for _, spec := range gd.Specs {
			vs := spec.(*ast.ValueSpec)
			for _, n := range vs.Names {
				c := g.info.Defs[n].(*types.Const)
				name := constLuaName(c)
				if i := strings.Index(name, "."); i >= 0 && !groups[name[:i]] {
					groups[name[:i]] = true
					g.line("%s.%s = %s.%s or {}", tbl, name[:i], tbl, name[:i])
				}
				g.line("%s.%s = %s", tbl, name, g.constValue(c.Val(), c.Type()))
			}
		}
		g.line("")
	}
	for _, d := range g.file.Decls {
		fd, ok := d.(*ast.FuncDecl)
		if !ok {
			continue
		}
		sig := g.info.Defs[fd.Name].Type().(*types.Signature)
		if fd.Recv != nil {
			recvField := fd.Recv.List[0]
			rt := sig.Recv().Type()
			if p, ok := rt.(*types.Pointer); ok {
				rt = p.Elem()
			}
			named := rt.(*types.Named)
			if len(recvField.Names) > 0 && recvField.Names[0].Name != "_" {
				g.names[g.info.Defs[recvField.Names[0]]] = "self"
			}
			if _, isStruct := named.Underlying().(*types.Struct); isStruct {
				g.funcDecl(named.Obj().Name()+":"+fd.Name.Name, fd.Type, fd.Body, sig)
			} else {
				// method on a named scalar type: package function <Type>_<Method>(self, ...)
				g.funcDeclSelf(tbl+"."+named.Obj().Name()+"_"+fd.Name.Name, fd.Type, fd.Body, sig)
			}
		} else {
			g.funcDecl(tbl+"."+fd.Name.Name, fd.Type, fd.Body, sig)
		}
		g.line("")
	}
	fileStart, fileEnd := g.file.Pos(), g.file.End()
	for _, init := range g.info.InitOrder {
		if len(init.Lhs) == 0 || init.Lhs[0].Pos() < fileStart || init.Lhs[0].Pos() > fileEnd {
			continue
		}
		var lhs []string
		for _, v := range init.Lhs {
			lhs = append(lhs, tbl+"."+v.Name())
		}
		g.line("%s = %s", strings.Join(lhs, ", "), g.expr(init.Rhs))
	}
	header := []string{"local " + tbl + " = require(\"tslua." + strings.TrimPrefix(g.pkg.PkgPath, modulePrefix) + "\")"}
	for m, a := range g.aliases {
		if a == tbl {
			continue
		}
		header = append(header, fmt.Sprintf("local %s = require(%q)", a, m))
	}
	if g.usesGort {
		header = append(header, `local gort = require("tslua.fourslash.goruntime")`)
	}
	return strings.Join(header, "\n") + "\n\n" + strings.Join(g.lines, "\n") + "\n"
}

func (g *gen) funcDeclSelf(name string, ft *ast.FuncType, body *ast.BlockStmt, sig *types.Signature) {
	params := append([]string{"self"}, g.params(ft)...)
	g.line("function %s(%s)", name, strings.Join(params, ", "))
	g.ind++
	g.funcPrologue(ft)
	g.sigStack = append(g.sigStack, sig)
	g.results, g.hasResults = g.namedResults(ft), sig.Results().Len() > 0
	savedDefer := g.deferStack
	g.deferStack = ""
	if !g.withDeferStack(body.List) {
		g.funcBody(body.List)
	}
	g.deferStack = savedDefer
	g.sigStack = g.sigStack[:len(g.sigStack)-1]
	g.ind--
	g.line("end")
}
