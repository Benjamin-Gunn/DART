#!/bin/csh -f
#
# DART software - Copyright 2004 - 2013 UCAR. This open source software is
# provided by UCAR, "as is", without charge, subject to all terms of use at
# http://www.image.ucar.edu/DAReS/DART/DART_download
#
# DART $Id$

# ==============================================================================
#
# ---------------------
# Purpose
# ---------------------
#
# This script is designed to set up, stage, and build a multi-instance run
# of CESM using an I compset where only CLM is active and the ocean and land
# states are specified by data files. The initial states come from a single
# multi-instance reference case so a CESM hybrid setup is used.
#
# CLM: Under a hybrid start, CESM uses the REFCASE and REFDATE information
#      to construct the name of the CLM restart file. This script makes an effort
#      to coordinate the staging of the file so it is consistent with CESM.
#
#      This script uses the result of the 'b40.20th.005_ens${instance}' experiments,
#      sort of.  CLM has changed and the CLM restart files needed to be converted
#      to the new format. I ran 'interpinic' to (essentially) reformat the files
#      and changed the CASENAME to 'cesm_test' and used the multi-instance naming
#      convention for the new files.
#
# DATM: We are using an ensemble of data atmospheres. This requires modification of
#       the stream text files (and the stream files) for each CESM instance.
#
# DOCN: We are using a single data ocean.
#
# Much of the complexity comes from ensuring compatibility between the namelists
# for each instance and staging of the files. The original experiments were run
# before the multi-instance capacity was developed and the naming convention decided.
# Consequently, there is a lot of manipulation of the 'instance' portion of the
# filenames.
#
# This script results in a viable setup for a CESM multi-instance experiment. You
# are STRONGLY encouraged to run the multi-instance CESM a few times and experiment
# with different settings BEFORE you try to assimilate observations. The amount of
# data volume is quite large and you should become comfortable using CESM's restart
# capability to re-stage files in your RUN directory
#
# ${CASEROOT}/CESM_DART_config will augment the CESM case with the required setup
# and configuration to perform a DART assimilation. CASEROOT/CESM_DART_config
# will insert a few dozen lines into the ${case}.run script after it makes a backup
# copy.  This, and the required setup, can be run at a later date. e.g. you can
# advance an ensemble from 2004-01-01 to 2004-02-01 and then run
# CESM_DART_config to augment the existing run script, modify STOP_N to 6 hours,
# and start assimilating observations when CESM stops at 2004-02-01 06Z ...
#
# This script relies heavily on the information in:
# http://www.cesm.ucar.edu/models/cesm1.1/cesm/doc/usersguide/book1.html
#
# ---------------------
# How to use this script.
# ---------------------
#
# -- You will have to read and understand the script in its entirety.
#    You will have to modify things outside this script.
#    This script sets up a plain CESM multi-instance run without DART,
#    intentionally.  Once it is running, calls to DART can be added.
#
# -- Examine the whole script to identify things to change for your experiments.
#
# -- Edit this script in the $DART/models/clm/shell_scripts directory
#    or copy it to somewhere where it will be preserved.
#
# -- Locate the initial multi-instance files that CESM will need.
#
# -- Run this script. When it is executed, it will create:
#    1) a CESM 'CASE' directory, where the model will be built,
#    2) a run directory, where each forecast (and assimilation) will take place,
#    3) a bld directory for the executables.
#    4) The short term archiver will use a fourth directory for
#    storage of model output until it can be moved to long term storage (HPSS)
#
# -- If you want to run DART; read, understand, and execute ${CASEROOT}/CESM_DART_config
#
# -- Submit the job using ${CASEROOT}/${CASE}.submit
#
# ---------------------
# Important features
# ---------------------
#
# If you want to change something in your case other than the runtime
# settings, it is safest to delete everything and start the run from scratch.
# For the brave, read
#
# http://www.cesm.ucar.edu/models/cesm1.1/cesm/doc/usersguide/x1142.html
#
# and you may be able to salvage something with
# ./cesm_setup -clean
# ./cesm_setup
# ./${case}.clean_build
# ./${case}.build
#
# ==============================================================================



# ==============================================================================
# case options:
#
# case          The value of "case" will be used many ways; directory and file
#               names both locally and on HPSS, and script names; so consider
#               its length and information content.
# compset       Must be one of the CESM standard names, see the CESM documentation
#               for supported strings.
# resolution    Sets the model grid resolution, see the CESM documentation.
# cesmtag       The version of the CESM source code to use when building the code.
# num_instances The number of ensemble members.
# ==============================================================================

