// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library dart.system;

var a;

_entry(int mainArity) {
  a = 1;
  _halt(a);
}

void foo(x) {
}

_halt(int code) native;
_printString(String s) native;
