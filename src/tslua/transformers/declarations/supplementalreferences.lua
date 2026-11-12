local declarations = require("tslua.transformers.declarations")
local ast = require("tslua.ast")
local core = require("tslua.core")
local tspath = require("tslua.tspath")

-- SupplementalReferencesTransformer adds triple-slash path references from a content mapper's
-- canonical declaration output to the declaration files emitted for its supplemental files.
-- This ensures that consumers loading the canonical declaration also include the supplemental types.
local SupplementalReferencesTransformer = {}
SupplementalReferencesTransformer.__index = SupplementalReferencesTransformer
declarations.SupplementalReferencesTransformer = SupplementalReferencesTransformer

function declarations.NewSupplementalReferencesTransformer(host, sourceFile, declarationFilePath, forceDeclarationPaths)
    return setmetatable({
        host = host,
        supplementalFiles = sourceFile:SupplementalSourceFiles(),
        declarationFilePath = declarationFilePath,
        forceDeclarationPaths = forceDeclarationPaths == true,
    }, SupplementalReferencesTransformer)
end

function SupplementalReferencesTransformer:TransformSourceFile(sourceFile)
    for _, supplemental in ipairs(self.supplementalFiles or {}) do
        if not self.host:SourceFileMayBeEmitted(supplemental, self.forceDeclarationPaths) then
            goto continue
        end
        do
            local declarationPath = self.host:GetOutputPathsFor(supplemental, self.forceDeclarationPaths):DeclarationFilePath()
            if declarationPath == "" then
                goto continue
            end
            sourceFile.referencedFiles = core.Append(sourceFile.referencedFiles, ast.NewFileReference(
                -1,
                -1,
                tspath.GetRelativePathFromFile(
                    self.declarationFilePath,
                    declarationPath,
                    {
                        currentDirectory = self.host:GetCurrentDirectory(),
                        useCaseSensitiveFileNames = self.host:UseCaseSensitiveFileNames(),
                    }
                ),
                core.ModuleKind.ResolutionModeNone,
                false
            ))
        end
        ::continue::
    end
    return sourceFile
end

function SupplementalReferencesTransformer:GetDiagnostics()
    return nil
end
