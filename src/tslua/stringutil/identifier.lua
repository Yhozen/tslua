local stringutil = require("tslua.stringutil")

-- IsUnicodeIdentifierStart reports whether ch may begin an ECMAScript
-- identifier, i.e. whether it has the Unicode ID_Start (or Other_ID_Start)
-- property. The range table is generated; see generate-unicode-data.mts.
-- ch is an integer code point.
function stringutil.IsUnicodeIdentifierStart(ch)
    return stringutil.unicodeIs(stringutil.unicodeESNextIdentifierStart, ch)
end

-- IsUnicodeIdentifierPart reports whether ch may appear after the first
-- character of an ECMAScript identifier, i.e. whether it has the Unicode
-- ID_Continue (or Other_ID_Continue) property, which also includes ID_Start.
function stringutil.IsUnicodeIdentifierPart(ch)
    return stringutil.unicodeIs(stringutil.unicodeESNextIdentifierPart, ch)
end
