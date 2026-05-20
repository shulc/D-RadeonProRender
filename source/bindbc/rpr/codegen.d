/// Re-export of bindbc-common's binding codegen, parameterised for RPR.
///
/// `bind/core.d` (generated) does `mixin(joinFnBinds(...))`. Whether that
/// produces static `extern(C)` decls or dynamic function pointers + a
/// `bindModuleSymbols(lib)` loader is controlled by `staticBinding` from
/// `bindbc.rpr.config`.
module bindbc.rpr.codegen;

import bindbc.rpr.config: staticBinding;
import bindbc.common.codegen;

mixin(makeFnBindFns(staticBinding));
