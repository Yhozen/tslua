-- Port of internal/jsnum/jsnum_test.go. The test tables were evaluated by Go (numbers as IEEE 754 bit
-- patterns, subtest names formatted by Go) with .context/scratch/go-unit-tests/jsnum/gen.mjs.
-- luacheck: ignore 631
local jsnum = require("tslua.jsnum")
local jstest = require("tslua.testutil.jstest")

local function F(bits)
    return (string.unpack("<d", string.pack("<i8", bits)))
end

local function numberToBits(n)
    return (string.unpack("<i8", string.pack("<d", n)))
end

local function assertEqualNumber(got, want)
    if jsnum.Number_IsNaN(got) or jsnum.Number_IsNaN(want) then
        assert.are.equal(jsnum.Number_IsNaN(want), jsnum.Number_IsNaN(got), "got: " .. tostring(got) .. ", want: " .. tostring(want))
    else
        assert.are.equal(want, got)
    end
end

-- Go testing.TB stand-in for jstest inside busted.
local T = {
    Helper = function() end,
    Skip = function(_, msg)
        pending(msg)
    end,
    Fatal = function(_, msg)
        error(msg, 2)
    end,
}

local function tempDir()
    local p = io.popen("mktemp -d")
    local dir = p:read("l")
    p:close()
    return dir
end

local function removeAll(dir)
    os.execute("rm -rf '" .. dir .. "'")
end

local function numToUint32s(n)
    local bits = numberToBits(n)
    return { bits & 0xffffffff, (bits >> 32) & 0xffffffff }
end

local function uint32sToNum(a)
    return F(math.tointeger(a[1]) | (math.tointeger(a[2]) << 32))
end

local bitsScript = [==[
		function fromBits(bits) {
			const buffer = new ArrayBuffer(8);
			(new Uint32Array(buffer))[0] = bits[0];
			(new Uint32Array(buffer))[1] = bits[1];
			return new Float64Array(buffer)[0];
		}

		function toBits(number) {
			const buffer = new ArrayBuffer(8);
			(new Float64Array(buffer))[0] = number;
			return [(new Uint32Array(buffer))[0], (new Uint32Array(buffer))[1]];
		}
]==]

local function writeFile(p, s)
    local f = assert(io.open(p, "wb"))
    f:write(s)
    f:close()
end

-- Lazily computes Node results once per table (Go computes them once per "Node" subtest).
local function memo(fn)
    local done, value = false, nil
    return function()
        if not done then
            value = fn()
            done = true
        end
        return value
    end
end

local function uint32Pair(a)
    return string.format("[%d,%d]", a[1], a[2])
end

