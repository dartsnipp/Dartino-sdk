// Copyright (c) 2015, the Fletch project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

// Generated file. Do not edit.

#ifndef PERSON_COUNTER_H
#define PERSON_COUNTER_H

#include "struct.h"

class AgeStats;
class AgeStatsBuilder;
class Person;
class PersonBuilder;
class PersonBox;
class PersonBoxBuilder;
class Node;
class NodeBuilder;
class Cons;
class ConsBuilder;

class PersonCounter {
 public:
  static void Setup();
  static void TearDown();
  static int GetAge(PersonBuilder person);
  static int GetBoxedAge(PersonBoxBuilder box);
  static AgeStats GetAgeStats(PersonBuilder person);
  static AgeStats CreateAgeStats(int averageAge, int sum);
  static Person CreatePerson(int children);
  static int Count(PersonBuilder person);
  static int Depth(NodeBuilder node);
};

class AgeStats : public Reader {
 public:
  AgeStats(Segment* segment, int offset)
      : Reader(segment, offset) { }

  int averageAge() const { return *PointerTo<int>(0); }
  int sum() const { return *PointerTo<int>(4); }
};

class AgeStatsBuilder : public Builder {
 public:
  static const int kSize = 8;

  explicit AgeStatsBuilder(const Builder& builder)
      : Builder(builder) { }
  AgeStatsBuilder(BuilderSegment* segment, int offset)
      : Builder(segment, offset) { }

  void set_averageAge(int value) { *PointerTo<int>(0) = value; }
  void set_sum(int value) { *PointerTo<int>(4) = value; }
};

class Person : public Reader {
 public:
  Person(Segment* segment, int offset)
      : Reader(segment, offset) { }

  int age() const { return *PointerTo<int>(0); }
};

class PersonBuilder : public Builder {
 public:
  static const int kSize = 16;

  explicit PersonBuilder(const Builder& builder)
      : Builder(builder) { }
  PersonBuilder(BuilderSegment* segment, int offset)
      : Builder(segment, offset) { }

  void set_age(int value) { *PointerTo<int>(0) = value; }
  List<PersonBuilder> NewChildren(int length);
};

class PersonBox : public Reader {
 public:
  PersonBox(Segment* segment, int offset)
      : Reader(segment, offset) { }

};

class PersonBoxBuilder : public Builder {
 public:
  static const int kSize = 8;

  explicit PersonBoxBuilder(const Builder& builder)
      : Builder(builder) { }
  PersonBoxBuilder(BuilderSegment* segment, int offset)
      : Builder(segment, offset) { }

  PersonBuilder NewPerson();
};

class Node : public Reader {
 public:
  Node(Segment* segment, int offset)
      : Reader(segment, offset) { }

  short tag() const { return *PointerTo<short>(0); }
  bool is_num() const { return 1 == tag(); }
  int num() const { return *PointerTo<int>(8); }
};

class NodeBuilder : public Builder {
 public:
  static const int kSize = 16;

  explicit NodeBuilder(const Builder& builder)
      : Builder(builder) { }
  NodeBuilder(BuilderSegment* segment, int offset)
      : Builder(segment, offset) { }

  void set_tag(short value) { *PointerTo<short>(0) = value; }
  void mark_num() { set_tag(1); }
  void set_num(int value) { *PointerTo<int>(8) = value; }
  void mark_cons() { set_tag(2); }
  ConsBuilder NewCons();
};

class Cons : public Reader {
 public:
  Cons(Segment* segment, int offset)
      : Reader(segment, offset) { }

};

class ConsBuilder : public Builder {
 public:
  static const int kSize = 16;

  explicit ConsBuilder(const Builder& builder)
      : Builder(builder) { }
  ConsBuilder(BuilderSegment* segment, int offset)
      : Builder(segment, offset) { }

  NodeBuilder NewFst();
  NodeBuilder NewSnd();
};

#endif  // PERSON_COUNTER_H
