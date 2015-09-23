/*

This second attempt at unwinding is based on the idea that unwinding
between stacks (MAIN,SIGNAL,REQUIRE,...)  is hard and *I* don't know
how to do it but Perl does.

So the plan is to just patch the retop of the current EVAL context
to return to the relevant unwindOP(LABEL), the unwindOP(LABEL)
than fixes up the context and resumes execution

main program  : markOP(FOO:) BLOCK unwindOP(FOO:)
signal handler: detour(FOO:)

unwindOP unwinds the current stack until it finds the mark

 */
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

static void _deb_stack(pTHX);
static void _deb_env(pTHX);
static void _deb_cx(pTHX);
static void _cx_dump(pTHX_ PERL_CONTEXT *cx);

#undef cx_dump
#define cx_dump(x) _cx_dump(aTHX_ x)
#define deb_cx(x) _deb_cx(aTHX_ x)
#define deb_stack() _deb_stack(aTHX)
#define deb_env() _deb_env(aTHX)

#ifdef UNWIND_DEBUG
#define DEBUG_printf(...) PerlIO_printf(PerlIO_stderr(), ##__VA_ARGS__)
#else
#define DEBUG_printf(...)
#endif

static XOP mark_xop;
static XOP erase_xop;
static XOP unwind_xop;
static int (*next_keyword_plugin)(pTHX_ char *, STRLEN, OP **);

static int _find_mark(pTHX_ const PERL_SI *, char *, OP **, I32 *);
static int _find_eval(pTHX_ const PERL_SI *, I32 *);

static char *BREADCRUMB = "666 number of the beast";


static const char * const si_names[] =
{
    "UNKNOWN","UNDEF","MAIN","MAGIC",
    "SORT","SIGNAL","OVERLOAD","DESTROY",
    "WARNHOOK","DIEHOOK","REQUIRE"
};

static OP *_mark_pp(pTHX)
{
    dVAR; dSP;
    DEBUG_printf("label(%s): cur(%p)->sibling(%p)->sibling(%p)-> next(%p)\n",
                 cPVOPx(PL_op)->op_pv,
                 PL_op,
                 PL_op->op_sibling,
                 PL_op->op_sibling->op_sibling,
                 PL_op->op_sibling->op_sibling->op_next);

    char *label = cPVOPx(PL_op)->op_pv;
    OP   *retop = PL_op->op_sibling->op_sibling;

    /*
      I probably need the push jumpenv magic
      from call_sv
     */

    XPUSHs((SV*)BREADCRUMB);
    XPUSHs((SV*)label);
    XPUSHs((SV*)retop);

    RETURN;
}

static OP* _erase_pp(pTHX)
{
    dSP;
    char *mark = cPVOPx(PL_op)->op_pv;

    DEBUG_printf("_erase_pp\n");

    DEBUG_printf("_erase_pp: unwinding stack to mark='%s' retop='%p'\n", mark, PL_op);
    deb_stack();
    deb_cx();
    {
        OP  *mark_retop;
        I32  mark_cxix;
        if (!_find_mark(aTHX_ PL_curstackinfo, mark, &mark_retop, &mark_cxix)) {
            croak("PANIC: _erase_pp - mark '%s' not found.", mark);
        }
        dounwind(mark_cxix);

    {
        SV   *what;
        char *m;
        char *b;
        OP   *r;

        what = POPs;
        r = (OP *)POPs; // retop
        m = (char *)POPs; // label
        b = (char *)POPs; // BREADCRUMB
        DEBUG_printf("_erase_pp: what=='%p' retop='%p', mark='%s' breadcrumb='%s'\n",
                     what, r, m, b);
    }

        DEBUG_printf("_erase_pp: after unwinding:\n");
        deb_stack();
        deb_cx();
    }

    RETURN;
}

