#define PERL_NO_GET_CONTEXT

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

typedef struct {
    SV* required_file;
    SV* previous_hook;
} die_hook_args;

static SV*  before_hooks    = NULL;
static SV*  after_hooks     = NULL;
static SV*  die_hooks       = NULL;
static bool hooking_enabled = FALSE;
static OP* (*old_pp_require)(pTHX) = NULL;

/* after hooks: */
static void
S_invoke_after_hooks(pTHX_ SV *file_required)
{
    AV *after_hooks_av = MUTABLE_AV(SvRV(after_hooks));
    IV num_hooks        = av_len(after_hooks_av) + 1;
    IV i                = 0;
    SV *file_to_require = NULL;

    for ( i = 0; i < num_hooks; i++ ) {
        SV* callback = (SV*)*av_fetch(after_hooks_av, i, 0);
        dSP;
        ENTER_with_name("Devel::HookRequire::after_hooks");
        SAVETMPS;

        PUSHMARK(SP);
        XPUSHs(sv_2mortal(newSVsv(file_required)));
        PUTBACK;

        int count = call_sv(callback, G_DISCARD|G_VOID);
        SPAGAIN;
        if ( count != 0 ) {
            warn("Devel::HookRequire: 'after' callback returned a value, will ignore");
        }
        PUTBACK;
        FREETMPS;
        LEAVE_with_name("Devel::HookRequire::after_hooks");
    }

    // Only you can pretend memory leaks:
    SvREFCNT_dec(file_required);
    return;
}

void
S_prepare_after_hooks(pTHX_ SV* initial_file)
#define prepare_after_hooks(sv)     (void)S_prepare_after_hooks(aTHX_ sv)
{
    MAGIC *mg;
    SV *magic_sv;
    IV num_hooks        = av_len(MUTABLE_AV(SvRV(after_hooks))) + 1;

    if ( num_hooks <= 0 )
        return; /* No hooks, nothing to do */

    /* This function will be called at the end of this scope: */
    SAVEDESTRUCTOR_X(S_invoke_after_hooks, newSVsv(initial_file));
}

/* before hooks: */
SV*
S_invoke_before_hook_callback(pTHX_ SV* callback, SV* file_to_require, SV* orig_file)
#define invoke_before_hook_callback(c, new, old)    S_invoke_before_hook_callback(aTHX_ c, new, old)
{
    dSP;
    ENTER;
    SAVETMPS;

    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newSVsv(file_to_require)));
    XPUSHs(sv_2mortal(newSVsv(orig_file)));
    PUTBACK;

    int count = call_sv(callback, G_SCALAR);
    SPAGAIN;
    if ( count != 0 ) {
        SV *new_require_target = TOPs;
        sv_setsv(file_to_require, new_require_target);
        /* TODO: check if the return value is the number 1, or undef */
    }
    PUTBACK;
    FREETMPS;
    LEAVE;

    return file_to_require;
}

SV*
S_invoke_before_hooks(pTHX_ SV* initial_file)
#define invoke_before_hooks(sv)     S_invoke_before_hooks(aTHX_ sv)
{
    AV *before_hooks_av = MUTABLE_AV(SvRV(before_hooks));
    IV num_hooks        = av_len(before_hooks_av) + 1;
    IV i                = 0;
    SV *file_to_require = NULL;

    if ( num_hooks <= 0 )
        return initial_file;

    file_to_require = sv_2mortal(newSVsv(initial_file));

    for ( i = 0; i < num_hooks; i++ ) {
        SV* callback = (SV*)*av_fetch(before_hooks_av, i, 0);
        file_to_require = invoke_before_hook_callback(callback, file_to_require, initial_file);
    }

    return file_to_require;
}

/* die hooks: */

