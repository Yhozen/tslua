-- Port of internal/jsnum/string_test.go and ryu_test.go (ryuTests are part of stringTests). The test tables were evaluated by Go (numbers as IEEE 754 bit
-- patterns, subtest names formatted by Go) with .context/scratch/go-unit-tests/jsnum/gen.mjs.
-- luacheck: ignore 631 613
local jsnum = require("tslua.jsnum")
local json = require("tslua.json")
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

local stringTests = {
    { number = F(0x7ff8000000000001), str = "NaN", v = "NaN", q = "fromString \"NaN\"" },
    { number = F(0x7ff0000000000000), str = "Infinity", v = "+Inf", q = "fromString \"Infinity\"" },
    { number = F(0xfff0000000000000), str = "-Infinity", v = "-Inf", q = "fromString \"-Infinity\"" },
    { number = F(0x0000000000000000), str = "0", v = "0", q = "fromString \"0\"" },
    { number = F(0x8000000000000000), str = "0", v = "-0", q = "fromString \"0\"" },
    { number = F(0x3ff0000000000000), str = "1", v = "1", q = "fromString \"1\"" },
    { number = F(0xbff0000000000000), str = "-1", v = "-1", q = "fromString \"-1\"" },
    { number = F(0x3fd3333333333333), str = "0.3", v = "0.3", q = "fromString \"0.3\"" },
    { number = F(0xbfd3333333333333), str = "-0.3", v = "-0.3", q = "fromString \"-0.3\"" },
    { number = F(0x3ff8000000000000), str = "1.5", v = "1.5", q = "fromString \"1.5\"" },
    { number = F(0xbff8000000000000), str = "-1.5", v = "-1.5", q = "fromString \"-1.5\"" },
    { number = F(0x7fe1ccf385ebc8a0), str = "1e+308", v = "1e+308", q = "fromString \"1e+308\"" },
    { number = F(0xffe1ccf385ebc8a0), str = "-1e+308", v = "-1e+308", q = "fromString \"-1e+308\"" },
    { number = F(0x400921fb54442d18), str = "3.141592653589793", v = "3.141592653589793", q = "fromString \"3.141592653589793\"" },
    { number = F(0xc00921fb54442d18), str = "-3.141592653589793", v = "-3.141592653589793", q = "fromString \"-3.141592653589793\"" },
    { number = F(0x433fffffffffffff), str = "9007199254740991", v = "9.007199254740991e+15", q = "fromString \"9007199254740991\"" },
    { number = F(0xc33fffffffffffff), str = "-9007199254740991", v = "-9.007199254740991e+15", q = "fromString \"-9007199254740991\"" },
    { number = F(0x000fffffffffffff), str = "2.225073858507201e-308", v = "2.225073858507201e-308", q = "fromString \"2.225073858507201e-308\"" },
    { number = F(0x0010000000000000), str = "2.2250738585072014e-308", v = "2.2250738585072014e-308", q = "fromString \"2.2250738585072014e-308\"" },
    { number = F(0x4132d687cccccccd), str = "1234567.8", v = "1.2345678e+06", q = "fromString \"1234567.8\"" },
    { number = F(0x43f11331c6015789), str = "19686109595169230000", v = "1.968610959516923e+19", q = "fromString \"19686109595169230000\"" },
    { number = F(0x405edd2f1a9fbe77), str = "123.456", v = "123.456", q = "fromString \"123.456\"" },
    { number = F(0xc05edd2f1a9fbe77), str = "-123.456", v = "-123.456", q = "fromString \"-123.456\"" },
    { number = F(0x411b1b6c00000000), str = "444123", v = "444123", q = "fromString \"444123\"" },
    { number = F(0xc11b1b6c00000000), str = "-444123", v = "-444123", q = "fromString \"-444123\"" },
    { number = F(0x411b1b6f280ffabe), str = "444123.7891234568", v = "444123.7891234568", q = "fromString \"444123.7891234568\"" },
    { number = F(0xc11b1b6f28966f56), str = "-444123.7896363636", v = "-444123.7896363636", q = "fromString \"-444123.7896363636\"" },
    { number = F(0x444b1ae4d6e2ef50), str = "1e+21", v = "1e+21", q = "fromString \"1e+21\"" },
    { number = F(0x4415af1d78b58c40), str = "100000000000000000000", v = "1e+20", q = "fromString \"100000000000000000000\"" },
    { number = F(0x0010000000000000), str = "2.2250738585072014e-308", v = "2.2250738585072014e-308", q = "fromString \"2.2250738585072014e-308\"" },
    { number = F(0x7fefffffffffffff), str = "1.7976931348623157e+308", v = "1.7976931348623157e+308", q = "fromString \"1.7976931348623157e+308\"" },
    { number = F(0x0000000000000001), str = "5e-324", v = "5e-324", q = "fromString \"5e-324\"" },
    { number = F(0x3e60000000000000), str = "2.9802322387695312e-8", v = "2.9802322387695312e-08", q = "fromString \"2.9802322387695312e-8\"" },
    { number = F(0xc352bd2668e077c4), str = "-21098088986959630", v = "-2.109808898695963e+16", q = "fromString \"-21098088986959630\"" },
    { number = F(0x00000000000f4240), str = "4.940656e-318", v = "4.940656e-318", q = "fromString \"4.940656e-318\"" },
    { number = F(0x00000000016e3600), str = "1.18575755e-316", v = "1.18575755e-316", q = "fromString \"1.18575755e-316\"" },
    { number = F(0x0000008cdcdea440), str = "2.989102097996e-312", v = "2.989102097996e-312", q = "fromString \"2.989102097996e-312\"" },
    { number = F(0x434018601510c000), str = "9060801153433600", v = "9.0608011534336e+15", q = "fromString \"9060801153433600\"" },
    { number = F(0x43d055dc36f24000), str = "4708356024711512000", v = "4.708356024711512e+18", q = "fromString \"4708356024711512000\"" },
    { number = F(0x43e052961c6f8000), str = "9409340012568248000", v = "9.409340012568248e+18", q = "fromString \"9409340012568248000\"" },
    { number = F(0x3ff3c0ca2a5b1d5d), str = "1.2345678", v = "1.2345678", q = "fromString \"1.2345678\"" },
    { number = F(0x4830f0cf064dd592), str = "5.764607523034235e+39", v = "5.764607523034235e+39", q = "fromString \"5.764607523034235e+39\"" },
    { number = F(0x4840f0cf064dd592), str = "1.152921504606847e+40", v = "1.152921504606847e+40", q = "fromString \"1.152921504606847e+40\"" },
    { number = F(0x4850f0cf064dd592), str = "2.305843009213694e+40", v = "2.305843009213694e+40", q = "fromString \"2.305843009213694e+40\"" },
    { number = F(0x3ff3333333333333), str = "1.2", v = "1.2", q = "fromString \"1.2\"" },
    { number = F(0x3ff3ae147ae147ae), str = "1.23", v = "1.23", q = "fromString \"1.23\"" },
    { number = F(0x3ff3be76c8b43958), str = "1.234", v = "1.234", q = "fromString \"1.234\"" },
    { number = F(0x3ff3c083126e978d), str = "1.2345", v = "1.2345", q = "fromString \"1.2345\"" },
    { number = F(0x3ff3c0c1fc8f3238), str = "1.23456", v = "1.23456", q = "fromString \"1.23456\"" },
    { number = F(0x3ff3c0c9539b8887), str = "1.234567", v = "1.234567", q = "fromString \"1.234567\"" },
    { number = F(0x3ff3c0ca2a5b1d5d), str = "1.2345678", v = "1.2345678", q = "fromString \"1.2345678\"" },
    { number = F(0x3ff3c0ca4283de1b), str = "1.23456789", v = "1.23456789", q = "fromString \"1.23456789\"" },
    { number = F(0x3ff3c0ca43db770a), str = "1.234567895", v = "1.234567895", q = "fromString \"1.234567895\"" },
    { number = F(0x3ff3c0ca428abd53), str = "1.2345678901", v = "1.2345678901", q = "fromString \"1.2345678901\"" },
    { number = F(0x3ff3c0ca428c1d2b), str = "1.23456789012", v = "1.23456789012", q = "fromString \"1.23456789012\"" },
    { number = F(0x3ff3c0ca428c51f2), str = "1.234567890123", v = "1.234567890123", q = "fromString \"1.234567890123\"" },
    { number = F(0x3ff3c0ca428c58fc), str = "1.2345678901234", v = "1.2345678901234", q = "fromString \"1.2345678901234\"" },
    { number = F(0x3ff3c0ca428c59dd), str = "1.23456789012345", v = "1.23456789012345", q = "fromString \"1.23456789012345\"" },
    { number = F(0x3ff3c0ca428c59f8), str = "1.234567890123456", v = "1.234567890123456", q = "fromString \"1.234567890123456\"" },
    { number = F(0x3ff3c0ca428c59fb), str = "1.2345678901234567", v = "1.2345678901234567", q = "fromString \"1.2345678901234567\"" },
    { number = F(0x40112e0be8047a7d), str = "4.294967294", v = "4.294967294", q = "fromString \"4.294967294\"" },
    { number = F(0x40112e0be815a889), str = "4.294967295", v = "4.294967295", q = "fromString \"4.294967295\"" },
    { number = F(0x40112e0be826d695), str = "4.294967296", v = "4.294967296", q = "fromString \"4.294967296\"" },
    { number = F(0x40112e0be83804a1), str = "4.294967297", v = "4.294967297", q = "fromString \"4.294967297\"" },
    { number = F(0x40112e0be84932ad), str = "4.294967298", v = "4.294967298", q = "fromString \"4.294967298\"" },
    { number = F(0x0040000000000000), str = "1.7800590868057611e-307", v = "1.7800590868057611e-307", q = "fromString \"1.7800590868057611e-307\"" },
    { number = F(0x007fffffffffffff), str = "2.8480945388892175e-306", v = "2.8480945388892175e-306", q = "fromString \"2.8480945388892175e-306\"" },
    { number = F(0x0290000000000000), str = "2.446494580089078e-296", v = "2.446494580089078e-296", q = "fromString \"2.446494580089078e-296\"" },
    { number = F(0x029fffffffffffff), str = "4.8929891601781557e-296", v = "4.8929891601781557e-296", q = "fromString \"4.8929891601781557e-296\"" },
    { number = F(0x4350000000000000), str = "18014398509481984", v = "1.8014398509481984e+16", q = "fromString \"18014398509481984\"" },
    { number = F(0x435fffffffffffff), str = "36028797018963964", v = "3.6028797018963964e+16", q = "fromString \"36028797018963964\"" },
    { number = F(0x1330000000000000), str = "2.900835519859558e-216", v = "2.900835519859558e-216", q = "fromString \"2.900835519859558e-216\"" },
    { number = F(0x133fffffffffffff), str = "5.801671039719115e-216", v = "5.801671039719115e-216", q = "fromString \"5.801671039719115e-216\"" },
    { number = F(0x3a6fa7161a4d6e0c), str = "3.196104012172126e-27", v = "3.196104012172126e-27", q = "fromString \"3.196104012172126e-27\"" },
    { number = F(0x433fffffffffffff), str = "9007199254740991", v = "9.007199254740991e+15", q = "fromString \"9007199254740991\"" },
    { number = F(0x4340000000000000), str = "9007199254740992", v = "9.007199254740992e+15", q = "fromString \"9007199254740992\"" },
    { number = F(0x3ff0000000000000), str = "1", v = "1", q = "fromString \"1\"" },
    { number = F(0x4028000000000000), str = "12", v = "12", q = "fromString \"12\"" },
    { number = F(0x405ec00000000000), str = "123", v = "123", q = "fromString \"123\"" },
    { number = F(0x4093480000000000), str = "1234", v = "1234", q = "fromString \"1234\"" },
    { number = F(0x40c81c8000000000), str = "12345", v = "12345", q = "fromString \"12345\"" },
    { number = F(0x40fe240000000000), str = "123456", v = "123456", q = "fromString \"123456\"" },
    { number = F(0x4132d68700000000), str = "1234567", v = "1.234567e+06", q = "fromString \"1234567\"" },
    { number = F(0x41678c29c0000000), str = "12345678", v = "1.2345678e+07", q = "fromString \"12345678\"" },
    { number = F(0x419d6f3454000000), str = "123456789", v = "1.23456789e+08", q = "fromString \"123456789\"" },
    { number = F(0x41d26580b4800000), str = "1234567890", v = "1.23456789e+09", q = "fromString \"1234567890\"" },
    { number = F(0x41d26580b5c00000), str = "1234567895", v = "1.234567895e+09", q = "fromString \"1234567895\"" },
    { number = F(0x4206fee0e1a80000), str = "12345678901", v = "1.2345678901e+10", q = "fromString \"12345678901\"" },
    { number = F(0x423cbe991a140000), str = "123456789012", v = "1.23456789012e+11", q = "fromString \"123456789012\"" },
    { number = F(0x4271f71fb04cb000), str = "1234567890123", v = "1.234567890123e+12", q = "fromString \"1234567890123\"" },
    { number = F(0x42a674e79c5fe400), str = "12345678901234", v = "1.2345678901234e+13", q = "fromString \"12345678901234\"" },
    { number = F(0x42dc12218377de40), str = "123456789012345", v = "1.23456789012345e+14", q = "fromString \"123456789012345\"" },
    { number = F(0x43118b54f22aeb00), str = "1234567890123456", v = "1.234567890123456e+15", q = "fromString \"1234567890123456\"" },
    { number = F(0x3ff0000000000000), str = "1", v = "1", q = "fromString \"1\"" },
    { number = F(0x4024000000000000), str = "10", v = "10", q = "fromString \"10\"" },
    { number = F(0x4059000000000000), str = "100", v = "100", q = "fromString \"100\"" },
    { number = F(0x408f400000000000), str = "1000", v = "1000", q = "fromString \"1000\"" },
    { number = F(0x40c3880000000000), str = "10000", v = "10000", q = "fromString \"10000\"" },
    { number = F(0x40f86a0000000000), str = "100000", v = "100000", q = "fromString \"100000\"" },
    { number = F(0x412e848000000000), str = "1000000", v = "1e+06", q = "fromString \"1000000\"" },
    { number = F(0x416312d000000000), str = "10000000", v = "1e+07", q = "fromString \"10000000\"" },
    { number = F(0x4197d78400000000), str = "100000000", v = "1e+08", q = "fromString \"100000000\"" },
    { number = F(0x41cdcd6500000000), str = "1000000000", v = "1e+09", q = "fromString \"1000000000\"" },
    { number = F(0x4202a05f20000000), str = "10000000000", v = "1e+10", q = "fromString \"10000000000\"" },
    { number = F(0x42374876e8000000), str = "100000000000", v = "1e+11", q = "fromString \"100000000000\"" },
    { number = F(0x426d1a94a2000000), str = "1000000000000", v = "1e+12", q = "fromString \"1000000000000\"" },
    { number = F(0x42a2309ce5400000), str = "10000000000000", v = "1e+13", q = "fromString \"10000000000000\"" },
    { number = F(0x42d6bcc41e900000), str = "100000000000000", v = "1e+14", q = "fromString \"100000000000000\"" },
    { number = F(0x430c6bf526340000), str = "1000000000000000", v = "1e+15", q = "fromString \"1000000000000000\"" },
    { number = F(0x430c6bf526340008), str = "1000000000000001", v = "1.000000000000001e+15", q = "fromString \"1000000000000001\"" },
    { number = F(0x430c6bf526340050), str = "1000000000000010", v = "1.00000000000001e+15", q = "fromString \"1000000000000010\"" },
    { number = F(0x430c6bf526340320), str = "1000000000000100", v = "1.0000000000001e+15", q = "fromString \"1000000000000100\"" },
    { number = F(0x430c6bf526341f40), str = "1000000000001000", v = "1.000000000001e+15", q = "fromString \"1000000000001000\"" },
    { number = F(0x430c6bf526353880), str = "1000000000010000", v = "1.00000000001e+15", q = "fromString \"1000000000010000\"" },
    { number = F(0x430c6bf526403500), str = "1000000000100000", v = "1.0000000001e+15", q = "fromString \"1000000000100000\"" },
    { number = F(0x430c6bf526ae1200), str = "1000000001000000", v = "1.000000001e+15", q = "fromString \"1000000001000000\"" },
    { number = F(0x430c6bf52af8b400), str = "1000000010000000", v = "1.00000001e+15", q = "fromString \"1000000010000000\"" },
    { number = F(0x430c6bf555e30800), str = "1000000100000000", v = "1.0000001e+15", q = "fromString \"1000000100000000\"" },
    { number = F(0x430c6bf7030a5000), str = "1000001000000000", v = "1.000001e+15", q = "fromString \"1000001000000000\"" },
    { number = F(0x430c6c07c6932000), str = "1000010000000000", v = "1.00001e+15", q = "fromString \"1000010000000000\"" },
    { number = F(0x430c6caf69eb4000), str = "1000100000000000", v = "1.0001e+15", q = "fromString \"1000100000000000\"" },
    { number = F(0x430c733bcb5c8000), str = "1001000000000000", v = "1.001e+15", q = "fromString \"1001000000000000\"" },
    { number = F(0x430cb4b799c90000), str = "1010000000000000", v = "1.01e+15", q = "fromString \"1010000000000000\"" },
    { number = F(0x430f438daa060000), str = "1100000000000000", v = "1.1e+15", q = "fromString \"1100000000000000\"" },
    { number = F(0x4020000000000000), str = "8", v = "8", q = "fromString \"8\"" },
    { number = F(0x4050000000000000), str = "64", v = "64", q = "fromString \"64\"" },
    { number = F(0x4080000000000000), str = "512", v = "512", q = "fromString \"512\"" },
    { number = F(0x40c0000000000000), str = "8192", v = "8192", q = "fromString \"8192\"" },
    { number = F(0x40f0000000000000), str = "65536", v = "65536", q = "fromString \"65536\"" },
    { number = F(0x4120000000000000), str = "524288", v = "524288", q = "fromString \"524288\"" },
    { number = F(0x4160000000000000), str = "8388608", v = "8.388608e+06", q = "fromString \"8388608\"" },
    { number = F(0x4190000000000000), str = "67108864", v = "6.7108864e+07", q = "fromString \"67108864\"" },
    { number = F(0x41c0000000000000), str = "536870912", v = "5.36870912e+08", q = "fromString \"536870912\"" },
    { number = F(0x4200000000000000), str = "8589934592", v = "8.589934592e+09", q = "fromString \"8589934592\"" },
    { number = F(0x4230000000000000), str = "68719476736", v = "6.8719476736e+10", q = "fromString \"68719476736\"" },
    { number = F(0x4260000000000000), str = "549755813888", v = "5.49755813888e+11", q = "fromString \"549755813888\"" },
    { number = F(0x42a0000000000000), str = "8796093022208", v = "8.796093022208e+12", q = "fromString \"8796093022208\"" },
    { number = F(0x42d0000000000000), str = "70368744177664", v = "7.0368744177664e+13", q = "fromString \"70368744177664\"" },
    { number = F(0x4300000000000000), str = "562949953421312", v = "5.62949953421312e+14", q = "fromString \"562949953421312\"" },
    { number = F(0x4340000000000000), str = "9007199254740992", v = "9.007199254740992e+15", q = "fromString \"9007199254740992\"" },
    { number = F(0x40bf400000000000), str = "8000", v = "8000", q = "fromString \"8000\"" },
    { number = F(0x40ef400000000000), str = "64000", v = "64000", q = "fromString \"64000\"" },
    { number = F(0x411f400000000000), str = "512000", v = "512000", q = "fromString \"512000\"" },
    { number = F(0x415f400000000000), str = "8192000", v = "8.192e+06", q = "fromString \"8192000\"" },
    { number = F(0x418f400000000000), str = "65536000", v = "6.5536e+07", q = "fromString \"65536000\"" },
    { number = F(0x41bf400000000000), str = "524288000", v = "5.24288e+08", q = "fromString \"524288000\"" },
    { number = F(0x41ff400000000000), str = "8388608000", v = "8.388608e+09", q = "fromString \"8388608000\"" },
    { number = F(0x422f400000000000), str = "67108864000", v = "6.7108864e+10", q = "fromString \"67108864000\"" },
    { number = F(0x425f400000000000), str = "536870912000", v = "5.36870912e+11", q = "fromString \"536870912000\"" },
    { number = F(0x429f400000000000), str = "8589934592000", v = "8.589934592e+12", q = "fromString \"8589934592000\"" },
    { number = F(0x42cf400000000000), str = "68719476736000", v = "6.8719476736e+13", q = "fromString \"68719476736000\"" },
    { number = F(0x42ff400000000000), str = "549755813888000", v = "5.49755813888e+14", q = "fromString \"549755813888000\"" },
    { number = F(0x433f400000000000), str = "8796093022208000", v = "8.796093022208e+15", q = "fromString \"8796093022208000\"" },
}

