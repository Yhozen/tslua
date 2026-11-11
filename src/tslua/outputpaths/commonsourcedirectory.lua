local outputpaths = require("tslua.outputpaths")
local tspath = require("tslua.tspath")

function outputpaths.computeCommonSourceDirectoryOfFilenames(fileNames, currentDirectory, useCaseSensitiveFileNames)
    local commonPathComponents = nil
    for _, sourceFile in ipairs(fileNames or {}) do
        -- Each file contributes into common source file path
        local sourcePathComponents = tspath.GetNormalizedPathComponents(sourceFile, currentDirectory)

        -- The base file name is not part of the common directory path
        sourcePathComponents = { table.unpack(sourcePathComponents, 1, #sourcePathComponents - 1) }

        if commonPathComponents == nil then
            -- first file
            commonPathComponents = sourcePathComponents
            goto continue
        end

        do
            local n = math.min(#commonPathComponents, #sourcePathComponents)
            for i = 0, n - 1 do
                if tspath.GetCanonicalFileName(commonPathComponents[i + 1], useCaseSensitiveFileNames) ~= tspath.GetCanonicalFileName(sourcePathComponents[i + 1], useCaseSensitiveFileNames) then
                    if i == 0 then
                        -- Failed to find any common path component
                        return ""
                    end

                    -- New common path found that is 0 -> i-1
                    commonPathComponents = { table.unpack(commonPathComponents, 1, i) }
                    break
                end
            end

            -- If the sourcePathComponents was shorter than the commonPathComponents, truncate to the sourcePathComponents
            if #sourcePathComponents < #commonPathComponents then
                commonPathComponents = { table.unpack(commonPathComponents, 1, #sourcePathComponents) }
            end
        end
        ::continue::
    end

    if commonPathComponents == nil or #commonPathComponents == 0 then
        -- Can happen when all input files are .d.ts files
        return currentDirectory
    end

    return tspath.GetPathFromPathComponents(commonPathComponents)
end

function outputpaths.GetComputedCommonSourceDirectory(emittedFiles, currentDirectory, useCaseSensitiveFileNames)
    local commonSourceDirectory = outputpaths.computeCommonSourceDirectoryOfFilenames(emittedFiles, currentDirectory, useCaseSensitiveFileNames)
    if #commonSourceDirectory > 0 then
        commonSourceDirectory = tspath.EnsureTrailingDirectorySeparator(commonSourceDirectory)
    end
    return commonSourceDirectory
end

function outputpaths.GetCommonSourceDirectory(options, files, currentDirectory, useCaseSensitiveFileNames, checkSourceFilesBelongToPath)
    local commonSourceDirectory
    if options.rootDir ~= "" then
        -- If a rootDir is specified use it as the commonSourceDirectory
        commonSourceDirectory = options.rootDir
        if checkSourceFilesBelongToPath ~= nil then
            checkSourceFilesBelongToPath(files(), options.rootDir)
        end
    elseif options.configFilePath ~= "" then
        -- If the rootDir is not specified, then the common source directory is the directory of the config file.
        commonSourceDirectory = tspath.GetDirectoryPath(options.configFilePath)
        if checkSourceFilesBelongToPath ~= nil then
            checkSourceFilesBelongToPath(files(), commonSourceDirectory)
        end
    else
        commonSourceDirectory = outputpaths.computeCommonSourceDirectoryOfFilenames(files(), currentDirectory, useCaseSensitiveFileNames)
    end

    if #commonSourceDirectory > 0 then
        -- Make sure directory path ends with directory separator so this string can directly
        -- used to replace with "" to get the relative path of the source file and the relative path doesn't
        -- start with / making it rooted path
        commonSourceDirectory = tspath.EnsureTrailingDirectorySeparator(commonSourceDirectory)
    end

    return commonSourceDirectory
end