-- evalBinaryOp evaluates a binary JS expression on all cases using Node.js.
-- Skips the calling test if Node.js is not available.
local function evalBinaryOp(t, op, xs, ys)
    t:Helper()
    jstest.SkipIfNoNodeJS(t)

    local tmpdir = tempDir()
    local inputs = {}
    for i = 1, #xs do
        inputs[i] = '{"x":' .. uint32Pair(numToUint32s(xs[i])) .. ',"y":' .. uint32Pair(numToUint32s(ys[i])) .. "}"
    end
    local inputPath = tmpdir .. "/input.json"
    writeFile(inputPath, "[" .. table.concat(inputs, ",") .. "]")

    local script = [[
		import fs from 'fs';
]] .. bitsScript .. [[
		export default function(inputFile) {
			const input = JSON.parse(fs.readFileSync(inputFile, 'utf8'));
			return input.map(({x, y}) => {
				const a = fromBits(x);
				const b = fromBits(y);
				return { x, y, result: toBits(]] .. op .. [[) };
			});
		};
	]]

    local results, err = jstest.EvalNodeScript(t, script, tmpdir, inputPath)
    removeAll(tmpdir)
    assert.is_nil(err)
    assert.are.equal(#xs, #results)

    local out = {}
    for i, r in ipairs(results) do
        out[i] = uint32sToNum(r.result)
    end
    return out
end

-- evalUnaryOp evaluates a unary JS expression on all cases using Node.js.
-- Skips the calling test if Node.js is not available.
local function evalUnaryOp(t, op, xs)
    t:Helper()
    jstest.SkipIfNoNodeJS(t)

    local tmpdir = tempDir()
    local inputs = {}
    for i, x in ipairs(xs) do
        inputs[i] = '{"x":' .. uint32Pair(numToUint32s(x)) .. "}"
    end
    local inputPath = tmpdir .. "/input.json"
    writeFile(inputPath, "[" .. table.concat(inputs, ",") .. "]")

    local script = [[
		import fs from 'fs';
]] .. bitsScript .. [[
		export default function(inputFile) {
			const input = JSON.parse(fs.readFileSync(inputFile, 'utf8'));
			return input.map(({x}) => {
				const a = fromBits(x);
				return { x, result: toBits(]] .. op .. [[) };
			});
		};
	]]

    local results, err = jstest.EvalNodeScript(t, script, tmpdir, inputPath)
    removeAll(tmpdir)
    assert.is_nil(err)
    assert.are.equal(#xs, #results)

    local out = {}
    for i, r in ipairs(results) do
        out[i] = uint32sToNum(r.result)
    end
    return out
end

-- assertWithinOneULP checks that got and want are either equal or differ by
-- at most 1 ULP (unit in the last place).
local function assertWithinOneULP(got, want)
    if jsnum.Number_IsNaN(got) or jsnum.Number_IsNaN(want) then
        assert.are.equal(jsnum.Number_IsNaN(want), jsnum.Number_IsNaN(got))
        return
    end
    if got == want then
        return
    end
    local gotBits = numberToBits(got)
    local wantBits = numberToBits(want)
    if gotBits == wantBits then
        return
    end
    local ulpDist
    if math.ult(wantBits, gotBits) then
        ulpDist = gotBits - wantBits
    else
        ulpDist = wantBits - gotBits
    end
    assert.is_false(math.ult(1, ulpDist), string.format("got %.17g (%016x), want %.17g (%016x) within 1 ULP", got, gotBits, want, wantBits))
end

local toInt32Tests = {
    { name = "0.0", input = F(0x0000000000000000), want = 0, sub = "0.0 (0)" },
    { name = "-0.0", input = F(0x8000000000000000), want = 0, sub = "-0.0 (-0)" },
    { name = "NaN", input = F(0x7ff8000000000001), want = 0, sub = "NaN (NaN)" },
    { name = "+Inf", input = F(0x7ff0000000000000), want = 0, sub = "+Inf (+Inf)" },
    { name = "-Inf", input = F(0xfff0000000000000), want = 0, sub = "-Inf (-Inf)" },
    { name = "MaxInt32", input = F(0x41dfffffffc00000), want = 2147483647, sub = "MaxInt32 (2.147483647e+09)" },
    { name = "MaxInt32+1", input = F(0x41e0000000000000), want = -2147483648, sub = "MaxInt32+1 (2.147483648e+09)" },
    { name = "MinInt32", input = F(0xc1e0000000000000), want = -2147483648, sub = "MinInt32 (-2.147483648e+09)" },
    { name = "MinInt32-1", input = F(0xc1e0000000200000), want = 2147483647, sub = "MinInt32-1 (-2.147483649e+09)" },
    { name = "MIN_SAFE_INTEGER", input = F(0xc33fffffffffffff), want = 1, sub = "MIN_SAFE_INTEGER (-9.007199254740991e+15)" },
    { name = "MIN_SAFE_INTEGER-1", input = F(0xc340000000000000), want = 0, sub = "MIN_SAFE_INTEGER-1 (-9.007199254740992e+15)" },
    { name = "MIN_SAFE_INTEGER+1", input = F(0xc33ffffffffffffe), want = 2, sub = "MIN_SAFE_INTEGER+1 (-9.00719925474099e+15)" },
    { name = "MAX_SAFE_INTEGER", input = F(0x433fffffffffffff), want = -1, sub = "MAX_SAFE_INTEGER (9.007199254740991e+15)" },
    { name = "MAX_SAFE_INTEGER-1", input = F(0x433ffffffffffffe), want = -2, sub = "MAX_SAFE_INTEGER-1 (9.00719925474099e+15)" },
    { name = "MAX_SAFE_INTEGER+1", input = F(0x4340000000000000), want = 0, sub = "MAX_SAFE_INTEGER+1 (9.007199254740992e+15)" },
    { name = "-8589934590", input = F(0xc1ffffffffe00000), want = 2, sub = "-8589934590 (-8.58993459e+09)" },
    { name = "0xDEADBEEF", input = F(0x41ebd5b7dde00000), want = -559038737, sub = "0xDEADBEEF (3.735928559e+09)" },
    { name = "4294967808", input = F(0x41f0000020000000), want = 512, sub = "4294967808 (4.294967808e+09)" },
    { name = "-0.4", input = F(0xbfd999999999999a), want = 0, sub = "-0.4 (-0.4)" },
    { name = "SmallestNonzeroFloat64", input = F(0x0000000000000001), want = 0, sub = "SmallestNonzeroFloat64 (5e-324)" },
    { name = "-SmallestNonzeroFloat64", input = F(0x8000000000000001), want = 0, sub = "-SmallestNonzeroFloat64 (-5e-324)" },
    { name = "MaxFloat64", input = F(0x7fefffffffffffff), want = 0, sub = "MaxFloat64 (1.7976931348623157e+308)" },
    { name = "-MaxFloat64", input = F(0xffefffffffffffff), want = 0, sub = "-MaxFloat64 (-1.7976931348623157e+308)" },
    { name = "Largest subnormal number", input = F(0x000fffffffffffff), want = 0, sub = "Largest subnormal number (2.225073858507201e-308)" },
    { name = "Smallest positive normal number", input = F(0x0010000000000000), want = 0, sub = "Smallest positive normal number (2.2250738585072014e-308)" },
    { name = "Largest normal number", input = F(0x7fefffffffffffff), want = 0, sub = "Largest normal number (1.7976931348623157e+308)" },
    { name = "-Largest normal number", input = F(0xffefffffffffffff), want = 0, sub = "-Largest normal number (-1.7976931348623157e+308)" },
    { name = "1.0", input = F(0x3ff0000000000000), want = 1, sub = "1.0 (1)" },
    { name = "-1.0", input = F(0xbff0000000000000), want = -1, sub = "-1.0 (-1)" },
    { name = "1e308", input = F(0x7fe1ccf385ebc8a0), want = 0, sub = "1e308 (1e+308)" },
    { name = "-1e308", input = F(0xffe1ccf385ebc8a0), want = 0, sub = "-1e308 (-1e+308)" },
    { name = "math.Pi", input = F(0x400921fb54442d18), want = 3, sub = "math.Pi (3.141592653589793)" },
    { name = "-math.Pi", input = F(0xc00921fb54442d18), want = -3, sub = "-math.Pi (-3.141592653589793)" },
    { name = "math.E", input = F(0x4005bf0a8b145769), want = 2, sub = "math.E (2.718281828459045)" },
    { name = "-math.E", input = F(0xc005bf0a8b145769), want = -2, sub = "-math.E (-2.718281828459045)" },
    { name = "0.5", input = F(0x3fe0000000000000), want = 0, sub = "0.5 (0.5)" },
    { name = "-0.5", input = F(0xbfe0000000000000), want = 0, sub = "-0.5 (-0.5)" },
    { name = "0.49999999999999994", input = F(0x3fdfffffffffffff), want = 0, sub = "0.49999999999999994 (0.49999999999999994)" },
    { name = "-0.49999999999999994", input = F(0xbfdfffffffffffff), want = 0, sub = "-0.49999999999999994 (-0.49999999999999994)" },
    { name = "0.5000000000000001", input = F(0x3fe0000000000001), want = 0, sub = "0.5000000000000001 (0.5000000000000001)" },
    { name = "-0.5000000000000001", input = F(0xbfe0000000000001), want = 0, sub = "-0.5000000000000001 (-0.5000000000000001)" },
    { name = "2^31 + 0.5", input = F(0x41e0000000100000), want = -2147483648, sub = "2^31 + 0.5 (2.1474836485e+09)" },
    { name = "-2^31 - 0.5", input = F(0xc1e0000000100000), want = -2147483648, sub = "-2^31 - 0.5 (-2.1474836485e+09)" },
    { name = "2^40", input = F(0x4270000000000000), want = 0, sub = "2^40 (1.099511627776e+12)" },
    { name = "-2^40", input = F(0xc270000000000000), want = 0, sub = "-2^40 (-1.099511627776e+12)" },
    { name = "TypeFlagsNarrowable", input = F(0x41bffc3bff000000), want = 536624127, sub = "TypeFlagsNarrowable (5.36624127e+08)" },
}

describe("TestToInt32", function()
    local inputs, zeros = {}, {}
    for i, test in ipairs(toInt32Tests) do
        inputs[i] = test.input
        zeros[i] = 0.0
    end
    for _, test in ipairs(toInt32Tests) do
        it(test.sub, function()
            assert.are.equal(test.want, jsnum.Number_toInt32(test.input))
        end)
    end

    describe("Node", function()
        local jsResults = memo(function()
            return evalBinaryOp(T, "a | b", inputs, zeros)
        end)
        for i, test in ipairs(toInt32Tests) do
            it(test.sub, function()
                assertEqualNumber(jsnum.Number_toInt32(test.input) + 0.0, jsResults()[i])
            end)
        end
    end)
end)

describe("TestBitwiseNOT", function()
    local tests = {
        { name = "~-2147483649", x = F(0xc1e0000000200000), want = F(0xc1e0000000000000) },
        { name = "~2147483647", x = F(0x41dfffffffc00000), want = F(0xc1e0000000000000) },
        { name = "~-4294967296", x = F(0xc1f0000000000000), want = F(0xbff0000000000000) },
        { name = "~0", x = F(0x0000000000000000), want = F(0xbff0000000000000) },
        { name = "~2147483648", x = F(0x41e0000000000000), want = F(0x41dfffffffc00000) },
        { name = "~-2147483648", x = F(0xc1e0000000000000), want = F(0x41dfffffffc00000) },
        { name = "~4294967296", x = F(0x41f0000000000000), want = F(0xbff0000000000000) },
    }

    local xs = {}
    for i, test in ipairs(tests) do
        xs[i] = test.x
    end
    for _, test in ipairs(tests) do
        it(test.name, function()
            assertEqualNumber(jsnum.Number_BitwiseNOT(test.x), test.want)
        end)
    end

    describe("Node", function()
        local jsResults = memo(function()
            return evalUnaryOp(T, "~a", xs)
        end)
        for i, test in ipairs(tests) do
            it(test.name, function()
                assertEqualNumber(jsnum.Number_BitwiseNOT(test.x), jsResults()[i])
            end)
        end
    end)
end)

describe("TestBitwiseAND", function()
    local tests = {
        { name = "0 & 0", x = F(0x0000000000000000), y = F(0x0000000000000000), want = F(0x0000000000000000) },
        { name = "0 & 1", x = F(0x0000000000000000), y = F(0x3ff0000000000000), want = F(0x0000000000000000) },
        { name = "1 & 0", x = F(0x3ff0000000000000), y = F(0x0000000000000000), want = F(0x0000000000000000) },
        { name = "1 & 1", x = F(0x3ff0000000000000), y = F(0x3ff0000000000000), want = F(0x3ff0000000000000) },
    }

    local xs, ys = {}, {}
    for i, test in ipairs(tests) do
        xs[i] = test.x
        ys[i] = test.y
    end
    for _, test in ipairs(tests) do
        it(test.name, function()
            assertEqualNumber(jsnum.Number_BitwiseAND(test.x, test.y), test.want)
        end)
    end

    describe("Node", function()
        local jsResults = memo(function()
            return evalBinaryOp(T, "a & b", xs, ys)
        end)
        for i, test in ipairs(tests) do
            it(test.name, function()
                assertEqualNumber(jsnum.Number_BitwiseAND(test.x, test.y), jsResults()[i])
            end)
        end
    end)
end)

describe("TestBitwiseOR", function()
    local tests = {
        { name = "0 | 0", x = F(0x0000000000000000), y = F(0x0000000000000000), want = F(0x0000000000000000) },
        { name = "0 | 1", x = F(0x0000000000000000), y = F(0x3ff0000000000000), want = F(0x3ff0000000000000) },
        { name = "1 | 0", x = F(0x3ff0000000000000), y = F(0x0000000000000000), want = F(0x3ff0000000000000) },
        { name = "1 | 1", x = F(0x3ff0000000000000), y = F(0x3ff0000000000000), want = F(0x3ff0000000000000) },
    }

    local xs, ys = {}, {}
    for i, test in ipairs(tests) do
        xs[i] = test.x
        ys[i] = test.y
    end
    for _, test in ipairs(tests) do
        it(test.name, function()
            assertEqualNumber(jsnum.Number_BitwiseOR(test.x, test.y), test.want)
        end)
    end

    describe("Node", function()
        local jsResults = memo(function()
            return evalBinaryOp(T, "a | b", xs, ys)
        end)
        for i, test in ipairs(tests) do
            it(test.name, function()
                assertEqualNumber(jsnum.Number_BitwiseOR(test.x, test.y), jsResults()[i])
            end)
        end
    end)
end)

describe("TestBitwiseXOR", function()
    local tests = {
        { name = "0 ^ 0", x = F(0x0000000000000000), y = F(0x0000000000000000), want = F(0x0000000000000000) },
        { name = "0 ^ 1", x = F(0x0000000000000000), y = F(0x3ff0000000000000), want = F(0x3ff0000000000000) },
        { name = "1 ^ 0", x = F(0x3ff0000000000000), y = F(0x0000000000000000), want = F(0x3ff0000000000000) },
        { name = "1 ^ 1", x = F(0x3ff0000000000000), y = F(0x3ff0000000000000), want = F(0x0000000000000000) },
    }

    local xs, ys = {}, {}
    for i, test in ipairs(tests) do
        xs[i] = test.x
        ys[i] = test.y
    end
    for _, test in ipairs(tests) do
        it(test.name, function()
            assertEqualNumber(jsnum.Number_BitwiseXOR(test.x, test.y), test.want)
        end)
    end

    describe("Node", function()
        local jsResults = memo(function()
            return evalBinaryOp(T, "a ^ b", xs, ys)
        end)
        for i, test in ipairs(tests) do
            it(test.name, function()
                assertEqualNumber(jsnum.Number_BitwiseXOR(test.x, test.y), jsResults()[i])
            end)
        end
    end)
end)

describe("TestSignedRightShift", function()
    local tests = {
        { name = "1 >> 0", x = F(0x3ff0000000000000), y = F(0x0000000000000000), want = F(0x3ff0000000000000) },
        { name = "1 >> 1", x = F(0x3ff0000000000000), y = F(0x3ff0000000000000), want = F(0x0000000000000000) },
        { name = "1 >> 2", x = F(0x3ff0000000000000), y = F(0x4000000000000000), want = F(0x0000000000000000) },
        { name = "1 >> 31", x = F(0x3ff0000000000000), y = F(0x403f000000000000), want = F(0x0000000000000000) },
        { name = "1 >> 32", x = F(0x3ff0000000000000), y = F(0x4040000000000000), want = F(0x3ff0000000000000) },
        { name = "-4 >> 0", x = F(0xc010000000000000), y = F(0x0000000000000000), want = F(0xc010000000000000) },
        { name = "-4 >> 1", x = F(0xc010000000000000), y = F(0x3ff0000000000000), want = F(0xc000000000000000) },
        { name = "-4 >> 2", x = F(0xc010000000000000), y = F(0x4000000000000000), want = F(0xbff0000000000000) },
        { name = "-4 >> 3", x = F(0xc010000000000000), y = F(0x4008000000000000), want = F(0xbff0000000000000) },
        { name = "-4 >> 4", x = F(0xc010000000000000), y = F(0x4010000000000000), want = F(0xbff0000000000000) },
        { name = "-4 >> 31", x = F(0xc010000000000000), y = F(0x403f000000000000), want = F(0xbff0000000000000) },
        { name = "-4 >> 32", x = F(0xc010000000000000), y = F(0x4040000000000000), want = F(0xc010000000000000) },
        { name = "-4 >> 33", x = F(0xc010000000000000), y = F(0x4040800000000000), want = F(0xc000000000000000) },
    }

    local xs, ys = {}, {}
    for i, test in ipairs(tests) do
        xs[i] = test.x
        ys[i] = test.y
    end
    for _, test in ipairs(tests) do
        it(test.name, function()
            assertEqualNumber(jsnum.Number_SignedRightShift(test.x, test.y), test.want)
        end)
    end

    describe("Node", function()
        local jsResults = memo(function()
            return evalBinaryOp(T, "a >> b", xs, ys)
        end)
        for i, test in ipairs(tests) do
            it(test.name, function()
                assertEqualNumber(jsnum.Number_SignedRightShift(test.x, test.y), jsResults()[i])
            end)
        end
    end)
end)

describe("TestUnsignedRightShift", function()
    local tests = {
        { name = "1 >>> 0", x = F(0x3ff0000000000000), y = F(0x0000000000000000), want = F(0x3ff0000000000000) },
        { name = "1 >>> 1", x = F(0x3ff0000000000000), y = F(0x3ff0000000000000), want = F(0x0000000000000000) },
        { name = "1 >>> 2", x = F(0x3ff0000000000000), y = F(0x4000000000000000), want = F(0x0000000000000000) },
        { name = "1 >>> 31", x = F(0x3ff0000000000000), y = F(0x403f000000000000), want = F(0x0000000000000000) },
        { name = "1 >>> 32", x = F(0x3ff0000000000000), y = F(0x4040000000000000), want = F(0x3ff0000000000000) },
        { name = "-4 >>> 0", x = F(0xc010000000000000), y = F(0x0000000000000000), want = F(0x41efffffff800000) },
        { name = "-4 >>> 1", x = F(0xc010000000000000), y = F(0x3ff0000000000000), want = F(0x41dfffffff800000) },
        { name = "-4 >>> 2", x = F(0xc010000000000000), y = F(0x4000000000000000), want = F(0x41cfffffff800000) },
        { name = "-4 >>> 3", x = F(0xc010000000000000), y = F(0x4008000000000000), want = F(0x41bfffffff000000) },
        { name = "-4 >>> 4", x = F(0xc010000000000000), y = F(0x4010000000000000), want = F(0x41affffffe000000) },
        { name = "-4 >>> 31", x = F(0xc010000000000000), y = F(0x403f000000000000), want = F(0x3ff0000000000000) },
        { name = "-4 >>> 32", x = F(0xc010000000000000), y = F(0x4040000000000000), want = F(0x41efffffff800000) },
        { name = "-4 >>> 33", x = F(0xc010000000000000), y = F(0x4040800000000000), want = F(0x41dfffffff800000) },
    }

    local xs, ys = {}, {}
    for i, test in ipairs(tests) do
        xs[i] = test.x
        ys[i] = test.y
    end
    for _, test in ipairs(tests) do
        it(test.name, function()
            assertEqualNumber(jsnum.Number_UnsignedRightShift(test.x, test.y), test.want)
        end)
    end

    describe("Node", function()
        local jsResults = memo(function()
            return evalBinaryOp(T, "a >>> b", xs, ys)
        end)
        for i, test in ipairs(tests) do
            it(test.name, function()
                assertEqualNumber(jsnum.Number_UnsignedRightShift(test.x, test.y), jsResults()[i])
            end)
        end
    end)
end)

describe("TestLeftShift", function()
    local tests = {
        { name = "1 << 0", x = F(0x3ff0000000000000), y = F(0x0000000000000000), want = F(0x3ff0000000000000) },
        { name = "1 << 1", x = F(0x3ff0000000000000), y = F(0x3ff0000000000000), want = F(0x4000000000000000) },
        { name = "1 << 2", x = F(0x3ff0000000000000), y = F(0x4000000000000000), want = F(0x4010000000000000) },
        { name = "1 << 31", x = F(0x3ff0000000000000), y = F(0x403f000000000000), want = F(0xc1e0000000000000) },
        { name = "1 << 32", x = F(0x3ff0000000000000), y = F(0x4040000000000000), want = F(0x3ff0000000000000) },
        { name = "-4 << 0", x = F(0xc010000000000000), y = F(0x0000000000000000), want = F(0xc010000000000000) },
        { name = "-4 << 1", x = F(0xc010000000000000), y = F(0x3ff0000000000000), want = F(0xc020000000000000) },
        { name = "-4 << 2", x = F(0xc010000000000000), y = F(0x4000000000000000), want = F(0xc030000000000000) },
        { name = "-4 << 3", x = F(0xc010000000000000), y = F(0x4008000000000000), want = F(0xc040000000000000) },
        { name = "-4 << 31", x = F(0xc010000000000000), y = F(0x403f000000000000), want = F(0x0000000000000000) },
        { name = "-4 << 32", x = F(0xc010000000000000), y = F(0x4040000000000000), want = F(0xc010000000000000) },
    }

    local xs, ys = {}, {}
    for i, test in ipairs(tests) do
        xs[i] = test.x
        ys[i] = test.y
    end
    for _, test in ipairs(tests) do
        it(test.name, function()
            assertEqualNumber(jsnum.Number_LeftShift(test.x, test.y), test.want)
        end)
    end

    describe("Node", function()
        local jsResults = memo(function()
            return evalBinaryOp(T, "a << b", xs, ys)
        end)
        for i, test in ipairs(tests) do
            it(test.name, function()
                assertEqualNumber(jsnum.Number_LeftShift(test.x, test.y), jsResults()[i])
            end)
        end
    end)
end)

describe("TestRemainder", function()
    local tests = {
        { name = "NaN % 1", x = F(0x7ff8000000000001), y = F(0x3ff0000000000000), want = F(0x7ff8000000000001) },
        { name = "1 % NaN", x = F(0x3ff0000000000000), y = F(0x7ff8000000000001), want = F(0x7ff8000000000001) },
        { name = "Infinity % 1", x = F(0x7ff0000000000000), y = F(0x3ff0000000000000), want = F(0x7ff8000000000001) },
        { name = "-Infinity % 1", x = F(0xfff0000000000000), y = F(0x3ff0000000000000), want = F(0x7ff8000000000001) },
        { name = "123 % Infinity", x = F(0x405ec00000000000), y = F(0x7ff0000000000000), want = F(0x405ec00000000000) },
        { name = "123 % -Infinity", x = F(0x405ec00000000000), y = F(0xfff0000000000000), want = F(0x405ec00000000000) },
        { name = "123 % 0", x = F(0x405ec00000000000), y = F(0x0000000000000000), want = F(0x7ff8000000000001) },
        { name = "123 % 0", x = F(0x405ec00000000000), y = F(0x8000000000000000), want = F(0x7ff8000000000001) },
        { name = "0 % 123", x = F(0x0000000000000000), y = F(0x405ec00000000000), want = F(0x0000000000000000) },
        { name = "0 % 123", x = F(0x8000000000000000), y = F(0x405ec00000000000), want = F(0x8000000000000000) },
        { name = "10 % 3", x = F(0x4024000000000000), y = F(0x4008000000000000), want = F(0x3ff0000000000000) },
        { name = "-10 % 3", x = F(0xc024000000000000), y = F(0x4008000000000000), want = F(0xbff0000000000000) },
        { name = "10 % -3", x = F(0x4024000000000000), y = F(0xc008000000000000), want = F(0x3ff0000000000000) },
        { name = "-10 % -3", x = F(0xc024000000000000), y = F(0xc008000000000000), want = F(0xbff0000000000000) },
        { name = "5.5 % 2", x = F(0x4016000000000000), y = F(0x4000000000000000), want = F(0x3ff8000000000000) },
        { name = "-5.5 % 2", x = F(0xc016000000000000), y = F(0x4000000000000000), want = F(0xbff8000000000000) },
        { name = "1 % 0.5", x = F(0x3ff0000000000000), y = F(0x3fe0000000000000), want = F(0x0000000000000000) },
        { name = "-1 % 0.5", x = F(0xbff0000000000000), y = F(0x3fe0000000000000), want = F(0x8000000000000000) },
        { name = "1.5 % 1", x = F(0x3ff8000000000000), y = F(0x3ff0000000000000), want = F(0x3fe0000000000000) },
        { name = "-1.5 % 1", x = F(0xbff8000000000000), y = F(0x3ff0000000000000), want = F(0xbfe0000000000000) },
        { name = "7 % 0.1", x = F(0x401c000000000000), y = F(0x3fb999999999999a), want = F(0x3fb999999999997e) },
        { name = "7 % 0.2", x = F(0x401c000000000000), y = F(0x3fc999999999999a), want = F(0x3fc999999999998c) },
        { name = "7 % 0.3", x = F(0x401c000000000000), y = F(0x3fd3333333333333), want = F(0x3fb99999999999ac) },
        { name = "100 % 0.3", x = F(0x4059000000000000), y = F(0x3fd3333333333333), want = F(0x3fb9999999999aa4) },
    }

    local xs, ys = {}, {}
    for i, test in ipairs(tests) do
        xs[i] = test.x
        ys[i] = test.y
    end
    for _, test in ipairs(tests) do
        it(test.name, function()
            assertEqualNumber(jsnum.Number_Remainder(test.x, test.y), test.want)
        end)
    end

    describe("Node", function()
        local jsResults = memo(function()
            return evalBinaryOp(T, "a % b", xs, ys)
        end)
        for i, test in ipairs(tests) do
            it(test.name, function()
                assertEqualNumber(jsnum.Number_Remainder(test.x, test.y), jsResults()[i])
            end)
        end
    end)
end)

describe("TestExponentiate", function()
    local tests = {
        { name = "2 ** 3", x = F(0x4000000000000000), y = F(0x4008000000000000), want = F(0x4020000000000000) },
        { name = "Infinity ** 3", x = F(0x7ff0000000000000), y = F(0x4008000000000000), want = F(0x7ff0000000000000) },
        { name = "Infinity ** -5", x = F(0x7ff0000000000000), y = F(0xc014000000000000), want = F(0x0000000000000000) },
        { name = "-Infinity ** 3", x = F(0xfff0000000000000), y = F(0x4008000000000000), want = F(0xfff0000000000000) },
        { name = "-Infinity ** 4", x = F(0xfff0000000000000), y = F(0x4010000000000000), want = F(0x7ff0000000000000) },
        { name = "-Infinity ** -3", x = F(0xfff0000000000000), y = F(0xc008000000000000), want = F(0x8000000000000000) },
        { name = "-Infinity ** -4", x = F(0xfff0000000000000), y = F(0xc010000000000000), want = F(0x0000000000000000) },
        { name = "0 ** 3", x = F(0x0000000000000000), y = F(0x4008000000000000), want = F(0x0000000000000000) },
        { name = "0 ** -10", x = F(0x0000000000000000), y = F(0xc024000000000000), want = F(0x7ff0000000000000) },
        { name = "0 ** 3", x = F(0x8000000000000000), y = F(0x4008000000000000), want = F(0x8000000000000000) },
        { name = "0 ** 4", x = F(0x8000000000000000), y = F(0x4010000000000000), want = F(0x0000000000000000) },
        { name = "0 ** -3", x = F(0x8000000000000000), y = F(0xc008000000000000), want = F(0xfff0000000000000) },
        { name = "0 ** -4", x = F(0x8000000000000000), y = F(0xc010000000000000), want = F(0x7ff0000000000000) },
        { name = "3 ** Infinity", x = F(0x4008000000000000), y = F(0x7ff0000000000000), want = F(0x7ff0000000000000) },
        { name = "-3 ** Infinity", x = F(0xc008000000000000), y = F(0x7ff0000000000000), want = F(0x7ff0000000000000) },
        { name = "3 ** -Infinity", x = F(0x4008000000000000), y = F(0xfff0000000000000), want = F(0x0000000000000000) },
        { name = "-3 ** -Infinity", x = F(0xc008000000000000), y = F(0xfff0000000000000), want = F(0x0000000000000000) },
        { name = "NaN ** 3", x = F(0x7ff8000000000001), y = F(0x4008000000000000), want = F(0x7ff8000000000001) },
        { name = "1 ** Infinity", x = F(0x3ff0000000000000), y = F(0x7ff0000000000000), want = F(0x7ff8000000000001) },
        { name = "1 ** -Infinity", x = F(0x3ff0000000000000), y = F(0xfff0000000000000), want = F(0x7ff8000000000001) },
        { name = "-1 ** Infinity", x = F(0xbff0000000000000), y = F(0x7ff0000000000000), want = F(0x7ff8000000000001) },
        { name = "-1 ** -Infinity", x = F(0xbff0000000000000), y = F(0xfff0000000000000), want = F(0x7ff8000000000001) },
        { name = "1 ** NaN", x = F(0x3ff0000000000000), y = F(0x7ff8000000000001), want = F(0x7ff8000000000001) },
        { name = "10 ** 308", x = F(0x4024000000000000), y = F(0x4073400000000000), want = F(0x7fe1ccf385ebc8a0) },
        { name = "5 ** 210", x = F(0x4014000000000000), y = F(0x406a400000000000), want = F(0x5e68557f31326bbb) },
        { name = "10 ** 200", x = F(0x4024000000000000), y = F(0x4069000000000000), want = F(0x6974e718d7d7625a) },
    }

    local xs, ys = {}, {}
    for i, test in ipairs(tests) do
        xs[i] = test.x
        ys[i] = test.y
    end
    for _, test in ipairs(tests) do
        it(test.name, function()
            assertEqualNumber(jsnum.Number_Exponentiate(test.x, test.y), test.want)
        end)
    end

    -- The ES spec says exponentiate is "implementation-approximated".
    -- Different JS engines (V8, SpiderMonkey, JSC) use different pow
    -- implementations that can differ by 1 ULP. Allow that tolerance.
    describe("Node", function()
        local jsResults = memo(function()
            return evalBinaryOp(T, "a ** b", xs, ys)
        end)
        for i, test in ipairs(tests) do
            it(test.name, function()
                assertWithinOneULP(jsnum.Number_Exponentiate(test.x, test.y), jsResults()[i])
            end)
        end
    end)
end)
