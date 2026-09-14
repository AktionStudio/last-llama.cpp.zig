const std = @import("std");
const llama = @import("runtime_llama");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.ExpectedModel;

    llama.Backend.init();
    defer llama.Backend.deinit();
    var params = llama.Model.defaultParams();
    params.n_gpu_layers = 0;
    const model = try llama.Model.initFromFile(args[1], params);
    defer model.deinit();
    const vocab = model.vocab() orelse return error.MissingVocab;

    const long: [1024]u8 = @splat('a');
    const inputs = [_][]const u8{ "", "blue", "  café 東京 🌱\n", "<|im_start|>user\nblue<|im_end|>", "a\x00b", "\t\n  ", &long };
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    for (inputs, 0..) |input, index| {
        var tokenizer = llama.Tokenizer.init(allocator);
        defer tokenizer.deinit();
        try tokenizer.tokenize(@ptrCast(vocab), input, false, true);
        const tokens = tokenizer.getTokens();
        const pieces = try allocator.alloc([]const u8, tokens.len);
        var detokenizer = llama.Detokenizer.init(allocator);
        defer detokenizer.deinit();
        for (tokens, 0..) |token, token_index| {
            const piece = try detokenizer.detokenize(@ptrCast(vocab), token);
            const hex = try allocator.alloc(u8, piece.len * 2);
            for (piece, 0..) |byte, byte_index| {
                hex[byte_index * 2] = "0123456789abcdef"[byte >> 4];
                hex[byte_index * 2 + 1] = "0123456789abcdef"[byte & 15];
            }
            pieces[token_index] = hex;
            detokenizer.clearRetainingCapacity();
        }
        try std.json.Stringify.value(.{
            .index = index,
            .input = input,
            .tokens = tokens,
            .pieces_hex = pieces,
            .eos = vocab.tokenEos(),
            .eos_is_eog = vocab.isEog(vocab.tokenEos()),
        }, .{}, &writer.interface);
        try writer.interface.writeByte('\n');
    }
    try writer.interface.flush();
}
