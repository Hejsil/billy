/* The markdown parser's headers, in the one file the translator is given.
   `md4cs.h` is mdflow's streaming fork of md4c; it carries the parser, the
   callback API and the incremental entry points. `entity.h` is included
   because billy decodes entities itself, both for a reply's text and for a
   link address it is about to trust. */
#include "md4cs.h"
#include "entity.h"
