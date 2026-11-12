local ls = require("tslua.ls")
local collections = require("tslua.collections")
local core = require("tslua.core")
local lsproto = require("tslua.lsp.lsproto")

-- Project is an interface: Id() tspath.Path, GetProgram() *compiler.Program, HasFile(fileName) bool.

-- projectAndTextDocumentPosition: { project, ls, uri, position, forOriginalLocation }

-- response[Resp]: { complete, result, forOriginalLocation }

-- CrossProjectOrchestrator is an interface:
--   GetDefaultProject() Project
--   GetAllProjectsForInitialRequest() []Project
--   GetLanguageServiceForProjectWithFile(ctx, project, uri) *LanguageService
--   GetProjectsForFile(ctx, uri) ([]Project, error)
--   GetProjectsLoadingProjectTree(ctx, requestedProjectTrees *collections.Set[tspath.Path]) iter.Seq[Project]
--     (a Lua iterator or an array)

-- lsproto.HasTextDocumentPosition accessors; params may be a generated lsproto struct (with the
-- methods) or a plain table with Go-shaped fields.
local function textDocumentURI(params)
    if type(params.TextDocumentURI) == "function" then
        return params:TextDocumentURI()
    end
    return params.textDocument.uri
end

local function textDocumentPosition(params)
    if type(params.TextDocumentPosition) == "function" then
        return params:TextDocumentPosition()
    end
    return params.position
end

local function iterate(seq)
    if type(seq) == "function" then
        return seq
    end
    local i = 0
    return function()
        i = i + 1
        return (seq or {})[i]
    end
end