setenv case                 NE_c_daily_assim_ICLM45BGC_point
setenv compset              I1PTCLM45
setenv resolution           CLM_USRDAT
setenv cesmtag              cesm1_2_0
setenv num_instances        80
setenv site                 US-Ha1
setenv neon_site            NE_c
setenv ptclm_site           ${site}
setenv filedate             140710     # Mpj 140825, Ha1 140710, NR1 140711
setenv mydatafiles          /glade/p/work/${USER}/clm4_5_74/models/lnd/clm/tools/shared/PTCLM/mydatafiles
setenv user_mods_dir        ${mydatafiles}/1x1pt_${site}

# ==============================================================================
# machines and directories:
#
# mach            Computer name
# cesmroot        Location of the CESM code base.  This version of the script
#                 only supports version cesm1_1_1.
# caseroot        Will create the CESM case directory here, where the CESM+DART
#                 configuration files will be stored.  This should probably not
#                 be in scratch (on yellowstone, your 'work' partition is suggested).
#                 This script will delete any existing caseroot, so this script,
#                 and other useful things should be kept elsewhere.
# rundir          Will create the CESM run directory here.  Will need large
#                 amounts of disk space, generally on a scratch partition.
# exeroot         Will create the CESM executable directory here, where the
#                 CESM executables will be built.  Medium amount of space
#                 needed, generally on a scratch partition.
# archdir         Will create the CESM short-term archive directories here.
#                 Large, generally on a scratch partition.  Files will remain
#                 here until the long-term archiver moves it to permanent storage.
# dartroot        Location of the root of _your_ DART installation
# ==============================================================================

setenv mach         yellowstone_intel

#setenv cesmroot     /glade/p/cesm/cseg/collections/$cesmtag
setenv cesmroot     /glade/p/work/afox/clm4_5_74
setenv caseroot     /glade/p/work/${USER}/cases/${case}
setenv rundir       /glade/scratch/${USER}/${case}/run
setenv exeroot      /glade/scratch/${USER}/${case}/bld
setenv archdir      /glade/scratch/${USER}/archive/${case}
setenv dartroot     /glade/p/work/${USER}/DART

# ==============================================================================
# configure settings:
#
# refcase    The name of the existing reference case that this run will
#            start from.
#
# refyear    The specific date/time-of-day in the reference case that this
# refmon     run will start from.  (Also see 'runtime settings' below for
# refday     start_year, start_mon, start_day and start_tod.)
# reftod
#
# stagedir   The directory location of the reference case files.
# ==============================================================================

setenv refcase     ${neon_site}_freerun_ICLM45BGC_point
setenv refyear     2005
setenv refmon      01
setenv refday      01
setenv reftod      00000

# useful combinations of time that we use below
setenv refdate      $refyear-$refmon-$refday
setenv reftimestamp $refyear-$refmon-$refday-$reftod

setenv stagedir /glade/scratch/afox/archive/$refcase/rest/${reftimestamp}
# setenv stagedir NULL

# ==============================================================================
# runtime settings:
#
# start_year     generally this is the same as the reference case date, but it can
# start_month    be different if you want to start this run as if it was a different time.
# start_day
# start_tod
#
# stream_year_first  settings for the stream files for the Data Atmosphere (DATM).
# stream_year_last
# stream_year_align
#
# short_term_archiver  Copies the files from each job step to a 'rest' directory.
# long_term_archiver   Puts the files from all completed steps on tape storage.
#
# resubmit      How many job steps to run on continue runs (should be 0 initially)
# stop_option   Units for determining the forecast length between assimilations
# stop_n        Number of time units in each forecast
#
# clm_dtime     CLM dynamical timestep (in seconds) ... 1800 is the default
# h1nsteps      is the number of time steps to put in a single CLM .h1. file
#               DART needs to know this and the only time it is known is during
#               this configuration step. Changing the value later has no effect.
#
# If the long-term archiver is off, you get a chance to examine the files before
# they get moved to long-term storage. You can always submit $CASE.l_archive
# whenever you want to free up space in the short-term archive directory.
# ==============================================================================

setenv start_year    2005
setenv start_month   01
setenv start_day     01
setenv start_tod     00000

setenv stream_year_first 2000
setenv stream_year_last  2010
setenv stream_year_align 2000

setenv short_term_archiver on
setenv long_term_archiver  off

