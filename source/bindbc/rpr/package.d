/// D bindings for AMD Radeon ProRender (RPR) SDK.
///
/// Style matches bindbc-sdl / bindbc-opengl: dynamic loading by default via
/// bindbc-loader, optional static binding behind `version=BindRPR_Static`.
///
/// Typical use:
/// ---
/// import bindbc.rpr;
///
/// // Load libRadeonProRender64.so / RadeonProRender64.dll
/// if (loadRPR() != RPRSupport.loaded) { /* handle error */ }
/// scope(exit) unloadRPR();
///
/// // ... rprRegisterPlugin / rprCreateContext / ... ...
/// ---
module bindbc.rpr;

public import bindbc.rpr.config;
public import bindbc.rpr.bind.types;
public import bindbc.rpr.bind.core;

enum RPRSupport {
    noLibrary,
    badLibrary,
    loaded,
}

static if (staticBinding)
{
    // Static binding: nothing to load at runtime. Provide stubs so callers
    // can keep the same load/unload shape.
    RPRSupport loadRPR()                        nothrow @nogc { return RPRSupport.loaded; }
    RPRSupport loadRPR(const(char)* libName)    nothrow @nogc { return RPRSupport.loaded; }
    void       unloadRPR()                      nothrow @nogc {}
    bool       isRPRLoaded()                    nothrow @nogc { return true; }
}
else
{
    import bindbc.loader;

    private SharedLib lib;

    /// Returns whether the RPR shared library has been successfully loaded.
    bool isRPRLoaded() nothrow @nogc { return lib != invalidHandle; }

    /// Unloads the RPR shared library and resets internal function pointers.
    void unloadRPR() nothrow @nogc {
        if (lib != invalidHandle) lib.unload();
    }

    /// Tries platform default library names in order.
    RPRSupport loadRPR() nothrow @nogc {
        version (Windows)      static immutable const(char)*[] candidates = ["RadeonProRender64.dll".ptr];
        else version (OSX)     static immutable const(char)*[] candidates = ["libRadeonProRender64.dylib".ptr];
        else /* posix */       static immutable const(char)*[] candidates = ["libRadeonProRender64.so".ptr];

        RPRSupport last = RPRSupport.noLibrary;
        foreach (name; candidates) {
            last = loadRPR(name);
            if (last == RPRSupport.loaded) return last;
        }
        return last;
    }

    /// Loads the RPR shared library from an explicit path / SONAME and binds
    /// every symbol declared in bindbc.rpr.bind.core. Missing symbols are
    /// accumulated via bindbc-loader's error log — inspect with `errors()`.
    RPRSupport loadRPR(const(char)* libName) nothrow @nogc {
        lib = bindbc.loader.load(libName);
        if (lib == invalidHandle) return RPRSupport.noLibrary;

        const errBefore = errorCount();
        bindbc.rpr.bind.core.bindModuleSymbols(lib);
        if (errorCount() != errBefore) return RPRSupport.badLibrary;
        return RPRSupport.loaded;
    }
}
