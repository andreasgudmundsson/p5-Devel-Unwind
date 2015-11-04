#ifndef _UNWIND_DEBUG_H_
#define _UNWIND_DEBUG_H_

static inline void _deb_stack(pTHX);
static inline void _deb_env(pTHX);
static inline void _deb_cx(pTHX);
static inline void _cx_dump(pTHX_ PERL_CONTEXT *cx);

#define deb_cx() _deb_cx(aTHX)
#define deb_stack() _deb_stack(aTHX)
#define deb_env() _deb_env(aTHX)

#ifdef UNWIND_DEBUG
#define DEBUG_printf(...) PerlIO_printf(PerlIO_stderr(), ##__VA_ARGS__)
#else
#define DEBUG_printf(...)
#endif

static const char * const si_names[] =
{
    "UNKNOWN","UNDEF","MAIN","MAGIC",
    "SORT","SIGNAL","OVERLOAD","DESTROY",
    "WARNHOOK","DIEHOOK","REQUIRE"
};

static inline void _deb_env(pTHX) {
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

static inline void _deb_stack(pTHX) {
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

static inline void _deb_cx(pTHX)
{
#ifdef UNWIND_DEBUG
    dVAR;
    I32 i;
    for (i = PL_curstackinfo->si_cxix; i >= 0; i--) {
        cx_dump(&PL_curstackinfo->si_cxstack[i]);
    }
#endif
}

#endif /* _UNWIND_DEBUG_H_ */
