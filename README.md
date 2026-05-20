# D-RadeonProRender

D bindings for the [AMD Radeon ProRender SDK](https://github.com/GPUOpen-LibrariesAndSDKs/RadeonProRenderSDK).
Bindbc-style: dynamic loading via `bindbc-loader` by default, optional static binding behind `version=BindRPR_Static`.

Auto-generated from `RadeonProRender.h` — covers 233 functions, 97 typedefs, 1085 enum constants, all RPR scene structs.

## Status

Phase 0 / proof-of-concept. Confirmed working: load `libRadeonProRender64.so`, register Northstar plugin, build a one-triangle scene, render on CPU, write a PNG. Not yet bound: `RprLoadStore.h`, `RadeonProRender_MaterialX.h`, `RadeonProRender_VK.h`, `RadeonProRender_GL.h`, `RadeonImageFilters.h`. See `examples/triangle/` for the smoke test.

## Dependencies

- DUB
- DMD/LDC
- AMD RPR SDK runtime — `libRadeonProRender64.so` + a backend plugin (`libNorthstar64.so`, `HybridPro.so`, ...). Get them from <https://github.com/GPUOpen-LibrariesAndSDKs/RadeonProRenderSDK> and put them on `LD_LIBRARY_PATH`.
- `bindbc-common` `~>1.0.5`, `bindbc-loader` `~>1.1.5` (pulled by DUB).

## Use

```d
import bindbc.rpr;

if (loadRPR() != RPRSupport.loaded) { /* check bindbc.loader.errors() */ }
scope(exit) unloadRPR();

const plugin = rprRegisterPlugin("libNorthstar64.so".toStringz);
rpr_int[1] plugins = [plugin];
rpr_context ctx;
rprCreateContext(RPR_VERSION_MAJOR_MINOR_REVISION,
                 plugins.ptr, 1,
                 RPR_CREATION_FLAGS_ENABLE_CPU,
                 null, null, &ctx);
// ...
```

## Layout

```
source/bindbc/rpr/
├── package.d        # loadRPR / unloadRPR, RPRSupport enum
├── config.d        # staticBinding flag
├── codegen.d       # bindbc-common joinFnBinds alias
└── bind/
    ├── types.d     # AUTO — typedefs + struct + enum-grouped #defines
    └── core.d      # AUTO — FnBind[] for RadeonProRender.h

tools/
└── gen_binds.py    # regenerate bind/*.d from a fresh SDK header

examples/triangle/  # smoke test: render one diffuse triangle to PNG
```

To refresh after an SDK update:

```bash
python3 tools/gen_binds.py /path/to/RadeonProRenderSDK/RadeonProRender/inc/RadeonProRender.h
dub build
```

## Triangle smoke test

```bash
cd examples/triangle
dub build

LD_LIBRARY_PATH=/path/to/SDK/RadeonProRender/binUbuntu20 \
RPR_PLUGIN_PATH=/path/to/SDK/RadeonProRender/binUbuntu20/libNorthstar64.so \
./triangle              # CPU backend, writes triangle.png
```

For GPU: `RPR_BACKEND=gpu` plus `RPR_HIPBIN=/path/to/hipbin` (precompiled HIP kernels — separate submodule of the SDK).

## License

- Bindings: Boost Software License 1.0 (matches the bindbc family).
- The RPR SDK itself is Apache 2.0 (headers + samples) + AMD EULA (runtime binaries). See `license.txt` in the SDK distribution.
