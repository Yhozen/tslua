local estransforms = require("tslua.transformers.estransforms")
local ast = require("tslua.ast")
local core = require("tslua.core")
local transformers = require("tslua.transformers")

local useStrictTransformer = transformers.NewTransformerType()
estransforms.useStrictTransformer = useStrictTransformer

function estransforms.NewUseStrictTransformer(opts)
    local tx = setmetatable({
        compilerOptions = opts.compilerOptions,
        getEmitModuleFormatOfFile = opts.getEmitModuleFormatOfFile,
    }, useStrictTransformer)
    return tx:NewTransformer(function(node) return tx:visit(node) end, opts.context)
end

function useStrictTransformer:visit(node)
    if node.kind ~= ast.Kind.SourceFile then
        return node
    end
    return self:visitSourceFile(node:AsSourceFile())
end

function useStrictTransformer:visitSourceFile(node)
    if node.scriptKind == core.ScriptKind.JSON then
        return node:AsNode()
    end

    local isExternalModule = ast.IsExternalModule(node)
    local moduleKind = self.compilerOptions:GetEmitModuleKind()
    local format = self.getEmitModuleFormatOfFile(node)

    -- ESM is always strict. If the file is ESM, and CJS emit
    -- has not been requested, then skip adding "use strict".
    if isExternalModule and moduleKind >= core.ModuleKind.ES2015 and
        (moduleKind == core.ModuleKind.Preserve or format >= core.ModuleKind.ES2015) then
        return node:AsNode()
    end

    local statements = self:Factory():EnsureUseStrict(node.statements.nodes)
    local statementList = self:Factory():NewNodeList(statements)
    statementList.loc = node.statements.loc
    return self:Factory():UpdateSourceFile(node, statementList, node.endOfFileToken):AsSourceFile():AsNode()
end
