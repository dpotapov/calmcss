const std = @import("std");
const Io = std.Io;
const calm = @import("calmcss");

const Usage =
    \\calmcss - tiny Tailwind-compatible utility compiler
    \\
    \\Usage:
    \\  calmcss -i input.html -o output.css
    \\  calmcss --chunk app.html=app.html --chunk component.html=component.html
    \\  calmcss --config calmcss.json input.html
    \\
    \\Options:
    \\  -i, --input FILE       Add an input chunk.
    \\  -o, --output FILE      Write CSS to a file instead of stdout.
    \\  --chunk NAME=FILE      Add a named chunk whose content is FILE.
    \\  --config FILE          Add JSON/YAML config as a chunk; safelist strings are scanned.
    \\  --help                 Show this help.
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const io = init.io;

    var chunks: std.ArrayList(calm.Chunk) = .empty;
    defer chunks.deinit(allocator);
    var output_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            try writeStdout(io, Usage);
            return;
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--input")) {
            i += 1;
            if (i >= args.len) return error.MissingInputPath;
            try addFileChunk(allocator, io, &chunks, args[i], args[i]);
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.MissingOutputPath;
            output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--chunk")) {
            i += 1;
            if (i >= args.len) return error.MissingChunk;
            try addNamedChunk(allocator, io, &chunks, args[i]);
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.MissingConfigPath;
            try addFileChunk(allocator, io, &chunks, args[i], args[i]);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownArgument;
        } else {
            try addFileChunk(allocator, io, &chunks, arg, arg);
        }
    }

    if (chunks.items.len == 0) {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin_reader = Io.File.stdin().reader(io, &stdin_buffer);
        const content = try stdin_reader.interface.allocRemaining(allocator, .limited(64 * 1024 * 1024));
        try chunks.append(allocator, .{ .name = "stdin", .content = content });
    }

    const css = try calm.compileAlloc(allocator, chunks.items, .{});
    if (output_path) |path| {
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = css });
    } else {
        try writeStdout(io, css);
    }
}

fn addNamedChunk(allocator: std.mem.Allocator, io: Io, chunks: *std.ArrayList(calm.Chunk), spec: []const u8) !void {
    const eq = std.mem.indexOfScalar(u8, spec, '=') orelse return error.InvalidChunk;
    const name = spec[0..eq];
    const path = spec[eq + 1 ..];
    try addFileChunk(allocator, io, chunks, name, path);
}

fn addFileChunk(allocator: std.mem.Allocator, io: Io, chunks: *std.ArrayList(calm.Chunk), name: []const u8, path: []const u8) !void {
    const content = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    try chunks.append(allocator, .{ .name = name, .content = content });
}

fn writeStdout(io: Io, bytes: []const u8) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.writeAll(bytes);
    try stdout.flush();
}
