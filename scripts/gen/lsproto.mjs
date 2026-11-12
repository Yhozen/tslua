// Generates src/tslua/lsp/lsproto/lsp_generated.lua from the LSP metaModel.
// This is the Lua analogue of typescript-go's internal/lsp/lsproto/_generate/generate.mts.
// The model patching, type naming and union dispatch analysis are taken verbatim from the
// upstream generator (its source is loaded from the vendored checkout, everything before
// generateCode() plus the structure helpers after it), so the Lua output is derived from exactly
// the same decisions as lsp_generated.go; only the emitter (generateCode) is rewritten for Lua.
// Enumeration and Method constants come from goconsts (consts_generated.lua) like every package.
//
// The metaModel is vendored in scripts/gen/lsproto/metaModel.json (fetched by
// _generate/fetchModel.mts for the vscode-languageclient version in package-lock.json).
//
// Usage: node scripts/gen/lsproto.mjs [typescript-go dir] [output file]
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import url from "node:url";

const here = path.dirname(url.fileURLToPath(import.meta.url));
const root = path.resolve(process.argv[2] ?? "vendor/typescript-go");
const outFile = path.resolve(process.argv[3] ?? "src/tslua/lsp/lsproto/lsp_generated.lua");
const metaModelPath = path.join(here, "lsproto", "metaModel.json");

// ── Load the upstream generator's model logic ─────────────────────────────

const genPath = path.join(root, "internal/lsp/lsproto/_generate/generate.mts");
const gen = fs.readFileSync(genPath, "utf-8").replace(/\r\n/g, "\n");

function sliceBetween(text, startMarker, endMarker) {
    const a = text.indexOf(startMarker);
    if (a < 0) throw new Error(`marker not found in generate.mts: ${startMarker}`);
    const b = text.indexOf(endMarker, a);
    if (b < 0) throw new Error(`marker not found in generate.mts: ${endMarker}`);
    return text.slice(a, b);
}

let partA = sliceBetween(gen, "const __filename", "/**\n * Generate the Go code\n */\nfunction generateCode()");
const partB = sliceBetween(gen, "function hasSomeProp(", "/**\n * Main function");
partA = partA.replace(/^const metaModelPath = .*$/m, `const metaModelPath = ${JSON.stringify(metaModelPath)};`);
partA = partA.replace(/^const out = .*$/m, "");

const exported = [
    "model",
    "typeInfo",
    "resolveType",
    "formatDocumentation",
    "titleCase",
    "goFieldName",
    "methodNameIdentifier",
    "jsonKindForType",
    "typeCanBeNull",
    "findDiscriminatorField",
    "findPresenceDiscriminator",
    "collectTypeDefinitions",
    "compareStructures",
    "customTypeAliases",
    "registrationMethods",
    "hasTextDocumentURI",
    "hasTextDocumentPosition",
    "getLocationUriProperty",
];

const moduleText = `import fs from "node:fs";
import path from "node:path";
import url from "node:url";
${partA}
${partB}
export { ${exported.join(", ")} };
`;

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "tslua-lsproto-"));
const tmpFile = path.join(tmpDir, "model.mts");
fs.writeFileSync(tmpFile, moduleText);
let up;
try {
    up = await import(url.pathToFileURL(tmpFile).href);
}
finally {
    fs.rmSync(tmpDir, { recursive: true, force: true });
}

const {
    model,
    typeInfo,
    resolveType,
    formatDocumentation,
    titleCase,
    goFieldName,
    methodNameIdentifier,
    jsonKindForType,
    typeCanBeNull,
    findDiscriminatorField,
    findPresenceDiscriminator,
    collectTypeDefinitions,
    compareStructures,
    customTypeAliases,
    registrationMethods,
    hasTextDocumentURI,
    hasTextDocumentPosition,
    getLocationUriProperty,
} = up;

// ── Lua naming ────────────────────────────────────────────────────────────

const LUA_KEYWORDS = new Set([
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if", "in",
    "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
]);

function luaName(name) {
    return LUA_KEYWORDS.has(name) ? name + "_" : name;
}

