#!/bin/bash
# Default behavior selects gcc as compiler
[[ $1 == "" ]] && comp="gcc" || comp=$1

# Switch compiler and correct namelist
module load $comp
module load nco
rm TEST_BASE_INPUT.nml
cp TEST_BASE_INPUT_$comp.nml TEST_BASE_INPUT.nml
echo "compiler=$comp"

# Clear any output from previous tests (if present)
rm test_output
rm test_result

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
cd ../../models/lorenz_96_tracer_advection/work/

# Compile with mpi
./quickbuild.sh clean
./quickbuild.sh mpif08

# Create a single step obs_sequence
./create_obs_sequence < ~/DART/developer_tests/tracer_filter/create_obs_sequence_input

# Generate the 1000 timestep obs_seq.in file
./create_fixed_network_seq < ~/DART/developer_tests/tracer_filter/create_fixed_network_seq_in