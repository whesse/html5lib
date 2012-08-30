#!/bin/bash
# Copyright (c) 2012, the Dart project authors.  Please see the LICENSE file
# for details. All rights reserved. Use of this source code is governed by a
# MIT-style license that can be found in the LICENSE file.

# bail on error
set -e

# TODO(sigmund): replace with a real test runner
for test in tests/*_test.dart; do
  # TODO(jmesserly): removed --enable-type-checks to work around VM bug in
  # the RegExp constructor when the optimizer kicks in.
  dart --enable-asserts --package-root=packages/ $test
done
