const std = @import("std");
const Result = extern struct { data: ?[*]u8 = null, size: usize = 0 };
extern fn lab_schema_compile(input: [*]const u8, input_size: usize, result: *Result, diagnostic: [*]u8, diagnostic_capacity: usize) c_int;
extern fn lab_schema_result_clear(result: *Result) void;

pub const Grammar = struct {
    result: Result,
    pub fn bytes(self: *const Grammar) []const u8 {
        return if (self.result.data) |data| data[0..self.result.size] else &.{};
    }
    pub fn deinit(self: *Grammar) void {
        lab_schema_result_clear(&self.result);
        std.debug.assert(self.result.data == null and self.result.size == 0);
    }
};

// Borrow the exact invocation schema. The caller owns diagnostic storage and the
// successful Grammar; no request or grammar is stored in this module.
pub fn compile(raw: []const u8, diagnostic: []u8) !Grammar {
    var result: Result = .{};
    const status = lab_schema_compile(raw.ptr, raw.len, &result, diagnostic.ptr, diagnostic.len);
    if (status != 0) {
        std.debug.assert(result.data == null and result.size == 0);
        return switch (status) {
            1 => error.InvalidSchemaArgument,
            2 => error.UnsupportedSchema,
            3 => error.InvalidSchemaJson,
            4 => error.SchemaConversionFailed,
            5 => error.OutOfMemory,
            else => error.UnknownSchemaStatus,
        };
    }
    if (result.data == null or result.size == 0) {
        lab_schema_result_clear(&result);
        return error.EmptyGrammar;
    }
    return .{ .result = result };
}
