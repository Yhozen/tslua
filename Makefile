UPSTREAM := vendor/typescript-go
GO_PKGS := ./internal/ast ./internal/core ./internal/checker ./internal/binder ./internal/scanner \
	./internal/parser ./internal/printer ./internal/compiler ./internal/diagnostics ./internal/tsoptions \
	./internal/transformers/... ./internal/module ./internal/jsnum ./internal/evaluator \
	./internal/outputpaths ./internal/tspath ./internal/collections ./internal/nodebuilder \
	./internal/sourcemap ./internal/stringutil

LUA_PATH_ENV := LUA_PATH="src/?.lua;src/?/init.lua;;"

.PHONY: all test spec lint baselines generate upstream

all: lint spec

upstream:
	./scripts/fetch-upstream.sh

generate:
	cd scripts/gen/goconsts && go run . $(abspath $(UPSTREAM)) $(abspath src/tslua) $(GO_PKGS)
	node scripts/gen/diagnostics.mjs $(UPSTREAM)
	node scripts/gen/ast.mjs $(UPSTREAM)

lint:
	luacheck src spec tests bin

spec:
	busted

test: lint spec baselines-passing

# Runs every case listed in tests/passing/ and fails on any regression.
baselines-passing:
	$(LUA_PATH_ENV) lua bin/tslua-test --passing

# Runs the full upstream compiler + conformance suites and reports the pass rate.
baselines:
	$(LUA_PATH_ENV) lua bin/tslua-test --all
