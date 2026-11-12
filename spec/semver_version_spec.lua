-- Port of internal/semver/version_test.go.
local semver = require("tslua.semver")

local function assertVersion(a, b)
    assert.are.equal(b.major, a.major)
    assert.are.equal(b.minor, a.minor)
    assert.are.equal(b.patch, a.patch)
    assert.are.same(b.prerelease, a.prerelease)
    assert.are.same(b.build, a.build)
end

describe("TestTryParseSemver", function()
    local tests = {
        { "1.2.3-pre.4+build.5", semver.NewVersion({ major = 1, minor = 2, patch = 3, prerelease = { "pre", "4" }, build = { "build", "5" } }) },
        { "1.2.3-pre.4", semver.NewVersion({ major = 1, minor = 2, patch = 3, prerelease = { "pre", "4" } }) },
        { "1.2.3+build.4", semver.NewVersion({ major = 1, minor = 2, patch = 3, build = { "build", "4" } }) },
        { "1.2.3", semver.NewVersion({ major = 1, minor = 2, patch = 3 }) },
    }

    for _, test in ipairs(tests) do
        it(test[1], function()
            local v, err = semver.TryParseVersion(test[1])
            assert.is_nil(err)
            assertVersion(v, test[2])
        end)
    end
end)

describe("TestVersionString", function()
    local tests = {
        { semver.NewVersion({ major = 1, minor = 2, patch = 3, prerelease = { "pre", "4" }, build = { "build", "5" } }), "1.2.3-pre.4+build.5" },
        { semver.NewVersion({ major = 1, minor = 2, patch = 3, prerelease = { "pre", "4" }, build = { "build" } }), "1.2.3-pre.4+build" },
        { semver.NewVersion({ major = 1, minor = 2, patch = 3, build = { "build" } }), "1.2.3+build" },
        { semver.NewVersion({ major = 1, minor = 2, patch = 3, prerelease = { "pre", "4" } }), "1.2.3-pre.4" },
        { semver.NewVersion({ major = 1, minor = 2, patch = 3, build = { "build", "4" } }), "1.2.3+build.4" },
        { semver.NewVersion({ major = 1, minor = 2, patch = 3 }), "1.2.3" },
    }

    for _, test in ipairs(tests) do
        it(test[2], function()
            assert.are.equal(test[2], test[1]:String())
        end)
    end
end)

describe("TestVersionCompare", function()
    local tests = {
        -- https://semver.org/#spec-item-11
        -- > Precedence is determined by the first difference when comparing each of these
        -- > identifiers from left to right as follows: Major, minor, and patch versions are
        -- > always compared numerically.
        { "1.0.0", "2.0.0", semver.comparisonLessThan },
        { "1.0.0", "1.1.0", semver.comparisonLessThan },
        { "1.0.0", "1.0.1", semver.comparisonLessThan },
        { "2.0.0", "1.0.0", semver.comparisonGreaterThan },
        { "1.1.0", "1.0.0", semver.comparisonGreaterThan },
        { "1.0.1", "1.0.0", semver.comparisonGreaterThan },
        { "1.0.0", "1.0.0", semver.comparisonEqualTo },

        -- https://semver.org/#spec-item-11
        -- > When major, minor, and patch are equal, a pre-release version has lower
        -- > precedence than a normal version.
        { "1.0.0", "1.0.0-pre", semver.comparisonGreaterThan },
        { "1.0.1-pre", "1.0.0", semver.comparisonGreaterThan },
        { "1.0.0-pre", "1.0.0", semver.comparisonLessThan },

        -- https://semver.org/#spec-item-11
        -- > identifiers consisting of only digits are compared numerically
        { "1.0.0-0", "1.0.0-1", semver.comparisonLessThan },
        { "1.0.0-1", "1.0.0-0", semver.comparisonGreaterThan },
        { "1.0.0-2", "1.0.0-10", semver.comparisonLessThan },
        { "1.0.0-10", "1.0.0-2", semver.comparisonGreaterThan },
        { "1.0.0-0", "1.0.0-0", semver.comparisonEqualTo },

        -- https://semver.org/#spec-item-11
        -- > identifiers with letters or hyphens are compared lexically in ASCII sort order.
        { "1.0.0-a", "1.0.0-b", semver.comparisonLessThan },
        { "1.0.0-a-2", "1.0.0-a-10", semver.comparisonGreaterThan },
        { "1.0.0-b", "1.0.0-a", semver.comparisonGreaterThan },
        { "1.0.0-a", "1.0.0-a", semver.comparisonEqualTo },
        { "1.0.0-A", "1.0.0-a", semver.comparisonLessThan },

        -- https://semver.org/#spec-item-11
        -- > Numeric identifiers always have lower precedence than non-numeric identifiers.
        { "1.0.0-0", "1.0.0-alpha", semver.comparisonLessThan },
        { "1.0.0-alpha", "1.0.0-0", semver.comparisonGreaterThan },
        { "1.0.0-0", "1.0.0-0", semver.comparisonEqualTo },
        { "1.0.0-alpha", "1.0.0-alpha", semver.comparisonEqualTo },

        -- https://semver.org/#spec-item-11
        -- > A larger set of pre-release fields has a higher precedence than a smaller set, if all
        -- > of the preceding identifiers are equal.
        { "1.0.0-alpha", "1.0.0-alpha.0", semver.comparisonLessThan },
        { "1.0.0-alpha.0", "1.0.0-alpha", semver.comparisonGreaterThan },

        -- https://semver.org/#spec-item-11
        -- > Precedence for two pre-release versions with the same major, minor, and patch version
        -- > MUST be determined by comparing each dot separated identifier from left to right until
        -- > a difference is found [...]
        { "1.0.0-a.0.b.1", "1.0.0-a.0.b.2", semver.comparisonLessThan },
        { "1.0.0-a.0.b.1", "1.0.0-b.0.a.1", semver.comparisonLessThan },
        { "1.0.0-a.0.b.2", "1.0.0-a.0.b.1", semver.comparisonGreaterThan },
        { "1.0.0-b.0.a.1", "1.0.0-a.0.b.1", semver.comparisonGreaterThan },

        -- https://semver.org/#spec-item-11
        -- > Build metadata does not figure into precedence
        { "1.0.0+build", "1.0.0", semver.comparisonEqualTo },
        { "1.0.0+build.stuff", "1.0.0", semver.comparisonEqualTo },
        { "1.0.0", "1.0.0+build", semver.comparisonEqualTo },
        { "1.0.0+build", "1.0.0+stuff", semver.comparisonEqualTo },

        -- https://semver.org/#spec-item-11
        -- Edge cases for numeric and lexical comparison of prerelease identifiers.
        { "1.0.0-alpha.99999", "1.0.0-alpha.100000", semver.comparisonLessThan },
        { "1.0.0-alpha.beta", "1.0.0-alpha.alpha", semver.comparisonGreaterThan },
    }

    for _, test in ipairs(tests) do
        it(test[1] .. " <=> " .. test[2], function()
            local v1, err1 = semver.TryParseVersion(test[1])
            assert.is_nil(err1, test[1])
            local v2, err2 = semver.TryParseVersion(test[2])
            assert.is_nil(err2, test[2])
            assert.are.equal(test[3], v1:Compare(v2))
        end)
    end
end)
