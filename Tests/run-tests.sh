#!/bin/zsh
# ponytail: swiftc assert-runner instead of a test target; add a GitpackTests
# target when UI/async tests appear. Models.swift and Parsers.swift must stay
# Foundation-only for this to keep working.
set -e
cd "$(dirname "$0")"
swiftc -parse-as-library -o /tmp/gitpack-parser-tests \
  ../Gitpack/Git/Models.swift ../Gitpack/Git/Parsers.swift \
  ../Gitpack/Git/FileSystemWatcher.swift ParserTests.swift
/tmp/gitpack-parser-tests && echo "ALL TESTS PASSED"
