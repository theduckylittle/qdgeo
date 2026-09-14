`qdgeo.wasm` here is a copy of `zig-out/bin/qdgeo.wasm`, so the examples
directory serves standalone. Refresh it after a rebuild:

```sh
zig build wasm && cp zig-out/bin/qdgeo.wasm examples/vendor/
```
