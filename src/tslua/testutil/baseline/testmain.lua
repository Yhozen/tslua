local baseline = require("tslua.testutil.baseline")

-- recordedBaselines tracks all baseline file paths that were written during the test run (a set).
baseline.recordedBaselines = {}

-- trackingInitialized is set to true when Track() is called.
baseline.trackingInitialized = false

-- trackingDir is the directory where tracking files should be written.
-- If non-empty, baseline tracking is enabled.
baseline.trackingDir = os.getenv("TSGO_BASELINE_TRACKING_DIR") or ""

-- FNV-1a 64-bit (hash/fnv New64a) of s.
local function fnv64a(s)
    local h = -3750763034362895579 -- 14695981039346656037 as a wrapped int64
    for i = 1, #s do
        h = h ~ string.byte(s, i)
        h = h * 1099511628211
    end
    return h
end

-- Track sets up baseline tracking and returns a cleanup function that writes the tracking file.
function baseline.Track()
    baseline.trackingInitialized = true

    if baseline.trackingDir == "" then
        return function() end
    end

    -- Hash the call stack to create a unique filename per calling script.
    local h = 0
    local level = 2
    local files = {}
    while true do
        local info = debug.getinfo(level, "S")
        if info == nil then
            break
        end
        files[#files + 1] = info.source
        level = level + 1
    end
    h = fnv64a(table.concat(files))
    local trackingPath = baseline.trackingDir .. "/" .. string.format("%016x.txt", h) -- luacheck: ignore

    return function()
        -- After tests complete, write the recorded baselines
        baseline.writeRecordedBaselines(trackingPath)
    end
end

-- recordBaseline adds a baseline file path to the recorded set.
-- The path should be relative to the baselines/reference directory.
function baseline.recordBaseline(t, relativePath)
    if baseline.trackingDir ~= "" then
        if not baseline.trackingInitialized then
            t:Error("baseline: package uses baselines but TestMain did not call baseline.Track(). " ..
                "Please add a TestMain function with: defer baseline.Track()()")
            return
        end
        baseline.recordedBaselines[relativePath] = true
    end
end

-- writeRecordedBaselines writes the list of recorded baseline files to a tracking file.
function baseline.writeRecordedBaselines(trackingPath)
    if next(baseline.recordedBaselines) == nil then
        return
    end

    local err = baseline.doWriteRecordedBaselines(trackingPath)
    if err ~= nil then
        io.stderr:write(string.format("baseline: failed to write tracking file %s: %s\n", trackingPath, tostring(err)))
        os.exit(1)
    end
end

function baseline.doWriteRecordedBaselines(trackingPath)
    local f, err = io.open(trackingPath, "wb")
    if f == nil then
        return err
    end
    local names = {}
    for name in pairs(baseline.recordedBaselines) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        f:write(name, "\n")
    end
    f:close()
    return nil
end

return baseline
