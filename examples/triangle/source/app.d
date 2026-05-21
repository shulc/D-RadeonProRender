/// Phase 0 smoke test for bindbc-rpr.
///
/// Loads libRadeonProRender64.so, registers the Northstar plugin, builds a
/// scene containing one triangle lit by an environment light, renders ~64
/// samples and writes triangle.png next to the executable.
///
/// Expects the SDK runtime on LD_LIBRARY_PATH and the Northstar plugin file
/// reachable by rprRegisterPlugin (either by absolute path or via the same
/// LD_LIBRARY_PATH). The hipbin precompiled-kernel directory must also be
/// reachable — defaults to RPR_HIPBIN env or "../../hipbin".

import std.stdio;
import std.string  : toStringz, fromStringz;
import std.process : environment;

import bindbc.rpr;

// Status check — RPR returns negative ints on error.
void check(rpr_status s, string where) {
    if (s != RPR_SUCCESS) {
        stderr.writefln("FAIL [%s]: RPR status %d", where, s);
        import core.stdc.stdlib : exit;
        exit(1);
    }
}

int main(string[] args) {
    // --- 1. Load the shared library ---------------------------------------
    const sup = loadRPR();
    if (sup != RPRSupport.loaded) {
        stderr.writeln("loadRPR failed: ", sup);
        import bindbc.loader : errors;
        foreach (e; errors()) {
            stderr.writeln("  ", fromStringz(e.error), ": ", fromStringz(e.message));
        }
        return 1;
    }
    scope(exit) unloadRPR();

    // --- 2. Register Northstar plugin -------------------------------------
    version (Windows)  enum pluginFile = "Northstar64.dll";
    else version (OSX) enum pluginFile = "libNorthstar64.dylib";
    else               enum pluginFile = "libNorthstar64.so";

    const pluginPath = environment.get("RPR_PLUGIN_PATH", pluginFile);
    const pluginId = rprRegisterPlugin(toStringz(pluginPath));
    if (pluginId == -1) {
        stderr.writefln("rprRegisterPlugin(%s) returned -1", pluginPath);
        return 1;
    }
    writefln("Plugin %s registered (id=%d).", pluginPath, pluginId);

    rpr_int[1] plugins = [ pluginId ];

    // --- 3. Create context ------------------------------------------------
    // hipbin path: precompiled kernels for Northstar. Falls back to upstream
    // SDK layout if env var not set.
    const hipbin = environment.get("RPR_HIPBIN", "../../hipbin");
    rpr_context_properties[3] ctxProps = [
        cast(rpr_context_properties) RPR_CONTEXT_PRECOMPILED_BINARY_PATH,
        cast(rpr_context_properties) toStringz(hipbin),
        cast(rpr_context_properties) null,
    ];

    rpr_context ctx;
    // Default to CPU. Override with RPR_BACKEND={cpu,gpu,opencl}.
    //   gpu     — GPU0 via HIP, requires hipbin kernels matching the GPU
    //             (works out-of-the-box on AMD; NVIDIA needs HIP-on-CUDA runtime).
    //   opencl  — GPU0 via OpenCL, works universally on NVIDIA/AMD/Intel
    //             but slower than HIP path; doesn't need hipbin.
    //   cpu     — CPU fallback (default).
    const backend = environment.get("RPR_BACKEND", "cpu");
    rpr_creation_flags flags;
    switch (backend) {
        case "gpu":    flags = RPR_CREATION_FLAGS_ENABLE_GPU0;                                  break;
        case "opencl": flags = RPR_CREATION_FLAGS_ENABLE_GPU0 | RPR_CREATION_FLAGS_ENABLE_OPENCL; break;
        default:       flags = RPR_CREATION_FLAGS_ENABLE_CPU;                                   break;
    }
    writefln("Backend: %s (flags=0x%x)", backend, flags);
    check(rprCreateContext(RPR_VERSION_MAJOR_MINOR_REVISION,
                           plugins.ptr, plugins.length,
                           flags, ctxProps.ptr, null, &ctx),
          "rprCreateContext");
    check(rprContextSetActivePlugin(ctx, pluginId), "rprContextSetActivePlugin");
    writeln("Context created.");

    // --- 4. Scene + camera ------------------------------------------------
    rpr_scene scene;
    check(rprContextCreateScene(ctx, &scene), "rprContextCreateScene");
    check(rprContextSetScene(ctx, scene),     "rprContextSetScene");

    rpr_camera cam;
    check(rprContextCreateCamera(ctx, &cam), "rprContextCreateCamera");
    check(rprCameraLookAt(cam, 0, 0, 3,   0, 0, 0,   0, 1, 0), "rprCameraLookAt");
    check(rprSceneSetCamera(scene, cam),     "rprSceneSetCamera");

    // --- 5. One triangle, normals +Z, uv unused ---------------------------
    static struct Vertex { float[3] pos; float[3] nrm; float[2] uv; }
    static immutable Vertex[3] verts = [
        Vertex([ 0.0f,  0.8f, 0.0f], [0, 0, 1], [0.5f, 1.0f]),
        Vertex([-0.8f, -0.6f, 0.0f], [0, 0, 1], [0.0f, 0.0f]),
        Vertex([ 0.8f, -0.6f, 0.0f], [0, 0, 1], [1.0f, 0.0f]),
    ];
    static immutable rpr_int[3] idx = [0, 1, 2];
    static immutable rpr_int[1] faceVertCounts = [3];

    rpr_shape shape;
    check(rprContextCreateMesh(ctx,
            cast(const(float)*) verts.ptr,                     verts.length, Vertex.sizeof,
            cast(const(float)*)(cast(const(ubyte)*) verts.ptr + float.sizeof * 3),
                                                               verts.length, Vertex.sizeof,
            cast(const(float)*)(cast(const(ubyte)*) verts.ptr + float.sizeof * 6),
                                                               verts.length, Vertex.sizeof,
            idx.ptr, rpr_int.sizeof,
            idx.ptr, rpr_int.sizeof,
            idx.ptr, rpr_int.sizeof,
            faceVertCounts.ptr, faceVertCounts.length, &shape),
          "rprContextCreateMesh");
    check(rprSceneAttachShape(scene, shape), "rprSceneAttachShape");

    // --- 6. Diffuse material ---------------------------------------------
    rpr_material_system matsys;
    check(rprContextCreateMaterialSystem(ctx, 0, &matsys), "rprContextCreateMaterialSystem");

    rpr_material_node diffuse;
    check(rprMaterialSystemCreateNode(matsys, RPR_MATERIAL_NODE_DIFFUSE, &diffuse),
          "create diffuse");
    check(rprMaterialNodeSetInputFByKey(diffuse, RPR_MATERIAL_INPUT_COLOR,
                                        0.85f, 0.25f, 0.15f, 1.0f),
          "set diffuse color");
    check(rprShapeSetMaterial(shape, diffuse), "rprShapeSetMaterial");

    // --- 7. Point light --------------------------------------------------
    // RPR env-lights need an HDRI to emit; a point light is the simplest way
    // to get illumination without bundling textures.
    rpr_light pointLight;
    check(rprContextCreatePointLight(ctx, &pointLight), "create point light");
    // Place it slightly above and in front of the triangle.
    static immutable float[16] lightXform = [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 2, 2, 1,
    ];
    check(rprLightSetTransform(pointLight, RPR_FALSE, lightXform.ptr), "light xform");
    check(rprPointLightSetRadiantPower3f(pointLight, 60.0f, 60.0f, 60.0f), "light power");
    check(rprSceneAttachLight(scene, pointLight), "rprSceneAttachLight");

    // --- 8. Framebuffer + AOV --------------------------------------------
    rpr_framebuffer_desc fbDesc = { fb_width: 512, fb_height: 512 };
    rpr_framebuffer_format fmt = { num_components: 4, type: 1 /* RPR_COMPONENT_TYPE_FLOAT32 */ };

    rpr_framebuffer fb;
    check(rprContextCreateFrameBuffer(ctx, fmt, &fbDesc, &fb), "create fb");
    rpr_framebuffer fbResolved;
    check(rprContextCreateFrameBuffer(ctx, fmt, &fbDesc, &fbResolved), "create fb resolved");
    check(rprContextSetAOV(ctx, RPR_AOV_COLOR, fb), "setAOV color");

    // --- 9. Render -------------------------------------------------------
    check(rprContextSetParameterByKey1u(ctx, RPR_CONTEXT_ITERATIONS, 64), "set iterations");
    check(rprContextSetParameterByKey1f(ctx, RPR_CONTEXT_DISPLAY_GAMMA, 2.2f), "set gamma");
    check(rprFrameBufferClear(fb), "fb clear");
    writeln("Rendering 64 samples...");
    check(rprContextRender(ctx), "render");
    check(rprContextResolveFrameBuffer(ctx, fb, fbResolved, false), "resolve");
    check(rprFrameBufferSaveToFile(fbResolved, "triangle.png".toStringz), "saveToFile");
    writeln("Wrote triangle.png");

    // --- 10. Cleanup -----------------------------------------------------
    rprObjectDelete(pointLight);
    rprObjectDelete(diffuse);
    rprObjectDelete(matsys);
    rprObjectDelete(shape);
    rprObjectDelete(cam);
    rprObjectDelete(fb);
    rprObjectDelete(fbResolved);
    rprObjectDelete(scene);
    rprObjectDelete(ctx);
    return 0;
}