local fromStringTests = {
    { number = F(0x7ff8000000000001), str = "    NaN", v = "NaN", q = "fromString \"    NaN\"" },
    { number = F(0x7ff0000000000000), str = "Infinity    ", v = "+Inf", q = "fromString \"Infinity    \"" },
    { number = F(0xfff0000000000000), str = "    -Infinity", v = "-Inf", q = "fromString \"    -Infinity\"" },
    { number = F(0x3ff0000000000000), str = "1.", v = "1", q = "fromString \"1.\"" },
    { number = F(0x3ff0000000000000), str = "1.0   ", v = "1", q = "fromString \"1.0   \"" },
    { number = F(0x3ff0000000000000), str = "+1", v = "1", q = "fromString \"+1\"" },
    { number = F(0x3ff0000000000000), str = "+1.", v = "1", q = "fromString \"+1.\"" },
    { number = F(0x3ff0000000000000), str = "+1.0", v = "1", q = "fromString \"+1.0\"" },
    { number = F(0x7ff8000000000001), str = "whoops", v = "NaN", q = "fromString \"whoops\"" },
    { number = F(0x0000000000000000), str = "", v = "0", q = "fromString \"\"" },
    { number = F(0x0000000000000000), str = "0", v = "0", q = "fromString \"0\"" },
    { number = F(0x0000000000000000), str = "0.", v = "0", q = "fromString \"0.\"" },
    { number = F(0x0000000000000000), str = "0.0", v = "0", q = "fromString \"0.0\"" },
    { number = F(0x0000000000000000), str = "0.0000", v = "0", q = "fromString \"0.0000\"" },
    { number = F(0x0000000000000000), str = ".0000", v = "0", q = "fromString \".0000\"" },
    { number = F(0x8000000000000000), str = "-0", v = "-0", q = "fromString \"-0\"" },
    { number = F(0x8000000000000000), str = "-0.", v = "-0", q = "fromString \"-0.\"" },
    { number = F(0x8000000000000000), str = "-0.0", v = "-0", q = "fromString \"-0.0\"" },
    { number = F(0x8000000000000000), str = "-.0", v = "-0", q = "fromString \"-.0\"" },
    { number = F(0x7ff8000000000001), str = ".", v = "NaN", q = "fromString \".\"" },
    { number = F(0x7ff8000000000001), str = "e", v = "NaN", q = "fromString \"e\"" },
    { number = F(0x7ff8000000000001), str = ".e", v = "NaN", q = "fromString \".e\"" },
    { number = F(0x7ff8000000000001), str = "+", v = "NaN", q = "fromString \"+\"" },
    { number = F(0x0000000000000000), str = "0X0", v = "0", q = "fromString \"0X0\"" },
    { number = F(0x7ff8000000000001), str = "e0", v = "NaN", q = "fromString \"e0\"" },
    { number = F(0x7ff8000000000001), str = "E0", v = "NaN", q = "fromString \"E0\"" },
    { number = F(0x7ff8000000000001), str = "1e", v = "NaN", q = "fromString \"1e\"" },
    { number = F(0x7ff8000000000001), str = "1e+", v = "NaN", q = "fromString \"1e+\"" },
    { number = F(0x7ff8000000000001), str = "1e-", v = "NaN", q = "fromString \"1e-\"" },
    { number = F(0x3ff0000000000000), str = "1e+0", v = "1", q = "fromString \"1e+0\"" },
    { number = F(0x7ff8000000000001), str = "++0", v = "NaN", q = "fromString \"++0\"" },
    { number = F(0x7ff8000000000001), str = "0_0", v = "NaN", q = "fromString \"0_0\"" },
    { number = F(0x7ff0000000000000), str = "1e1000", v = "+Inf", q = "fromString \"1e1000\"" },
    { number = F(0xfff0000000000000), str = "-1e1000", v = "-Inf", q = "fromString \"-1e1000\"" },
    { number = F(0x0000000000000000), str = ".0e0", v = "0", q = "fromString \".0e0\"" },
    { number = F(0x7ff8000000000001), str = "0e++0", v = "NaN", q = "fromString \"0e++0\"" },
    { number = F(0x4024000000000000), str = "0XA", v = "10", q = "fromString \"0XA\"" },
    { number = F(0x4024000000000000), str = "0b1010", v = "10", q = "fromString \"0b1010\"" },
    { number = F(0x4024000000000000), str = "0B1010", v = "10", q = "fromString \"0B1010\"" },
    { number = F(0x4024000000000000), str = "0o12", v = "10", q = "fromString \"0o12\"" },
    { number = F(0x4024000000000000), str = "0O12", v = "10", q = "fromString \"0O12\"" },
    { number = F(0x43b23456789abcdf), str = "0x123456789abcdef0", v = "1.3117684674637903e+18", q = "fromString \"0x123456789abcdef0\"" },
    { number = F(0x43b23456789abcdf), str = "0X123456789ABCDEF0", v = "1.3117684674637903e+18", q = "fromString \"0X123456789ABCDEF0\"" },
    { number = F(0x43f0000000000000), str = "0X10000000000000000", v = "1.8446744073709552e+19", q = "fromString \"0X10000000000000000\"" },
    { number = F(0x43f000000000000b), str = "0X1000000000000A801", v = "1.8446744073709597e+19", q = "fromString \"0X1000000000000A801\"" },
    { number = F(0x7ff8000000000001), str = "0B0.0", v = "NaN", q = "fromString \"0B0.0\"" },
    { number = F(0x52d82d4fb614915b), str = "12312353450834030486384068034683603046834603806830644850340602384608368034634603680348603864", v = "1.231235345083403e+91", q = "fromString \"12312353450834030486384068034683603046834603806830644850340602384608368034634603680348603864\"" },
    { number = F(0x7ff8000000000001), str = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX8OOOOOOOOOOOOOOOOOOO", v = "NaN", q = "fromString \"XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX8OOOOOOOOOOOOOOOOOOO\"" },
    { number = F(0x7ff0000000000000), str = "+Infinity", v = "+Inf", q = "fromString \"+Infinity\"" },
    { number = F(0x40934a3d70a3d70a), str = "  \0091234.56  ", v = "1234.56", q = "fromString \"  \\t1234.56  \"" },
    { number = F(0x7ff8000000000001), str = "\226\128\139", v = "NaN", q = "fromString \"\\u200b\"" },
    { number = F(0x0000000000000000), str = " ", v = "0", q = "fromString \" \"" },
    { number = F(0x0000000000000000), str = "\010", v = "0", q = "fromString \"\\n\"" },
    { number = F(0x0000000000000000), str = "\013", v = "0", q = "fromString \"\\r\"" },
    { number = F(0x0000000000000000), str = "\013\010", v = "0", q = "fromString \"\\r\\n\"" },
    { number = F(0x0000000000000000), str = "\226\128\168", v = "0", q = "fromString \"\\u2028\"" },
    { number = F(0x0000000000000000), str = "\226\128\169", v = "0", q = "fromString \"\\u2029\"" },
    { number = F(0x0000000000000000), str = "\009", v = "0", q = "fromString \"\\t\"" },
    { number = F(0x0000000000000000), str = "\011", v = "0", q = "fromString \"\\v\"" },
    { number = F(0x0000000000000000), str = "\012", v = "0", q = "fromString \"\\f\"" },
    { number = F(0x0000000000000000), str = "\239\187\191", v = "0", q = "fromString \"\\ufeff\"" },
    { number = F(0x0000000000000000), str = "\194\160", v = "0", q = "fromString \"\\u00a0\"" },
    { number = F(0x43e158e460913d00), str = "010000000000000000000", v = "1e+19", q = "fromString \"010000000000000000000\"" },
    { number = F(0x7ff8000000000001), str = "0x1.fffffffffffffp1023", v = "NaN", q = "fromString \"0x1.fffffffffffffp1023\"" },
    { number = F(0x7ff8000000000001), str = "0X_1FFFP-16", v = "NaN", q = "fromString \"0X_1FFFP-16\"" },
    { number = F(0x7ff8000000000001), str = "1_000", v = "NaN", q = "fromString \"1_000\"" },
    { number = F(0x0000000000000000), str = "0x0", v = "0", q = "fromString \"0x0\"" },
    { number = F(0x0000000000000000), str = "0X0", v = "0", q = "fromString \"0X0\"" },
    { number = F(0x7ff8000000000001), str = "0xOOPS", v = "NaN", q = "fromString \"0xOOPS\"" },
    { number = F(0x416579bde0000000), str = "0xABCDEF", v = "1.1259375e+07", q = "fromString \"0xABCDEF\"" },
    { number = F(0x416579bde0000000), str = "0xABCDEF", v = "1.1259375e+07", q = "fromString \"0xABCDEF\"" },
    { number = F(0x0000000000000000), str = "0o0", v = "0", q = "fromString \"0o0\"" },
    { number = F(0x0000000000000000), str = "0O0", v = "0", q = "fromString \"0O0\"" },
    { number = F(0x7ff8000000000001), str = "0o8", v = "NaN", q = "fromString \"0o8\"" },
    { number = F(0x7ff8000000000001), str = "0O8", v = "NaN", q = "fromString \"0O8\"" },
    { number = F(0x40b4e50000000000), str = "0o12345", v = "5349", q = "fromString \"0o12345\"" },
    { number = F(0x40b4e50000000000), str = "0O12345", v = "5349", q = "fromString \"0O12345\"" },
    { number = F(0x0000000000000000), str = "0b0", v = "0", q = "fromString \"0b0\"" },
    { number = F(0x0000000000000000), str = "0B0", v = "0", q = "fromString \"0B0\"" },
    { number = F(0x7ff8000000000001), str = "0b2", v = "NaN", q = "fromString \"0b2\"" },
    { number = F(0x7ff8000000000001), str = "0b2", v = "NaN", q = "fromString \"0b2\"" },
    { number = F(0x4035000000000000), str = "0b10101", v = "21", q = "fromString \"0b10101\"" },
    { number = F(0x4035000000000000), str = "0B10101", v = "21", q = "fromString \"0B10101\"" },
    { number = F(0x7ff8000000000001), str = "1.f", v = "NaN", q = "fromString \"1.f\"" },
    { number = F(0x7ff8000000000001), str = "1.e", v = "NaN", q = "fromString \"1.e\"" },
    { number = F(0x7ff8000000000001), str = "1.0ef", v = "NaN", q = "fromString \"1.0ef\"" },
    { number = F(0x7ff8000000000001), str = "1.0e", v = "NaN", q = "fromString \"1.0e\"" },
    { number = F(0x7ff8000000000001), str = ".f", v = "NaN", q = "fromString \".f\"" },
    { number = F(0x7ff8000000000001), str = ".e", v = "NaN", q = "fromString \".e\"" },
    { number = F(0x7ff8000000000001), str = ".0ef", v = "NaN", q = "fromString \".0ef\"" },
    { number = F(0x7ff8000000000001), str = ".0e", v = "NaN", q = "fromString \".0e\"" },
    { number = F(0x7ff8000000000001), str = "a.f", v = "NaN", q = "fromString \"a.f\"" },
    { number = F(0x7ff8000000000001), str = "a.e", v = "NaN", q = "fromString \"a.e\"" },
    { number = F(0x7ff8000000000001), str = "a.0ef", v = "NaN", q = "fromString \"a.0ef\"" },
    { number = F(0x7ff8000000000001), str = "a.0e", v = "NaN", q = "fromString \"a.0e\"" },
}

