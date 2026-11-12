local estransforms = require("tslua.transformers.estransforms")
local core = require("tslua.core")
local transformers = require("tslua.transformers")

-- Go package-level function values are resolved at call time so that load order of the
-- package files does not matter.
local function lazy(name)
    return function(opts) return estransforms[name](opts) end
end

estransforms.esDecoratorAndClassFields = transformers.Chain(lazy("newESDecoratorTransformer"), lazy("newClassFieldsTransformer"))
estransforms.NewESNextTransformer = transformers.Chain(lazy("newUsingDeclarationTransformer"), estransforms.esDecoratorAndClassFields)
-- 2025: only module system syntax (import attributes, json modules), untransformed regex modifiers
-- 2024: no new downlevel syntax
-- 2023: no new downlevel syntax
-- 2022: class static blocks and class fields are handled by newClassFieldsTransformer
estransforms.NewES2021Transformer = transformers.Chain(estransforms.NewESNextTransformer, lazy("newLogicalAssignmentTransformer"))
estransforms.NewES2020Transformer = transformers.Chain(estransforms.NewES2021Transformer, lazy("newNullishCoalescingTransformer"), lazy("newOptionalChainTransformer"))
estransforms.NewES2019Transformer = transformers.Chain(estransforms.NewES2020Transformer, lazy("newOptionalCatchTransformer"))
estransforms.NewES2018Transformer = transformers.Chain(estransforms.NewES2019Transformer, lazy("newObjectRestSpreadTransformer"), lazy("newforawaitTransformer"), lazy("newTaggedTemplateLiftRestrictionTransformer"))
estransforms.NewES2017Transformer = transformers.Chain(estransforms.NewES2018Transformer, lazy("newAsyncTransformer"))
estransforms.NewES2016Transformer = transformers.Chain(estransforms.NewES2017Transformer, lazy("newExponentiationTransformer"))

function estransforms.GetESTransformer(opts)
    local options = opts.compilerOptions
    local target = options:GetEmitScriptTarget()
    local ST = core.ScriptTarget
    if target == ST.ESNext then
        return estransforms.esDecoratorAndClassFields(opts)
    elseif target == ST.ES2025 or target == ST.ES2024 or target == ST.ES2023 or target == ST.ES2022 or target == ST.ES2021 then
        return estransforms.NewESNextTransformer(opts)
    elseif target == ST.ES2020 then
        return estransforms.NewES2021Transformer(opts)
    elseif target == ST.ES2019 then
        return estransforms.NewES2020Transformer(opts)
    elseif target == ST.ES2018 then
        return estransforms.NewES2019Transformer(opts)
    elseif target == ST.ES2017 then
        return estransforms.NewES2018Transformer(opts)
    elseif target == ST.ES2016 then
        return estransforms.NewES2017Transformer(opts)
    else -- other, older, option, transform maximally
        return estransforms.NewES2016Transformer(opts)
    end
end