setenv resubmit            0
setenv stop_option         ndays
setenv stop_n              1

@ clm_dtime = 1800
@ h1nsteps = $stop_n * 3600 / $clm_dtime

# ==============================================================================
# job settings:
#
# queue      can be changed during a series by changing the ${case}.run
# timewall   can be changed during a series by changing the ${case}.run
#
# TJH: Advancing 80 instances for 72 hours with 2400 pes (80*15*2) with
#      an assimilation step took about 10 minutes on yellowstone.
# ==============================================================================

setenv ACCOUNT      P93300641
setenv queue        small
setenv timewall     0:10

# ==============================================================================
# standard commands:
#
# If you are running on a machine where the standard commands are not in the
# expected location, add a case for them below.
# ==============================================================================

set nonomatch       # suppress "rm" warnings if wildcard does not match anything

# The FORCE options are not optional.
# The VERBOSE options are useful for debugging though
# some systems don't like the -v option to any of the following
switch ("`hostname`")
   case be*:
      # NCAR "bluefire"
      set   MOVE = '/usr/local/bin/mv -fv'
      set   COPY = '/usr/local/bin/cp -fv --preserve=timestamps'
      set   LINK = '/usr/local/bin/ln -fvs'
      set REMOVE = '/usr/local/bin/rm -fr'

   breaksw
   default:
      # NERSC "hopper", NWSC "yellowstone"
      set   MOVE = '/bin/mv -fv'
      set   COPY = '/bin/cp -fv --preserve=timestamps'
      set   LINK = '/bin/ln -fvs'
      set REMOVE = '/bin/rm -fr'
   breaksw
endsw

# ==============================================================================
# ==============================================================================
# by setting the values above you should be able to execute this script and
# have it run.  however, for running a real experiment there are still many
# settings below this point - e.g. component namelists, history file options,
# the processor layout, xml file options, etc - that you will almost certainly
# want to change before doing a real science run.
# ==============================================================================
# ==============================================================================


# ==============================================================================
# Make sure the CESM directories exist.
# VAR is the shell variable name, DIR is the value
# ==============================================================================

foreach VAR ( cesmroot dartroot)
   set DIR = `eval echo \${$VAR}`
   if ( ! -d $DIR ) then
      echo "ERROR: directory '$DIR' not found"
      echo " In the setup script check the setting of: $VAR "
      exit -1
   endif
end

# ==============================================================================
#  Create the case - this creates the CASEROOT directory.
#  
# For list of the pre-defined component sets: ./create_newcase -list
# To create a variant compset, see the CESM documentation and carefully
# incorporate any needed changes into this script.
# ==============================================================================

# fatal idea to make caseroot the same dir as where this setup script is
# since the build process removes all files in the caseroot dir before
# populating it.  try to prevent shooting yourself in the foot.


if ( $caseroot == `dirname $0` ) then
   echo "ERROR: the setup script should not be located in the caseroot"
   echo "directory, because all files in the caseroot dir will be removed"
   echo "before creating the new case.  move the script to a safer place."
   exit -1
endif

echo "removing old files from ${caseroot}"
echo "removing old files from ${exeroot}"
echo "removing old files from ${rundir}"
${REMOVE} ${caseroot}
${REMOVE} ${exeroot}
${REMOVE} ${rundir}

${cesmroot}/scripts/create_newcase -user_mods_dir ${user_mods_dir} -case ${caseroot} -mach ${mach} \
                -res ${resolution} -compset ${compset}

if ( $status != 0 ) then
   echo "ERROR: Case could not be created."
   exit -1
endif

# preserve a copy of this script as it was run
set ThisFileName = $0:t
${COPY} $ThisFileName ${caseroot}/${ThisFileName}.original

cd ${caseroot}

# ==============================================================================
# Record the DARTROOT directory and copy the DART setup script to CASEROOT.
# CESM_DART_config can be run at some later date if desired, but it presumes
# to be run from a CASEROOT directory. If CESM_DART_config does not exist locally,
# then it better exist in the expected part of the DARTROOT tree.
# ==============================================================================

if ( ! -e CESM_DART_config ) then
   ${COPY} ${dartroot}/models/clm/shell_scripts/CESM_DART_config .
endif

if (   -e CESM_DART_config ) then
   sed -e "s#BOGUS_DART_ROOT_STRING#$dartroot#" \
       -e "s#HISTORY_OUTPUT_INTERVAL#$stop_n#" < CESM_DART_config >! temp.$$
   ${MOVE} temp.$$ ${caseroot}/CESM_DART_config
   chmod 755       ${caseroot}/CESM_DART_config
