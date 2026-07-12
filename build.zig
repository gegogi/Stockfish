const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = mem.Allocator;
const Build = std.Build;
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const http = std.http;
const math = std.math;
const mem = std.mem;
const Io = std.Io;

pub fn build(b: *Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opts = b.addOptions();

    const embed_nets = b.option(bool, "embed-nets", "Whether or not to embed the NNUE file in the executable (default: true)") orelse true;
    opts.addOption(bool, "embed-nets", embed_nets);

    const small_net = b.option([]const u8, "small-net", "Name of the small NNUE (default: \"nn-37f18f62d772.nnue\")") orelse "nn-37f18f62d772.nnue";
    opts.addOption([]const u8, "small-net", small_net);

    const big_net = b.option([]const u8, "big-net", "Name of the big NNUE (default: \"nn-c288c895ea92.nnue\")") orelse "nn-c288c895ea92.nnue";
    opts.addOption([]const u8, "big-net", big_net);

    try downloadNNUE(b, small_net);
    try downloadNNUE(b, big_net);

    const stockfish_dep = b.dependency("Stockfish", .{});
    const stockfish_src_path = stockfish_dep.path("src/");

    // Everything main.cpp needs (engine logic, search, NNUE eval, UCI
    // protocol handling) *except* main.cpp itself -- shared between the
    // desktop/Android subprocess executable below and the "stockfish_core"
    // module exposed for a host app to embed directly (see znogfx's
    // app/chess/stockfish_embed.cpp and uci_engine.zig's Engine.spawnThread).
    // main.cpp defines `main()`, which would collide with a host app's own
    // entry point if linked into the same binary, so it's added separately,
    // only for the standalone `stockfish` executable.
    const engine_sources = &[_][]const u8{
        "benchmark.cpp",
        "bitboard.cpp",
        "engine.cpp",
        "evaluate.cpp",
        "memory.cpp",
        "misc.cpp",
        "movegen.cpp",
        "movepick.cpp",
        "nnue/features/half_ka_v2_hm.cpp",
        "nnue/features/full_threats.cpp",
        "nnue/network.cpp",
        "nnue/nnue_accumulator.cpp",
        "nnue/nnue_misc.cpp",
        "position.cpp",
        "score.cpp",
        "search.cpp",
        "syzygy/tbprobe.cpp",
        "thread.cpp",
        "timeman.cpp",
        "tt.cpp",
        "tune.cpp",
        "uci.cpp",
        "ucioption.cpp",
    };
    const nnue_flags = &[_][]const u8{
        if (embed_nets) "" else "-DNNUE_EMBEDDING_OFF=1",
    };

    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    module.addCSourceFiles(.{ .root = stockfish_src_path, .files = engine_sources, .flags = nnue_flags });
    module.addCSourceFile(.{ .file = stockfish_src_path.path(b, "main.cpp"), .flags = nnue_flags });
    const exe = b.addExecutable(.{
        .name = "stockfish",
        .root_module = module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Build and run stockfish");
    run_step.dependOn(&run_cmd.step);

    if (optimize != .Debug) {
        exe.root_module.pic = true;
        exe.pie = true;
        exe.root_module.omit_frame_pointer = true;
        exe.root_module.strip = true;
        exe.lto = switch (builtin.os.tag) {
            .macos => .none,
            else => .full,
        };
    }

    // Library-only variant (no main.cpp, so no `main()` symbol conflict) for
    // a host app to embed and drive on its own thread. `root_source_file =
    // null`: this is a pure-C++-sources module with no Zig code of its own.
    // `addModule` (rather than `createModule`) registers it under a stable
    // name so a parent build can do `dep.module("stockfish_core")`, append
    // its own bridge source file (addCSourceFile), and wrap the result in
    // its own `b.addLibrary(...)` -- see build.zig/build_ios.zig/
    // build_android.zig.
    const embed_module = b.addModule("stockfish_core", .{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
    });
    embed_module.addCSourceFiles(.{ .root = stockfish_src_path, .files = engine_sources, .flags = nnue_flags });
    // So a parent build's own bridge file (e.g. znogfx's
    // app/chess/stockfish_embed.cpp) can `#include "misc.h"` etc. -- this
    // source root only resolves correctly from inside *this* build.zig (it
    // comes from our own nested "Stockfish" dependency), so it must be
    // attached here rather than left for the consumer to guess a path.
    embed_module.addIncludePath(stockfish_src_path);
}

/// The first time we run "zig build", we need to download the necessary nnue files
fn downloadNNUE(b: *Build, nnue_file: []const u8) !void {
    const result = if (@hasDecl(fs, "Dir") and @hasDecl(fs.Dir, "statFile"))
        fs.cwd().statFile(nnue_file)
    else
        Io.Dir.cwd().statFile(b.graph.io, nnue_file, .{});

    _ = result catch |err| switch (err) {
        error.FileNotFound => {
            const url = try fmt.allocPrint(b.allocator, "https://data.stockfishchess.org/nn/{s}", .{nnue_file});
            std.debug.print("No nnue file found, downloading {s}\n\n", .{url});

            if (@hasDecl(std.process, "spawn")) {
                var child = try std.process.spawn(b.graph.io, .{
                    .argv = &.{ "curl", "-o", nnue_file, url },
                });
                std.debug.assert((try child.wait(b.graph.io)).exited == 0);
            } else {
                var child = std.process.Child.init(&.{ "curl", "-o", nnue_file, url }, b.allocator);
                try child.spawn();
                _ = try child.wait();
            }
        },
        else => return err,
    };
}