SV*
S_invoke_die_hooks(pTHX_ SV* required_file, SV *original_exception)
#define invoke_die_hooks(f, e)     S_invoke_die_hooks(aTHX_ f, e)
{
    AV *die_hooks_av = MUTABLE_AV(SvRV(die_hooks));
    IV num_hooks     = av_len(die_hooks_av) + 1;
    IV i             = 0;
    SV *final_exception;

    if ( num_hooks <= 0 )
        return original_exception;

    final_exception = sv_2mortal(newSVsv(original_exception));

    for ( i = 0; i < num_hooks; i++ ) {
        SV* callback = (SV*)*av_fetch(die_hooks_av, i, 0);
        dSP;
        ENTER;
        SAVETMPS;

        PUSHMARK(SP);
        XPUSHs(sv_2mortal(newSVsv(required_file)));
        XPUSHs(final_exception);
        PUTBACK;

        int count = call_sv(callback, G_SCALAR);
        SPAGAIN;
        if ( count != 0 ) {
            SV *new_exception = TOPs;
            if ( !SvOK(new_exception) ) {
                sv_setsv(final_exception, original_exception);
            }
            else {
                sv_setsv(final_exception, new_exception);
            }
        }
        PUTBACK;
        FREETMPS;
        LEAVE;
    }

    return final_exception;
}

/* The following creates an XSUB that we are not exposing to the world.
 * It implements a __DIE__ hook.
 * It expects its any_ptr slot to point toa die_hook_args structure that
 * holds the filename being required, and possibly the previous __DIE__
 * hook; so this is really a closure in XS
 */
XS(__DIE__callback) {
    dVAR;
    dXSARGS;
    dORIGMARK;

    /* Grab our closed-over arguements: */
    die_hook_args *args = (die_hook_args *)(CvXSUBANY(cv).any_ptr);
    SV *orig_exception  = TOPs;
    SV *final_exception = NULL;
    SV *required_file   = args->required_file;
    SV *previous_hook   = args->previous_hook;

    if ( !CvDEPTH(cv) ) {
        // Prevent infinite recursion -- for normal subs, pp_entersub increases
        // CvDEPTH.  For XSUBS, that doesn't happen.
        // Perl uses CvDEPTH to decide if it should try invoking a __DIE__
        // handler more than once.
        SAVEI32(CvDEPTHunsafe(cv)); // at the end of this scope, return to no depth
        CvDEPTH(cv)++; // increment the depth
    }

    final_exception = invoke_die_hooks(required_file, orig_exception);
    if ( !SvOK(final_exception) ) {
        final_exception = orig_exception;
    }

    if ( previous_hook ) {
        dSP;
        ENTER;
        SAVETMPS;

        PUSHMARK(SP);
        XPUSHs(orig_exception);
        PUTBACK;

        // note that previous_hook can be any kind of reference;
        // could be a scalarref with &{} overloading, for all we know.
        (void)call_sv(previous_hook, G_DISCARD|G_VOID);
        FREETMPS;
        LEAVE;
    }

    die_sv(final_exception);
    XSRETURN(1);
}

void
S_prepare_die_hooks(pTHX_ SV* required_file)
#define prepare_die_hooks(sv)   STMT_START {                \
    AV *die_hooks_av = MUTABLE_AV(SvRV(die_hooks));         \
    IV num_hooks     = av_len(die_hooks_av) + 1;            \
    if ( num_hooks > 0 )                                    \
        S_prepare_die_hooks(aTHX_ sv);                      \
} STMT_END
{
    /* Fun stuff part two!
     * When hooking die() during requires, we hook $SIG{__DIE__};
     * when we hit a death, that calls our hook.
     * So below we are defining an xsub that we stuff in sigdie here:
     */

    HV *stash           = gv_stashpv("Devel::HookRequire::die_hook", TRUE);
    CV *xs_closure_cv   = newXS(0, __DIE__callback, __FILE__);
    SV *xs_closure_rv   = newRV_noinc(MUTABLE_SV(xs_closure_cv));
    die_hook_args *args = NULL;

    New(0, args, 1, die_hook_args);

    args->required_file = newSVsv(required_file);
    args->previous_hook = NULL;

    if ( PL_diehook ) {
        if ( SvROK(PL_diehook) ) {
            args->previous_hook = newRV(SvRV(PL_diehook));
        }
        else {
            warn("Devel::HookRequire: $SIG{__DIE__} is set to '%"SVf"', type '%s', will pretend that did not exist", PL_diehook, sv_reftype(PL_diehook, 0));
        }
    }

    CvXSUBANY(xs_closure_cv).any_ptr = args;
    sv_bless(xs_closure_rv, stash);

    SAVEGENERICSV(PL_diehook);
    PL_diehook = xs_closure_rv;
}

