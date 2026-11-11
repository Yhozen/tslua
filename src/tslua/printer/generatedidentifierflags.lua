-- GeneratedIdentifierFlags constants are generated (top level): printer.GeneratedIdentifierFlagsAuto, ...
local printer = require("tslua.printer")

function printer.GeneratedIdentifierFlags_Kind(f)
    return f & printer.GeneratedIdentifierFlagsKindMask
end

function printer.GeneratedIdentifierFlags_IsAuto(f)
    return printer.GeneratedIdentifierFlags_Kind(f) == printer.GeneratedIdentifierFlagsAuto
end

function printer.GeneratedIdentifierFlags_IsLoop(f)
    return printer.GeneratedIdentifierFlags_Kind(f) == printer.GeneratedIdentifierFlagsLoop
end

function printer.GeneratedIdentifierFlags_IsUnique(f)
    return printer.GeneratedIdentifierFlags_Kind(f) == printer.GeneratedIdentifierFlagsUnique
end

function printer.GeneratedIdentifierFlags_IsNode(f)
    return printer.GeneratedIdentifierFlags_Kind(f) == printer.GeneratedIdentifierFlagsNode
end

function printer.GeneratedIdentifierFlags_IsReservedInNestedScopes(f)
    return f & printer.GeneratedIdentifierFlagsReservedInNestedScopes ~= 0
end

function printer.GeneratedIdentifierFlags_IsOptimistic(f)
    return f & printer.GeneratedIdentifierFlagsOptimistic ~= 0
end

function printer.GeneratedIdentifierFlags_IsFileLevel(f)
    return f & printer.GeneratedIdentifierFlagsFileLevel ~= 0
end

function printer.GeneratedIdentifierFlags_HasAllowNameSubstitution(f)
    return f & printer.GeneratedIdentifierFlagsAllowNameSubstitution ~= 0
end
