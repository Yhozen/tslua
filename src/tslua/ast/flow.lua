local ast = require("tslua.ast")

-- FlowNode: { flags = FlowFlags, node = Node, antecedent = FlowNode, antecedents = FlowList }
-- FlowList: { flow = FlowNode, next = FlowList }
-- FlowLabel = FlowNode

-- Lua constructor for the Go struct literal &ast.FlowNode{...}.
function ast.NewFlowNode(flags, node, antecedent, antecedents)
    return { flags = flags or 0, node = node, antecedent = antecedent, antecedents = antecedents }
end

-- FlowSwitchClauseData (synthetic AST node for FlowFlagsSwitchClause)

local FlowSwitchClauseData = ast.DefineStruct("FlowSwitchClauseData", { "NodeBase" })

function ast.NewFlowSwitchClauseData(switchStatement, clauseStart, clauseEnd)
    local node = setmetatable({
        switchStatement = switchStatement,
        clauseStart = clauseStart, -- Start index of case/default clause range
        clauseEnd = clauseEnd, -- End index of case/default clause range
    }, FlowSwitchClauseData)
    return ast.newNode(ast.Kind.Unknown, node, {})
end

function FlowSwitchClauseData:IsEmpty()
    return self.clauseStart == self.clauseEnd
end

-- FlowReduceLabelData (synthetic AST node for FlowFlagsReduceLabel)

local FlowReduceLabelData = ast.DefineStruct("FlowReduceLabelData", { "NodeBase" })

function ast.NewFlowReduceLabelData(target, antecedents)
    local node = setmetatable({
        target = target, -- Target label
        antecedents = antecedents, -- Temporary antecedent list
    }, FlowReduceLabelData)
    return ast.newNode(ast.Kind.Unknown, node, {})
end