/* Invoking all the hooks inside require(): */
void
S_handle_require_hook(pTHX)
#define handle_require_hook()   S_handle_require_hook(aTHX)
{
    dSP;
    SV* require = POPs;

    prepare_after_hooks(require);
    SV* new_require = invoke_before_hooks(require);

    prepare_die_hooks(new_require);

    PUSHs(new_require);
    PUTBACK;
}

/* Our OP_REQUIRE override: */
static OP*
S_pp_hooked_require(pTHX)
{
    OP *next = NULL;
    if ( !hooking_enabled )
        return CALL_FPTR(old_pp_require)(aTHX);

    {
        /* TODO: this segfaults and/or causes things to not compile -- once this is fixed
         * this module is more or less finished
         */
        /* We need a scope, since after hooks want to run 'after require, before the next statement',
         * and exception hooks need to localize $SIG{__DIE__}.
         * Consider:
         *      require foo, say "bar";
         * The 'after' hook MUST fire before 'say "bar"', which means that
         * internally the code above must be invoked as
         *      do { require foo }, say "bar"
         */
        ENTER_with_name("Devel::HookRequire");
        handle_require_hook();
        next = CALL_FPTR(old_pp_require)(aTHX);
        /* TODO: segfault here: something has popped too many scopes??? */
        LEAVE_with_name("Devel::HookedRequire");
    }
    return next;
}

/* Support for the die hook.
 * We need to free the two variables we put inside xs_closure.
 * PL_diehook is itself magical, so we won't use
 * a vtable there and instead use a destructor, and we cannot use a C-level
 * function as the closure may be freed before we get to it.
 * */

MODULE = Devel::HookRequire::die_hook             PACKAGE = Devel::HookRequire::die_hook

void
DESTROY(SV* self)
CODE:
{
    int i;
    CV *xs_closure = (CV*)SvRV(self);
    die_hook_args *args = (die_hook_args *)(CvXSUBANY(xs_closure).any_ptr);
    if ( !args )
        return; // double delete, or manually invoked without an xsub

    SvREFCNT_dec(args->required_file);
    if ( args->previous_hook ) {
        SvREFCNT_dec(args->previous_hook);
    }

    Safefree(args);
    CvXSUBANY(xs_closure).any_ptr = NULL;
}


MODULE = Devel::HookRequire        PACKAGE = Devel::HookRequire

void
enable_hooking()
CODE:
{
    hooking_enabled = TRUE;
}

void
disable_hooking()
CODE:
{
    hooking_enabled = FALSE;
}

void
add_before_hook(CV* before_cv)
CODE:
{
    av_push(MUTABLE_AV(SvRV(before_hooks)), newRV(MUTABLE_SV(before_cv)));
}

void
add_after_hook(CV* after_cv)
CODE:
{
    av_push(MUTABLE_AV(SvRV(after_hooks)), newRV(MUTABLE_SV(after_cv)));
}

void
add_die_hook(CV* die_cv)
CODE:
{
    av_push(MUTABLE_AV(SvRV(die_hooks)), newRV(MUTABLE_SV(die_cv)));
}

BOOT:
{
    old_pp_require = PL_ppaddr[OP_REQUIRE];
    PL_ppaddr[OP_REQUIRE] = S_pp_hooked_require;

    before_hooks = newRV_noinc(MUTABLE_SV(newAV()));
    after_hooks  = newRV_noinc(MUTABLE_SV(newAV()));
    die_hooks    = newRV_noinc(MUTABLE_SV(newAV()));
}