else
   echo "WARNING: the script to configure for data assimilation is not available."
   echo "         CESM_DART_config should be present locally or in"
   echo "         ${dartroot}/models/clm/shell_scripts/"
   echo "         You can stage this script later, but you must manually edit it"
   echo "         to reflect the location of the DART code tree."
endif

# ==============================================================================
# Configure the case.
# ==============================================================================

source ./Tools/ccsm_getenv || exit -2

# MAX_TASKS_PER_NODE comes from $case/Tools/mkbatch.$machine
@ ptile = $MAX_TASKS_PER_NODE / 2
@ nthreads = 1

# Save a copy for debug purposes
foreach FILE ( *xml )
   if ( ! -e        ${FILE}.original ) then
      ${COPY} $FILE ${FILE}.original
   endif
end

@ cpl_pes  = 1
@ atm_pes  = $num_instances
@ ice_pes  = 1
@ lnd_pes  = $num_instances
@ rof_pes  = $num_instances
@ glc_pes  = 1
@ ocn_pes  = 1

echo "task layout"
echo ""
echo "CPL gets $cpl_pes"
echo "ATM gets $atm_pes"
echo "ICE gets $ice_pes"
echo "LND gets $lnd_pes"
echo "ROF gets $rof_pes"
echo "GLC gets $glc_pes"
echo "OCN gets $ocn_pes"
echo ""

./xmlchange NTHRDS_CPL=1,NTASKS_CPL=$cpl_pes
./xmlchange NTHRDS_ATM=1,NTASKS_ATM=$atm_pes,NINST_ATM=$num_instances
./xmlchange NTHRDS_ICE=1,NTASKS_ICE=$ice_pes,NINST_ICE=1
./xmlchange NTHRDS_LND=1,NTASKS_LND=$lnd_pes,NINST_LND=$num_instances
./xmlchange NTHRDS_ROF=1,NTASKS_ROF=$rof_pes,NINST_ROF=$num_instances
./xmlchange NTHRDS_GLC=1,NTASKS_GLC=$glc_pes,NINST_GLC=1
./xmlchange NTHRDS_OCN=1,NTASKS_OCN=$ocn_pes,NINST_OCN=1

./cesm_setup

# http://www.cesm.ucar.edu/models/cesm1.1/cesm/doc/usersguide/c1158.html#run_start_stop
# "A hybrid run indicates that CESM is initialized more like a startup, but uses
# initialization datasets from a previous case. This is somewhat analogous to a
# branch run with relaxed restart constraints. A hybrid run allows users to bring
# together combinations of initial/restart files from a previous case (specified
# by $RUN_REFCASE) at a given model output date (specified by $RUN_REFDATE).
# Unlike a branch run, the starting date of a hybrid run (specified by $RUN_STARTDATE)
# can be modified relative to the reference case. In a hybrid run, the model does not
# continue in a bit-for-bit fashion with respect to the reference case. The resulting
# climate, however, should be continuous provided that no model source code or
# namelists are changed in the hybrid run. In a hybrid initialization, the ocean
# model does not start until the second ocean coupling (normally the second day),
# and the coupler does a "cold start" without a restart file."
#
# The RUN_REFCASE/REFDATE/REFTOD  are used by CLM & RTM to specify the namelist input
# filenames - BUT - their buildnml scripts do not use the INSTANCE, so they all specify
# the same (single) filename. This is remedied by using patched [clm,rtm].buildnml.csh
# scripts that exist in the SourceMods directory.

./xmlchange RUN_TYPE=hybrid
./xmlchange RUN_STARTDATE=${start_year}-${start_month}-${start_day}
./xmlchange START_TOD=$start_tod
./xmlchange RUN_REFCASE=$refcase
./xmlchange RUN_REFDATE=$refdate
./xmlchange RUN_REFTOD=$reftod
./xmlchange BRNCH_RETAIN_CASENAME=FALSE
./xmlchange GET_REFCASE=FALSE
./xmlchange EXEROOT=${exeroot}

./xmlchange DATM_MODE=CLM1PT
./xmlchange DATM_CPLHIST_CASE=$case
./xmlchange DATM_CPLHIST_YR_ALIGN=$stream_year_align
./xmlchange DATM_CPLHIST_YR_START=$stream_year_first
./xmlchange DATM_CPLHIST_YR_END=$stream_year_last

