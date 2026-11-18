#include <stdint.h>

/* A "language" from a tree-sitter too new for the app: only its ABI version (the first
   field) is read before it is refused. */
static const uint32_t language[64] = {99};

const void *tree_sitter_future(void) { return language; }