static OP* _detour_pp(pTHX)
{
    dVAR;
    dSP;
    {
        char *mark;
        mark = cPVOPx(PL_op)->op_pv;
        DEBUG_printf("_detour_pp: mark(%s)\n", mark);
        if (!PL_in_eval) {
            croak("You must be in an 'eval' to detour execution.");
        }
        deb_stack();
        {
            OP *mark_retop = NULL;
            const PERL_SI *si;
            I32  mark_cxix;
            I32  eval_cxix;

            for (si = PL_curstackinfo; si; si = si->si_prev) {
                if (_find_mark(aTHX_ si, mark, &mark_retop, &mark_cxix)) break;
            }

            if (!mark_retop) {
                croak("Can not setup a detour: mark '%s' not found.", mark );
            } else {
                DEBUG_printf("Mark%s on the current stack\n",
                             si == PL_curstackinfo ? "" : " not");
                if (!_find_eval(si, &eval_cxix)) {
                    DEBUG_printf("Didn't find an 'EVAL' context. WTF?");
                } else {
                    DEBUG_printf("patching with mark_retop\n");
                    si->si_cxstack[eval_cxix].blk_eval.retop = mark_retop;
                }
            }
        }
    }
    RETURN;
}

static int _find_eval(pTHX_
                      const PERL_SI *stackinfo,
                      I32 *outIx)
{
    dVAR;
    I32 i;
    for (i = stackinfo->si_cxix; i >= 0; i--) {
	PERL_CONTEXT *cx = &(stackinfo->si_cxstack[i]);
	switch (CxTYPE(cx)) {
	default:
	    continue;
	case CXt_EVAL:
	    DEBUG_printf("(dopoptoeval(): found eval at cx=%ld)\n", (long)i);
            *outIx = i;
	    return 1;
	}
    }
    return 0;
}

static int
_find_mark(pTHX_ const PERL_SI *stackinfo, char *tomark,
           OP **outRetop, I32 *outIx)
{
    I32 i;
    DEBUG_printf("find mark '%s' on stack '%s'\n", tomark, si_names[stackinfo->si_type+1]);
    DEBUG_printf("\tStack Mark Scope\n");
    for (i=stackinfo->si_cxix; i >= 0; i--) {
        PERL_CONTEXT *cx         = &(stackinfo->si_cxstack[i]);
        SV          **stack_base = AvARRAY(stackinfo->si_stack);
        char         *breadcrumb = (char *)*(stack_base + cx->blk_oldsp+1);
        /*
          I don't completely understand why the breadcrumb is not at
          stack_base + cx->blk_oldsp.

          I could have created my own CXt_MARK that stores the old
          stack pointers and the retop. But that's outside the scope
          of XS.
        */

        DEBUG_printf("\t%d%s    %d%s     %d%s\n",
                     cx->blk_oldsp, ((char *)(*(stack_base + cx->blk_oldsp+1)) == BREADCRUMB ? "X" : ""),
                     cx->blk_oldmarksp, ((char *)(*(stack_base + cx->blk_oldmarksp)) == BREADCRUMB ? "X" : ""),
                     cx->blk_oldscopesp, ((char *)(*(stack_base + cx->blk_oldscopesp)) == BREADCRUMB ? "X" : ""));

        if ( breadcrumb == BREADCRUMB) {
            char *mark	= (char *)*(stack_base + cx->blk_oldsp+2);
            OP   *retop	=   (OP *)*(stack_base + cx->blk_oldsp+3);
            DEBUG_printf("\tretop=%p mark=%s\n", retop, tomark);
            if (0 == strcmp(mark,tomark)) {
                DEBUG_printf("\tMARK '%s' FOUND RETOP='%p'\n", tomark, retop);
                *outRetop = retop;
                *outIx    = i;
                return 1;
            }
        }
    }
    DEBUG_printf("\tMARK '%s' NOT FOUND\n",tomark);
    return 0;
}

static OP *_parse_block(pTHX)
{
    OP *o = parse_block(0);
    if (!o) {
        o = newOP(OP_STUB, 0);
    }
    if (PL_hints & HINT_BLOCK_SCOPE) {
        o->op_flags |= OPf_PARENS;
    }
    return op_scope(o);
}