./xmlchange CALENDAR=GREGORIAN

./xmlchange STOP_OPTION=$stop_option
./xmlchange STOP_N=$stop_n
./xmlchange CONTINUE_RUN=FALSE
./xmlchange RESUBMIT=$resubmit

./xmlchange PIO_TYPENAME=pnetcdf

./xmlchange MPILIB=mpich2

# The river transport model ON is useful only when using an active ocean or
# land surface diagnostics. Setting ROF_GRID to 'null' turns off the RTM.
# so we are also turning on the CLM biogeochemistry.

./xmlchange RTM_MODE='NULL'
./xmlchange ROF_GRID='null'

# Turn on BGC
./xmlchange CLM_BLDNML_OPTS='-bgc bgc'

if ($short_term_archiver == 'off') then
   ./xmlchange DOUT_S=FALSE
else
   ./xmlchange DOUT_S=TRUE
   ./xmlchange DOUT_S_ROOT=${archdir}
   ./xmlchange DOUT_S_SAVE_INT_REST_FILES=FALSE
endif
if ($long_term_archiver == 'off') then
   ./xmlchange DOUT_L_MS=FALSE
else
   ./xmlchange DOUT_L_MS=TRUE
   ./xmlchange DOUT_L_MSROOT="csm/${case}"
   ./xmlchange DOUT_L_HTAR=FALSE
endif

# level of debug output, 0=minimum, 1=normal, 2=more, 3=too much, valid values: 0,1,2,3 (integer)

./xmlchange DEBUG=FALSE
./xmlchange INFO_DBUG=0

./preview_namelists

# ==============================================================================
# Edit the run script to reflect queue and wallclock
# ==============================================================================

echo ''
echo 'Updating the run script to set wallclock and queue.'
echo ''

if ( ! -e  ${case}.run.original ) then
   ${COPY} ${case}.run ${case}.run.original
endif

source Tools/ccsm_getenv
set BATCH = `echo $BATCHSUBMIT | sed 's/ .*$//'`
switch ( $BATCH )
   case bsub*:
      # NCAR "bluefire", "yellowstone"
      set TIMEWALL=`grep BSUB ${case}.run | grep -e '-W' `
      set    QUEUE=`grep BSUB ${case}.run | grep -e '-q' `
      sed -e "s/$TIMEWALL[3]/$timewall/" \
          -e "s/ptile=[0-9][0-9]*/ptile=$ptile/" \
          -e "s/$QUEUE[3]/$queue/" < ${case}.run >! temp.$$
          ${MOVE} temp.$$ ${case}.run
          chmod 755       ${case}.run
   breaksw

   default:

   breaksw
endsw

# ==============================================================================
# Update source files.
#    Ideally, using DART would not require any modifications to the model source.
#    Until then, this script accesses sourcemods from a hardwired location.
#    If you have additional sourcemods, they will need to be merged into any DART
#    mods and put in the SourceMods subdirectory found in the 'caseroot' directory.
# ==============================================================================

