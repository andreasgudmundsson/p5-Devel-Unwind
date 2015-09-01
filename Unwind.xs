#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#define UNWIND_DEBUG
#ifdef UNWIND_DEBUG
#define DEBUG_printf(...) PerlIO_printf(PerlIO_stderr(), ##__VA_ARGS__)
#else
#define DEBUG_printf(...)
#endif

static XOP mark_xop;
static XOP erase_xop;
static XOP unwind_xop;
static int (*next_keyword_plugin)(pTHX_ char *, STRLEN, OP **);

static char *BREADCRUMB = "666 number of the beast";

static OP *_mark_pp(pTHX)
{
    dSP;
    DEBUG_printf("label(%s): cur(%p)->sibling(%p)->sibling(%p)-> next(%p)\n",
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

static OP* _erase_pp(pTHX)
{
    dSP;
    DEBUG_printf("_erase_pp\n");
    POPs; // retop
    POPs; // label
    POPs; // BREADCRUMB

    RETURN;
}

static OP* _unwind_pp(pTHX)
{

    dSP;
    char *tolabel;
    tolabel = cPVOPx(PL_op)->op_pv;
    DEBUG_printf("_unwind_pp: label(%s)\n", tolabel);
    DEBUG_printf("unwinding:\n%d     %d     %d\n",
                 PL_stack_sp - PL_stack_base,
                 *PL_markstack_ptr,
                 PL_scopestack_ix
        );
//    POPSTACK_TO(PL_mainstack);
    {
        int i;
        DEBUG_printf("Stack Mark Scope\n");
        for (i=cxstack_ix; i >= 0; i--) {
            const PERL_CONTEXT *cx = &cxstack[i];
            DEBUG_printf("%d%s    %d%s     %d%s\n"
                         , cx->blk_oldsp
                         , ((char *)(*(PL_stack_base + cx->blk_oldsp+1)) == BREADCRUMB
                            ? "X" : "")
                         , cx->blk_oldmarksp
                         , ((char *)(*(PL_stack_base + cx->blk_oldmarksp)) == BREADCRUMB
                            ? "X" : "")
                         , cx->blk_oldscopesp
                         , ((char *)(*(PL_stack_base + cx->blk_oldscopesp)) == BREADCRUMB
                            ? "X" : "")
                );
            /*
              I have a feeling that looking at 1+cx->blk_oldsp is a
              sign I'm doing something wrong. At least I don't
              completely understand why the MARK is not at
              PL_stack_base + cx->blk_oldsp. I think its because I'm
              not pushing a new block on the context stack. I could
              have created my own CXt_MARK that stores the old stack
              pointers and the retop. But that's outside the scope of
              XS it seems.
            */
            {
                char *breadcrumb = (char *)*(PL_stack_base + cx->blk_oldsp+1);
                if ( breadcrumb == BREADCRUMB) {
                    char *label = (char *)*(PL_stack_base + cx->blk_oldsp+2);
                    OP   *retop =   (OP *)*(PL_stack_base + cx->blk_oldsp+3);
                    DEBUG_printf("retop=%p label=%s\n", retop, label);
                    if (0 == strcmp(label,tolabel)) {
                        DEBUG_printf("FOUND retop=%p label=%s\n", retop, label);
                        dounwind(i);
                        PL_op->op_next  = retop;
                        RETURN;
                    }
                }
            }
        }
    }


    RETURN;
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
    int error_count = PL_parser->error_count;
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

        erase = newOP(OP_CUSTOM, 0);
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
        OP   *unwind;

        label  = _parse_label(aTHX);
        unwind = newPVOP(OP_CUSTOM, 0, label);
        unwind->op_ppaddr = _unwind_pp;

        *op_ptr = unwind;

        return KEYWORD_PLUGIN_STMT;
    }
    else {
        return next_keyword_plugin(aTHX_ keyword_ptr, keyword_len, op_ptr);
    }
}

static void
_unwind(pTHX, char *tolabel)
{
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

    XopENTRY_set(&unwind_xop, xop_name,  "unwind_xop");
    XopENTRY_set(&unwind_xop, xop_desc,  "unwind the stack to the mark");
    XopENTRY_set(&unwind_xop, xop_class, OA_PVOP_OR_SVOP);
    Perl_custom_op_register(aTHX_ _unwind_pp, &unwind_xop);

    next_keyword_plugin =  PL_keyword_plugin;
    PL_keyword_plugin   = mark_keyword_plugin;


void unwind_old(char *s)
    CODE:
     _unwind(aTHX_ s);
