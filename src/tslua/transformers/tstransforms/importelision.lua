local tstransforms = require("tslua.transformers.tstransforms")
local transformers = require("tslua.transformers")
local ast = require("tslua.ast")
local core = require("tslua.core")

local Kind = ast.Kind

local ImportElisionTransformer = transformers.NewTransformerType()
tstransforms.ImportElisionTransformer = ImportElisionTransformer

function tstransforms.NewImportElisionTransformer(opt)
    local compilerOptions = opt.compilerOptions
    local emitContext = opt.context
    if core.Tristate_IsTrue(compilerOptions.verbatimModuleSyntax) then
        error("ImportElisionTransformer should not be used with VerbatimModuleSyntax", 0)
    end
    local tx = setmetatable({ compilerOptions = compilerOptions, currentSourceFile = nil, emitResolver = opt.emitResolver }, ImportElisionTransformer)
    return tx:NewTransformer(function(node) return tx:visit(node) end, emitContext)
end

function ImportElisionTransformer:visit(node)
    if ast.IsSourceFile(node) and self.emitResolver ~= nil then
        self.emitResolver:MarkLinkedReferencesRecursively(self:EmitContext():MostOriginal(node):AsSourceFile())
    end

    local kind = node.kind
    if kind == Kind.ImportEqualsDeclaration then
        if ast.IsExternalModuleImportEqualsDeclaration(node) then
            if not self:shouldEmitAliasDeclaration(node) then
                return nil
            end
        else
            if not self:shouldEmitImportEqualsDeclaration(node:AsImportEqualsDeclaration()) then
                return nil
            end
        end
        return self:Visitor():VisitEachChild(node)
    elseif kind == Kind.ImportDeclaration then
        local n = node:AsImportDeclaration()
        -- Do not elide a side-effect only import declaration.
        --  import "foo";
        if n.importClause ~= nil then
            local importClause = self:Visitor():VisitNode(n.importClause)
            if importClause == nil then
                return nil
            end
            return self:Factory():UpdateImportDeclaration(n, n:Modifiers(), importClause, n.moduleSpecifier, self:Visitor():VisitNode(n.attributes))
        end
        return self:Visitor():VisitEachChild(node)
    elseif kind == Kind.ImportClause then
        local n = node:AsImportClause()
        local name
        if self:shouldEmitAliasDeclaration(node) then
            name = n:Name()
        end
        local namedBindings = self:Visitor():VisitNode(n.namedBindings)
        if name == nil and namedBindings == nil then
            -- all import bindings were elided
            return nil
        end
        return self:Factory():UpdateImportClause(n, n.phaseModifier, name, namedBindings)
    elseif kind == Kind.NamespaceImport then
        if not self:shouldEmitAliasDeclaration(node) then
            -- elide unused imports
            return nil
        end
        return node
    elseif kind == Kind.NamedImports then
        local n = node:AsNamedImports()
        local elements = self:Visitor():VisitNodes(n.elements)
        if core.Len(elements.nodes) == 0 then
            -- all import specifiers were elided
            return nil
        end
        return self:Factory():UpdateNamedImports(n, elements)
    elseif kind == Kind.ImportSpecifier then
        if not self:shouldEmitAliasDeclaration(node) then
            -- elide type-only or unused imports
            return nil
        end
        return node
    elseif kind == Kind.ExportAssignment then
        if not core.Tristate_IsTrue(self.compilerOptions.verbatimModuleSyntax) and not self:isValueAliasDeclaration(node) then
            -- elide unused import
            return nil
        end
        return self:Visitor():VisitEachChild(node)
    elseif kind == Kind.ExportDeclaration then
        local n = node:AsExportDeclaration()
        local exportClause
        if n.exportClause ~= nil then
            exportClause = self:Visitor():VisitNode(n.exportClause)
            if exportClause == nil then
                -- all export bindings were elided
                return nil
            end
        end
        return self:Factory():UpdateExportDeclaration(n, nil --[[modifiers]], false --[[isTypeOnly]], exportClause, self:Visitor():VisitNode(n.moduleSpecifier), self:Visitor():VisitNode(n.attributes))
    elseif kind == Kind.NamedExports then
        local n = node:AsNamedExports()
        local elements = self:Visitor():VisitNodes(n.elements)
        if core.Len(elements.nodes) == 0 then
            -- all export specifiers were elided
            return nil
        end
        return self:Factory():UpdateNamedExports(n, elements)
    elseif kind == Kind.ExportSpecifier then
        if not self:isValueAliasDeclaration(node) then
            -- elide unused export
            return nil
        end
        return node
    elseif kind == Kind.SourceFile then
        local savedCurrentSourceFile = self.currentSourceFile
        self.currentSourceFile = node:AsSourceFile()
        node = self:Visitor():VisitEachChild(node)
        self.currentSourceFile = savedCurrentSourceFile
        return node
    elseif kind == Kind.ModuleDeclaration or kind == Kind.ModuleBlock then
        return self:Visitor():VisitEachChild(node)
    else
        return node
    end
end

function ImportElisionTransformer:shouldEmitAliasDeclaration(node)
    return ast.IsInJSFile(node) or self:isReferencedAliasDeclaration(node)
end

function ImportElisionTransformer:shouldEmitImportEqualsDeclaration(node)
    -- preserve old compiler's behavior: emit import declaration (even if we do not consider them referenced) when
    -- - current file is not external module
    -- - import declaration is top level and target is value imported by entity name
    return self:shouldEmitAliasDeclaration(node:AsNode()) or (not ast.IsExternalModule(self.currentSourceFile) and self:isTopLevelValueImportEqualsWithEntityName(node:AsNode()))
end

function ImportElisionTransformer:isReferencedAliasDeclaration(node)
    node = self:EmitContext():ParseNode(node)
    return node == nil or self.emitResolver:IsReferencedAliasDeclaration(node)
end

function ImportElisionTransformer:isValueAliasDeclaration(node)
    node = self:EmitContext():ParseNode(node)
    return node == nil or self.emitResolver:IsValueAliasDeclaration(node)
end

function ImportElisionTransformer:isTopLevelValueImportEqualsWithEntityName(node)
    node = self:EmitContext():ParseNode(node)
    return node ~= nil and self.emitResolver:IsTopLevelValueImportEqualsWithEntityName(node)
end