static char *_parse_label(pTHX) {
    I32 error_count = PL_parser->error_count;
    SV *label       = parse_label(0);

    if (error_count < PL_parser->error_count)
        croak("Invalid label for 'mark' at %s.\n", OutCopFILE(PL_curcop));
    else
        DEBUG_printf("Valid label: %s\n", SvPV_nolen(label));

    char *p = savesharedsvpv(label);
    SvREFCNT_dec(label);
    return p;
}

/*
 * mark LABEL BLOCK
 */
static int
mark_keyword_plugin(pTHX_
                  char *keyword_ptr,
                  STRLEN keyword_len,
                  OP **op_ptr)
{
    if (keyword_len == 4 && strnEQ(keyword_ptr, "mark", 4))  {
        char *label;
        OP   *mark;
        OP   *block;
        OP   *erase;

        label = _parse_label(aTHX);
        block = _parse_block(aTHX);

        mark = newPVOP(OP_CUSTOM, 0, label);
        mark->op_ppaddr = _mark_pp;

        erase = newPVOP(OP_CUSTOM, 0, label);
        erase->op_ppaddr = _erase_pp;


        mark->op_sibling = block;
        block->op_sibling = erase;
        erase->op_sibling = NULL;

        DEBUG_printf("mark(%p)->block(%p)->erase(%p)\n", mark, block, erase);

        *op_ptr = newLISTOP(OP_NULL, 0, mark, erase->op_sibling);

        return KEYWORD_PLUGIN_STMT;
    }
    else if (keyword_len == 6 && strnEQ(keyword_ptr, "unwind", 6)) {
        char *label;
        OP   *detour;

        label  = _parse_label(aTHX);
        detour = newPVOP(OP_CUSTOM, 0, label);
        detour->op_ppaddr = _detour_pp;

        *op_ptr = detour;

        return KEYWORD_PLUGIN_STMT;
    }
    else {
        return next_keyword_plugin(aTHX_ keyword_ptr, keyword_len, op_ptr);
    }
}

static void _deb_env(pTHX) {
#ifdef UNWIND_DEBUG
    const JMPENV *env = PL_top_env;
    const JMPENV *eit;
    I32 eix;
    I32 eix_max;

    for (eix_max= -1, eit=env; eit; eit=eit->je_prev, eix_max++);
    warn("env: eix_max=%d\n",eix_max);
    for (eix=0, eit=env; eit; eit=eit->je_prev,eix++) {
        warn("\tlevel=%d je_ret=%d je_mustcatch=%d\n",
             eix_max - eix,
             eit->je_ret,
             eit->je_mustcatch
            );
    }
#else
    PERL_UNUSED_CONTEXT;
#endif
}

static void _deb_stack(pTHX) {
#ifdef UNWIND_DEBUG
  const PERL_SI *si = PL_curstackinfo;
  I32 siix;
  while (si->si_prev) {
    si = si->si_prev;
  }
  for (siix = 0; si; si = si->si_next, siix++) {
    I32 cxix;
    warn("stack %d type %s(%d) %p\n",
         siix, si_names[si->si_type + 1], si->si_type, si);
    for (cxix = 0; cxix <= si->si_cxix; cxix++) {
      const PERL_CONTEXT* const cx = &(si->si_cxstack[cxix]);
      warn("\tcxix %d type %s(%d)\n",
           cxix, PL_block_type[CxTYPE(cx)], CxTYPE(cx));
    }
    if (si == PL_curstackinfo) {
      break;
    }
  }
#else
  PERL_UNUSED_CONTEXT;
#endif
}

static void _deb_cx(pTHX)
{
#ifdef UNWIND_DEBUG
    dVAR;
    I32 i;
    for (i = PL_curstackinfo->si_cxix; i >= 0; i--) {
        cx_dump(&PL_curstackinfo->si_cxstack[i]);
    }
#endif
}

