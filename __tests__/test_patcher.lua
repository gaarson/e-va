
local patcher = require("patcher")

describe("Patcher - Basic Functionality", function()

    it("should apply a simple SEARCH/REPLACE block", function()
        local original = "line1\nline2\nline3"
        local patch = [[<<<<<<< SEARCH

line2

=======

LINE2

>>>>>>> REPLACE]]

        local success, result = patcher.apply_patch(original, patch)
        assert.is_true(success)
        assert.equals("line1\nLINE2\nline3", result)
    end)

    it("should handle multiple SEARCH/REPLACE blocks", function()
        local original = "aaa\nbbb\nccc\nddd"
        local patch = [[<<<<<<< SEARCH
aaa
=======
AAA
>>>>>>> REPLACE
<<<<<<< SEARCH
ccc
=======
CCC
>>>>>>> REPLACE]]

        local success, result = patcher.apply_patch(original, patch)
        assert.is_true(success)
        assert.equals("AAA\nbbb\nCCC\nddd", result)
    end)

    it("should reject empty SEARCH block", function()
        local original = "line1\nline2"
        local patch = [[<<<<<<< SEARCH

=======

replacement

>>>>>>> REPLACE]]

        local success, result = patcher.apply_patch(original, patch)
        assert.is_false(success)
        assert.truthy(result:match("empty"))
    end)

    it("should reject identical SEARCH and REPLACE blocks", function()
        local original = "line1\nline2"
        local patch = [[<<<<<<< SEARCH

line1

=======

line1

>>>>>>> REPLACE]]

        local success, result = patcher.apply_patch(original, patch)
        assert.is_false(success)
        assert.truthy(result:match("identical"))
    end)
end)


describe("Patcher - Nested Conflict Markers Bug Fix", function()

    it("should handle content containing <<<<<<< SEARCH inside REPLACE block", function()
        local original = "function foo()\n    return 1\nend"
        local patch = [[<<<<<<< SEARCH

function foo()

    return 1

end

=======

function foo()

    -- example: <<<<<<< SEARCH is a marker

    return 2

end

>>>>>>> REPLACE]]

        local success, result = patcher.apply_patch(original, patch)
        assert.is_true(success)
        assert.truthy(result:match("<<<<<<< SEARCH is a marker"))
        assert.equals(2, select(3, patcher.apply_patch(original, patch)))
    end)

    it("should handle content containing >>>>>>> REPLACE inside SEARCH block", function()
        local original = "local x = 1"
        local patch = [[<<<<<<< SEARCH

local x = 1

=======

local x = 2

>>>>>>> REPLACE]]

        local success, result = patcher.apply_patch(original, patch)
        assert.is_true(success)
        assert.equals("local x = 2", result)
    end)

    it("should handle ======= inside SEARCH block content", function()
        local original = "a == b"
        local patch = [[<<<<<<< SEARCH
a == b
=======
a ~= b
>>>>>>> REPLACE]]

        local success, result = patcher.apply_patch(original, patch)
        assert.is_true(success)
        assert.equals("a ~= b", result)
    end)

    it("should handle multiple conflict markers in content", function()
        local original = "old_code"
        local patch = [[<<<<<<< SEARCH
old_code
=======
<<<<<<< SEARCH
=======
>>>>>>> REPLACE
new_code
>>>>>>> REPLACE]]

        local success, result = patcher.apply_patch(original, patch)

        assert.is_true(success)
        assert.equals("<<<<<<< SEARCH\n=======", result)
    end)
end)

describe("Patcher - Delimiter Exact Matching", function()

    it("should NOT treat '<<<<<<< SEARCH extra' as a delimiter", function()
        local original = "start\nmiddle\nend"
        local patch = [[<<<<<<< SEARCH
middle
=======
<<<<<<< SEARCH extra content here
>>>>>>> REPLACE]]

        local success, result = patcher.apply_patch(original, patch)
        assert.is_true(success)
        assert.truthy(result:match("<<<<<<< SEARCH extra content here"))
    end)

    it("should NOT treat '>>>>>>> something' as a closing delimiter", function()
        local original = "line1"
        local patch = [[<<<<<<< SEARCH
line1
=======
>>>>>>> something else
>>>>>>> REPLACE]]

        local success, result = patcher.apply_patch(original, patch)
        assert.is_true(success)
        assert.equals(">>>>>>> something else", result)
    end)

    it("should require exact '>>>>>>> REPLACE' as closing delimiter", function()
        local original = "x"
        local patch = [[<<<<<<< SEARCH
x
=======
y
>>>>>>> REPLACE]]

        local success, result = patcher.apply_patch(original, patch)
        assert.is_true(success)
        assert.equals("y", result)
    end)
end)


describe("Patcher - Edge Cases", function()

    it("should handle missing closing delimiter gracefully", function()
        local original = "line1"
        local patch = [[<<<<<<< SEARCH
line1
=======
replacement]]

        local success, result = patcher.apply_patch(original, patch)
        assert.is_true(success)
        assert.equals("replacement", result)
    end)

    it("should handle whitespace-only lines in blocks", function()
        local original = "a\n\nb"

        local patch = [[<<<<<<< SEARCH

a


b

=======

A


B

>>>>>>> REPLACE]]

        local success, result = patcher.apply_patch(original, patch)
        assert.is_true(success)
    end)

    it("should handle no valid blocks", function()
        local original = "content"
        local patch = "no blocks here"

        local success, result = patcher.apply_patch(original, patch)
        assert.is_false(success)
        assert.truthy(result:match("No valid"))
    end)

    it("should handle ambiguous matches", function()

        local original = "x\nx\nx"

        local patch = [[<<<<<<< SEARCH

x

=======

y

>>>>>>> REPLACE]]

        local success, result = patcher.apply_patch(original, patch)
        assert.is_false(success)
        assert.truthy(result:match("AMBIGUOUS"))
    end)
end)


describe("Patcher - Fuzzy Matching", function()
    it("should handle whitespace differences", function()
        local original = "  indented  "
        local patch = [[<<<<<<< SEARCH
indented
=======
replaced
>>>>>>> REPLACE]]

        local success, result = patcher.apply_patch(original, patch)
        assert.is_true(success)
    end)
end)
