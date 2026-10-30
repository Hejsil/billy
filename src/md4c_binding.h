/* The markdown parser's headers, in the one file the translator is given. `md4c.h` carries the
   parser, the callback API and the entry point. `entity.h` is included because billy decodes
   entities itself, both for a reply's text and for a link address it is about to trust. */
#include "md4c.h"
#include "entity.h"