// lowerCamelCase of a Go field name: the leading run of capitals is lowered
// (Text -> text, ID -> id, JSDoc -> jsDoc, URLPath -> urlPath, VSOnAutoInsert -> vsOnAutoInsert).
function lowerCamel(name) {
    const m = /^[A-Z]+/.exec(name);
    if (!m) return name;
    const run = m[0];
    if (run.length === name.length) return name.toLowerCase();
    if (run.length === 1) return run.toLowerCase() + name.slice(1);
    return run.slice(0, -1).toLowerCase() + name.slice(run.length - 1);
}

function luaField(goName) {
    return luaName(lowerCamel(goName));
}

function luaStr(s) {
    // JSON string syntax is valid Lua for everything the model contains except \u escapes.
    return JSON.stringify(s).replace(/\\u([0-9a-fA-F]{4})/g, (_, h) => {
        return Buffer.from(String.fromCodePoint(parseInt(h, 16))).toString("binary").split("")
            .map(c => "\\" + c.charCodeAt(0)).join("");
    }).replace(/[\u0080-￿]/g, c => Buffer.from(c).toString("binary").split("").map(b => "\\" + b.charCodeAt(0)).join(""));
}

// Go documentation comment ("// a\n// b\n") -> Lua comment with the given indent.
function luaDoc(s, indent = "") {
    const doc = formatDocumentation(s);
    if (!doc) return "";
    return doc.split("\n").filter(l => l !== "").map(l => (indent + "--" + l.slice(2)).trimEnd()).join("\n") + "\n";
}

function goTypeOf(type) {
    return type.needsPointer ? `*${type.name}` : type.name;
}

// ── Emitter ───────────────────────────────────────────────────────────────

// Custom Registration marshal/unmarshal (the MarshalJSONTo/UnmarshalJSONFrom generate.mts emits
// right after the Registration struct), driven by lsproto.registrationMethods.
const registrationCodec = `lsproto.structSpecs.Registration.marshal = function(buf, s)
    if s.registerOptions == nil then
        error("RegisterOptions must be set", 0)
    end
    lsproto.assertOnlyOne("exactly one element of RegisterOptions should be set", lsproto.countNonNil("RegisterOptions", s.registerOptions))

    local method, opts, optsType
    for _, reg in ipairs(lsproto.registrationMethods) do
        if s.registerOptions[reg[1]] ~= nil then
            method = reg[2]
            opts = s.registerOptions[reg[1]]
            optsType = "*" .. reg[3]
            break
        end
    end
    buf[#buf + 1] = '{"id":'
    local err = lsproto.encode(buf, "string", s.id)
    if err ~= nil then
        return err
    end
    buf[#buf + 1] = ',"method":'
    buf[#buf + 1] = lsproto.quoteString(method)
    buf[#buf + 1] = ',"registerOptions":'
    err = lsproto.encode(buf, optsType, opts)
    if err ~= nil then
        return err
    end
    buf[#buf + 1] = "}"
    return nil
end

lsproto.structSpecs.Registration.unmarshal = function(dec)
    local s = lsproto.Registration({})
    local missingId, missingMethod = true, true

    local k = dec:PeekKind()
    if k ~= "{" then
        return nil, lsproto.errNotObject(k)
    end
    local _, err = dec:ReadToken()
    if err ~= nil then
        return nil, err
    end

    local method = ""
    local rawRegisterOptions

    while dec:PeekKind() ~= "}" do
        local name
        name, err = dec:ReadValue()
        if err ~= nil then
            return nil, err
        end
        if name == '"id"' then
            missingId = false
            s.id, err = lsproto.decode(dec, "string")
        elseif name == '"method"' then
            missingMethod = false
            method, err = lsproto.decode(dec, "string")
        elseif name == '"registerOptions"' then
            rawRegisterOptions, err = dec:ReadValue()
        else
            err = dec:SkipValue()
        end
        if err ~= nil then
            return nil, err
        end
    end

    _, err = dec:ReadToken()
    if err ~= nil then
        return nil, err
    end

    if missingId or missingMethod then
        local missingProps = {}
        if missingId then
            missingProps[#missingProps + 1] = "id"
        end
        if missingMethod then
            missingProps[#missingProps + 1] = "method"
        end
        return nil, lsproto.errMissing(missingProps)
    end

    if rawRegisterOptions ~= nil and #rawRegisterOptions > 0 then
        s.registerOptions = lsproto.RegisterOptions({})
        for _, reg in ipairs(lsproto.registrationMethods) do
            if method == reg[2] then
                local v
                v, err = lsproto.UnmarshalAs(reg[3], rawRegisterOptions)
                if err ~= nil then
                    return nil, err
                end
                s.registerOptions[reg[1]] = v
                return s, nil
            end
        end
        return nil, "unknown registration method: " .. method
    end
    return nil, "missing registerOptions for method: " .. method
end

`;

