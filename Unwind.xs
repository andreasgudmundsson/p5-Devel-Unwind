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

#include "unwind_debug.h"

static XOP mark_xop;
static XOP erase_xop;
static XOP unwind_xop;
static int (*next_keyword_plugin)(pTHX_ char *, STRLEN, OP **);

static int find_mark(pTHX_ const PERL_SI *, char *, OP **, I32 *);
static int find_eval(pTHX_ const PERL_SI *, I32 *, I32 *);

static char *BREADCRUMB = "666 number of the beast";

static OP *mark_pp(pTHX)
{
    dVAR; dSP;
    DEBUG_printf("mark_pp: label(%s): cur(%p)->sibling(%p)->sibling(%p)-> next(%p)\n",
                 cPVOPx(PL_op)->op_pv,
                 PL_op,
                 PL_op->op_sibling,
                 PL_op->op_sibling->op_sibling,
                 PL_op->op_sibling->op_sibling->op_next);

    char *label = cPVOPx(PL_op)->op_pv;
    OP   *retop = PL_op->op_sibling->op_sibling;

    XPUSHs((SV*)BREADCRUMB);
    XPUSHs((SV*)label);
    XPUSHs((SV*)retop);

    RETURN;
}

static OP* erase_pp(pTHX)
{
    dSP;
    char *mark = cPVOPx(PL_op)->op_pv;

    DEBUG_printf("erase_pp: unwinding stack to mark='%s' retop='%p'\n", mark, PL_op);
    deb_stack();
    deb_cx();
    {
        OP  *mark_retop;
        I32  mark_cxix;
        if (!find_mark(aTHX_ PL_curstackinfo, mark, &mark_retop, &mark_cxix)) {
            croak("PANIC: _erase_pp - mark '%s' not found.", mark);
        }
        dounwind(mark_cxix);

    {
        SV   *what;
        char *m;
        char *b;
        OP   *r;

        /*
          This seems like an extra POP,
          is it related to the fact that
          find_mark gets to the breadcrumb at
               (char *)*(stack_base + cx->blk_oldsp+1) ?
         */
        what = POPs;

        r = (OP *)POPs; // retop
        m = (char *)POPs; // label
        b = (char *)POPs; // BREADCRUMB
        DEBUG_printf("_erase_pp: what='%p(%s)', retop='%p' label='%s', breadcrumb='%s'\n",
                     what, (what==&PL_sv_undef ? "PL_sv_undef" : ""), r, m, b);
    }

        DEBUG_printf("_erase_pp: after unwinding:\n");
        deb_stack();
        deb_cx();
    }

    RETURN;
}

static OP* detour_pp(pTHX)
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
            I32  eval_cxix_first;
            I32  eval_cxix_second;

            for (si = PL_curstackinfo; si; si = si->si_prev) {
                if (find_mark(aTHX_ si, mark, &mark_retop, &mark_cxix)) break;
            }

            if (!mark_retop) {
                croak("Can not setup a detour: mark '%s' not found.", mark );
            } else {
                DEBUG_printf("Mark%s on the current stack\n",
                             si == PL_curstackinfo ? "" : " not");
                if (!find_eval(si, &eval_cxix_first, &eval_cxix_second)) {
                    DEBUG_printf("Didn't find an 'EVAL' context. WTF?");
                } else {
                    DEBUG_printf("patching with mark_retop\n");
                    si->si_cxstack[eval_cxix_first].blk_eval.retop  = mark_retop;
                    si->si_cxstack[eval_cxix_second].blk_eval.retop = mark_retop;
                }
            }
        }
    }
    /* Unwinding from an require i.e. from the toplevel of a required
     * file needs special handling.  If we rely on die() to initiate
     * the unwinding mechanism then we must counteract the special
     * REQUIRE handling done by die_unwind(), I suppose patching
     * 2-levels of eval context will do the trick. If I do that then
     * we can be lazy and transform
     *  mark LABEL: BLOCK -> mark' LABEL: eval{eval{ BLOCK }}
     *
     * or be smart and somehow figure out that we're in an require so
     * there must already be 2 eval contexts on the stack.
     */
    die("Unwinding from detour_pp. It leaks.");
}

static int find_eval(pTHX_
                     const PERL_SI *stackinfo,
                     I32 *outIx, I32 *outIx2)
{
    dVAR;
    I32 ix = 0;
    I32 i;
    for (i = stackinfo->si_cxix; i >= 0; i--) {
	PERL_CONTEXT *cx = &(stackinfo->si_cxstack[i]);
	switch (CxTYPE(cx)) {
	default:
	    continue;
	case CXt_EVAL:
	    DEBUG_printf("(find_eval(): found eval at cx=%ld)\n", (long)i);
            if (ix == 0) {
                *outIx = i;
            } else if (ix == 1) {
                *outIx2 = i;
            }
            if (ix == 1) {
                return 1;
            }
            ix++;
	}
    }
    return 0;
}

