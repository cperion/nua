// GPL-3.0-or-later. See ../../../COPYING.
#include "tree_sitter/parser.h"
#include <stdbool.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>

enum { LONG_STRING, LONG_COMMENT, NAME_ARGUMENT, ENDALL, IMPLICIT_END, ERROR_SENTINEL, ENDALL_RESET, ATTACHED_PAREN, BLOCK_COLON, HEADER_NAME, HEADER_DOTS, WITH };
typedef struct { bool endall; bool header; uint32_t column; int32_t next; } Scanner;
void *tree_sitter_nua_external_scanner_create(void) { return calloc(1, sizeof(Scanner)); }
void tree_sitter_nua_external_scanner_destroy(void *p) { free(p); }
unsigned tree_sitter_nua_external_scanner_serialize(void *p, char *b) { memcpy(b, p, sizeof(Scanner)); return sizeof(Scanner); }
void tree_sitter_nua_external_scanner_deserialize(void *p, const char *b, unsigned n) {
  memset(p, 0, sizeof(Scanner)); if (n == sizeof(Scanner)) memcpy(p, b, n);
}
static void advance(TSLexer *l) { l->advance(l, false); }
static bool name_start(int32_t c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_'; }
static bool name_char(int32_t c) { return name_start(c) || (c >= '0' && c <= '9'); }
// Past mark_end: does only spaces, tabs and a `--` comment remain on this line?
static bool line_ends(TSLexer *l) {
  while (l->lookahead == ' ' || l->lookahead == '\t' || l->lookahead == '\r') advance(l);
  if (l->lookahead == '-') { advance(l); return l->lookahead == '-'; }
  return l->eof(l) || l->lookahead == '\n';
}
static bool dots_ahead(TSLexer *l) {
  if (l->lookahead != '.') return false;
  advance(l);
  if (l->lookahead != '.') return false;
  advance(l);
  return true;
}
// The trailing colon (syntax 2.4, rule 11): a colon directly followed by a space or
// the end of the line, then only names, `name..` and `..`, then the end of the line.
// The colon is the token; the names are read as HEADER_NAME / HEADER_DOTS while
// `header` is set. A block never starts with a closing bracket or a comma, so a
// last struct field (`x: F32` before `}`) is not a block opener.
static bool block_colon(Scanner *s, TSLexer *l) {
  advance(l);
  if (l->lookahead == ':' || name_char(l->lookahead)) return false;
  l->mark_end(l);
  bool any = false;
  for (;;) {
    while (l->lookahead == ' ' || l->lookahead == '\t' || l->lookahead == '\r') advance(l);
    if (l->eof(l) || l->lookahead == '\n') break;
    if (l->lookahead == '-') { advance(l); if (l->lookahead != '-') return false; break; }
    if (name_start(l->lookahead)) {
      while (name_char(l->lookahead)) advance(l);
      dots_ahead(l);
    } else if (!dots_ahead(l)) return false;
    any = true;
  }
  while (!l->eof(l) && l->lookahead != '\n') advance(l);
  while (l->lookahead == ' ' || l->lookahead == '\t' || l->lookahead == '\r' || l->lookahead == '\n') advance(l);
  if (l->eof(l) || l->lookahead == '}' || l->lookahead == ')' || l->lookahead == ']' || l->lookahead == ',') return false;
  s->header = any;
  l->result_symbol = BLOCK_COLON;
  return true;
}
bool tree_sitter_nua_external_scanner_scan(void *p, TSLexer *l, const bool *valid) {
  Scanner *s = p;
  if (valid[ERROR_SENTINEL]) return false;
  // One endall can close several adjacent untyped lambdas. Emit their extra
  // closers only at that exact boundary; the grammar excludes typed words.
  if (s->endall && s->column == l->get_column(l) && s->next == l->lookahead && valid[IMPLICIT_END]) {
    l->mark_end(l); l->result_symbol = IMPLICIT_END; return true;
  }
  // Persist clearing the endall state. Failed scans do not update Tree-sitter's
  // serialized state, so merely clearing the flag before returning false would
  // allow it to reappear at a later token with the same column.
  if (s->endall && valid[ENDALL_RESET]) {
    s->endall = false; l->mark_end(l); l->result_symbol = ENDALL_RESET; return true;
  }
  // A `(` with no whitespace before it continues an argument's postfix chain;
  // a spaced one is left to the grammar as the next argument group.
  if (valid[ATTACHED_PAREN] && l->lookahead == '(') {
    advance(l); l->mark_end(l); l->result_symbol = ATTACHED_PAREN; return true;
  }
  // Unlike literal arguments, a juxtaposed name must stay on the same line.
  // Scan it externally so skipped whitespace cannot erase that distinction.
  bool same_line = l->get_column(l) > 0;
  bool space = false;
  while (l->lookahead == ' ' || l->lookahead == '\t' || l->lookahead == '\n' || l->lookahead == '\r') {
    space = true;
    if (l->lookahead == '\n' || l->lookahead == '\r') same_line = false;
    l->advance(l, true);
  }
  if (valid[BLOCK_COLON] && l->lookahead == ':' && block_colon(s, l)) return true;
  if (s->header && same_line) {
    if (valid[HEADER_DOTS] && l->lookahead == '.') {
      if (!dots_ahead(l)) return false;
      l->mark_end(l); s->header = !line_ends(l); l->result_symbol = HEADER_DOTS; return true;
    }
    if (valid[HEADER_NAME] && name_start(l->lookahead)) {
      while (name_char(l->lookahead)) advance(l);
      l->mark_end(l);
      while (l->lookahead == ' ' || l->lookahead == '\t') advance(l);
      s->header = !(l->lookahead == '\r' || l->lookahead == '\n' || l->eof(l) || l->lookahead == '-');
      l->result_symbol = HEADER_NAME; return true;
    }
  }
  if (s->header && !same_line) s->header = false;
  if ((valid[ENDALL] || valid[WITH] || (valid[NAME_ARGUMENT] && same_line && space)) && name_start(l->lookahead)) {
    char name[128]; unsigned n = 0;
    while (name_char(l->lookahead)) {
      if (n < sizeof(name) - 1) name[n++] = (char)l->lookahead;
      advance(l);
    }
    name[n] = 0;
    if (valid[ENDALL] && !strcmp(name, "endall")) {
      s->endall = true; s->column = l->get_column(l); s->next = l->lookahead;
      l->mark_end(l); l->result_symbol = ENDALL; return true;
    }
    // `T with entries end`: scanned here so it wins over a statement starting with the name
    if (valid[WITH] && !strcmp(name, "with")) { l->mark_end(l); l->result_symbol = WITH; return true; }
    if (!valid[NAME_ARGUMENT] || !same_line || !space) return false;
    const char *keywords[] = {"and", "break", "continue", "do", "else", "elseif", "end", "endall", "export", "false", "for", "function", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while", "with"};
    for (unsigned i = 0; i < sizeof(keywords)/sizeof(*keywords); ++i) if (!strcmp(name, keywords[i])) return false;
    l->mark_end(l); l->result_symbol = NAME_ARGUMENT; return true;
  }
  bool comment = l->lookahead == '-';
  if (comment) {
    if (!valid[LONG_COMMENT]) return false;
    advance(l); if (l->lookahead != '-') return false; advance(l);
  } else if (!valid[LONG_STRING]) return false;
  if (l->lookahead != '[') return false;
  advance(l);
  unsigned equals = 0;
  while (l->lookahead == '=') { ++equals; advance(l); }
  if (l->lookahead != '[') return false;
  advance(l);
  while (!l->eof(l)) {
    if (l->lookahead != ']') { advance(l); continue; }
    advance(l);
    unsigned n = 0;
    while (l->lookahead == '=') { ++n; advance(l); }
    if (n == equals && l->lookahead == ']') {
      advance(l); l->mark_end(l); l->result_symbol = comment ? LONG_COMMENT : LONG_STRING; return true;
    }
  }
  return false;
}
