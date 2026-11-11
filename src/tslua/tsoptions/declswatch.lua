local tsoptions = require("tslua.tsoptions")
local core = require("tslua.core")
local diagnostics = require("tslua.diagnostics")

local CommandLineOptionKind = tsoptions.CommandLineOptionKind

tsoptions.OptionsForWatch = {
    tsoptions.newCommandLineOption({
        name = "watchInterval",
        kind = CommandLineOptionKind.CommandLineOptionTypeNumber,
        category = diagnostics.Watch_and_Build_Modes,
    }),
    tsoptions.newCommandLineOption({
        name = "watchFile",
        kind = CommandLineOptionKind.CommandLineOptionTypeEnum,
        category = diagnostics.Watch_and_Build_Modes,
        description = diagnostics.Specify_how_the_TypeScript_watch_mode_works,
        defaultValueDescription = core.WatchFileKind.UseFsEvents,
    }),
    tsoptions.newCommandLineOption({
        name = "watchDirectory",
        kind = CommandLineOptionKind.CommandLineOptionTypeEnum,
        category = diagnostics.Watch_and_Build_Modes,
        description = diagnostics.Specify_how_directories_are_watched_on_systems_that_lack_recursive_file_watching_functionality,
        defaultValueDescription = core.WatchDirectoryKind.UseFsEvents,
    }),
    tsoptions.newCommandLineOption({
        name = "fallbackPolling",
        kind = CommandLineOptionKind.CommandLineOptionTypeEnum,
        category = diagnostics.Watch_and_Build_Modes,
        description = diagnostics.Specify_what_approach_the_watcher_should_use_if_the_system_runs_out_of_native_file_watchers,
        defaultValueDescription = core.PollingKind.PriorityInterval,
    }),
    tsoptions.newCommandLineOption({
        name = "synchronousWatchDirectory",
        kind = CommandLineOptionKind.CommandLineOptionTypeBoolean,
        category = diagnostics.Watch_and_Build_Modes,
        description = diagnostics.Synchronously_call_callbacks_and_update_the_state_of_directory_watchers_on_platforms_that_don_t_support_recursive_watching_natively,
        defaultValueDescription = false,
    }),
    tsoptions.newCommandLineOption({
        name = "excludeDirectories",
        kind = CommandLineOptionKind.CommandLineOptionTypeList,
        allowConfigDirTemplateSubstitution = true,
        category = diagnostics.Watch_and_Build_Modes,
        description = diagnostics.Remove_a_list_of_directories_from_the_watch_process,
    }),
    tsoptions.newCommandLineOption({
        name = "excludeFiles",
        kind = CommandLineOptionKind.CommandLineOptionTypeList,
        allowConfigDirTemplateSubstitution = true,
        category = diagnostics.Watch_and_Build_Modes,
        description = diagnostics.Remove_a_list_of_files_from_the_watch_mode_s_processing,
    }),
}

