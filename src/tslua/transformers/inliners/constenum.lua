local inliners = require("tslua.transformers.inliners")
local transformers = require("tslua.transformers")
local ast = require("tslua.ast")
local core = require("tslua.core")
local debug = require("tslua.debug")
local jsnum = require("tslua.jsnum")
local scanner = require("tslua.scanner")

local Kind = ast.Kind

local ConstEnumInliningTransformer = transformers.NewTransformerType()
inliners.ConstEnumInliningTransformer = ConstEnumInliningTransformer

function inliners.NewConstEnumInliningTransformer(opt)
    local compilerOptions = opt.compilerOptions
    local emitContext = opt.context
    if compilerOptions:GetIsolatedModules() then
        debug.Fail("const enums are not inlined under isolated modules")
    end
    local tx = setmetatable({ compilerOptions = compilerOptions, currentSourceFile = nil, emitResolver = opt.emitResolver }, ConstEnumInliningTransformer)
    return tx:NewTransformer(function(node) return tx:visit(node) end, emitContext)
end

function ConstEnumInliningTransformer:visit(node)
    if node.kind == Kind.PropertyAccessExpression or node.kind == Kind.ElementAccessExpression then
        local parse = self:EmitContext():ParseNode(node)
        if parse == nil then
            return self:Visitor():VisitEachChild(node)
        end
        local value = self.emitResolver:GetConstantValue(parse)
        if value ~= nil then
            local replacement
            if type(value) == "number" then
                local v = value
                if jsnum.Number_IsInf(v) then
                    if jsnum.Number_Abs(v) == v then
                        replacement = self:Factory():NewIdentifier("Infinity")
                    else
                        replacement = self:Factory():NewPrefixUnaryExpression(Kind.MinusToken, self:Factory():NewIdentifier("Infinity"))
                    end
                elseif jsnum.Number_IsNaN(v) then
                    replacement = self:Factory():NewIdentifier("NaN")
                elseif jsnum.Number_Abs(v) == v then
                    replacement = self:Factory():NewNumericLiteral(jsnum.Number_String(v), ast.TokenFlags.None)
                else
                    replacement = self:Factory():NewPrefixUnaryExpression(Kind.MinusToken, self:Factory():NewNumericLiteral(jsnum.Number_String(jsnum.Number_Abs(v)), ast.TokenFlags.None))
                end
            elseif type(value) == "string" then
                replacement = self:Factory():NewStringLiteral(value, ast.TokenFlags.None)
            elseif getmetatable(value) == jsnum.PseudoBigInt then -- technically not supported by strada, and issues a checker error, handled here for completeness
                local v = value
                if not v.negative and v.base10Value == "" then
                    replacement = self:Factory():NewBigIntLiteral("0", ast.TokenFlags.None)
                elseif not v.negative then
                    replacement = self:Factory():NewBigIntLiteral(v.base10Value, ast.TokenFlags.None)
                else
                    replacement = self:Factory():NewPrefixUnaryExpression(Kind.MinusToken, self:Factory():NewBigIntLiteral(v.base10Value, ast.TokenFlags.None))
                end
            end

            if core.Tristate_IsFalseOrUnknown(self.compilerOptions.removeComments) then
                local original = self:EmitContext():MostOriginal(node)
                if original ~= nil and not ast.NodeIsSynthesized(original) then
                    local originalText = scanner.GetTextOfNode(original)
                    local escapedText = inliners.safeMultiLineComment(originalText)
                    self:EmitContext():AddSyntheticTrailingComment(replacement, Kind.MultiLineCommentTrivia, escapedText, false)
                end
            end
            return replacement
        end
        return self:Visitor():VisitEachChild(node)
    end
    return self:Visitor():VisitEachChild(node)
end

function inliners.safeMultiLineComment(text)
    local b = { " " }
    while true do
        local i = string.find(text, "*/", 1, true)
        if i == nil then
            break
        end
        b[#b + 1] = string.sub(text, 1, i - 1)
        b[#b + 1] = "*_/"
        text = string.sub(text, i + 2)
    end
    b[#b + 1] = text
    b[#b + 1] = " "
    return table.concat(b)
end
