#!/bin/bash
# $1 = CSV File, $2 = Ensemble Size, $3 = PE Count (or 0 for new CVS file setup), 
# $4 = positive_tracer, $5 = bounded_above, $6 = post_inf_flavor

test_setup () {
	echo "TEST SETUP: $1 $2 $3 $4 $5 $6 --------------"
}

test_test () {
	echo "Test Value: $1 $2 $3 $4 $5 $6"
}

setup_test () {
	# Set up input.nml to do the initial perfect_model_obs run
	cp TESTS/TEST_BASE_INPUT.NML input.nml

	vi input.nml << HERE
:1,\$s/T_QCEFF_TABLE_FILENAME/$1/
:1,\$s/T_READ_INPUT_STATE_FROM_FILE/.false./
:1,\$s/T_POST_INF_FLAVOR/$6/
:1,\$s/T_POSITIVE_TRACER/$4/
:1,\$s/T_BOUNDED_ABOVE_IS_ONE/$5/
:wq
HERE
   	./perfect_model_obs

   	# Do the next perfect_model iteration and the filter
   	cp perfect_output.nc perfect_input.nc

   	# Do ensemble size of 160 so that subsequent ICs with mpirun will have same ICs
   	cp TESTS/TEST_BASE_INPUT.NML input.nml
   	vi input.nml << HERE
:1,\$s/T_QCEFF_TABLE_FILENAME/$1/
:1,\$s/T_READ_INPUT_STATE_FROM_FILE/.true./
:1,\$s/T_FILTER_INPUT/perfect_input.nc/
:1,\$s/T_ENS_SIZE/160/
:1,\$s/T_POST_INF_FLAVOR/$6/
:1,\$s/T_PERTURB_FROM_SINGLE_INSTANCE/.true./
:1,\$s/T_POSITIVE_TRACER/$4/
:1,\$s/T_BOUNDED_ABOVE_IS_ONE/$5/
:wq
HERE

   	./perfect_model_obs
   	./filter

   	# Do the next cycle of DA that has non-random filter ensemble ICs
   	cp perfect_output.nc perfect_input.nc
   	cp filter_output.nc filter_input.nc

	./perfect_model_obs
}

range_test () {
	cp TESTS/TEST_BASE_INPUT.NML input.nml
	vi input.nml << HERE
:1,\$s/T_QCEFF_TABLE_FILENAME/$1/
:1,\$s/T_READ_INPUT_STATE_FROM_FILE/.true./
:1,\$s/T_FILTER_INPUT/filter_input.nc/
:1,\$s/T_ENS_SIZE/$2/
:1,\$s/T_PERTURB_FROM_SINGLE_INSTANCE/.false./
:1,\$s/T_POST_INF_FLAVOR/$6/
:1,\$s/T_POSITIVE_TRACER/$4/
:1,\$s/T_BOUNDED_ABOVE_IS_ONE/$5/
:wq
HERE
	# Make sure there is no file around in case filter fails
	rm filter_output.nc

	mpirun --oversubscribe -np $3 filter
	echo -n 'ens_size = ' $2, 'pes = ' $3 '  ' >> TESTS/test_output
	rm one_var_temp.nc
	ncrcat -d location,1,1 filter_output.nc one_var_temp.nc
	ncks -V -C -v state_variable_mean one_var_temp.nc | tail -3 | head -1 >> TESTS/test_output
	rm one_var_temp.nc
}

# Tests called down here so that functions are declared

cd ..

if [[ $3 -eq 0 ]]; then
        test_setup $1 $2 $3 $4 $5 $6
else
        test_test $1 $2 $3 $4 $5 $6
fi
