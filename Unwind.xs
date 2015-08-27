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
static OP  mark_pp(pTHX);
static int (*next_keyword_plugin)(pTHX_ char *, STRLEN, OP **);

static char *MARK = "666 number of the beast";

static OP* _mark_pp(pTHX)
{
    dSP;
    DEBUG_printf("cur(%p)->sibling(%p)->sibling(%p)-> next(%p)\n",
                 PL_op,
                 PL_op->op_sibling,
                 PL_op->op_sibling->op_sibling,
                 PL_op->op_sibling->op_sibling->op_next);
    XPUSHs((SV*)MARK);
    /*
      I store the address of the OP for  _erase_pp
      as the potentinal retop
     */
    XPUSHs((SV*)PL_op->op_sibling->op_sibling);
    RETURN;
}

static OP* _erase_pp(pTHX)
{
    dSP;
    DEBUG_printf("_erase_pp\n");
    POPs;
    POPs;
    RETURN;
}

static OP* _parse_mark(pTHX)
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

static int
mark_keyword_plugin(pTHX_
                  char *keyword_ptr,
                  STRLEN keyword_len,
                  OP **op_ptr)
{
    if (keyword_len == 4 && strnEQ(keyword_ptr, "mark", 4))  {
        OP *mark;
        OP *block;
        OP *erase;

        mark = newOP(OP_CUSTOM, 0);
        mark->op_ppaddr = _mark_pp;

        erase = newOP(OP_CUSTOM, 0);
        erase->op_ppaddr = _erase_pp;

        block = _parse_mark(aTHX);

        mark->op_sibling = block;
        block->op_sibling = erase;
        erase->op_sibling = NULL;

        DEBUG_printf("mark(%p)->block(%p)->erase(%p)\n", mark, block, erase);

        *op_ptr = newLISTOP(OP_NULL, 0, mark, erase->op_sibling);

        return KEYWORD_PLUGIN_EXPR;
    }
    else {
        return next_keyword_plugin(aTHX_ keyword_ptr, keyword_len, op_ptr);
    }
}

static void
_unwind(pTHX)
{
    DEBUG_printf("unwinding:\n%d     %d     %d\n",
                 PL_stack_sp - PL_stack_base,
                 *PL_markstack_ptr,
                 PL_scopestack_ix
        );
    {
        int i;
        DEBUG_printf("Stack Mark Scope\n");
        for (i=cxstack_ix; i >= 0; i--) {
            const PERL_CONTEXT *cx = &cxstack[i];
            DEBUG_printf("%d%s    %d%s     %d%s\n"
                         , cx->blk_oldsp
                         , ((char *)(*(PL_stack_base + cx->blk_oldsp+1)) == MARK
                            ? "X" : "")
                         , cx->blk_oldmarksp
                         , ((char *)(*(PL_stack_base + cx->blk_oldmarksp)) == MARK
                            ? "X" : "")
                         , cx->blk_oldscopesp
                         , ((char *)(*(PL_stack_base + cx->blk_oldscopesp)) == MARK
                            ? "X" : "")
                );
            if ( ((char *)(*(PL_stack_base + cx->blk_oldsp+1))) == MARK) {
                OP *retop = *(PL_stack_base + cx->blk_oldsp+2);
                DEBUG_printf("retop=%p\n", retop);
                PL_op->op_next    = retop;
                PL_stack_sp       = cx->blk_oldsp;
                *PL_markstack_ptr = cx->blk_oldmarksp;
                PL_scopestack_ix  = cx->blk_oldscopesp;
                return;
            }
        }
    }
}

MODULE = Stack::Unwind PACKAGE = Stack::Unwind

BOOT:
    XopENTRY_set(&mark_xop, xop_name,  "mark_xop");
    XopENTRY_set(&mark_xop, xop_desc,  "mark of the beast");
    XopENTRY_set(&mark_xop, xop_class, OA_UNOP);
    Perl_custom_op_register(aTHX_ _mark_pp, &mark_xop);

    XopENTRY_set(&erase_xop, xop_name,  "erase_xop");
    XopENTRY_set(&erase_xop, xop_desc,  "erase the mark of the beast");
    XopENTRY_set(&erase_xop, xop_class, OA_UNOP);
    Perl_custom_op_register(aTHX_ _erase_pp, &erase_xop);

    next_keyword_plugin =  PL_keyword_plugin;
    PL_keyword_plugin   = mark_keyword_plugin;


void unwind()
    CODE:
     _unwind(aTHX);
