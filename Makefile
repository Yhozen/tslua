UPSTREAM := vendor/typescript-go
GO_PKGS := ./internal/ast ./internal/core ./internal/checker ./internal/binder ./internal/scanner \
	./internal/parser ./internal/printer ./internal/compiler ./internal/diagnostics ./internal/tsoptions \
	./internal/transformers/... ./internal/module ./internal/jsnum ./internal/evaluator \
	./internal/outputpaths ./internal/tspath ./internal/collections ./internal/nodebuilder \
	./internal/sourcemap ./internal/stringutil ./internal/modulespecifiers \
	./internal/pseudochecker ./internal/ls ./internal/ls/lsutil ./internal/ls/lsconv ./internal/ls/change ./internal/ls/autoimport \
	./internal/project ./internal/project/dirty ./internal/project/logging ./internal/project/background \
	./internal/jsonrpc ./internal/lsp ./internal/lsp/lsproto ./internal/api ./internal/api/encoder \
	./internal/astnav ./internal/format ./internal/execute/incremental ./internal/spanmap ./internal/contentmapper \
	./internal/vfs/...

JOBS ?= 4
LUA_PATH_ENV := LUA_PATH="src/?.lua;src/?/init.lua;;"

.PHONY: all test spec spec-all lint baselines baselines-passing tsctests-passing fourslash-passing generate upstream rock

all: lint spec

upstream:
	./scripts/fetch-upstream.sh

generate:
	cd scripts/gen/goconsts && go run . $(abspath $(UPSTREAM)) $(abspath src/tslua) $(GO_PKGS)
	node scripts/gen/diagnostics.mjs $(UPSTREAM)
	cd scripts/gen/loctables && go run . $(abspath $(UPSTREAM)) $(abspath src/tslua)
	node scripts/gen/ast.mjs $(UPSTREAM)
	node scripts/gen/lsproto.mjs $(UPSTREAM)

# bin/* have no .lua extension, so they are listed explicitly.
lint:
	luacheck src spec tests $(wildcard bin/*)

# Skips the specs tagged #slow; spec-all runs them too.
spec:
	busted

spec-all:
	busted --run=all

test: lint spec baselines-passing tsctests-passing fourslash-passing

# Runs every case listed in tests/passing/ and fails on any regression.
baselines-passing:
	$(LUA_PATH_ENV) lua bin/tslua-test --passing --jobs $(JOBS) --batch 100 -q

# tsc / tsc -b / --watch scenarios (tests/passing/tsc.txt) and fourslash tests (tests/passing/fourslash.txt).
tsctests-passing:
	lua bin/tslua-tsctest --passing --jobs $(JOBS) -q

fourslash-passing:
	lua bin/tslua-fourslash --passing --jobs $(JOBS) -q

# Runs the full upstream compiler + conformance suites and reports the pass rate.
baselines:
	$(LUA_PATH_ENV) lua bin/tslua-test --all

# Installs the modules, the bundled lib .d.ts files and bin/tslua into the default LuaRocks tree.
rock:
	luarocks make tslua-dev-1.rockspec
