local ls = require("tslua.ls")
local core = require("tslua.core")
local lsconv = require("tslua.ls.lsconv")
local outputpaths = require("tslua.outputpaths")
local sourcemap = require("tslua.sourcemap")
local tspath = require("tslua.tspath")

local LanguageService = ls.LanguageService

-- sourceFileRangeToLSPLocation maps a range from an arbitrary program SourceFile to an LSP location,
-- composing content-mapper span maps and declaration source maps as needed. LS features should use this
-- for cross-file results instead of calling getMappedLocation or lsconv.ToLSPLocation directly.
-- This unfiltered form is appropriate for diagnostics and text edits.
-- Returns (lsproto.Location, spanmap.Fidelity).
function LanguageService:sourceFileRangeToLSPLocation(file, fileRange)
    if file:ContentMapper() ~= "" then
        return self.converters:ToLSPLocation(file, fileRange)
    end
    return self:getMappedLocation(file:FileName(), fileRange)
end

-- sourceFileRangeToLSPLocationForFeature is the preferred conversion for visible LS results that may
-- come from another file. It applies content-mapper feature filtering and follows declaration source maps.
-- Do not use it for diagnostics or text edits.
function LanguageService:sourceFileRangeToLSPLocationForFeature(file, fileRange, feature)
    if file:ContentMapper() ~= "" then
        return self.converters:ToLSPLocationForFeature(file, fileRange, feature)
    end
    return self:getMappedLocation(file:FileName(), fileRange)
end

-- getMappedLocation follows declaration source maps from a .d.ts range to its source location.
-- It is an implementation detail of sourceFileRangeToLSPLocation; LS features should not call it directly,
-- because it does not preserve a content-mapper projection or apply span-map feature filtering.
function LanguageService:getMappedLocation(fileName, fileRange)
    local startPos = self:tryGetSourcePosition(fileName, fileRange:Pos())
    if startPos == nil then
        local lspRange, fidelity = self:createLspRangeFromRange(fileRange, self:getScript(fileName))
        return {
            uri = lsconv.FileNameToDocumentURI(fileName),
            range = lspRange,
        }, fidelity
    end
    local endPos = self:tryGetSourcePosition(fileName, fileRange:End())
    if endPos == nil or endPos.fileName ~= startPos.fileName or endPos.pos < startPos.pos then
        -- When end doesn't map, maps to a different source file (e.g. in a .d.ts with a
        -- multi-source source map from --outFile compilation), or maps to a position before
        -- start (non-monotonic source map mappings), approximate the end position.
        endPos = sourcemap.NewDocumentPosition(startPos.fileName, startPos.pos + fileRange:Len())
    end
    local newRange = core.NewTextRange(startPos.pos, endPos.pos)
    local lspRange, fidelity = self:createLspRangeFromRange(newRange, self:getScript(startPos.fileName))
    return {
        uri = lsconv.FileNameToDocumentURI(startPos.fileName),
        range = lspRange,
    }, fidelity
end

-- script: { fileName, text } implementing lsconv.Script
local script = {}
script.__index = script
ls.script = script

function script:FileName()
    return self.fileName
end

function script:OriginalFileName() return self.fileName end

function script:Text()
    return self.text
end

function script:OriginalText() return self.text end
function script:SpanMap() return nil end

function LanguageService:getScript(fileName)
    local text, ok = self.host:ReadFile(fileName)
    if not ok then
        return nil
    end
    return setmetatable({ fileName = fileName, text = text }, script)
end

function LanguageService:tryGetSourcePosition(fileName, position)
    local newPos = self:tryGetSourcePositionWorker(fileName, position)
    if newPos ~= nil then
        local _, ok = self:ReadFile(newPos.fileName)
        if not ok then -- File doesn't exist
            return nil
        end
    end
    return newPos
end

function LanguageService:tryGetSourcePositionWorker(fileName, position)
    if not tspath.IsDeclarationFileName(fileName) then
        return nil
    end

    local positionMapper = self:GetDocumentPositionMapper(fileName)
    local documentPos = sourcemap.DocumentPositionMapper.GetSourcePosition(positionMapper, sourcemap.NewDocumentPosition(fileName, position))
    if documentPos == nil then
        return nil
    end
    local newPos = self:tryGetSourcePositionWorker(documentPos.fileName, documentPos.pos)
    if newPos ~= nil then
        return newPos
    end
    return documentPos
end

function LanguageService:tryGetGeneratedPosition(fileName, position)
    local newPos = self:tryGetGeneratedPositionWorker(fileName, position)
    if newPos ~= nil then
        local _, ok = self:ReadFile(newPos.fileName)
        if not ok then -- File doesn't exist
            return nil
        end
    end
    return newPos
end

function LanguageService:tryGetGeneratedPositionWorker(fileName, position)
    if tspath.IsDeclarationFileName(fileName) then
        return nil
    end

    local program = self:GetProgram()
    if program == nil or program:GetSourceFile(fileName) == nil then
        return nil
    end

    local path = self:toPath(fileName)
    -- If this is source file of project reference source (instead of redirect) there is no generated position
    if program:IsSourceFromProjectReference(path) then
        return nil
    end

    local declarationFileName = outputpaths.GetOutputDeclarationFileNameWorker(fileName, program:Options(), program)
    local positionMapper = self:GetDocumentPositionMapper(declarationFileName)
    local documentPos = sourcemap.DocumentPositionMapper.GetGeneratedPosition(positionMapper, sourcemap.NewDocumentPosition(fileName, position))
    if documentPos == nil then
        return nil
    end
    local newPos = self:tryGetGeneratedPositionWorker(documentPos.fileName, documentPos.pos)
    if newPos ~= nil then
        return newPos
    end
    return documentPos
end
