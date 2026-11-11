local tsoptions = require("tslua.tsoptions")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")

local CommandLineOptionKind = tsoptions.CommandLineOptionKind

tsoptions.TscBuildOption = tsoptions.newCommandLineOption({
    name = "build",
    kind = "boolean",
    shortName = "b",
    showInSimplifiedHelpView = true,
    category = diagnostics.Command_line_Options,
    description = diagnostics.Build_one_or_more_projects_and_their_dependencies_if_out_of_date,
    defaultValueDescription = false,
})

tsoptions.OptionsForBuild = {
    tsoptions.TscBuildOption,
    tsoptions.newCommandLineOption({
        name = "verbose",
        shortName = "v",
        category = diagnostics.Command_line_Options,
        description = diagnostics.Enable_verbose_logging,
        kind = "boolean",
        defaultValueDescription = false,
    }),
    tsoptions.newCommandLineOption({
        name = "dry",
        shortName = "d",
        category = diagnostics.Command_line_Options,
        description = diagnostics.Show_what_would_be_built_or_deleted_if_specified_with_clean,
        kind = "boolean",
        defaultValueDescription = false,
    }),
    tsoptions.newCommandLineOption({
        name = "force",
        shortName = "f",
        category = diagnostics.Command_line_Options,
        description = diagnostics.Build_all_projects_including_those_that_appear_to_be_up_to_date,
        kind = "boolean",
        defaultValueDescription = false,
    }),
    tsoptions.newCommandLineOption({
        name = "clean",
        category = diagnostics.Command_line_Options,
        description = diagnostics.Delete_the_outputs_of_all_projects,
        kind = "boolean",
        defaultValueDescription = false,
    }),
    tsoptions.newCommandLineOption({
        name = "builders",
        kind = CommandLineOptionKind.CommandLineOptionTypeNumber,
        category = diagnostics.Command_line_Options,
        description = diagnostics.Set_the_number_of_projects_to_build_concurrently,
        defaultValueDescription = diagnostics.X_4_unless_singleThreaded_is_passed,
        minValue = 1,
    }),
    tsoptions.newCommandLineOption({
        name = "stopBuildOnErrors",
        category = diagnostics.Command_line_Options,
        description = diagnostics.Skip_building_downstream_projects_on_error_in_upstream_project,
        kind = "boolean",
        defaultValueDescription = false,
    }),
}

tsoptions.BuildOpts = core.Concatenate(tsoptions.commonOptionsWithBuild, tsoptions.OptionsForBuild)