-- Go's iter.Seq results are passed to combineResults as an array.
function ls.handleCrossProject(defaultLs, ctx, params, orchestrator, symbolAndEntriesToResp, combineResults, isRename, implementations, options)
    local resp = nil
    local err = nil

    -- Single project
    if orchestrator == nil then
        local data = defaultLs:provideSymbolsAndEntries(ctx, textDocumentURI(params), textDocumentPosition(params), isRename, implementations)
        return symbolAndEntriesToResp(defaultLs, ctx, params, data, options)
    end

    local defaultProject = orchestrator:GetDefaultProject()
    local allProjects = orchestrator:GetAllProjectsForInitialRequest()
    -- Go sync.Map; iterated in insertion order here.
    local results = collections.NewOrderedMap()
    local defaultDefinition = nil
    local canSearchProject = function(project)
        return not results:Has(project:Id())
    end
    local wg = core.NewWorkGroup(false)
    local enqueueItem
    local panicsOccured = nil
    enqueueItem = function(item)
        local response = { complete = false, result = nil, forOriginalLocation = false }
        if results:Has(item.project:Id()) then
            return
        end
        results:Set(item.project:Id(), response)
        wg:Queue(function()
            if core.ContextErr(ctx) ~= nil then
                return
            end
            local ok, perr = pcall(function()
                -- Process the item
                local itemLs = item.ls
                if itemLs == nil then
                    -- Get it now
                    itemLs = orchestrator:GetLanguageServiceForProjectWithFile(ctx, item.project, item.uri)
                    if itemLs == nil then
                        return
                    end
                end
                local data, found = itemLs:provideSymbolsAndEntries(ctx, item.uri, item.position, isRename, implementations)
                if core.ContextErr(ctx) ~= nil then
                    return
                end
                if found then
                    for _, entry in ipairs(data.symbolsAndEntries or {}) do
                        -- Find the default definition that can be in another project
                        -- Later we will use this load ancestor tree that references this location and expand search
                        if item.project == defaultProject and defaultDefinition == nil then
                            defaultDefinition = itemLs:getNonLocalDefinition(ctx, entry)
                        end
                        itemLs:forEachOriginalDefinitionLocation(ctx, entry, function(uri, position)
                            -- Get default configured project for this file
                            local defProjects, errProjects = orchestrator:GetProjectsForFile(ctx, uri)
                            if errProjects ~= nil then
                                return
                            end
                            for _, defProject in ipairs(defProjects or {}) do
                                -- Optimization: don't enqueue if will be discarded
                                if canSearchProject(defProject) then
                                    enqueueItem({
                                        project = defProject,
                                        uri = uri,
                                        position = position,
                                        forOriginalLocation = true,
                                    })
                                end
                            end
                        end)
                    end
                end

                local result, errSearch = symbolAndEntriesToResp(itemLs, ctx, params, data, options)
                if errSearch == nil then
                    response.complete = true
                    response.result = result
                    response.forOriginalLocation = item.forOriginalLocation or false
                else
                    if err == nil then
                        err = errSearch
                    end
                end
            end)
            if not ok then
                local panicOccured = "panic handling request: " .. tostring(perr) .. "\n" .. debug.traceback()
                panicsOccured = core.Append(panicsOccured, panicOccured)
            end
        end)
    end

    -- Initial set of projects and locations in the queue, starting with default project
    enqueueItem({
        project = defaultProject,
        ls = defaultLs,
        uri = textDocumentURI(params),
        position = textDocumentPosition(params),
    })
    for _, project in ipairs(allProjects or {}) do
        if project ~= defaultProject then
            enqueueItem({
                project = project,
                -- TODO!! symlinks need to change the URI
                uri = textDocumentURI(params),
                position = textDocumentPosition(params),
            })
        end
    end

    local getResults = function()
        local out = {}
        local seenProjects = collections.NewSet()
        local response = results:Get(defaultProject:Id())
        if response ~= nil and response.complete then
            out[#out + 1] = response.result
        end
        seenProjects:Add(defaultProject:Id())
        for _, project in ipairs(allProjects or {}) do
            if seenProjects:AddIfAbsent(project:Id()) then
                local r = results:Get(project:Id())
                if r ~= nil and r.complete then
                    out[#out + 1] = r.result
                end
            end
        end
        -- Prefer the searches from locations for default definition
        for key, r in results:Entries() do
            if not r.forOriginalLocation and seenProjects:AddIfAbsent(key) and r.complete then
                out[#out + 1] = r.result
            end
        end
        -- Then the searches from original locations
        for key, r in results:Entries() do
            if r.forOriginalLocation and seenProjects:AddIfAbsent(key) and r.complete then
                out[#out + 1] = r.result
            end
        end
        return out
    end

    -- Outer loop - to complete work if more is added after completing existing queue
    while true do
        -- Process existing known projects first
        wg:RunAndWait()
        if panicsOccured ~= nil then
            error("Panics occurred during cross-project handling: [" .. table.concat(panicsOccured, " ") .. "]", 0)
        end
        if core.ContextErr(ctx) ~= nil then
            return resp, core.ContextErr(ctx)
        end
        if err ~= nil then
            return resp, err
        end

        wg = core.NewWorkGroup(false)
        local hasMoreWork = false
        if defaultDefinition ~= nil then
            local requestedProjectTrees = collections.NewSet()
            for key, r in results:Entries() do
                if r.complete then
                    requestedProjectTrees:Add(key)
                end
            end

            -- Load more projects based on default definition found
            for loadedProject in iterate(orchestrator:GetProjectsLoadingProjectTree(ctx, requestedProjectTrees)) do
                if core.ContextErr(ctx) ~= nil then
                    return resp, core.ContextErr(ctx)
                end

                -- Can loop forever without this (enqueue here, dequeue above, repeat)
                if not canSearchProject(loadedProject) or loadedProject:GetProgram() == nil then
                    goto continue
                end

                do
                    -- Enqueue the project and location for further processing
                    local sourcePos, generatedPos
                    if loadedProject:HasFile(lsproto.DocumentUri_FileName(defaultDefinition:TextDocumentURI())) then
                        enqueueItem({
                            project = loadedProject,
                            uri = defaultDefinition:TextDocumentURI(),
                            position = defaultDefinition:TextDocumentPosition(),
                        })
                        hasMoreWork = true
                    else
                        sourcePos = defaultDefinition.getSourcePosition()
                        if sourcePos ~= nil and loadedProject:HasFile(lsproto.DocumentUri_FileName(sourcePos:TextDocumentURI())) then
                            enqueueItem({
                                project = loadedProject,
                                uri = sourcePos:TextDocumentURI(),
                                position = sourcePos:TextDocumentPosition(),
                            })
                            hasMoreWork = true
                        else
                            generatedPos = defaultDefinition.getGeneratedPosition()
                            if generatedPos ~= nil and loadedProject:HasFile(lsproto.DocumentUri_FileName(generatedPos:TextDocumentURI())) then
                                enqueueItem({
                                    project = loadedProject,
                                    uri = generatedPos:TextDocumentURI(),
                                    position = generatedPos:TextDocumentPosition(),
                                })
                                hasMoreWork = true
                            end
                        end
                    end
                end
                ::continue::
            end
        end
        if not hasMoreWork then
            break
        end
    end

    if results:Size() > 1 then
        resp = combineResults(getResults())
    else
        -- Single result, return that directly
        local values = getResults()
        if #values > 0 then
            resp = values[1]
        end
    end
    return resp, nil
end

-- Struct keys for sets of lsproto.Location / lsproto.Range.
local function rangeKey(r)
    return string.format("%d:%d-%d:%d", r.start.line, r.start.character, r.end_.line, r.end_.character)
end

local function locationKey(loc)
    return tostring(loc.uri) .. "\0" .. rangeKey(loc.range)
end

-- lsproto.HasLocation.GetLocation for generated structs or plain tables.
local function getLocation(x)
    if type(x.GetLocation) == "function" then
        return x:GetLocation()
    end
    if x.targetUri ~= nil then
        return { uri = x.targetUri, range = x.targetRange }
    end
    return { uri = x.uri, range = x.range }
end

-- lsproto.HasLocations.GetLocations
local function getLocations(x)
    if type(x.GetLocations) == "function" then
        return x:GetLocations()
    end
    return x.locations
end

-- seen is a collections.Set of location keys.
function ls.combineLocationArray(combined, locations, seen)
    for _, loc in ipairs(locations or {}) do
        if seen:AddIfAbsent(locationKey(getLocation(loc))) then
            combined = core.Append(combined, loc)
        end
    end
    return combined
end

function ls.combineResponseLocations(results)
    local combined = nil
    local seenLocations = collections.NewSet()
    for _, resp in ipairs(results) do
        local locations = getLocations(resp)
        if locations ~= nil then
            combined = ls.combineLocationArray(combined, locations, seenLocations)
        end
    end
    return combined or {}
end

-- Unions are tables with the Go field names (lsproto.LocationsOrNull{Locations: x} -> { locations = x }).
function ls.combineReferences(results)
    return { locations = ls.combineResponseLocations(results) }
end

function ls.combineVSReferences(results)
    local combined = nil
    -- Re-number IDs across projects to maintain unique IDs and correct definition references
    local nextId = 0
    for _, resp in ipairs(results) do
        if resp.vsReferenceItems == nil then
            goto continue
        end
        do
            -- Map old IDs to new IDs for this batch
            local idMap = {}
            for _, item in ipairs(resp.vsReferenceItems) do
                local oldId = item.vsId
                local newId = nextId
                idMap[oldId] = newId
                nextId = nextId + 1

                local newItem = {}
                for k, v in pairs(item) do
                    newItem[k] = v
                end
                setmetatable(newItem, getmetatable(item))
                newItem.vsId = newId
                if item.vsDefinitionId ~= nil then
                    local newDefId = idMap[item.vsDefinitionId] or 0
                    newItem.vsDefinitionId = newDefId
                end
                combined = core.Append(combined, newItem)
            end
        end
        ::continue::
    end
    return { vsReferenceItems = combined or {} }
end

function ls.combineImplementations(results)
    local combined = nil
    local seenLocations = collections.NewSet()
    for _, resp in ipairs(results) do
        local definitionLinks = resp.definitionLinks
        if definitionLinks ~= nil then
            combined = ls.combineLocationArray(combined, definitionLinks, seenLocations)
        elseif resp.locations ~= nil then
            -- Go passes the iter.Seq on, which iterates all results again from the start.
            return { locations = ls.combineResponseLocations(results) }
        end
    end
    return { definitionLinks = combined or {} }
end

function ls.combineRenameResponse(results)
    local combined = {}
    local combinedOrder = {}
    local seenChanges = {}
    local documentChanges = nil
    local seenRenames = collections.NewSet()

    for _, resp in ipairs(results) do
        if resp.workspaceEdit ~= nil and resp.workspaceEdit.documentChanges ~= nil then
            for _, c in ipairs(resp.workspaceEdit.documentChanges) do
                if c.renameFile ~= nil then
                    local key = tostring(c.renameFile.oldUri) .. "\0" .. tostring(c.renameFile.newUri)
                    if seenRenames:AddIfAbsent(key) then
                        documentChanges = core.Append(documentChanges, c)
                    end
                else
                    documentChanges = core.Append(documentChanges, c)
                end
            end
        end
        if resp.workspaceEdit ~= nil and resp.workspaceEdit.changes ~= nil then
            -- Go map iteration order is random; iterate documents sorted.
            local docs = {}
            for doc in pairs(resp.workspaceEdit.changes) do
                docs[#docs + 1] = doc
            end
            table.sort(docs)
            for _, doc in ipairs(docs) do
                local changes = resp.workspaceEdit.changes[doc]
                local seenSet = seenChanges[doc]
                if seenSet == nil then
                    seenSet = collections.NewSet()
                    seenChanges[doc] = seenSet
                end
                local changesForDoc = combined[doc]
                if changesForDoc == nil then
                    changesForDoc = {}
                    combinedOrder[#combinedOrder + 1] = doc
                end
                for _, c in ipairs(changes) do
                    local key = rangeKey(c.range)
                    if not seenSet:Has(key) then
                        seenSet:Add(key)
                        changesForDoc[#changesForDoc + 1] = c
                    end
                end
                combined[doc] = changesForDoc
            end
        end
    end
    if core.Len(documentChanges) > 0 or #combinedOrder > 0 then
        local workspaceEdit = {}
        if core.Len(documentChanges) > 0 then
            workspaceEdit.documentChanges = documentChanges
        end
        if #combinedOrder > 0 then
            workspaceEdit.changes = combined
        end
        return {
            workspaceEdit = workspaceEdit,
        }
    end
    return {}
end

function ls.combineIncomingCalls(results)
    local combined = nil
    local seenCalls = collections.NewSet()
    for _, resp in ipairs(results) do
        if resp.callHierarchyIncomingCalls ~= nil then
            for _, call in ipairs(resp.callHierarchyIncomingCalls) do
                if seenCalls:AddIfAbsent(locationKey(getLocation(call.from))) then
                    combined = core.Append(combined, call)
                end
            end
        end
    end
    return { callHierarchyIncomingCalls = combined or {} }
end
