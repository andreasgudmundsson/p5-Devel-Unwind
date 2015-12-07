#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "unwind_debug.h"

static XOP label_xop;
static XOP unwind_xop;
static int (*next_keyword_plugin)(pTHX_ char *, STRLEN, OP **);

static int find_labeled_eval(pTHX_ const PERL_SI *, char *);

static OP* label_pp(pTHX)
{
    dSP;

    DEBUG_printf("label_pp\n");
    deb_stack();
    deb_cx();

    RETURN;
}

static OP* detour_pp(pTHX)
{
    dVAR;
    char *label = cPVOPx(PL_op)->op_pv;;
    DEBUG_printf("_detour_pp: label(%s)\n", label);
    if (!PL_in_eval) {
        croak("You must be in an 'eval' to detour execution.");
    }
    {
        const PERL_SI *si;
        I32  label_cxix;

        for (si = PL_curstackinfo; si; si = si->si_prev) {
            if ((label_cxix = find_labeled_eval(aTHX_ si, label)) >= 0)
                break;
        }
        if (label_cxix < 0)
            croak("Can not setup a detour: label '%s' not found.", label );


        POPSTACK_TO(si->si_stack);
        dounwind(label_cxix);
        {
            /* hack for one test */
            PL_top_env = PL_top_env->je_prev;
        }

        /* Hit correct run-loop. Possibly by storing not only the
           RETOP on the stack but also the JMPENV index.
         */
    }
    die("death");
    return NULL; /* not reached */
}

static int
find_labeled_eval(pTHX_ const PERL_SI *stackinfo, char *label)
{
    I32 i;
    DEBUG_printf("find label '%s' on stack '%s'\n",
                 label, si_names[stackinfo->si_type+1]);
    for (i=stackinfo->si_cxix; i >= 0; i--) {
        PERL_CONTEXT *cx = &(stackinfo->si_cxstack[i]);
        OP  *retop = cx->blk_eval.retop;
        if (CxTYPE(cx) == CXt_EVAL && retop && retop->op_ppaddr == label_pp) {
            assert(cPVOPx(retop)->op_pv);
            if (!strcmp(label,cPVOPx(retop)->op_pv)) {
                DEBUG_printf("\tLABEL '%s' FOUND at '%d'\n", label, i);
                return i;
            }
        }
    }
    DEBUG_printf("\tLABEL '%s' NOT FOUND\n",label);
    return -1;
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
        OP   *eval_block;
        OP   *label_op;

        /*
          Transform
             mark LABEL: BLOCK
          to
            eval BLOCK; PVOP(erase_pp, LABEL)
          think of it as
            LABEL: eval BLOCK
          and we label the eval by making sure a labeled PVOP
          is the retop of the eval block.
         */

        label = _parse_label(aTHX);
        eval_block =  create_eval(aTHX_
                                  _parse_block(aTHX));

        label_op = newPVOP(OP_CUSTOM, 0, label);
        label_op->op_ppaddr = label_pp;

        DEBUG_printf("eval(%p)->erase(%p)\n", eval_block, label_op);
        *op_ptr = newLISTOP(OP_LIST, 0, NULL, NULL);
        op_append_elem(OP_LIST, *op_ptr, eval_block);
        op_append_elem(OP_LIST, *op_ptr, label_op);

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

PROTOTYPES: DISABLE

BOOT:
    XopENTRY_set(&label_xop, xop_name,  "label_xop");
    XopENTRY_set(&label_xop, xop_desc,  "label the mark");
    XopENTRY_set(&label_xop, xop_class, OA_UNOP);
    Perl_custom_op_register(aTHX_ label_pp, &label_xop);

    XopENTRY_set(&unwind_xop, xop_name,  "unwind");
    XopENTRY_set(&unwind_xop, xop_desc,  "unwind the stack to the mark");
    XopENTRY_set(&unwind_xop, xop_class, OA_PVOP_OR_SVOP);
    Perl_custom_op_register(aTHX_ detour_pp, &unwind_xop);

    next_keyword_plugin =  PL_keyword_plugin;
    PL_keyword_plugin   = mark_keyword_plugin;
