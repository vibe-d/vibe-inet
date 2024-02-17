#!/bin/bash

set -e -x -o pipefail

DCVER=${DC#*-}
DC=${DC%-*}
if [ "$DC" == "ldc" ]; then DC="ldc2"; fi
DUB_FLAGS="${DUB_FLAGS:-} --compiler=$DC"


# Check for trailing whitespace"
grep -nrI --include='*.d' '\s$' . && (echo "Trailing whitespace found"; exit 1)

# test for successful release build
dub build -b release $DUB_FLAGS

# test for successful 32-bit build
if [ "$DC" == "dmd" ]; then
	dub build --arch=x86 $DUB_FLAGS
fi

dub test $DUB_FLAGS
dub test :crypto $DUB_FLAGS
dub test :textfilter $DUB_FLAGS
