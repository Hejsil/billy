/* The md4c headers billy translates into Zig, in the one file the translator is
   given: the library's own, its entity table, and its HTML renderer. The table
   is needed because a link address is decoded before it is trusted -- a
   `javascript:` scheme can be spelled with entities, and the decoded address is
   the one a browser follows. The HTML renderer is only used by billy's oracle
   test, which checks its own renderer against md4c's. */
#include "md4c.h"
#include "entity.h"
#include "md4c-html.h"
