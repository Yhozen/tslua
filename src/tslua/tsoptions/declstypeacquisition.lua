local tsoptions = require("tslua.tsoptions")

local CommandLineOptionKind = tsoptions.CommandLineOptionKind

-- Do not delete this without updating the website's tsconfig generation.
tsoptions.typeAcquisitionDecls = {
    tsoptions.newCommandLineOption({
        name = "enable",
        kind = CommandLineOptionKind.CommandLineOptionTypeBoolean,
        defaultValueDescription = false,
    }),
    tsoptions.newCommandLineOption({
        name = "include",
        kind = CommandLineOptionKind.CommandLineOptionTypeList,
    }),
    tsoptions.newCommandLineOption({
        name = "exclude",
        kind = CommandLineOptionKind.CommandLineOptionTypeList,
    }),
    tsoptions.newCommandLineOption({
        name = "disableFilenameBasedTypeAcquisition",
        kind = CommandLineOptionKind.CommandLineOptionTypeBoolean,
        defaultValueDescription = false,
    }),
}

tsoptions.typeAcquisitionDeclaration = tsoptions.newCommandLineOption({
    name = "typeAcquisition",
    kind = CommandLineOptionKind.CommandLineOptionTypeObject,
    elementOptions = tsoptions.commandLineOptionsToMap(tsoptions.typeAcquisitionDecls),
})