if (    -d     ~/${cesmtag}/SourceMods ) then
   ${COPY} -r  ~/${cesmtag}/SourceMods/* ${caseroot}/SourceMods/
else
   echo "ERROR - No SourceMods for this case."
   echo "ERROR - No SourceMods for this case."
   echo "DART requires modifications to several src files."
   echo "These files can be downloaded from:"
   echo "http://www.image.ucar.edu/pub/DART/CESM/DART_SourceMods_cesm1_1_1_24Oct2013.tar"
   echo "untar these into your HOME directory - they will create a"
   echo "~/cesm_1_1_1  directory with the appropriate SourceMods structure."
   exit -4
endif

# The CESM multi-instance capability is relatively new and still has a few
# implementation bugs. These are known problems and will be fixed soon.
# this should be removed when the files are fixed:

echo "REPLACING BROKEN CESM FILES HERE - SHOULD BE REMOVED WHEN FIXED"
echo caseroot is ${caseroot}
if ( -d ~/${cesmtag} ) then

   # preserve the original version of the files
   if ( ! -e  ${caseroot}/Buildconf/clm.buildnml.csh.original ) then
      ${COPY} ${caseroot}/Buildconf/clm.buildnml.csh \
              ${caseroot}/Buildconf/clm.buildnml.csh.original
   endif
   if ( ! -e  ${caseroot}/preview_namelists.original ) then
      ${COPY} ${caseroot}/preview_namelists \
              ${caseroot}/preview_namelists.original
   endif

   # patch/replace the broken files
#   ${COPY} ~/${cesmtag}/clm.buildnml.csh  ${caseroot}/Buildconf/.
#   ${COPY} ~/${cesmtag}/preview_namelists ${caseroot}/.

endif

# ==============================================================================
# Modify namelist templates for each instance.
#
# In a hybrid run with CONTINUE_RUN = FALSE (i.e. just starting up):
#
# CLM builds its own 'finidat' value from the REFCASE variables but in CESM1_1_1
#     it does not use the instance string. There is a patch for clm.buildnml.csh
#
# All of these must later on be staged with these same filenames.
# OR - all these namelists can be changed to match whatever has been staged.
# MAKE SURE THE STAGING SECTION OF THIS SCRIPT MATCHES THESE VALUES.
# ==============================================================================

@ inst = 1
while ($inst <= $num_instances)

   # following the CESM strategy for 'inst_string'
   set inst_string = `printf _%04d $inst`

   # ===========================================================================
   set fname = "user_nl_datm${inst_string}"
   # ===========================================================================
   # DATM Namelist

   echo "dtlimit  = 1.5, 1.5, 1.5"                    >> ${fname}
   echo "fillalgo = 'nn', 'nn', 'nn'"                 >> ${fname}
   echo "fillmask = 'nomask','nomask','nomask'"       >> ${fname}
   echo "mapalgo  = 'bilinear','bilinear','bilinear'" >> ${fname}
   echo "mapmask  = 'nomask','nomask','nomask'"       >> ${fname}
   echo "streams  = 'datm.streams.txt.CLM1PT.CLM_USRDAT.Solar${inst_string}             $stream_year_align $stream_year_first $stream_year_last'," >> ${fname}
   echo "           'datm.streams.txt.CLM1PT.CLM_USRDAT.Precip${inst_string}            $stream_year_align $stream_year_first $stream_year_last'," >> ${fname}
   echo "           'datm.streams.txt.CLM1PT.CLM_USRDAT.nonSolarNonPrecip${inst_string} $stream_year_align $stream_year_first $stream_year_last'"  >> ${fname}
   echo "taxmode  = 'cycle','cycle','cycle'"          >> ${fname}
   echo "tintalgo = 'coszen','nearest','linear'"      >> ${fname}
   echo "restfils = 'unset'"                          >> ${fname}
   echo "restfilm = 'unset'"                          >> ${fname}

   # ===========================================================================
   set fname = "user_nl_clm${inst_string}"
   # ===========================================================================
   # LAND namelist
   # With a RUN_TYPE=hybrid the finidat is automatically specified
   # using the REFCASE/REFDATE/REFTOD information. i.e.
   # finidat = ${stagedir}/${refcase}.clm2${inst_string}.r.${reftimestamp}.nc
   #
   # This is the time to consider how DART and CESM will interact.  If you intend
   # on assimilating flux tower observations (nominally at 30min intervals),
   # then it is required to create a .h1. file with the instantaneous flux
   # variables every 30 minutes. Despite being in a namelist, these values
   # HAVE NO EFFECT once CONTINUE_RUN = TRUE so now is the time to set these.
   #
   # See page 65 of:
   # http://www.cesm.ucar.edu/models/cesm1.1/clm/models/lnd/clm/doc/UsersGuide/clm_ug.pdf
   #
   # DART's forward observation operators for these fluxes just reads them
   # from the .h1. file rather than trying to create them from the subset of
   # CLM variables that are available in the DART state vector. We have a terrible
   # time trying to predict the .h1. filename given only current model time.
   # DART does not read the clm namelist input that has this information, and
   # since it is in a namelist - it can change during the course of a run - BUT
   # as discussed above, only the first settings are important. Tricky.
   #
   # For a HOP TEST ... hist_empty_htapes = .false.
   # For a HOP TEST ... use a default hist_fincl1

#   echo "dtime             = $clm_dtime,"             >> ${fname}
   echo "hist_empty_htapes = .false.,"                >> ${fname}
#   echo "hist_fincl1 = 'NEP',"                        >> ${fname}
   echo "hist_fincl2 = 'NEP','FSH','EFLX_LH_TOT_R',"  >> ${fname}
   echo "hist_nhtfrq = -24,1"                   >> ${fname}
   echo "hist_mfilt  = 100,4800"                  >> ${fname}
#   echo "hist_avgflag_pertape = 'A','A'"              >> ${fname}
   echo "fsurdat = '/glade/p/work/afox/clm4_5_74/models/lnd/clm/tools/shared/PTCLM/mydatafiles/1x1pt_${site}/surfdata_1x1pt_${site}_simyr2000_clm4_5_c${filedate}.nc'"     >> ${fname}
   @ inst ++
end

# ==============================================================================
# to create custom streamfiles ...
# "To modify the contents of a stream txt file, first use preview_namelists to
#  obtain the contents of the stream txt files in CaseDocs, and then place a copy
#  of the modified stream txt file in $CASEROOT with the string user_ prepended."
#
# -or-
#
# we copy a template stream txt file from the
# $dartroot/models/clm/shell_scripts directory and modify one for each instance.
#
# ==============================================================================

./preview_namelists

# rm -rf *CLM_USRDAT*
# rm -rf CaseDocs/*CLM_USRDAT*

# This gives us a stream txt file for each instance that we can
# modify for our own purpose.

foreach FILE (CaseDocs/*streams*)
   set FNAME = $FILE:t

   switch ( ${FNAME} )
      case *presaero*:
         echo "Using default prescribed aerosol stream.txt file ${FNAME}"
         breaksw
      case *diatren*:
         echo "Using default runoff stream.txt file ${FNAME}"
         breaksw
      default:
         ${COPY} $FILE user_${FNAME}
         chmod   644   user_${FNAME}
         breaksw
   endsw

end

# Replace each default stream txt file with one that uses the CAM DATM
# conditions for a default year and modify the instance number.

foreach FNAME (user*streams*)
   set name_parse = `echo ${FNAME} | sed 's/\_/ /g'`
   @ instance_index = $#name_parse
   @ filename_index = $#name_parse - 1
   set streamname = $name_parse[$filename_index]
   set   instance = $name_parse[$instance_index]

echo "name_parse" $name_parse
echo "streamname" $streamname
echo "dartroot" $dartroot

foreach FILE ($dartroot/models/clm/shell_scripts/datm.stream*$streamname*)
   set FNAME2 = $FILE:t

      echo "Copying DART template for ${FNAME} and changing instances, runyear"

      ${COPY} $dartroot/models/clm/shell_scripts/${FNAME2} ${FNAME2}_$instance

      sed s/NINST/$instance/g ${FNAME2}_$instance >! out.$$
      sed s/NEON/$neon_site/g   out.$$ >! out2.$$
      sed s/FILEDATE/$filedate/g out2.$$ >! out3.$$
      sed s/AMERI/$ptclm_site/g out3.$$ >! ${FNAME2}_$instance
      \rm -f ou*.$$

      ${COPY} ${FNAME2}_$instance ${rundir} 

end

end

# ==============================================================================
# Stage the restarts now that the run directory exists
# ==============================================================================

set init_time = ${reftimestamp}

cat << EndOfText >! stage_cesm_files
#!/bin/csh -f
# This script can be used to help restart an experiment from any previous step.
# The appropriate files are copied to the RUN directory.
#
# Before running this script:
#  1) be sure CONTINUE_RUN is set correctly in the env_run.xml file in
#     your CASEROOT directory.
#     CONTINUE_RUN=FALSE => you are starting over at the initial time.
#     CONTINUE_RUN=TRUE  => you are starting from a previous step but not
#                           the very first one.
#  2) be sure 'restart_time' is set to the day and time that you want to
#     restart from if not the initial time.

set restart_time = $init_time


# get the settings for this case from the CESM environment
cd ${caseroot}
source ./Tools/ccsm_getenv || exit -2
cd ${RUNDIR}

echo 'Copying the required CESM files to the run directory to rerun'
echo 'a previous step.  CONTINUE_RUN from env_run.xml is' \$CONTINUE_RUN
if ( \$CONTINUE_RUN == TRUE ) then
  echo 'so files for some later step than the initial one will be restaged.'
  echo "Date to reset files to is: \$restart_time"
else
  echo 'so files for the initial step of this experiment will be restaged.'
  echo "Date to reset files to is: $init_time"
endif
echo ''


if ( \$CONTINUE_RUN == TRUE ) then

   #----------------------------------------------------------------------
   # This block copies over a set of restart files from any previous step of
   # the experiment that is NOT the initial step.
   # After running this script resubmit the job to rerun.
   #----------------------------------------------------------------------

   echo "Staging restart files for run date/time: " \$restart_time

   #  The short term archiver is on, so the files we want should be in one
   #  of the short term archive 'rest' restart directories.  This assumes
   #  the long term archiver has NOT copied these files to the HPSS yet.

   if (  \$DOUT_S   == TRUE ) then

      # The restarts should be in the short term archive directory.  See
      # www.cesm.ucar.edu/models/cesm1.1/cesm/doc/usersguide/x1631.html#running_ccsm_restart_back
      # for more help and information.

      if ( ! -d \$DOUT_S_ROOT/rest/\${restart_time} ) then

         echo "restart file directory not found: "
         echo " \$DOUT_S_ROOT/rest/\${restart_time} "
         echo "If the long-term archiver is on, you may have to restore this directory first."
         echo "You can also check for either a .sta or a .sta2 hidden subdirectory in"
         echo \$DOUT_S_ROOT
         echo "which may contain the 'rest' directory you need."
         exit -1

      endif

      ${COPY} \$DOUT_S_ROOT/rest/\${restart_time}/* . || exit -1

   else

      # The short term archiver is off, which leaves all the restart files
      # in the run directory.  The rpointer files must still be updated to
      # point to the files with the right day/time.

      @ inst=1
      while (\$inst <= $num_instances)

         set inst_string = \`printf _%04d \$inst\`

         echo "${case}.clm2\${inst_string}.r.\${restart_time}.nc"   >! rpointer.lnd\${inst_string}
         echo "${case}.datm\${inst_string}.r.\${restart_time}.nc"   >! rpointer.atm\${inst_string}
         echo "${case}.datm\${inst_string}.rs1.\${restart_time}.nc" >> rpointer.atm\${inst_string}

         @ inst ++
      end

      # There is only a single coupler restart file even in the multi-instance case.
      echo "${case}.cpl.r.\${restart_time}.nc" >! rpointer.drv

   endif

   echo "All files reset to rerun experiment step for time " \$restart_time

else     # CONTINUE_RUN == FALSE

   #----------------------------------------------------------------------
   # This block links the right files to rerun the initial (very first)
   # step of an experiment.  The names and locations are set during the
   # building of the case; to change them rebuild the case.
   # After running this script resubmit the job to rerun.
   #----------------------------------------------------------------------

   @ inst=1
   while (\$inst <= $num_instances)

      set inst_string = \`printf _%04d \$inst\`

      echo "Staging initial files for instance \$inst of $num_instances"

      ${LINK} ${stagedir}/${refcase}.clm2\${inst_string}.r.${init_time}.nc .

      @ inst ++
   end

   echo "All files set to run the FIRST experiment step at time" $init_time

endif
exit 0

EndOfText
chmod 0755 stage_cesm_files

./stage_cesm_files

# ==============================================================================
# build
# ==============================================================================

exit

echo ''
echo 'Building the case'
echo ''

./${case}.build

if ( $status != 0 ) then
   echo "ERROR: Case could not be built."
   exit -5
endif

# ==============================================================================
# What to do next
# ==============================================================================

echo ""
echo "Time to check the case."
echo ""
echo "1) cd ${rundir}"
echo "   and check the compatibility between the namelists/pointer"
echo "   files and the files that were staged."
echo ""
echo "2) cd ${caseroot}"
echo "   (on yellowstone) If the ${case}.run script still contains:"
echo '   #BSUB -R "select[scratch_ok > 0]"'
echo "   around line 9, delete it."
echo ""
echo "3) The case is initially configured to do NO ASSIMILATION."
echo "   When you are ready to add data assimilation, configure and execute"
echo "   the ${caseroot}/CESM_DART_config script."
echo ""
echo "4) Verify the contents of env_run.xml and submit the CESM job:"
echo "   ./${case}.submit"
echo ""
echo "5) After the job has run, check to make sure it worked."
echo ""
echo "6) To extend the run in $stop_n '"$stop_option"' steps,"
echo "   change the env_run.xml variables:"
echo ""
echo "   ./xmlchange CONTINUE_RUN=TRUE"
echo "   ./xmlchange RESUBMIT=<number_of_cycles_to_run>"
echo ""
echo "   and"
echo "   ./${case}.submit"
echo ""
echo "Check the streams listed in the streams text files.  If more or different"
echo 'dates need to be added, then do this in the $CASEROOT/user_*files*'
echo "then invoke 'preview_namelists' so you can check the information in the"
echo "CaseDocs or ${rundir} directories."
echo ""

exit 0

# <next few lines under version control, do not edit>
# $URL$
# $Revision$
# $Date$
