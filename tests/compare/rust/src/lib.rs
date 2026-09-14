// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Dan "Ducky" Little
//! rust-geo behind the same flat ABI this library uses, compiled to wasm32.
//!
//! The suite compares WASM against WASM in one Node host: same inputs, same
//! interchange, same timing boundary. Comparing our WASM against a native Rust
//! binary would have flattered neither side honestly.
use geo::algorithm::{
    bool_ops::{unary_union, BooleanOps, OpType},
    buffer::{BufferStyle, LineJoin},
};
use geo::{Buffer, Coord, LineString, MultiPolygon, Polygon};

static mut COORDS: Vec<f64> = Vec::new();
static mut RING_ENDS: Vec<u32> = Vec::new();
static mut POLYGON_ENDS: Vec<u32> = Vec::new();
static mut OUT_COORDS: Vec<f64> = Vec::new();
static mut OUT_RING_ENDS: Vec<u32> = Vec::new();
static mut OUT_POLYGON_ENDS: Vec<u32> = Vec::new();

fn coords() -> &'static mut Vec<f64> { unsafe { &mut *(&raw mut COORDS) } }
fn ring_ends() -> &'static mut Vec<u32> { unsafe { &mut *(&raw mut RING_ENDS) } }
fn polygon_ends() -> &'static mut Vec<u32> { unsafe { &mut *(&raw mut POLYGON_ENDS) } }
fn out_coords() -> &'static mut Vec<f64> { unsafe { &mut *(&raw mut OUT_COORDS) } }
fn out_ring_ends() -> &'static mut Vec<u32> { unsafe { &mut *(&raw mut OUT_RING_ENDS) } }
fn out_polygon_ends() -> &'static mut Vec<u32> { unsafe { &mut *(&raw mut OUT_POLYGON_ENDS) } }

#[unsafe(no_mangle)]
pub extern "C" fn rg_input(coordinates: usize, rings: usize, polygons: usize) -> usize {
    coords().clear();
    coords().resize(coordinates * 2, 0.0);
    ring_ends().clear();
    ring_ends().resize(rings, 0);
    polygon_ends().clear();
    polygon_ends().resize(polygons, 0);
    coords().as_ptr() as usize
}
#[unsafe(no_mangle)]
pub extern "C" fn rg_ring_ends_ptr() -> usize { ring_ends().as_ptr() as usize }
#[unsafe(no_mangle)]
pub extern "C" fn rg_polygon_ends_ptr() -> usize { polygon_ends().as_ptr() as usize }
#[unsafe(no_mangle)]
pub extern "C" fn rg_result_ptr() -> usize { out_coords().as_ptr() as usize }
#[unsafe(no_mangle)]
pub extern "C" fn rg_result_coordinates() -> usize { out_coords().len() / 2 }
#[unsafe(no_mangle)]
pub extern "C" fn rg_result_ring_ends_ptr() -> usize { out_ring_ends().as_ptr() as usize }
#[unsafe(no_mangle)]
pub extern "C" fn rg_result_rings() -> usize { out_ring_ends().len() }
#[unsafe(no_mangle)]
pub extern "C" fn rg_result_polygon_ends_ptr() -> usize { out_polygon_ends().as_ptr() as usize }
#[unsafe(no_mangle)]
pub extern "C" fn rg_result_polygons() -> usize { out_polygon_ends().len() }

fn read() -> Vec<Polygon<f64>> {
    let (c, re, pe) = (coords(), ring_ends(), polygon_ends());
    let mut out = Vec::with_capacity(pe.len());
    let (mut ring, mut point) = (0usize, 0usize);
    for &end in pe.iter() {
        let mut rings: Vec<LineString<f64>> = Vec::new();
        while ring < end as usize {
            let stop = re[ring] as usize;
            let mut cs = Vec::with_capacity(stop - point);
            while point < stop {
                cs.push(Coord { x: c[2 * point], y: c[2 * point + 1] });
                point += 1;
            }
            rings.push(LineString(cs));
            ring += 1;
        }
        if rings.is_empty() { continue; }
        let shell = rings.remove(0);
        out.push(Polygon::new(shell, rings));
    }
    out
}
fn write(mp: &MultiPolygon<f64>) {
    let (c, re, pe) = (out_coords(), out_ring_ends(), out_polygon_ends());
    c.clear();
    re.clear();
    pe.clear();
    for poly in mp.0.iter() {
        for ring in std::iter::once(poly.exterior()).chain(poly.interiors().iter()) {
            for p in ring.0.iter() {
                c.push(p.x);
                c.push(p.y);
            }
            re.push((c.len() / 2) as u32);
        }
        pe.push(re.len() as u32);
    }
}

/// 0 union, 1 intersection, 2 difference, 3 symmetric difference, 4 buffer.
#[unsafe(no_mangle)]
pub extern "C" fn rg_execute(op: u32, subject: usize, distance: f64, steps: f64) -> u32 {
    let polygons = read();
    let result = match op {
        0 => unary_union(&polygons),
        4 => {
            let style = BufferStyle::new(distance)
                .line_join(LineJoin::Round(std::f64::consts::PI / (2.0 * steps)));
            unary_union(&polygons).buffer_with_style(style)
        }
        1 | 2 | 3 => {
            let split = subject.min(polygons.len());
            let a = MultiPolygon::new(polygons[..split].to_vec());
            let b = MultiPolygon::new(polygons[split..].to_vec());
            a.boolean_op(&b, match op {
                1 => OpType::Intersection,
                2 => OpType::Difference,
                _ => OpType::Xor,
            })
        }
        _ => return 6,
    };
    write(&result);
    0
}
