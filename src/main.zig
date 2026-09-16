// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
const std = @import("std");
const geo = @import("qdgeo");

pub fn main() !void {
    const ring = [_]geo.Coordinate{ .{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 2, .y = 2 }, .{ .x = 0, .y = 2 }, .{ .x = 0, .y = 0 } };
    var result = try geo.bufferAll(std.heap.page_allocator, &.{.{ .rings = &.{&ring} }}, 1, .{});
    defer result.deinit();
    const bytes = try geo.wkb.write(std.heap.page_allocator, result.polygons, .little);
    defer std.heap.page_allocator.free(bytes);
    std.debug.print("Buffered rectangle: {d} polygon, {d} WKB bytes\n", .{ result.polygons.len, bytes.len });
}