void _cx_dump(pTHX_ PERL_CONTEXT *cx)
{
    dVAR;

    PERL_ARGS_ASSERT_CX_DUMP;

#ifdef UNWIND_DEBUG
    PerlIO_printf(Perl_debug_log, "CX %ld = %s\n", (long)(cx - cxstack), PL_block_type[CxTYPE(cx)]);
    if (CxTYPE(cx) != CXt_SUBST) {
	PerlIO_printf(Perl_debug_log, "BLK_OLDSP = %ld\n", (long)cx->blk_oldsp);
	PerlIO_printf(Perl_debug_log, "BLK_OLDCOP = 0x%"UVxf"\n",
		      PTR2UV(cx->blk_oldcop));
	PerlIO_printf(Perl_debug_log, "BLK_OLDMARKSP = %ld\n", (long)cx->blk_oldmarksp);
	PerlIO_printf(Perl_debug_log, "BLK_OLDSCOPESP = %ld\n", (long)cx->blk_oldscopesp);
	PerlIO_printf(Perl_debug_log, "BLK_OLDPM = 0x%"UVxf"\n",
		      PTR2UV(cx->blk_oldpm));
	PerlIO_printf(Perl_debug_log, "BLK_GIMME = %s\n", cx->blk_gimme ? "LIST" : "SCALAR");
    }
    switch (CxTYPE(cx)) {
    case CXt_NULL:
    case CXt_BLOCK:
	break;
    case CXt_FORMAT:
	PerlIO_printf(Perl_debug_log, "BLK_FORMAT.CV = 0x%"UVxf"\n",
		PTR2UV(cx->blk_format.cv));
	PerlIO_printf(Perl_debug_log, "BLK_FORMAT.GV = 0x%"UVxf"\n",
		PTR2UV(cx->blk_format.gv));
	PerlIO_printf(Perl_debug_log, "BLK_FORMAT.DFOUTGV = 0x%"UVxf"\n",
		PTR2UV(cx->blk_format.dfoutgv));
	PerlIO_printf(Perl_debug_log, "BLK_FORMAT.HASARGS = %d\n",
		      (int)CxHASARGS(cx));
	PerlIO_printf(Perl_debug_log, "BLK_FORMAT.RETOP = 0x%"UVxf"\n",
		PTR2UV(cx->blk_format.retop));
	break;
    case CXt_SUB:
	PerlIO_printf(Perl_debug_log, "BLK_SUB.CV = 0x%"UVxf"\n",
		PTR2UV(cx->blk_sub.cv));
	PerlIO_printf(Perl_debug_log, "BLK_SUB.OLDDEPTH = %ld\n",
		(long)cx->blk_sub.olddepth);
	PerlIO_printf(Perl_debug_log, "BLK_SUB.HASARGS = %d\n",
		(int)CxHASARGS(cx));
	PerlIO_printf(Perl_debug_log, "BLK_SUB.LVAL = %d\n", (int)CxLVAL(cx));
	PerlIO_printf(Perl_debug_log, "BLK_SUB.RETOP = 0x%"UVxf"\n",
		PTR2UV(cx->blk_sub.retop));
	break;
    case CXt_EVAL:
	PerlIO_printf(Perl_debug_log, "BLK_EVAL.OLD_IN_EVAL = %ld\n",
		(long)CxOLD_IN_EVAL(cx));
	PerlIO_printf(Perl_debug_log, "BLK_EVAL.OLD_OP_TYPE = %s (%s)\n",
		PL_op_name[CxOLD_OP_TYPE(cx)],
		PL_op_desc[CxOLD_OP_TYPE(cx)]);
	if (cx->blk_eval.old_namesv)
	    PerlIO_printf(Perl_debug_log, "BLK_EVAL.OLD_NAME = %s\n",
			  SvPVX_const(cx->blk_eval.old_namesv));
	PerlIO_printf(Perl_debug_log, "BLK_EVAL.OLD_EVAL_ROOT = 0x%"UVxf"\n",
		PTR2UV(cx->blk_eval.old_eval_root));
	PerlIO_printf(Perl_debug_log, "BLK_EVAL.RETOP = 0x%"UVxf"\n",
		PTR2UV(cx->blk_eval.retop));
	break;

    case CXt_LOOP_LAZYIV:
    case CXt_LOOP_LAZYSV:
    case CXt_LOOP_FOR:
    case CXt_LOOP_PLAIN:
	PerlIO_printf(Perl_debug_log, "BLK_LOOP.LABEL = %s\n", CxLABEL(cx));
	PerlIO_printf(Perl_debug_log, "BLK_LOOP.RESETSP = %ld\n",
		(long)cx->blk_loop.resetsp);
	PerlIO_printf(Perl_debug_log, "BLK_LOOP.MY_OP = 0x%"UVxf"\n",
		PTR2UV(cx->blk_loop.my_op));
	/* XXX: not accurate for LAZYSV/IV */
	PerlIO_printf(Perl_debug_log, "BLK_LOOP.ITERARY = 0x%"UVxf"\n",
		PTR2UV(cx->blk_loop.state_u.ary.ary));
	PerlIO_printf(Perl_debug_log, "BLK_LOOP.ITERIX = %ld\n",
		(long)cx->blk_loop.state_u.ary.ix);
	PerlIO_printf(Perl_debug_log, "BLK_LOOP.ITERVAR = 0x%"UVxf"\n",
		PTR2UV(CxITERVAR(cx)));
	break;

    case CXt_SUBST:
	PerlIO_printf(Perl_debug_log, "SB_ITERS = %ld\n",
		(long)cx->sb_iters);
	PerlIO_printf(Perl_debug_log, "SB_MAXITERS = %ld\n",
		(long)cx->sb_maxiters);
	PerlIO_printf(Perl_debug_log, "SB_RFLAGS = %ld\n",
		(long)cx->sb_rflags);
	PerlIO_printf(Perl_debug_log, "SB_ONCE = %ld\n",
		(long)CxONCE(cx));
	PerlIO_printf(Perl_debug_log, "SB_ORIG = %s\n",
		cx->sb_orig);
	PerlIO_printf(Perl_debug_log, "SB_DSTR = 0x%"UVxf"\n",
		PTR2UV(cx->sb_dstr));
	PerlIO_printf(Perl_debug_log, "SB_TARG = 0x%"UVxf"\n",
		PTR2UV(cx->sb_targ));
	PerlIO_printf(Perl_debug_log, "SB_S = 0x%"UVxf"\n",
		PTR2UV(cx->sb_s));
	PerlIO_printf(Perl_debug_log, "SB_M = 0x%"UVxf"\n",
		PTR2UV(cx->sb_m));
	PerlIO_printf(Perl_debug_log, "SB_STREND = 0x%"UVxf"\n",
		PTR2UV(cx->sb_strend));
	PerlIO_printf(Perl_debug_log, "SB_RXRES = 0x%"UVxf"\n",
		PTR2UV(cx->sb_rxres));
	break;
    }
#else
    PERL_UNUSED_CONTEXT;
    PERL_UNUSED_ARG(cx);
#endif	/* DEBUGGING */
}


