local moduletransforms = require("tslua.transformers.moduletransforms")
local ast = require("tslua.ast")
local core = require("tslua.core")
local transformers = require("tslua.transformers")

local ImpliedModuleTransformer = transformers.NewTransformerType()
moduletransforms.ImpliedModuleTransformer = ImpliedModuleTransformer

function moduletransforms.NewImpliedModuleTransformer(opts)
    local tx = setmetatable({
        opts = opts,
        resolver = opts.resolver,
        getEmitModuleFormatOfFile = opts.getEmitModuleFormatOfFile,
        cjsTransformer = nil,
        esmTransformer = nil,
    }, ImpliedModuleTransformer)
    return tx:NewTransformer(function(node) return tx:visit(node) end, opts.context)
end

function ImpliedModuleTransformer:visit(node)
    if node.kind == ast.Kind.SourceFile then
        node = self:visitSourceFile(node:AsSourceFile())
    end
    return node
end

function ImpliedModuleTransformer:visitSourceFile(node)
    if node.isDeclarationFile then
        return node:AsNode()
    end

    local format = self.getEmitModuleFormatOfFile(node)

    local transformer
    if format >= core.ModuleKind.ES2015 then
        if self.esmTransformer == nil then
            self.esmTransformer = moduletransforms.NewESModuleTransformer(self.opts)
        end
        transformer = self.esmTransformer
    else
        if self.cjsTransformer == nil then
            self.cjsTransformer = moduletransforms.NewCommonJSModuleTransformer(self.opts)
        end
        transformer = self.cjsTransformer
    end

    return transformer:TransformSourceFile(node):AsNode()
end
