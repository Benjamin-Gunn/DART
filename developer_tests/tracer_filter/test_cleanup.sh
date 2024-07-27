#!/bin/bash
# Note: this program should be run by the last job array
# $1 = number of job arrays tested

for (( i=0 ; i<$1 ; i++ )); do
	cat ~/DART/models/lorenz_96_tracer_advection/work_test_$i/temp_test_output >> ~/DART/developer_tests/tracer_filter/test_output
	rm -r ~/DART/models/lorenz_96_tracer_advection/work_test_$i
done
