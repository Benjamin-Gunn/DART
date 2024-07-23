#!/bin/bash
# Note: this program should be run by the last job array
# $1 = number of job arrays tested

cd ../../work/TESTS/

for (( i=0 ; i<$1 ; i++ )); do
	cat ../../work_test_$i/TESTS/test_output >> test_output
	rm -r ../../work_test_$i
done
