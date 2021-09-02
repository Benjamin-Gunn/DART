#!/bin/csh
#
# DART software - Copyright UCAR. This open source software is provided
# by UCAR, "as is", without charge, subject to all terms of use at
# http://www.image.ucar.edu/DAReS/DART/DART_download
#
# DART $Id: convert_many_gpsro.csh 12575 2018-05-03 22:30:00Z thoar@ucar.edu $
#
# this script loops over days, calling the AIRS convert script
# once per day.  it can roll over month and year boundaries.
#
# it can download data on demand from the AIRS web site,
# convert it, and delete it, or any combination of these
# three functions, depending on need.  e.g. if the data is
# already downloaded, it can just convert.  it can download
# and convert and not delete until the results are checked
# and then in a second pass just delete, etc, etc.
#
# this script requires the executable 'advance_time' to be
# built and exist in the current directory, and advance_time
# requires a minimal input.nml namelist file (empty &utilities_nml only).
#
# this script constructs the arguments needed for the script that
# is doing all the "real" work:  convert_airs_L2.csh
# see that script for details of what is involved in doing
# the actual conversion.
# 
# -------------------
#
# if you want to submit this as a batch job:
#
# -------------------
# SLURM directives             sbatch script.csh
#
# sinfo     information about the whole slurm system
# squeue    information about running jobs
# sbatch    submit a job
# scancel   kill a job
#
#SBATCH --ignore-pbs
#SBATCH --job-name=AIRSobs1
#SBATCH -n 1
#SBATCH --ntasks-per-node=8
#SBATCH --time=00:10:00
#SBATCH -A p86850054
#SBATCH -p dav
#SBATCH -C caldera
#SBATCH -e AIRSobs1.%j.err
#SBATCH -o AIRSobs1.%j.out
#
# -------------------
# PBS directives                qsub script.csh
#
# qstat    information on running jobs
# qsub     submit a job
# qdel     kill a job
# qpeek    see output from a running job
#
#PBS -N AIRSobs1
#PBS -l walltime=04:00:00
#PBS -q share
#PBS -l select=1:ncpus=1:mpiprocs=1
#PBS -A p86850054
#
# -------------------
# LSF directives                bsub < script.csh
#
# bstat    information on running jobs
# bsub     submit a job
# bdel     kill a job
# bpeek    see output from a running job
#
#BSUB -J AIRSobs1
#BSUB -o AIRSobs1.%J.log
#BSUB -q small
#BSUB -n 16
#BSUB -W 0:10:00
#BSUB -P p86850054
#
# -------------------

setenv TMPDIR /glade/scratch/$USER/temp
mkdir -p $TMPDIR

# -------------------
# -------------------

# start of things you should have to set in this script

# set the first and last days.  can roll over month and year boundaries.
set start_year=2010
set start_month=6
set start_day=30

set end_year=2010
set end_month=8
set end_day=2


# for each day: 
#  download the data from the web site or not, 
#  convert to daily obs_seq files or not, and 
#  delete the data files after conversion or not.

set do_download = 'no'
set do_convert  = 'yes'
set do_delete   = 'no'

# where to download the data and do the conversions, relative to
# this shell_scripts directory.

set datadir = ../output_daily

# end of things you should have to set in this script

# -------------------
# -------------------

# make sure there is a working advance_time 
# and minimal namelist here.

if ( ! -f advance_time) then
  ln -sf ../work/advance_time .
endif
if ( ! -f input.nml ) then
  echo \&utilities_nml > input.nml
  echo / >> input.nml
endif


# convert the start and stop times to gregorian days, so we can
# compute total number of days including rolling over month and
# year boundaries.  make sure all values have leading 0s if they
# are < 10.  do the end time first so we can use the same values
# to set the initial day while we are doing the total day calc.

# the output of advance time with the -g input is:
#   gregorian_day_number  seconds
# use $var[1] to return just the day number

set mon2=`printf %02d $end_month`
set day2=`printf %02d $end_day`
set end_d=(`echo ${end_year}${mon2}${day2}00 0 -g | ./advance_time`)

set mon2=`printf %02d $start_month`
set day2=`printf %02d $start_day`
set start_d=(`echo ${start_year}${mon2}${day2}00 0 -g | ./advance_time`)

# the output of this call is a string YYYYMMDDHH
# see below for help in how to easily parse this up into words
set curday=`echo ${start_year}${mon2}${day2}00 0 | ./advance_time`

# how many total days are going to be processed (for the loop counter)
# note that the parens below are necessary; otherwise the computation
# does total = end - (start+1), or total = end - start - 1, which is
# not how elementary math is supposed to work.
@ totaldays = ( $end_d[1] - $start_d[1] ) + 1

# loop over each day
set d=1
while ( $d <= $totaldays )

  # parse out the parts from a string which is YYYYMMDDHH
  # use cut with the byte option to pull out columns 1-4, 5-6, and 7-8
  set  year=`echo $curday | cut -b1-4`
  set month=`echo $curday | cut -b5-6`
  set   day=`echo $curday | cut -b7-8`

  # compute the equivalent gregorian day here.
  set g=(`echo ${year}${month}${day}00 0 -g | ./advance_time`)
  set greg=$g[1]

  # status/debug - comment in or out as desired.
  echo starting processing for $year $month $day
  #echo which is gregorian day: $greg

  # use $year, $month, $day, and $greg as needed.
  # month, day have leading 0s if needed so they are always 2 digits

  # THE WORK HAPPENS HERE:  call the convert script for each day.

  ./convert_airs_L2.csh ${year}${month}${day} $datadir \
                         $do_download $do_convert $do_delete 

  #  if you want to do multiple conversions at a time, they have to
  #  be in different subdirectories - add the year/month to the end
  #  of the datadir.
  # 
  #./convert_airs_L2.csh ${year}${month}${day} $datadir/${year}${month} \
  #                       $do_download $do_convert $do_delete 
  #

  # advance the day; the output is YYYYMMDD00
  set curday=`echo ${year}${month}${day}00 +1d | ./advance_time`

  # advance the loop counter
  @ d++
 
end

exit 0

# <next few lines under version control, do not edit>
# $URL: https://svn-dares-dart.cgd.ucar.edu/DART/branches/rma_trunk/observations/obs_converters/gps/shell_scripts/convert_many_gpsro.csh $
# $Revision: 12575 $
# $Date: 2018-05-03 16:30:00 -0600 (Thu, 03 May 2018) $

