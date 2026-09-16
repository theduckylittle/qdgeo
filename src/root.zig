// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
//! Allocator-explicit 2D polygon geometry: the four boolean operations and a
//! rounded signed buffer, over one degenerate-tolerant planar overlay.
pub const Coordinate = @import("geometry.zig").Coordinate;
pub const LinearRing = @import("geometry.zig").LinearRing;
pub const Polygon = @import("geometry.zig").Polygon;
pub const LineString = @import("geometry.zig").LineString;
pub const Geometry = @import("geometry.zig").Geometry;
pub const wkb = @import("wkb.zig");
pub const flat = @import("flat.zig");
pub const BooleanOptions = @import("operations.zig").BooleanOptions;
pub const unionAll = @import("operations.zig").unionAll;
pub const boolean = @import("operations.zig").boolean;
pub const Mode = @import("geometry.zig").Mode;
pub const BufferOptions = @import("operations.zig").BufferOptions;
pub const BufferInput = @import("operations.zig").BufferInput;
pub const buffer = @import("operations.zig").buffer;

test {
    _ = @import("tests.zig");
}
