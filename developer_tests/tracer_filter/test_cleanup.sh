#!/bin/bash
# $1 = number of job arrays tested

cd ~/DART/developer_tests/tracer_filter

# Check if all test arrays are done so cleanup can proceed
for (( i=0 ; i<$1 ; i++ )); do
	if [ ! -f /test_array_finished_$i ]; then 
		exit
	else
		rm test_array_finished_$i
	fi
done

for (( i=0 ; i<$1 ; i++ )); do
	cat ~/DART/models/lorenz_96_tracer_advection/work_test_$i/temp_test_output >> ~/DART/developer_tests/tracer_filter/test_output
	rm -r ~/DART/models/lorenz_96_tracer_advection/work_test_$i
done

# test_out should be an empty string if it was identical
test_out=$(diff -q test_output BASELINE_OUTPUT)

# Output the test result to a stand alone file
if [[ test_out ]]; then
    echo "TEST FAILED: test_output differs from BASELINE_OUTPUT" > test_result
else
    echo "TEST PASSED: test_output is the same as BASELINE_OUTPUT" > test_result
fi

# Restore the user's mkmf.template
rm ~/DART/build_templates/mkmf.template
mv ~/DART/build_templates/mkmf.template.previous ~/DART/build_templates/mkmf.template