#!/bin/bash
# $1 = CSV File, $2 = Ensemble Size, $3 = PE Count (or 0 for new CVS file setup), 
# $4 = positive_tracer, $5 = bounded_above, $6 = post_inf_flavor

module load nco

test_setup () {
	echo "TEST SETUP: $1 $2 $3 $4 $5 $6 --------------"
	ls
	cp TESTS/TEST_BASE_INPUT.nml input.nml
}

test_test () {
	echo "Test Value: $1 $2 $3 $4 $5 $6"
	ls
}

setup_test () {
	# Set up input.nml to do the initial perfect_model_obs run
	cp TESTS/TEST_BASE_INPUT.nml input.nml

	sed -i "s/T_QCEFF_TABLE_FILENAME/$1/g" input.nml
	sed -i "s/T_READ_INPUT_STATE_FROM_FILE/.false./g" input.nml
	sed -i "s/T_POST_INF_FLAVOR/$6/g" input.nml
	sed -i "s/T_POSITIVE_TRACER/$4/g" input.nml
	sed -i "s/T_BOUNDED_ABOVE_IS_ONE/$5/g" input.nml
	
   	./perfect_model_obs

   	# Do the next perfect_model iteration and the filter
   	cp perfect_output.nc perfect_input.nc

   	# Do ensemble size of 160 so that subsequent ICs with mpirun will have same ICs
	cp TESTS/TEST_BASE_INPUT.nml input.nml

	sed -i "s/T_QCEFF_TABLE_FILENAME/$1/g" input.nml
	sed -i "s/T_READ_INPUT_STATE_FROM_FILE/.true./g" input.nml
	sed -i "s/T_FILTER_INPUT/perfect_input.nc/" input.nml
	sed -i "s/T_ENS_SIZE/160/g" input.nml
	sed -i "s/T_POST_INF_FLAVOR/$6/g" input.nml
	sed -i "s/T_PERTURB_FROM_SINGLE_INSTANCE/.true./g" input.nml
	sed -i "s/T_POSITIVE_TRACER/$4/g" input.nml
	sed -i "s/T_BOUNDED_ABOVE_IS_ONE/$5/g" input.nml

   	./perfect_model_obs
   	./filter

   	# Do the next cycle of DA that has non-random filter ensemble ICs
   	cp perfect_output.nc perfect_input.nc
   	cp filter_output.nc filter_input.nc

	./perfect_model_obs
}

range_test () {
	cp TESTS/TEST_BASE_INPUT.nml input.nml

        sed -i "s/T_QCEFF_TABLE_FILENAME/$1/g" input.nml
        sed -i "s/T_READ_INPUT_STATE_FROM_FILE/.true./g" input.nml
        sed -i "s/T_FILTER_INPUT/filter_input.nc/g" input.nml
        sed -i "s/T_ENS_SIZE/$2/g" input.nml
        sed -i "s/T_PERTURB_FROM_SINGLE_INSTANCE/.false./g" input.nml
        sed -i "s/T_POST_INF_FLAVOR/$6/g" input.nml
        sed -i "s/T_POSITIVE_TRACER/$4/g" input.nml
        sed -i "s/T_BOUNDED_ABOVE_IS_ONE/$5/g" input.nml

	# Make sure there is no file around in case filter fails
	rm filter_output.nc

	mpirun -np $3 ./filter
	echo -n 'ens_size = ' $2, 'pes = ' $3 '  ' >> TESTS/test_output
	rm one_var_temp.nc
	ncrcat -d location,1,1 filter_output.nc one_var_temp.nc
	ncks -V -C -v state_variable_mean one_var_temp.nc | tail -3 | head -1 >> TESTS/test_output
	rm one_var_temp.nc
}

# Tests called down here so that functions are declared,
# Also, the script should be currently in the test work directory

if [[ $3 -eq 0 ]]; then
	setup_test $1 $2 $3 $4 $5 $6
else
        range_test $1 $2 $3 $4 $5 $6
fi