describe("TestString", function()
    for _, test in ipairs(stringTests) do
        it(test.v, function()
            assert.are.equal(test.str, jsnum.Number_String(test.number))
        end)
    end
end)

describe("TestFromString", function()
    describe("stringTests", function()
        for _, test in ipairs(stringTests) do
            it(test.str, function()
                assertEqualNumber(jsnum.FromString(test.str), test.number)
                assertEqualNumber(jsnum.FromString(test.str .. " "), test.number)
                assertEqualNumber(jsnum.FromString(" " .. test.str), test.number)
            end)
        end
    end)

    describe("fromStringTests", function()
        for _, test in ipairs(fromStringTests) do
            it(test.str, function()
                assertEqualNumber(jsnum.FromString(test.str), test.number)
            end)
        end
    end)
end)

describe("TestStringRoundtrip", function()
    for _, test in ipairs(stringTests) do
        it(test.str, function()
            assert.are.equal(test.str, jsnum.Number_String(jsnum.FromString(test.str)))
        end)
    end
end)

local function getStringResultsFromJS(t, tests)
    t:Helper()
    local tmpdir = tempDir()

    local inputData = {}
    for i, test in ipairs(tests) do
        local bits = numToUint32s(test.number)
        inputData[i] = string.format('{"bits":[%d,%d],"str":', bits[1], bits[2]) .. json.QuoteString(test.str) .. "}"
    end

    local jsonInputPath = tmpdir .. "/input.json"
    writeFile(jsonInputPath, "[" .. table.concat(inputData, ",") .. "]")

    local script = [[
		import fs from 'fs';
]] .. bitsScript .. [[
		export default function(inputFile) {
			const input = JSON.parse(fs.readFileSync(inputFile, 'utf8'));

			const output = input.map((input) => ({
				str: ""+fromBits(input.bits),
				bits: toBits(+input.str),	
			}));

			return output;
		};
	]]

    local outputData, err = jstest.EvalNodeScript(t, script, tmpdir, jsonInputPath)
    removeAll(tmpdir)
    assert.is_nil(err)
    assert.are.equal(#tests, #outputData)

    local output = {}
    for i, outputDatum in ipairs(outputData) do
        output[i] = { number = uint32sToNum(outputDatum.bits), str = outputDatum.str }
    end
    return output
end

describe("TestStringJS", function()
    describe("stringTests", function()
        -- These tests should roundtrip both ways.
        local stringTestsResults = memo(function()
            jstest.SkipIfNoNodeJS(T)
            return getStringResultsFromJS(T, stringTests)
        end)
        for i, test in ipairs(stringTests) do
            it(test.v, function()
                assertEqualNumber(stringTestsResults()[i].number, test.number)
                assert.are.equal(test.str, stringTestsResults()[i].str)
            end)
        end
    end)

    describe("fromStringTests", function()
        -- These tests should convert the string to the same number.
        local fromStringTestsResults = memo(function()
            jstest.SkipIfNoNodeJS(T)
            return getStringResultsFromJS(T, fromStringTests)
        end)
        for i, test in ipairs(fromStringTests) do
            it(test.q, function()
                assertEqualNumber(fromStringTestsResults()[i].number, test.number)
            end)
        end
    end)
end)
