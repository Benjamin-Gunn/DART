#!/usr/bin/env bash

main() {

[ -z "$DART" ] && echo "ERROR: Must set DART environment variable" && exit 9
source "$DART"/build_templates/buildfunctions.sh

MODEL=cice
LOCATION=threed_sphere


# clean the directory
\rm -f -- *.o *.mod Makefile .cppdefs


programs=(
closest_member_tool \
filter \
model_mod_check \
perfect_model_obs \
perturb_single_instance \
wakeup_filter
)

serial_programs=(
advance_time \
create_fixed_network_seq \
create_obs_sequence \
fill_inflation_restart \
obs_common_subset \
obs_diag \
obs_selection \
obs_seq_coverage \
obs_seq_to_netcdf \
obs_seq_verify \
obs_sequence_tool
)

model_serial_programs=(
cice_to_dart
dart_to_cice
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
