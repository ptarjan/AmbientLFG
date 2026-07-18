-- Minimal zero-dependency spec runner (busted-style describe/it/expect).
-- Canonical copy: D:\World of Warcraft\tools\spec.lua (copied into each
-- repo's tests/ directory). Works on Lua 5.1+ with no libraries.
--
-- Usage in a test file:
--   local spec = dofile("tests/spec.lua")
--   spec.describe("thing", function()
--     spec.it("does x", function()
--       spec.eq(actual, expected, "optional label")
--       spec.near(actual, expected, tolerance)
--       spec.ok(condition, "label")
--     end)
--   end)
--   os.exit(spec.finish())

local M = { passed = 0, failed = 0, context = "" }

local function fail(msg)
    M.failed = M.failed + 1
    io.write(string.format("FAIL %s: %s\n", M.context, msg))
end

local function pass()
    M.passed = M.passed + 1
end

function M.describe(name, fn)
    local prev = M.context
    M.context = prev == "" and name or (prev .. " > " .. name)
    fn()
    M.context = prev
end

function M.it(name, fn)
    local prev = M.context
    M.context = prev .. " > " .. name
    local ok, err = pcall(fn)
    if not ok then
        M.failed = M.failed + 1
        io.write(string.format("ERROR %s: %s\n", M.context, tostring(err)))
    end
    M.context = prev
end

local function repr(v)
    if type(v) == "string" then
        return string.format("%q", v)
    end
    return tostring(v)
end

function M.eq(actual, expected, label)
    if actual ~= expected then
        fail(string.format("%sexpected %s, got %s",
            label and (label .. ": ") or "", repr(expected), repr(actual)))
    else
        pass()
    end
end

function M.near(actual, expected, tolerance, label)
    tolerance = tolerance or 0.001
    if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
        fail(string.format("%sexpected %s (±%s), got %s",
            label and (label .. ": ") or "", tostring(expected),
            tostring(tolerance), repr(actual)))
    else
        pass()
    end
end

function M.ok(condition, label)
    if not condition then
        fail(string.format("%sexpected truthy, got %s",
            label and (label .. ": ") or "", repr(condition)))
    else
        pass()
    end
end

function M.finish()
    io.write(string.format("\n%d passed, %d failed\n", M.passed, M.failed))
    return M.failed == 0 and 0 or 1
end

return M
