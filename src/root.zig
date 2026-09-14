// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
//! Experimental allocator-explicit 2D polygon geometry: union, the three other
//! boolean operations, and rounded signed buffer, over one degenerate-tolerant
//! planar overlay. Read TODO.md for verified status before relying on it.
pub const Coordinate = @import("geometry.zig").Coordinate;
pub const LinearRing = @import("geometry.zig").LinearRing;
pub const Polygon = @import("geometry.zig").Polygon;
pub const LineString = @import("geometry.zig").LineString;
pub const Geometry = @import("geometry.zig").Geometry;
pub const wkb = @import("wkb.zig");
pub const flat = @import("flat.zig");
pub const UnionOptions = @import("operations.zig").UnionOptions;
pub const unionAll = @import("operations.zig").unionAll;
pub const boolean = @import("operations.zig").boolean;
pub const Mode = @import("geometry.zig").Mode;
pub const BufferOptions = @import("operations.zig").BufferOptions;
pub const buffer = @import("operations.zig").buffer;
pub const bufferWithOptions = @import("operations.zig").bufferWithOptions;
pub const bufferAll = @import("operations.zig").bufferAll;
pub const Input = @import("operations.zig").Input;
pub const bufferInput = @import("operations.zig").bufferInput;

test {
    _ = @import("tests.zig");
}
