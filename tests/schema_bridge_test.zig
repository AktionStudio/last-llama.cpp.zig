const std = @import("std");
const schema = @import("schema");

fn expectGrammar(raw: []const u8) !void {
    var diagnostic: [2048]u8 = undefined;
    var grammar = try schema.compile(raw, &diagnostic);
    defer grammar.deinit();
    try std.testing.expect(grammar.bytes().len > 0);
}

test "guarded converter accepts closed constants nullable alternatives and nesting" {
    try expectGrammar(
        \\{"type":"object","additionalProperties":false,"properties":{"answer":{"type":"string","const":"blue"}},"required":["answer"]}
    );
    try expectGrammar(
        \\{"type":"object","additionalProperties":false,"properties":{"optional":{"anyOf":[{"type":"null"},{"type":"string","maxLength":8}]}},"required":[]}
    );
    try expectGrammar(
        \\{"type":"object","additionalProperties":false,"properties":{"items":{"type":"array","minItems":1,"maxItems":2,"items":{"type":"object","additionalProperties":false,"properties":{"kind":{"type":"string","enum":["a","b"]}},"required":["kind"]}}},"required":["items"]}
    );
}

test "guarded converter rejects an open object before converter fallback" {
    var diagnostic: [2048]u8 = undefined;
    try std.testing.expectError(
        error.UnsupportedSchema,
        schema.compile(
            \\{"type":"object","properties":{"answer":{"type":"string"}}}
        , &diagnostic),
    );
}
