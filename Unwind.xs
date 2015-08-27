#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

static XOP mark_xop;
static OP  mark_pp(pTHX);
static int (*next_keyword_plugin)(pTHX_ char *, STRLEN, OP **);

static OP* _mark_pp(pTHX)
{
    return PL_op->op_next;
}

#define parse_mark() _parse_mark(aTHX)
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
        OP *mark_op = newUNOP(OP_CUSTOM, 0, parse_mark());
        mark_op->op_ppaddr = _mark_pp;
        *op_ptr = mark_op;
        return KEYWORD_PLUGIN_EXPR;
    }
    else {
        return next_keyword_plugin(aTHX_ keyword_ptr, keyword_len, op_ptr);
    }
}

/*
  i've got a custom keyword that just splices in a regular
  op-tree, not my custom op
 */

MODULE = Stack::Unwind PACKAGE = Stack::Unwind

BOOT:
    XopENTRY_set(&mark_xop, xop_name,  "mark_xop");
    XopENTRY_set(&mark_xop, xop_desc,  "mark of the beast");
    XopENTRY_set(&mark_xop, xop_class, OA_UNOP);
    Perl_custom_op_register(aTHX_ _mark_pp, &mark_xop);
    next_keyword_plugin =  PL_keyword_plugin;
    PL_keyword_plugin   = mark_keyword_plugin;
