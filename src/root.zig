// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
//! Allocator-explicit 2D polygon geometry: the four boolean operations and a
//! rounded signed buffer, over one degenerate-tolerant planar overlay, plus
//! the spatial predicates over the same exact arithmetic.
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
pub const makeValid = @import("valid.zig").makeValid;
pub const buffer = @import("operations.zig").buffer;
pub const Collection = @import("geometry.zig").Collection;
pub const Matrix = @import("relate.zig").Matrix;
pub const Pattern = @import("relate.zig").Pattern;
pub const Predicate = @import("relate.zig").Predicate;
pub const RelateOptions = @import("relate.zig").Options;
pub const relate = @import("relate.zig").relate;
pub const matches = @import("relate.zig").matches;
pub const match = @import("relate.zig").match;
pub const intersects = @import("relate.zig").intersects;
pub const predicate = @import("relate.zig").evaluate;

test {
    _ = @import("tests.zig");
}
