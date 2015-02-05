// Copyright (c) 2015, the Fletch project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library servicec.grammar;

import 'package:petitparser/petitparser.dart';

class ServiceGrammarDefinition extends GrammarDefinition {
  Parser token(String input) {
    Parser parser = input.length == 1 ? char(input) : string(input);
    return parser.token().trim(ref(HIDDEN));
  }


  // -----------------------------------------------------------------
  // Keyword definitions.
  // -----------------------------------------------------------------
  LIST() => ref(token, 'List');

  SERVICE() => ref(token, 'service');

  STRUCT() => ref(token, 'struct');

  UNION() => ref(token, 'union');


  // -----------------------------------------------------------------
  // Grammar productions.
  // -----------------------------------------------------------------
  start() => ref(unit).end();

  unit() => (ref(service) | ref(struct)).star();

  service() => ref(SERVICE)
      & ref(identifier)
      & ref(token, '{')
      & ref(method).star()
      & ref(token, '}');

  method() => ref(type)
      & ref(identifier)
      & ref(token, '(')
      & ref(formals).optional(const [])
      & ref(token, ')')
      & ref(token, ';');

  struct() => ref(STRUCT)
      & ref(identifier)
      & ref(token, '{')
      & (ref(slot) | ref(union)).star()
      & ref(token, '}');

  slot() => ref(formal)
      & ref(token, ';');

  union() => ref(UNION)
      & ref(token, '{')
      & ref(slot).star()
      & ref(token, '}');

  formals() => ref(formal)
      .separatedBy(ref(token, ','), includeSeparators: false);

  formal() => ref(type)
      & ref(identifier);

  type() => ref(listType)
      | ref(simpleType);

  simpleType() => ref(identifier);

  listType() => ref(LIST)
      & ref(token, '<')
      & ref(identifier)
      & ref(token, '>');

  identifier() => ref(IDENTIFIER).trim(ref(HIDDEN));


  // -----------------------------------------------------------------
  // Lexical tokens.
  // -----------------------------------------------------------------
  IDENTIFIER() => ref(IDENTIFIER_START)
      & ref(IDENTIFIER_PART).star();

  IDENTIFIER_START() => ref(IDENTIFIER_START_NO_DOLLAR)
      | char('\$');

  IDENTIFIER_START_NO_DOLLAR() => ref(LETTER)
      | char('_');

  IDENTIFIER_PART_NO_DOLLAR() => ref(IDENTIFIER_START_NO_DOLLAR)
      | ref(DIGIT);

  IDENTIFIER_PART() => ref(IDENTIFIER_START)
      | ref(DIGIT);

  LETTER() => letter();

  DIGIT() => digit();


  // -----------------------------------------------------------------
  // Whitespace and comments.
  // -----------------------------------------------------------------
  HIDDEN() => ref(WHITESPACE_OR_COMMENT).plus();

  WHITESPACE_OR_COMMENT() => ref(WHITESPACE)
     | ref(SINGLE_LINE_COMMENT)
     | ref(MULTI_LINE_COMMENT)
     ;

  WHITESPACE() => whitespace();
  NEWLINE() => pattern('\n\r');

  SINGLE_LINE_COMMENT() => string('//')
     & ref(NEWLINE).neg().star()
     & ref(NEWLINE).optional()
     ;

  MULTI_LINE_COMMENT() => string('/*')
     & (ref(MULTI_LINE_COMMENT) | string('*/').neg()).star() & string('*/')
     ;
}
