#!/bin/bash
# Switch compiler and correct namelist
module load $1
rm TEST_BASE_INPUT.nml
cp TEST_BASE_INPUT_$1.nml TEST_BASE_INPUT.nml

# Clear any output from previous tests (if present)
rm test_output

# Rename previous mkmf.template
mv ../../build_templates/mkmf.template ../../build_templates/mkmf.template.previous

# Run fixsystem and select mkmf.template based on compiler selected
chmod +x ../../assimilation_code/modules/utilities/fixsystem
if [[ $1 -eq "gcc" ]]; then
	./../../assimilation_code/modules/utilities/fixsystem gfortran
	cp ../../build_templates/mkmf.template.gfortran ../../build_templates/mkmf.template
elif [[ $1 -eq "intel" ]]; then
	./../../assimilation_code/modules/utilities/fixsystem ifort
	cp ../../build_templates/mkmf.template.intel.linux ../../build_templates/mkmf.template
else
	./../../assimilation_code/modules/utilities/fixsystem ifort
	cp ../../build_templates/mkmf.template.intel.linux ../../build_templates/mkmf.template
fi

# Change to L96 directory
cd ../../models/lorenz_96_tracer_advection/

# Compile with mpi
./quickbuild.sh clean
./quickbuild.sh mpif08

# Create a single step obs_sequenc
./create_obs_sequence < ../../../developer_tests/tracer_filter/create_obs_sequence_input

# Generate the 1000 timestep obs_seq.in file
./create_fixed_network_seq < ../../../developer_tests/tracer_filter/create_fixed_network_seq_in