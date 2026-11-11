local tsoptions = require("tslua.tsoptions")
local diagnostics = require("tslua.diagnostics")

-- DidYouMeanOptionsDiagnostics: { alternateMode = *AlternateModeDiagnostics, optionDeclarations,
--   unknownOptionDiagnostic, unknownDidYouMeanDiagnostic }
-- AlternateModeDiagnostics: { diagnostic, optionsNameMap = *NameMap }
-- ParseCommandLineWorkerDiagnostics: { didYouMean, optionsNameMap, optionsNameMapOnce,
--   optionTypeMismatchDiagnostic }

function tsoptions.getParseCommandLineWorkerDiagnostics(decls)
    -- this will only return the correct diagnostics for `compiler` mode, and is factored into a function for testing reasons.
    return {
        didYouMean = {
            alternateMode = {
                diagnostic = diagnostics.Compiler_option_0_may_only_be_used_with_build,
                optionsNameMap = tsoptions.BuildNameMap,
            },
            optionDeclarations = decls,
            unknownOptionDiagnostic = diagnostics.Unknown_compiler_option_0,
            unknownDidYouMeanDiagnostic = diagnostics.Unknown_compiler_option_0_Did_you_mean_1,
        },
        optionsNameMap = nil,
        optionsNameMapOnce = false,
        optionTypeMismatchDiagnostic = diagnostics.Compiler_option_0_expects_an_argument,
    }
end

tsoptions.CompilerOptionsDidYouMeanDiagnostics = tsoptions.getParseCommandLineWorkerDiagnostics(tsoptions.OptionsDeclarations)

tsoptions.watchOptionsDidYouMeanDiagnostics = {
    didYouMean = {
        -- no alternateMode
        alternateMode = nil,
        optionDeclarations = tsoptions.OptionsForWatch,
        unknownOptionDiagnostic = diagnostics.Unknown_watch_option_0,
        unknownDidYouMeanDiagnostic = diagnostics.Unknown_watch_option_0_Did_you_mean_1,
    },
    optionsNameMap = nil,
    optionsNameMapOnce = false,
    optionTypeMismatchDiagnostic = diagnostics.Watch_option_0_requires_a_value_of_type_1,
}

tsoptions.buildOptionsDidYouMeanDiagnostics = {
    didYouMean = {
        alternateMode = {
            diagnostic = diagnostics.Compiler_option_0_may_not_be_used_with_build,
            optionsNameMap = tsoptions.CompilerNameMap,
        },
        optionDeclarations = tsoptions.BuildOpts,
        unknownOptionDiagnostic = diagnostics.Unknown_build_option_0,
        unknownDidYouMeanDiagnostic = diagnostics.Unknown_build_option_0_Did_you_mean_1,
    },
    optionsNameMap = nil,
    optionsNameMapOnce = false,
    optionTypeMismatchDiagnostic = diagnostics.Build_option_0_requires_a_value_of_type_1,
}
