// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("qdgeo", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib = b.addLibrary(.{ .name = "qdgeo", .root_module = mod, .linkage = .static });
    b.installArtifact(lib);
    const exe = b.addExecutable(.{
        .name = "qdgeo-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "qdgeo", .module = mod }},
        }),
    });
    b.step("run", "Run rounded buffer example").dependOn(&b.addRunArtifact(exe).step);
    const tests = b.addTest(.{ .root_module = mod });
    b.step("test", "Run geometry tests").dependOn(&b.addRunArtifact(tests).step);

    const native_mod = b.createModule(.{
        .root_source_file = b.path("src/native.zig"),
        .target = target,
        .optimize = optimize,
    });
    const native = b.addLibrary(.{ .name = "qdgeo_native", .root_module = native_mod, .linkage = .dynamic });
    b.step("native", "Build shared C ABI for native differential benchmarks").dependOn(&b.addInstallArtifact(native, .{}).step);

    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/abi.zig"),
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
            .cpu_features_add = std.Target.wasm.featureSet(&.{.simd128}),
        }),
        // ReleaseSafe by default: goal 4 outranks goal 1, and the shipped
        // artifact keeps its runtime safety checks. `-Dwasm-optimize=ReleaseFast`
        // exists to measure what those checks cost, not to ship.
        .optimize = b.option(
            std.builtin.OptimizeMode,
            "wasm-optimize",
            "Optimize mode for the WASM artifact (default ReleaseSafe)",
        ) orelse .ReleaseSafe,
        // 80% of an unstripped artifact is DWARF, which no browser reads.
        .strip = true,
    });
    const wasm = b.addExecutable(.{ .name = "qdgeo", .root_module = wasm_mod });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.max_memory = 512 * 1024 * 1024;
    b.step("wasm", "Build dependency-free WASM with simd128").dependOn(&b.addInstallArtifact(wasm, .{}).step);
}
