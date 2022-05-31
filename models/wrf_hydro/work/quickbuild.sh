#!/usr/bin/env bash

# DART software - Copyright UCAR. This open source software is provided
# by UCAR, "as is", without charge, subject to all terms of use at
# http://www.image.ucar.edu/DAReS/DART/DART_download

main() {

export DART=$(git rev-parse --show-toplevel)
source "$DART"/build_templates/buildfunctions.sh

MODEL=wrf_hydro
LOCATION=threed_sphere
EXTRA="$DART/models/wrf/module_map_utils.f90"


programs=(
closest_member_tool
filter
model_mod_check
perfect_model_obs
perturb_single_instance
wakeup_filter
)

serial_programs=(
advance_time
create_fixed_network_seq
create_obs_sequence
fill_inflation_restart
obs_common_subset
obs_diag
obs_selection
obs_seq_coverage
obs_seq_to_netcdf
obs_seq_verify
obs_sequence_tool
streamflow_obs_diag
)


#radiance_obs_to_netcdf \  # needs rttov

model_serial_programs=(
create_identity_streamflow_obs
)

arguments "$@"

# clean the directory
\rm -f -- *.o *.mod Makefile .cppdefs

# build and run preprocess before making any other DART executables
buildpreprocess

# build DART
buildit

# clean up
\rm -f -- *.o *.mod

}

main "$@"