function generateCode() {
    const parts = [];
    const write = s => parts.push(s);
    const writeLine = (s = "") => parts.push(s + "\n");

    function unmarshalArm(indent, entry, fn, src) {
        writeLine(`${indent}return lsproto.${fn}(o, ${luaStr(luaField(entry.fieldName))}, ${src}, ${luaStr(entry.typeName)})`);
    }

    function tryEach(indent, entries) {
        for (const entry of entries) {
            writeLine(`${indent}if lsproto.tryUnmarshalArm(o, ${luaStr(luaField(entry.fieldName))}, data, ${luaStr(entry.typeName)}) then`);
            writeLine(`${indent}    return nil`);
            writeLine(`${indent}end`);
        }
    }

    // Mirrors generateDiscriminatorDispatch. Returns true if all branches return.
    function generateDiscriminatorDispatch(disc, indent) {
        writeLine(`${indent}local disc = lsproto.jsonObjectRawField(data, ${luaStr(disc.fieldName)})`);
        let first = true;
        for (const [value, entry] of disc.mapping) {
            writeLine(`${indent}${first ? "if" : "elseif"} disc == ${luaStr(`"${value}"`)} then`);
            unmarshalArm(indent + "    ", entry, "unmarshalArm", "data");
            first = false;
        }
        let exhaustive = false;
        if (disc.unmapped.length > 0) {
            writeLine(`${indent}else`);
            exhaustive = generateUnmappedFallback(disc.unmapped, indent + "    ");
        }
        writeLine(`${indent}end`);
        return exhaustive;
    }

    // Mirrors generateUnmappedFallback.
    function generateUnmappedFallback(unmapped, indent) {
        if (unmapped.length <= 1) {
            for (const entry of unmapped) {
                unmarshalArm(indent, entry, "unmarshalArm", "data");
            }
            return unmapped.length === 1;
        }
        const pres = findPresenceDiscriminator(unmapped);
        if (pres) {
            return generatePresenceDispatch(pres, indent);
        }
        tryEach(indent, unmapped);
        return false;
    }

    // Mirrors collectAllPresenceChecks.
    function collectAllPresenceChecks(pres) {
        const allChecks = [...pres.checks];
        let remaining = pres.unmapped;
        while (remaining.length > 1) {
            const next = findPresenceDiscriminator(remaining);
            if (!next) break;
            allChecks.push(...next.checks);
            remaining = next.unmapped;
        }
        return { allChecks, finalUnmapped: remaining };
    }

    // Mirrors generatePresenceDispatch.
    function generatePresenceDispatch(pres, indent) {
        const { allChecks, finalUnmapped } = collectAllPresenceChecks(pres);
        const args = allChecks.map(c => luaStr(c.jsonFieldName)).join(", ");
        writeLine(`${indent}local key = lsproto.jsonObjectHasKey(data, ${args})`);
        for (let i = 0; i < allChecks.length; i++) {
            writeLine(`${indent}${i === 0 ? "if" : "elseif"} key == ${i} then -- ${allChecks[i].jsonFieldName}`);
            unmarshalArm(indent + "    ", allChecks[i].entry, "unmarshalArm", "data");
        }
        if (finalUnmapped.length > 0) {
            writeLine(`${indent}else`);
            if (finalUnmapped.length === 1) {
                unmarshalArm(indent + "    ", finalUnmapped[0], "unmarshalArm", "data");
            }
            else {
                tryEach(indent + "    ", finalUnmapped);
            }
        }
        writeLine(`${indent}end`);
        return finalUnmapped.length === 1;
    }

    function luaKindCond(kind) {
        switch (kind) {
            case "string":
                return `kind == '"'`;
            case "number":
                return `kind == "0"`;
            case "object":
                return `kind == "{"`;
            case "array":
                return `kind == "["`;
            case "boolean":
                return `kind == "t" or kind == "f"`;
            default:
                throw new Error("unexpected kind " + kind);
        }
    }

    // File header
    writeLine("-- Code generated by scripts/gen/lsproto.mjs from the LSP metaModel; DO NOT EDIT.");
    writeLine("-- Lua counterpart of typescript-go internal/lsp/lsproto/lsp_generated.go (generate.mts).");
    writeLine("--");
    writeLine("-- Structures, unions and literal types are described by Go type strings (\"*Position\",");
    writeLine("-- \"[]*Location\", \"map[DocumentUri][]*TextEdit\", ...) that the codec in structcodec.lua");
    writeLine("-- interprets. Struct fields are { luaField, goType, jsonTag, lspTag }; the Lua field name is the");
    writeLine("-- lowerCamelCase of the Go field name. Enumerations and Method constants are in");
    writeLine("-- consts_generated.lua (lsproto.CompletionItemKind.Function, lsproto.Method.Initialize).");
    writeLine("local lsproto = require(\"tslua.lsp.lsproto\")");
    writeLine("");
    writeLine("-- Meta model version " + model.metaData.version);
    writeLine("");

    // Structures
    writeLine("-- Structures");
    writeLine("");

    for (const structure of model.structures) {
        write(luaDoc(structure.documentation));

        const requiredProps = structure.properties?.filter(p => !p.optional && !p.omitzeroValue) || [];
        const hasNullRejectableFields = structure.properties?.some(p => {
            if (p.omitzeroValue) return false;
            if (typeCanBeNull(p.type)) return false;
            const resolved = resolveType(p.type);
            return p.optional || resolved.needsPointer || resolved.name.startsWith("[]") || resolved.name.startsWith("map[");
        }) || false;
        const strict = (requiredProps.length > 0 || hasNullRejectableFields) && structure.name !== "Registration";

        writeLine(`lsproto.defineStruct(${luaStr(structure.name)}, ${strict}, {`);
        const seen = new Set();
        for (const prop of structure.properties) {
            write(luaDoc(prop.documentation, "    "));
            const type = resolveType(prop.type);
            const useOmitzero = prop.optional || prop.omitzeroValue;
            const goType = (prop.optional || type.needsPointer) && !prop.omitzeroValue ? `*${type.name}` : type.name;
            const required = !prop.optional && !prop.omitzeroValue;
            const nilable = prop.optional || type.needsPointer || type.name.startsWith("[]") || type.name.startsWith("map[") || !!prop.omitzeroValue;
            const nullable = nilable && (typeCanBeNull(prop.type) || !!prop.omitzeroValue);
            const lspMarkers = [required ? "required" : "", nullable ? "nullable" : ""].filter(Boolean).join(",");
            const field = luaField(goFieldName(prop));
            if (seen.has(field)) throw new Error(`duplicate Lua field ${field} in ${structure.name}`);
            seen.add(field);
            const tag = `${prop.name}${useOmitzero ? ",omitzero" : ""}`;
            const entries = [luaStr(field), luaStr(goType), luaStr(tag)];
            if (lspMarkers) entries.push(luaStr(lspMarkers));
            writeLine(`    { ${entries.join(", ")} },`);
        }
        if (structure.name === "Registration") {
            writeLine(`    -- Options necessary for the registration. Determines the method.`);
            writeLine(`    { "registerOptions", "*RegisterOptions", "-" },`);
        }
        writeLine("})");
        writeLine("");

        if (hasTextDocumentURI(structure)) {
            const textDocProp = structure.properties?.find(p => (p.name === "textDocument" || p.name === "_vs_textDocument") && p.type.kind === "reference" && p.type.name === "TextDocumentIdentifier");
            const textDocFieldName = textDocProp ? goFieldName(textDocProp) : "TextDocument";
            writeLine(`function lsproto.${structure.name}:TextDocumentURI()`);
            writeLine(`    return self.${luaField(textDocFieldName)}.uri`);
            writeLine(`end`);
            writeLine("");

            if (hasTextDocumentPosition(structure)) {
                const posProp = structure.properties?.find(p => (p.name === "position" || p.name === "_vs_position") && p.type.kind === "reference" && p.type.name === "Position");
                const posFieldName = posProp ? goFieldName(posProp) : "Position";
                writeLine(`function lsproto.${structure.name}:TextDocumentPosition()`);
                writeLine(`    return self.${luaField(posFieldName)}`);
                writeLine(`end`);
                writeLine("");
            }
        }

        const locationUriProperty = getLocationUriProperty(structure);
        if (locationUriProperty) {
            writeLine(`function lsproto.${structure.name}:GetLocation()`);
            if (locationUriProperty === "Uri" && structure.name === "Location") {
                writeLine(`    return self`);
            }
            else {
                writeLine(`    return lsproto.Location({`);
                writeLine(`        uri = self.${luaField(locationUriProperty)},`);
                writeLine(`        range = self.${luaField(locationUriProperty.replace(/Uri$/, "Range"))},`);
                writeLine(`    })`);
            }
            writeLine(`end`);
            writeLine("");
        }

        if (structure.name === "Registration") {
            writeLine(`-- RegisterOptions is an externally-tagged union representing the options for a capability registration.`);
            writeLine(`-- Exactly one field should be set. The set field determines the method for the registration.`);
            writeLine(`lsproto.defineStruct("RegisterOptions", false, {`);
            for (const reg of registrationMethods) {
                writeLine(`    { ${luaStr(luaField(reg.fieldName))}, ${luaStr("*" + reg.optionsTypeName)}, ${luaStr(reg.fieldName)} },`);
            }
            writeLine(`})`);
            writeLine("");
            writeLine(`-- { RegisterOptions field, registration method, options type } in RegisterOptions field order.`);
            writeLine(`lsproto.registrationMethods = {`);
            for (const reg of registrationMethods) {
                writeLine(`    { ${luaStr(luaField(reg.fieldName))}, ${luaStr(reg.registrationMethod)}, ${luaStr(reg.optionsTypeName)} },`);
            }
            writeLine(`}`);
            writeLine("");
            write(registrationCodec);
        }

        if (compareStructures.has(structure.name)) {
            generateCompareMethod(structure);
        }
    }

    function generateCompareMethod(structure) {
        const props = structure.properties ?? [];
        writeLine(`function lsproto.${structure.name}:Compare(other)`);
        for (let i = 0; i < props.length; i++) {
            const prop = props[i];
            const isLast = i === props.length - 1;
            const expr = compareExpressionForProperty(structure.name, prop, luaField(goFieldName(prop)));
            if (isLast) {
                writeLine(`    return ${expr}`);
            }
            else {
                writeLine(`    do`);
                writeLine(`        local c = ${expr}`);
                writeLine(`        if c ~= 0 then`);
                writeLine(`            return c`);
                writeLine(`        end`);
                writeLine(`    end`);
            }
        }
        writeLine(`end`);
        writeLine("");
    }

    function compareExpressionForProperty(structName, prop, fieldName) {
        if (prop.type.kind === "reference") {
            const refName = prop.type.name;
            if (compareStructures.has(refName)) {
                return `lsproto.${refName}.Compare(self.${fieldName}, other.${fieldName})`;
            }
        }
        if (prop.type.kind === "base") {
            switch (prop.type.name) {
                case "string":
                case "URI":
                case "DocumentUri":
                case "integer":
                case "uinteger":
                case "decimal":
                    return `lsproto.cmpCompare(self.${fieldName}, other.${fieldName})`;
            }
        }
        throw new Error(`Cannot generate Compare for ${structName}.${fieldName}`);
    }

    // Enumerations: the constants are in consts_generated.lua; here the base types and String().
    const bitflagEnums = new Set(["WatchKind"]);

    writeLine("-- Enumerations");
    writeLine("");

    for (const enumeration of model.enumerations) {
        let baseType;
        switch (enumeration.type.name) {
            case "string":
                baseType = "string";
                break;
            case "integer":
                baseType = "int32";
                break;
            case "uinteger":
                baseType = "uint32";
                break;
            default:
                throw new Error(`Unsupported enum type: ${enumeration.type.name}`);
        }
        writeLine(`lsproto.defineEnum(${luaStr(enumeration.name)}, ${luaStr(baseType)})`);

        if (enumeration.type.name !== "string") {
            const sortedValues = enumeration.values.map(value => ({ name: value.name, numericValue: Number(value.value) }))
                .sort((a, b) => a.numericValue - b.numericValue);
            if (bitflagEnums.has(enumeration.name)) {
                writeLine(`local ${enumeration.name}_bits = {`);
                for (const v of sortedValues) {
                    writeLine(`    { ${v.numericValue}, ${luaStr(v.name)} },`);
                }
                writeLine(`}`);
                writeLine("");
                writeLine(`function lsproto.${enumeration.name}_String(e)`);
                writeLine(`    if e == 0 then`);
                writeLine(`        return "0"`);
                writeLine(`    end`);
                writeLine(`    local parts = {}`);
                writeLine(`    for _, b in ipairs(${enumeration.name}_bits) do`);
                writeLine(`        if e & b[1] ~= 0 then`);
                writeLine(`            parts[#parts + 1] = b[2]`);
                writeLine(`        end`);
                writeLine(`    end`);
                writeLine(`    if #parts == 0 then`);
                writeLine(`        return ${luaStr(enumeration.name + "(")} .. tostring(e) .. ")"`);
                writeLine(`    end`);
                writeLine(`    return table.concat(parts, "|")`);
                writeLine(`end`);
            }
            else {
                // Same results as the stringer-style String() of lsp_generated.go.
                writeLine(`local ${enumeration.name}_strings = {`);
                const seenValues = new Set();
                for (const v of sortedValues) {
                    if (seenValues.has(v.numericValue)) continue;
                    seenValues.add(v.numericValue);
                    writeLine(`    [${v.numericValue}] = ${luaStr(v.name)},`);
                }
                writeLine(`}`);
                writeLine("");
                writeLine(`function lsproto.${enumeration.name}_String(e)`);
                writeLine(`    local s = ${enumeration.name}_strings[e]`);
                writeLine(`    if s ~= nil then`);
                writeLine(`        return s`);
                writeLine(`    end`);
                writeLine(`    return ${luaStr(enumeration.name + "(")} .. tostring(e) .. ")"`);
                writeLine(`end`);
            }
            writeLine("");
        }

        if (enumeration.name === "ErrorCode") {
            writeLine(`function lsproto.${enumeration.name}_Error(e)`);
            writeLine(`    return lsproto.${enumeration.name}_String(e)`);
            writeLine(`end`);
            writeLine("");
        }
    }
    writeLine("");

    const requestsAndNotifications = [...model.requests, ...model.notifications];

    // Request response types and type mapping infos
    writeLine("-- Request response types");
    writeLine("");

    for (const request of requestsAndNotifications) {
        const methodName = methodNameIdentifier(request.method);
        let responseTypeName;

        if ("result" in request) {
            if (request.typeName && request.typeName.endsWith("Request")) {
                responseTypeName = request.typeName.replace(/Request$/, "Response");
            }
            else {
                responseTypeName = `${methodName}Response`;
            }
            writeLine(`-- Response type for \`${request.method}\``);
            if (request.result.kind === "base" && request.result.name === "null") {
                writeLine(`lsproto.defineAlias(${luaStr(responseTypeName)}, "Null")`);
            }
            else {
                writeLine(`lsproto.defineAlias(${luaStr(responseTypeName)}, ${luaStr(goTypeOf(resolveType(request.result)))})`);
            }
            writeLine("");
        }

        if (Array.isArray(request.params)) {
            throw new Error("Unexpected request params for " + methodName);
        }
        const paramType = request.params ? resolveType(request.params) : undefined;
        const paramGoType = paramType ? goTypeOf(paramType) : "NoParams";

        writeLine(`-- Type mapping info for \`${request.method}\``);
        if (responseTypeName) {
            writeLine(`lsproto.${methodName}Info = lsproto.NewRequestInfo(lsproto.Method.${methodName}, ${luaStr(paramGoType)}, ${luaStr(responseTypeName)})`);
        }
        else {
            writeLine(`lsproto.${methodName}Info = lsproto.NewNotificationInfo(lsproto.Method.${methodName}, ${luaStr(paramGoType)})`);
        }
        writeLine("");
    }

    // Type aliases
    writeLine("-- Type aliases");
    writeLine("");
    for (const alias of customTypeAliases) {
        writeLine(`lsproto.defineAlias(${luaStr(alias.name)}, ${luaStr(goTypeOf(resolveType(alias.type)))})`);
        writeLine("");
    }

    // Union types
    writeLine("-- Union types");
    writeLine("");

    for (const [name, members] of typeInfo.unionTypes.entries()) {
        const uniqueTypeFields = new Map();
        const uniqueTypeToOriginal = new Map();
        let hasLocations = false;
        const armLines = [];
        for (const member of members) {
            const memberType = resolveType(member.type).name;
            if (!uniqueTypeFields.has(memberType)) {
                const fieldName = titleCase(member.name);
                uniqueTypeFields.set(memberType, fieldName);
                uniqueTypeToOriginal.set(memberType, member.type);
                armLines.push(`    { ${luaStr(luaField(fieldName))}, ${luaStr(memberType)} },`);
                if (fieldName === "Locations" && memberType === "[]Location") {
                    hasLocations = true;
                }
            }
        }
        const fieldEntries = Array.from(uniqueTypeFields.entries()).map(([typeName, fieldName]) => ({
            fieldName,
            typeName,
            originalType: uniqueTypeToOriginal.get(typeName),
        }));
        const unionContainedNull = members.some(member => member.containedNull);

        writeLine(`lsproto.defineUnion(${luaStr(name)}, ${unionContainedNull}, {`);
        for (const l of armLines) writeLine(l);
        writeLine(`}, function(o, dec)`);

        const kindMap = new Map();
        const unknownKindEntries = [];
        for (const entry of fieldEntries) {
            const kind = jsonKindForType(entry.originalType);
            if (!kind) {
                unknownKindEntries.push(entry);
            }
            else {
                if (!kindMap.has(kind)) kindMap.set(kind, []);
                kindMap.get(kind).push(entry);
            }
        }

        function countRequiredFields(entry) {
            if (entry.originalType.kind !== "reference") return 0;
            const structure = model.structures.find(s => s.name === entry.originalType.name);
            if (!structure) return 0;
            return structure.properties.filter(p => !p.optional && !p.omitzeroValue).length;
        }

        for (const [, entries] of kindMap) {
            if (entries.length > 1) {
                entries.sort((a, b) => countRequiredFields(b) - countRequiredFields(a));
            }
        }
        {
            const sorted = [];
            const seen = new Set();
            for (const [, entries] of kindMap) {
                for (const entry of entries) {
                    sorted.push(entry);
                    seen.add(entry.fieldName);
                }
            }
            for (const entry of unknownKindEntries) {
                if (!seen.has(entry.fieldName)) {
                    sorted.push(entry);
                }
            }
            fieldEntries.length = 0;
            fieldEntries.push(...sorted);
        }

        const hasUnknownKinds = unknownKindEntries.length > 0;
        const distinctKinds = kindMap.size + (unionContainedNull ? 1 : 0);
        const canDispatch = !hasUnknownKinds && distinctKinds >= 2;

        let fallbackExhaustive = false;
        if (canDispatch) {
            // Both the unambiguous and the mixed case of generate.mts: PeekKind dispatch, buffering
            // only the ambiguous groups.
            writeLine(`    local kind = dec:PeekKind()`);
            let first = true;
            const branch = cond => {
                writeLine(`    ${first ? "if" : "elseif"} ${cond} then`);
                first = false;
            };
            if (unionContainedNull) {
                branch(`kind == "n"`);
                writeLine(`        local _, err = dec:ReadToken()`);
                writeLine(`        return err`);
            }
            for (const [kind, entries] of kindMap) {
                branch(luaKindCond(kind));
                if (entries.length === 1) {
                    const entry = entries[0];
                    if (kind === "boolean") {
                        writeLine(`        o.${luaField(entry.fieldName)} = kind == "t"`);
                        writeLine(`        local _, err = dec:ReadToken()`);
                        writeLine(`        return err`);
                    }
                    else {
                        unmarshalArm("        ", entry, "decodeArm", "dec");
                    }
                }
                else {
                    writeLine(`        local data, err = dec:ReadValue()`);
                    writeLine(`        if err ~= nil then`);
                    writeLine(`            return err`);
                    writeLine(`        end`);
                    let exhaustive = false;
                    const disc = findDiscriminatorField(entries);
                    if (disc) {
                        exhaustive = generateDiscriminatorDispatch(disc, "        ");
                    }
                    else {
                        const pres = findPresenceDiscriminator(entries);
                        if (pres) {
                            exhaustive = generatePresenceDispatch(pres, "        ");
                        }
                        else {
                            tryEach("        ", entries);
                        }
                    }
                    if (!exhaustive) {
                        writeLine(`        return lsproto.errInvalidValue(${luaStr(name)}, data)`);
                    }
                }
            }
            writeLine(`    else`);
            writeLine(`        return lsproto.errInvalidKind(${luaStr(name)}, dec:PeekKind())`);
            writeLine(`    end`);
        }
        else {
            writeLine("    local data, err = dec:ReadValue()");
            writeLine("    if err ~= nil then");
            writeLine("        return err");
            writeLine("    end");
            if (unionContainedNull) {
                writeLine(`    if data == "null" then`);
                writeLine(`        return nil`);
                writeLine(`    end`);
            }
            let exhaustive = false;
            const disc = findDiscriminatorField(fieldEntries);
            if (disc) {
                exhaustive = generateDiscriminatorDispatch(disc, "    ");
            }
            else {
                const pres = findPresenceDiscriminator(fieldEntries);
                if (pres) {
                    exhaustive = generatePresenceDispatch(pres, "    ");
                }
                else {
                    tryEach("    ", fieldEntries);
                }
            }
            fallbackExhaustive = exhaustive;
            if (!fallbackExhaustive) {
                writeLine(`    return lsproto.errInvalidValue(${luaStr(name)}, data)`);
            }
        }
        writeLine(`end)`);
        writeLine("");

        if (hasLocations) {
            writeLine(`function lsproto.${name}:GetLocations()`);
            writeLine(`    return self.locations`);
            writeLine(`end`);
            writeLine("");
        }
    }

    // Literal types
    writeLine("-- Literal types");
    writeLine("");
    for (const [value, name] of typeInfo.literalTypes.entries()) {
        const jsonValue = JSON.stringify(value);
        writeLine(`-- ${name} is a literal type for ${jsonValue}`);
        writeLine(`lsproto.defineLiteral(${luaStr(name)}, ${luaStr(jsonValue)})`);
        writeLine("");
    }

    // Resolved client capabilities
    const clientCapsStructure = model.structures.find(s => s.name === "ClientCapabilities");
    if (clientCapsStructure) {
        function collectStructureDependencies(structure, visited = new Set()) {
            if (visited.has(structure.name)) return [];
            visited.add(structure.name);
            const deps = [];
            for (const prop of structure.properties) {
                if (prop.type.kind === "reference") {
                    const refStructure = model.structures.find(s => s.name === prop.type.name);
                    if (refStructure) {
                        deps.push(...collectStructureDependencies(refStructure, new Set(visited)));
                        deps.push(refStructure);
                    }
                }
            }
            return deps;
        }

        function generateResolved(structure, isMain) {
            const typeName = `Resolved${structure.name}`;
            const methodName = isMain ? "Resolve" : "resolve";
            if (!isMain) {
                writeLine(`-- ${typeName} is a resolved version of ${structure.name} with all optional fields`);
                writeLine(`-- converted to non-pointer values for easier access.`);
                if (structure.documentation) {
                    writeLine(`--`);
                    write(luaDoc(structure.documentation));
                }
            }
            writeLine(`lsproto.defineResolved(${luaStr(typeName)}, ${luaStr(structure.name)}, {`);
            for (const prop of structure.properties) {
                write(luaDoc(prop.documentation, "    "));
                const type = resolveType(prop.type);
                let goType = type.name;
                if (prop.type.kind === "reference" && model.structures.find(s => s.name === type.name)) {
                    goType = `Resolved${type.name}`;
                }
                writeLine(`    { ${luaStr(luaField(goFieldName(prop)))}, ${luaStr(goType)}, ${luaStr(prop.name + ",omitzero")} },`);
            }
            writeLine(`})`);
            writeLine("");
            writeLine(`function lsproto.${structure.name}.${methodName}(v)`);
            writeLine(`    return lsproto.resolveStruct(${luaStr(typeName)}, v)`);
            writeLine(`end`);
            writeLine("");
        }

        const deps = collectStructureDependencies(clientCapsStructure);
        const uniqueDeps = Array.from(new Map(deps.map(d => [d.name, d])).values());
        for (const dep of uniqueDeps) {
            generateResolved(dep, false);
        }
        writeLine("-- ResolvedClientCapabilities is a version of ClientCapabilities where all nested");
        writeLine("-- fields are values (not pointers), making it easier to access deeply nested capabilities.");
        writeLine("-- Use lsproto.ClientCapabilities.Resolve(caps) to convert from ClientCapabilities.");
        if (clientCapsStructure.documentation) {
            writeLine("--");
            write(luaDoc(clientCapsStructure.documentation));
        }
        generateResolved(clientCapsStructure, true);
    }

    return parts.join("");
}

collectTypeDefinitions();
const code = generateCode();
fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, code);
console.log(`Successfully generated ${outFile}`);
