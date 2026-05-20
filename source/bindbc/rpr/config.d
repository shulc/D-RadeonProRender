/// Compile-time configuration for D-RadeonProRender bindings.
///
/// Default is dynamic binding via bindbc-loader (runtime dlopen of
/// libRadeonProRender64.so / RadeonProRender64.dll). Add
/// `versions: ["BindRPR_Static"]` to dub.json to switch to direct
/// link-time binding against the import library instead.
module bindbc.rpr.config;

version(BindRPR_Static) enum staticBinding = true;
else                    enum staticBinding = false;