MODULE = Stack::Unwind PACKAGE = Stack::Unwind

BOOT:
    XopENTRY_set(&mark_xop, xop_name,  "mark_xop");
    XopENTRY_set(&mark_xop, xop_desc,  "mark the stack for unwinding");
    XopENTRY_set(&mark_xop, xop_class, OA_PVOP_OR_SVOP);
    Perl_custom_op_register(aTHX_ _mark_pp, &mark_xop);

    XopENTRY_set(&erase_xop, xop_name,  "erase_xop");
    XopENTRY_set(&erase_xop, xop_desc,  "erase the mark");
    XopENTRY_set(&erase_xop, xop_class, OA_UNOP);
    Perl_custom_op_register(aTHX_ _erase_pp, &erase_xop);

    XopENTRY_set(&unwind_xop, xop_name,  "unwind");
    XopENTRY_set(&unwind_xop, xop_desc,  "unwind the stack to the mark");
    XopENTRY_set(&unwind_xop, xop_class, OA_PVOP_OR_SVOP);
    Perl_custom_op_register(aTHX_ _detour_pp, &unwind_xop);

    next_keyword_plugin =  PL_keyword_plugin;
    PL_keyword_plugin   = mark_keyword_plugin;


void unwind_old(char *s)
    CODE:
     _unwind(aTHX_ s);