static int
find_mark(pTHX_ const PERL_SI *stackinfo, char *tomark,
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

static OP*
create_or_die(pTHX_ OP *block) {
    /*
      [andreasg@latti] ((v5.14.4)) ~/r/perl$ perl -MO=Terse -e 'eval {} or die'
        ...
        LOGOP (0xd1d298) or
            LISTOP (0xd1d328) leavetry
                LOGOP (0xd1d370) entertry
                OP (0xd1d3f8) stub
            LISTOP (0xd1d2e0) die [1]
                OP (0xd1d3b8) pushmark
     */

    return newLOGOP(OP_OR, 0, block,
                    newLISTOP(OP_DIE, 0,
                              newOP(OP_PUSHMARK, 0),
                              newSVOP(OP_CONST, 0, SvREFCNT_inc(ERRSV))));
}

static OP*
create_eval(pTHX_ OP *block) {
    OP    *o;
    LOGOP *enter;

    /*
      Shamelessly copied from Perl_ck_eval
     */

    NewOp(1101, enter, 1, LOGOP);
    enter->op_type = OP_ENTERTRY;
    enter->op_ppaddr = PL_ppaddr[OP_ENTERTRY];
    enter->op_private = 0;

    o = op_prepend_elem(OP_LINESEQ, (OP*)enter, (OP*)block);
    o->op_type = OP_LEAVETRY;
    o->op_ppaddr = PL_ppaddr[OP_LEAVETRY];
    enter->op_other = o;

    return o;
}

static OP *_parse_block(pTHX)
{
    OP *o = parse_block(0);
    if (!o) {
        o = newOP(OP_STUB, 0);
    }
    /*
     * Do I need to set any flags?
     */
    return o;
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
        OP   *eval_block;
        OP   *erase;

        /*
          Transform
             mark LABEL: BLOCK
          to
             mark' LABEL: { eval { eval BLOCK } }

          because the unwinding mechanism relies on patching the "next"
          eval context, or in the case of a request the second to next.
         */

        label      = _parse_label(aTHX);
        eval_block = create_or_die(aTHX_
                                   create_eval(aTHX_
                                               create_or_die(aTHX_
                                                             create_eval(aTHX_
                                                                         _parse_block(aTHX)
                                                                 ))));

        mark = newPVOP(OP_CUSTOM, 0, label);
        mark->op_ppaddr = mark_pp;

        DEBUG_printf("mark(%p)->eval(%p)->erase(%p)\n", mark, eval_block, erase);

        erase = newPVOP(OP_CUSTOM, 0, label);
        erase->op_ppaddr = erase_pp;

        mark->op_sibling = eval_block;
        eval_block->op_sibling = erase;
        erase->op_sibling = NULL;

        DEBUG_printf("mark(%p)->eval(%p)->erase(%p)\n", mark, eval_block, erase);

        *op_ptr = newLISTOP(OP_NULL, 0, mark, erase->op_sibling);

        return KEYWORD_PLUGIN_STMT;
    }
    else if (keyword_len == 6 && strnEQ(keyword_ptr, "unwind", 6)) {
        char *label;
        OP   *detour;

        label  = _parse_label(aTHX);
        detour = newPVOP(OP_CUSTOM, 0, label);
        detour->op_ppaddr = detour_pp;

        *op_ptr = detour;

        return KEYWORD_PLUGIN_STMT;
    }
    else {
        return next_keyword_plugin(aTHX_ keyword_ptr, keyword_len, op_ptr);
    }
}

MODULE = Stack::Unwind PACKAGE = Stack::Unwind

BOOT:
    XopENTRY_set(&mark_xop, xop_name,  "mark_xop");
    XopENTRY_set(&mark_xop, xop_desc,  "mark the stack for unwinding");
    XopENTRY_set(&mark_xop, xop_class, OA_PVOP_OR_SVOP);
    Perl_custom_op_register(aTHX_ mark_pp, &mark_xop);

    XopENTRY_set(&erase_xop, xop_name,  "erase_xop");
    XopENTRY_set(&erase_xop, xop_desc,  "erase the mark");
    XopENTRY_set(&erase_xop, xop_class, OA_UNOP);
    Perl_custom_op_register(aTHX_ erase_pp, &erase_xop);

    XopENTRY_set(&unwind_xop, xop_name,  "unwind");
    XopENTRY_set(&unwind_xop, xop_desc,  "unwind the stack to the mark");
    XopENTRY_set(&unwind_xop, xop_class, OA_PVOP_OR_SVOP);
    Perl_custom_op_register(aTHX_ detour_pp, &unwind_xop);

    next_keyword_plugin =  PL_keyword_plugin;
    PL_keyword_plugin   = mark_keyword_plugin;
