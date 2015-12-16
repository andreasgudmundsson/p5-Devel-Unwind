#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "unwind_debug.h"

static XOP label_xop;
static XOP unwind_xop;

static int (*next_keyword_plugin)(pTHX_ char *, STRLEN, OP **);
static int find_mark(pTHX_ const PERL_SI *, const char*);

STATIC SV *
my_with_queued_errors(pTHX_ SV *ex)
{
    if (PL_errors && SvCUR(PL_errors) && !SvROK(ex)) {
	sv_catsv(PL_errors, ex);
	ex = sv_mortalcopy(PL_errors);
	SvCUR_set(PL_errors, 0);
    }
    return ex;
}

static OP* label_pp(pTHX)
{
    dSP;
    DEBUG_printf("label_pp\n");
    RETURN;
}

static OP* detour_pp(pTHX)
{
    dVAR; dSP; dMARK;
    SV *exsv;
    const char *label;

    label = SvPVX(POPs);
    if (SP - MARK != 1) {
	exsv = newSVpvs_flags("",SVs_TEMP);
	do_join(exsv, &PL_sv_no, MARK, SP);
	SP = MARK + 1;
    } else {
        exsv = POPs;
    }

    if (!PL_in_eval) {
        croak("You must be in an 'eval' to detour execution.");
    }
    {
        const PERL_SI *si;
        I32  label_cxix;

        for (si = PL_curstackinfo; si; si = si->si_prev) {
            label_cxix = find_mark(aTHX_ si, label);
            if (label_cxix >= 0)
                break;
        }
        if (label_cxix < 0) {
            Perl_write_to_stderr(
                my_with_queued_errors(
                    mess("Can not setup a detour: label '%s' not found. Exiting..",
                         label)));
            Perl_my_failure_exit();
        }

        POPSTACK_TO(si->si_stack);
        dounwind(label_cxix);
        {
            JMPENV *eval_jmpenv = si->si_cxstack[label_cxix].blk_eval.cur_top_env;
            while (PL_top_env != eval_jmpenv) {
                dJMPENV;
                cur_env = *PL_top_env;
                PL_top_env = &cur_env; /* Hackishly silence assertion */
                JMPENV_POP;
            }
        }
    }

     /* die_unwind() is called directly to skip the $SIG{__DIE__} handler */
    Perl_die_unwind(exsv);
    assert(0); /* NOTREACHED */
}

static int
find_mark(pTHX_ const PERL_SI *stackinfo, const char *label)
{
    I32 i;
    DEBUG_printf("find label '%s' on stack '%s'\n",
                 label, si_names[stackinfo->si_type+1]);
    for (i=stackinfo->si_cxix; i >= 0; i--) {
        PERL_CONTEXT *cx = &(stackinfo->si_cxstack[i]);
        OP  *retop = cx->blk_eval.retop;
        if (CxTYPE(cx) == CXt_EVAL && retop && retop->op_ppaddr == label_pp) {
            assert(cPVOPx(retop)->op_pv);
            char *mark_label = cPVOPx(retop)->op_pv;
            if (!strcmp(label,mark_label)) {
                DEBUG_printf("\tLABEL '%s' FOUND at '%d'\n", label, i);
                return i;
            }
        }
    }
    DEBUG_printf("\tLABEL '%s' NOT FOUND\n", label);
    return -1;
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

static SV *_parse_label(pTHX) {
    I32 error_count = PL_parser->error_count;
    SV *label = parse_label(0);

    if (error_count < PL_parser->error_count)
        croak("Invalid label at %s.\n", OutCopFILE(PL_curcop));
    else
        DEBUG_printf("Valid label: %s\n", SvPV_nolen(label));

    return label;
}

static int
mark_keyword_plugin(pTHX_
                  char *keyword_ptr,
                  STRLEN keyword_len,
                  OP **op_ptr)
{
    if (keyword_len == 4 && strnEQ(keyword_ptr, "mark", 4))  {
        OP *eval_block;
        OP *label_op;
        char *label;
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
        {
            SV *l = _parse_label(aTHX);
            label = savesharedsvpv(l);
            SvREFCNT_dec(l);
        }

        eval_block = create_eval(aTHX_
                                 _parse_block(aTHX)),

        label_op = newPVOP(OP_CUSTOM, 0, label);
        label_op->op_ppaddr = label_pp;

        *op_ptr = op_append_elem(OP_LIST, eval_block, label_op);

        return KEYWORD_PLUGIN_EXPR;
    }
    else if (keyword_len == 6 && strnEQ(keyword_ptr, "unwind", 6)) {
        /*
          unwind LABEL [EXPRESSION];
         */
        SV *label;
        OP *expr;

        label = _parse_label(aTHX);
        expr  = parse_listexpr(aTHX_ PARSE_OPTIONAL);
        expr  = op_contextualize(expr, G_ARRAY);

        *op_ptr =  op_convert_list(OP_CUSTOM, 0,
                                   op_append_elem(OP_LIST,
                                                  expr,
                                                  newSVOP(OP_CONST, 0, label)));
        (*op_ptr)->op_ppaddr = detour_pp;

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
