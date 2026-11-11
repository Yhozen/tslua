-- Exports interfaces and types defining the node builder - concrete implementations are on top of
-- the checker, but these types and interfaces are used by the emit resolver in the printer.
--
-- SymbolTracker is an interface: any table providing the methods
--   TrackSymbol(symbol, enclosingDeclaration, meaning) -> bool
--   ReportInaccessibleThisError()
--   ReportPrivateInBaseOfClassExpression(propertyName)
--   ReportInaccessibleUniqueSymbolError()
--   ReportCyclicStructureError()
--   ReportLikelyUnsafeImportRequiredError(specifier, symbolName)
--   ReportTruncationError()
--   ReportNonlocalAugmentation(containingFile, parentSymbol, augmentingSymbol)
--   ReportNonSerializableProperty(propertyName)
--   ReportInferenceFallback(node)
--   PushErrorFallbackNode(node)
--   PopErrorFallbackNode()
-- Flags and InternalFlags come from consts_generated.lua (nodebuilder.Flags, nodebuilder.InternalFlags).
local nodebuilder = require("tslua.nodebuilder")

return nodebuilder
