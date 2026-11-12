local printer = require("tslua.printer")
local ast = require("tslua.ast")
local core = require("tslua.core")

-- PrintAndPositionNode prints a synthesized node to text using the standard
-- change-tracker printer options, trims the trailing newline, and assigns
-- positions to the resulting node tree.
-- sourceFile may be nil; when non-nil it is passed to the printer for comment
-- preservation.
-- The returned text is the printed source, and positioned is the node with
-- concrete source positions assigned to it and all descendants.
-- Returns text, positioned.
function printer.PrintAndPositionNode(factory, node, sourceFile, newLine, indentSize, emitContext)
    local writer = printer.NewChangeTrackerWriter(newLine, indentSize)
    printer.NewPrinter(
        {
            newLine = core.GetNewLineKind(newLine),
            neverAsciiEscape = true,
            preserveSourceNewlines = true,
            terminateUnterminatedLiterals = true,
        },
        writer:GetPrintHandlers(),
        emitContext
    ):Write(node, sourceFile, writer, nil)

    local text = writer:String()
    if newLine ~= "" and string.sub(text, -#newLine) == newLine then
        text = string.sub(text, 1, #text - #newLine)
    end
    local positioned = writer:AssignPositionsToNode(node, factory)
    return text, positioned
end

-- CreateSyntheticSourceFile wraps a positioned node in a synthetic source file
-- suitable for use with the formatter. The node must already have valid source
-- positions assigned (e.g. via PrintAndPositionNode or AssignPositionsToNode).
function printer.CreateSyntheticSourceFile(factory, node, text, parseOptions)
    local eof = factory:NewToken(ast.Kind.EndOfFile)
    eof.loc = core.NewTextRange(#text, #text)
    local statements = factory:NewNodeList({ node })
    statements.loc = core.NewTextRange(node:Pos(), node:End())
    local syntheticFile = factory:NewSourceFile(
        parseOptions,
        text,
        statements,
        eof
    )
    syntheticFile.loc = core.NewTextRange(0, #text)
    ast.SetParentInChildren(syntheticFile)
    return syntheticFile:AsSourceFile()
end
