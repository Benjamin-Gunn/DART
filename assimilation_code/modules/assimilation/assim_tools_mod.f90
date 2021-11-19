! DART software - Copyright UCAR. This open source software is provided
! by UCAR, "as is", without charge, subject to all terms of use at
! http://www.image.ucar.edu/DAReS/DART/DART_download

!>  A variety of operations required by assimilation.
module assim_tools_mod

!> \defgroup assim_tools assim_tools_mod
!>
!> @{
use      types_mod,       only : r8, i8, digits12, PI, missing_r8

use    options_mod,       only : get_missing_ok_status

use  utilities_mod,       only : file_exist, get_unit, check_namelist_read, do_output,    &
                                 find_namelist_in_file, error_handler,   &
                                 E_ERR, E_MSG, nmlfileunit, do_nml_file, do_nml_term,     &
                                 open_file, close_file, timestamp
use       sort_mod,       only : index_sort 
use random_seq_mod,       only : random_seq_type, random_gaussian, init_random_seq,       &
                                 random_uniform

use obs_sequence_mod,     only : obs_sequence_type, obs_type, get_num_copies, get_num_qc, &
                                 init_obs, get_obs_from_key, get_obs_def, get_obs_values, &
                                 destroy_obs

use          obs_def_mod, only : obs_def_type, get_obs_def_location, get_obs_def_time,    &
                                 get_obs_def_error_variance, get_obs_def_type_of_obs

use         obs_kind_mod, only : get_num_types_of_obs, get_index_for_type_of_obs,                   &
                                 get_quantity_for_type_of_obs, assimilate_this_type_of_obs

use       cov_cutoff_mod, only : comp_cov_factor

use       reg_factor_mod, only : comp_reg_factor

use       obs_impact_mod, only : allocate_impact_table, read_impact_table, free_impact_table

use sampling_error_correction_mod, only : get_sampling_error_table_size, &
                                          read_sampling_error_correction

use         location_mod, only : location_type, get_close_type, query_location,           &
                                 operator(==), set_location_missing, write_location,      &
                                 LocationDims, is_vertical, vertical_localization_on,     &
                                 set_vertical, has_vertical_choice, get_close_init,       &
                                 get_vertical_localization_coord, get_close_destroy,      &
                                 set_vertical_localization_coord

use ensemble_manager_mod, only : ensemble_type, get_my_num_vars, get_my_vars,             &
                                 compute_copy_mean_var, get_var_owner_index,              &
                                 prepare_to_update_copies, map_pe_to_task

use mpi_utilities_mod,    only : my_task_id, broadcast_send, broadcast_recv,              &
                                 sum_across_tasks, task_count, start_mpi_timer,           &
                                 read_mpi_timer, task_sync

use adaptive_inflate_mod, only : do_obs_inflate,  do_single_ss_inflate, do_ss_inflate,    &
                                 do_varying_ss_inflate,                                   &
                                 update_inflation, update_single_state_space_inflation,   &
                                 update_varying_state_space_inflation,                    &
                                 inflate_ens, adaptive_inflate_type,                      &
                                 deterministic_inflate, solve_quadratic

use time_manager_mod,     only : time_type, get_time

use assim_model_mod,      only : get_state_meta_data,                                     &
                                 get_close_obs,         get_close_state,                  &
                                 convert_vertical_obs,  convert_vertical_state

use distributed_state_mod, only : create_mean_window, free_mean_window

use quality_control_mod, only : good_dart_qc, DARTQC_FAILED_VERT_CONVERT

implicit none
private

public :: filter_assim, &
          set_assim_tools_trace, &
          test_state_copies

! Indicates if module initialization subroutine has been called yet
logical :: module_initialized = .false.

! Saves the ensemble size used in the previous call of obs_inc_bounded_norm_rhf
integer :: bounded_norm_rhf_ens_size = -99

integer :: print_timestamps    = 0
integer :: print_trace_details = 0

! True if random sequence needs to be initialized
logical                :: first_inc_ran_call = .true.
type (random_seq_type) :: inc_ran_seq

integer                :: num_types = 0
real(r8), allocatable  :: cutoff_list(:)
logical                :: has_special_cutoffs
logical                :: close_obs_caching = .true.
real(r8), parameter    :: small = epsilon(1.0_r8)   ! threshold for avoiding NaNs/Inf

! true if we have multiple vert choices and we're doing vertical localization
! (make it a local variable so we don't keep making subroutine calls)
logical                :: is_doing_vertical_conversion = .false.

character(len=512)     :: msgstring, msgstring2, msgstring3

! Need to read in table for off-line based sampling correction and store it
integer                :: sec_table_size
real(r8), allocatable  :: exp_true_correl(:), alpha(:)

! if adjust_obs_impact is true, read in triplets from the ascii file
! and fill this 2d impact table.
real(r8), allocatable  :: obs_impact_table(:,:)

character(len=*), parameter :: source = 'assim_tools_mod.f90'

!============================================================================

!---- namelist with default values

! Filter kind selects type of observation space filter
!      1 = EAKF filter
!      2 = ENKF
!      3 = Kernel filter
!      4 = particle filter
!      5 = random draw from posterior
!      6 = deterministic draw from posterior with fixed kurtosis
!      8 = Rank Histogram Filter (see Anderson 2011)
!
!  special_localization_obs_types -> Special treatment for the specified observation types
!  special_localization_cutoffs   -> Different cutoff value for each specified obs type
!
integer  :: filter_kind                     = 1
real(r8) :: cutoff                          = 0.2_r8
logical  :: sort_obs_inc                    = .false.
logical  :: spread_restoration              = .false.
logical  :: sampling_error_correction       = .false.
integer  :: adaptive_localization_threshold = -1
real(r8) :: adaptive_cutoff_floor           = 0.0_r8
integer  :: print_every_nth_obs             = 0

! since this is in the namelist, it has to have a fixed size.
integer, parameter   :: MAX_ITEMS = 300
character(len = 129) :: special_localization_obs_types(MAX_ITEMS)
real(r8)             :: special_localization_cutoffs(MAX_ITEMS)

logical              :: output_localization_diagnostics = .false.
character(len = 129) :: localization_diagnostics_file = "localization_diagnostics"

! Following only relevant for filter_kind = 8
logical  :: rectangular_quadrature          = .true.
logical  :: gaussian_likelihood_tails       = .false.

! False by default; if true, expect to read in an ascii table
! to adjust the impact of obs on other state vector and obs values.
logical            :: adjust_obs_impact  = .false.
character(len=256) :: obs_impact_filename = ''
logical            :: allow_any_impact_values = .false.

! These next two only affect models with multiple options
! for vertical localization:
!
! "convert_state" is false by default; it depends on the model
! what is faster - do the entire state up front and possibly
! do unneeded work, or do the conversion during the assimilation
! loop. we think this depends heavily on how much of the state
! is going to be adjusted by the obs.  for a global model
! we think false may be better; for a regional model with
! a lot of obs and full coverage true may be better.
!
! "convert_obs" is true by default; in general it seems to
! be better for each task to convert the obs vertical before
! going into the loop but again this depends on how many
! obs per task and whether the mean is distributed or
! replicated on each task.
logical :: convert_all_state_verticals_first = .false.
logical :: convert_all_obs_verticals_first   = .true.

! Not in the namelist; this var disables the experimental
! linear and spherical case code in the adaptive localization
! sections.  to try out the alternatives, set this to .false.
logical  :: only_area_adapt  = .true.

! Option to distribute the mean.  If 'false' each task will have a full
! copy of the ensemble mean, which speeds models doing vertical conversion.
! If 'true' the mean will be spread across all tasks which reduces the
! memory needed per task but requires communication if the mean is used
! for vertical conversion.  We have changed the default to be .false.
! compared to previous versions of this namelist item.
logical  :: distribute_mean  = .false.

namelist / assim_tools_nml / filter_kind, cutoff, sort_obs_inc, &
   spread_restoration, sampling_error_correction,                          &
   adaptive_localization_threshold, adaptive_cutoff_floor,                 &
   print_every_nth_obs, rectangular_quadrature, gaussian_likelihood_tails, &
   output_localization_diagnostics, localization_diagnostics_file,         &
   special_localization_obs_types, special_localization_cutoffs,           &
   distribute_mean, close_obs_caching,                                     &
   adjust_obs_impact, obs_impact_filename, allow_any_impact_values,        &
   convert_all_state_verticals_first, convert_all_obs_verticals_first

!============================================================================

contains

!-------------------------------------------------------------

subroutine assim_tools_init()

integer :: iunit, io, i, j
integer :: num_special_cutoff, type_index
logical :: cache_override = .false.


! do this up front
module_initialized = .true.

! give these guys initial values at runtime *before* we read
! in the namelist.  this is to help detect how many items are
! actually given in the namelist.
special_localization_obs_types(:)  = 'null'
special_localization_cutoffs(:)    =  missing_r8

! Read the namelist entry
call find_namelist_in_file("input.nml", "assim_tools_nml", iunit)
read(iunit, nml = assim_tools_nml, iostat = io)
call check_namelist_read(iunit, io, "assim_tools_nml")

! Write the namelist values to the log file
if (do_nml_file()) write(nmlfileunit, nml=assim_tools_nml)
if (do_nml_term()) write(     *     , nml=assim_tools_nml)

! Forcing distributed_mean for single processor.
! Note null_win_mod.f90 ignores distibute_mean.
if (task_count() == 1) distribute_mean = .true.

! FOR NOW, can only do spread restoration with filter option 1 (need to extend this)
if(spread_restoration .and. .not. filter_kind == 1) then
   write(msgstring, *) 'cannot combine spread_restoration and filter_kind ', filter_kind
   call error_handler(E_ERR,'assim_tools_init:', msgstring, source)
endif

! allocate a list in all cases - even the ones where there is only
! a single cutoff value.  note that in spite of the name these
! are specific types (e.g. RADIOSONDE_TEMPERATURE, AIRCRAFT_TEMPERATURE)
! because that's what get_close() is passed.   and because i've confused
! myself several times -- we define generic kinds starting at 0, but
! the specific types are autogenerated and always start at 1.  so the
! cutoff list is never (0:num_types); it is always (num_types).
num_types = get_num_types_of_obs()
allocate(cutoff_list(num_types))
cutoff_list(:) = cutoff
has_special_cutoffs = .false.

! Go through special-treatment observation kinds, if any.
num_special_cutoff = 0
j = 0
do i = 1, MAX_ITEMS
   if(special_localization_obs_types(i) == 'null') exit
   if(special_localization_cutoffs(i) == MISSING_R8) then
      write(msgstring, *) 'cutoff value', i, ' is uninitialized.'
      call error_handler(E_ERR,'assim_tools_init:', &
                         'special cutoff namelist for types and distances do not match', &
                         source, &
                         text2='kind = '//trim(special_localization_obs_types(i)), &
                         text3=trim(msgstring))
   endif
   j = j + 1
enddo
num_special_cutoff = j

if (num_special_cutoff > 0) has_special_cutoffs = .true.

do i = 1, num_special_cutoff
   type_index = get_index_for_type_of_obs(special_localization_obs_types(i))
   if (type_index < 0) then
      write(msgstring, *) 'unrecognized TYPE_ in the special localization namelist:'
      call error_handler(E_ERR,'assim_tools_init:', msgstring, source, &
                         text2=trim(special_localization_obs_types(i)))
   endif
   cutoff_list(type_index) = special_localization_cutoffs(i)
end do

! cannot cache previous obs location if different obs types have different
! localization radii.  change it to false, and warn user why.
if (has_special_cutoffs .and. close_obs_caching) then
   cache_override = .true.
   close_obs_caching = .false.
endif

if(sampling_error_correction) then
   sec_table_size = get_sampling_error_table_size()
   allocate(exp_true_correl(sec_table_size), alpha(sec_table_size))
   ! we can't read the table here because we don't have access to the ens_size
endif

is_doing_vertical_conversion = (has_vertical_choice() .and. vertical_localization_on())

call log_namelist_selections(num_special_cutoff, cache_override)

end subroutine assim_tools_init

!-------------------------------------------------------------

subroutine filter_assim(ens_handle, obs_ens_handle, obs_seq, keys,           &
   ens_size, num_groups, obs_val_index, inflate, ENS_MEAN_COPY, ENS_SD_COPY, &
   ENS_INF_COPY, ENS_INF_SD_COPY, OBS_KEY_COPY, OBS_GLOBAL_QC_COPY,          &
   OBS_PRIOR_MEAN_START, OBS_PRIOR_MEAN_END, OBS_PRIOR_VAR_START,            &
   OBS_PRIOR_VAR_END, inflate_only)

type(ensemble_type),         intent(inout) :: ens_handle, obs_ens_handle
type(obs_sequence_type),     intent(in)    :: obs_seq
integer,                     intent(in)    :: keys(:)
integer,                     intent(in)    :: ens_size, num_groups, obs_val_index
! JLA: At present, this only needs to be inout because of the possible use of
! non-determinstic obs_space adaptive inflation that is not currently supported.
! Implementing that would require communication of the info about the inflation
! values as each observation updated them.
type(adaptive_inflate_type), intent(inout) :: inflate
integer,                     intent(in)    :: ENS_MEAN_COPY, ENS_SD_COPY, ENS_INF_COPY
integer,                     intent(in)    :: ENS_INF_SD_COPY
integer,                     intent(in)    :: OBS_KEY_COPY, OBS_GLOBAL_QC_COPY
integer,                     intent(in)    :: OBS_PRIOR_MEAN_START, OBS_PRIOR_MEAN_END
integer,                     intent(in)    :: OBS_PRIOR_VAR_START, OBS_PRIOR_VAR_END
logical,                     intent(in)    :: inflate_only

! changed the ensemble sized things here to allocatable

real(r8) :: obs_prior(ens_size), obs_inc(ens_size), updated_ens(ens_size)
real(r8) :: orig_obs_likelihood(ens_size)
real(r8) :: final_factor
real(r8) :: net_a(num_groups), correl(num_groups)
real(r8) :: obs(1), obs_err_var, my_inflate, my_inflate_sd
real(r8) :: obs_qc, cutoff_rev, cutoff_orig
real(r8) :: orig_obs_prior(ens_size)
real(r8) :: orig_obs_prior_mean(num_groups), orig_obs_prior_var(num_groups)
real(r8) :: obs_prior_mean(num_groups), obs_prior_var(num_groups)
real(r8) :: vertvalue_obs_in_localization_coord, whichvert_real
real(r8), allocatable :: close_obs_dist(:)
real(r8), allocatable :: close_state_dist(:)
real(r8), allocatable :: last_close_obs_dist(:)
real(r8), allocatable :: last_close_state_dist(:)
real(r8), allocatable :: all_my_orig_obs_priors(:, :)
real(r8), allocatable :: state_likelihood(:, :), prior_state_mass(:, :), prior_state_ens(:, :)

integer(i8) :: state_index
integer(i8), allocatable :: my_state_indx(:)
integer(i8), allocatable :: my_obs_indx(:)
integer,     allocatable :: prior_state_index_sort(:, :)

integer :: my_num_obs, i, j, owner, owners_index, my_num_state
integer :: obs_mean_index, obs_var_index
integer :: grp_beg(num_groups), grp_end(num_groups), grp_size, grp_bot, grp_top, group
integer :: num_close_obs, obs_index, num_close_states
integer :: last_num_close_obs, last_num_close_states
integer :: base_obs_kind, base_obs_type, nth_obs
integer :: num_close_obs_cached, num_close_states_cached
integer :: num_close_obs_calls_made, num_close_states_calls_made
integer :: whichvert_obs_in_localization_coord
integer :: istatus, localization_unit
integer, allocatable :: close_obs_ind(:)
integer, allocatable :: close_state_ind(:)
integer, allocatable :: last_close_obs_ind(:)
integer, allocatable :: last_close_state_ind(:)
integer, allocatable :: my_obs_kind(:)
integer, allocatable :: my_obs_type(:)
integer, allocatable :: my_state_kind(:)
integer, allocatable :: vstatus(:)

type(location_type)  :: base_obs_loc, last_base_obs_loc, last_base_states_loc
type(location_type)  :: dummyloc
type(location_type), allocatable :: my_obs_loc(:)
type(location_type), allocatable :: my_state_loc(:)

type(get_close_type) :: gc_obs, gc_state
type(obs_type)       :: observation
type(obs_def_type)   :: obs_def
type(time_type)      :: obs_time

logical :: allow_missing_in_state
logical :: local_single_ss_inflate
logical :: local_varying_ss_inflate
logical :: local_ss_inflate
logical :: local_obs_inflate

integer, allocatable :: n_close_state_items(:), n_close_obs_items(:)

! Just to make sure multiple tasks are running for tests
write(*, *) 'my_task_id ', my_task_id()

! how about this?  look for imbalances in the tasks
allocate(n_close_state_items(obs_ens_handle%num_vars), &
         n_close_obs_items(  obs_ens_handle%num_vars))

! allocate rather than dump all this on the stack
allocate(close_obs_dist(     obs_ens_handle%my_num_vars), &
         last_close_obs_dist(obs_ens_handle%my_num_vars), &
         close_obs_ind(      obs_ens_handle%my_num_vars), &
         last_close_obs_ind( obs_ens_handle%my_num_vars), &
         vstatus(            obs_ens_handle%my_num_vars), &
         my_obs_indx(        obs_ens_handle%my_num_vars), &
         my_obs_kind(        obs_ens_handle%my_num_vars), &
         my_obs_type(        obs_ens_handle%my_num_vars), &
         my_obs_loc(         obs_ens_handle%my_num_vars))

allocate(close_state_dist(     ens_handle%my_num_vars), &
         last_close_state_dist(ens_handle%my_num_vars), &
         close_state_ind(      ens_handle%my_num_vars), &
         last_close_state_ind( ens_handle%my_num_vars), &
         my_state_indx(        ens_handle%my_num_vars), &
         my_state_kind(        ens_handle%my_num_vars), &
         my_state_loc(         ens_handle%my_num_vars))
! end alloc

! we are going to read/write the copies array
call prepare_to_update_copies(ens_handle)
call prepare_to_update_copies(obs_ens_handle)

! Initialize assim_tools_module if needed
if (.not. module_initialized) call assim_tools_init()

!HK make window for mpi one-sided communication
! used for vertical conversion in get_close_obs
! Need to give create_mean_window the mean copy
call create_mean_window(ens_handle, ENS_MEAN_COPY, distribute_mean)

! filter kinds 1 and 8 return sorted increments, however non-deterministic
! inflation can scramble these. the sort is expensive, so help users get better
! performance by rejecting namelist combinations that do unneeded work.
if (sort_obs_inc) then
   if(deterministic_inflate(inflate) .and. ((filter_kind == 1) .or. (filter_kind == 8))) then
      write(msgstring,  *) 'With a deterministic filter [assim_tools_nml:filter_kind = ',filter_kind,']'
      write(msgstring2, *) 'and deterministic inflation [filter_nml:inf_deterministic = .TRUE.]'
      write(msgstring3, *) 'assim_tools_nml:sort_obs_inc = .TRUE. is not needed and is expensive.'
      call error_handler(E_MSG,'', '')  ! whitespace
      call error_handler(E_MSG,'WARNING filter_assim:', msgstring, source, &
                         text2=msgstring2,text3=msgstring3)
      call error_handler(E_MSG,'', '')  ! whitespace
      sort_obs_inc = .FALSE.
   endif
endif

! Open the localization diagnostics file
if(output_localization_diagnostics .and. my_task_id() == 0) &
  localization_unit = open_file(localization_diagnostics_file, action = 'append')

! For performance, make local copies of these settings which
! are really in the inflate derived type.
local_single_ss_inflate  = do_single_ss_inflate(inflate)
local_varying_ss_inflate = do_varying_ss_inflate(inflate)
local_ss_inflate         = do_ss_inflate(inflate)
local_obs_inflate        = do_obs_inflate(inflate)

! Default to printing nothing
nth_obs = -1

! Divide ensemble into num_groups groups.
! make sure the number of groups and ensemble size result in
! at least 2 members in each group (to avoid divide by 0) and
! that the groups all have the same number of members.
grp_size = ens_size / num_groups
if ((grp_size * num_groups) /= ens_size) then
   write(msgstring,  *) 'The number of ensemble members must divide into the number of groups evenly.'
   write(msgstring2, *) 'Ensemble size = ', ens_size, '  Number of groups = ', num_groups
   write(msgstring3, *) 'Change number of groups or ensemble size to avoid remainders.'
   call error_handler(E_ERR,'filter_assim:', msgstring, source, &
                         text2=msgstring2,text3=msgstring3)
endif
if (grp_size < 2) then
   write(msgstring,  *) 'There must be at least 2 ensemble members in each group.'
   write(msgstring2, *) 'Ensemble size = ', ens_size, '  Number of groups = ', num_groups
   write(msgstring3, *) 'results in < 2 members/group.  Decrease number of groups or increase ensemble size'
   call error_handler(E_ERR,'filter_assim:', msgstring, source, &
                         text2=msgstring2,text3=msgstring3)
endif
do group = 1, num_groups
   grp_beg(group) = (group - 1) * grp_size + 1
   grp_end(group) = grp_beg(group) + grp_size - 1
enddo

! Put initial value of state space inflation in copy normally used for SD
! This is to avoid weird storage footprint in filter
ens_handle%copies(ENS_SD_COPY, :) = ens_handle%copies(ENS_INF_COPY, :)

! For single state or obs space inflation, the inflation is like a token
! Gets passed from the processor with a given obs on to the next
if(local_single_ss_inflate) then
   my_inflate    = ens_handle%copies(ENS_INF_COPY,    1)
   my_inflate_sd = ens_handle%copies(ENS_INF_SD_COPY, 1)
end if

! Get info on my number and indices for obs
my_num_obs = get_my_num_vars(obs_ens_handle)
call get_my_vars(obs_ens_handle, my_obs_indx)

! Construct an observation temporary
call init_obs(observation, get_num_copies(obs_seq), get_num_qc(obs_seq))

! Get the locations for all of my observations
! HK I would like to move this to before the calculation of the forward operator so you could
! overwrite the vertical location with the required localization vertical coordinate when you
! do the forward operator calculation
call get_my_obs_loc(obs_ens_handle, obs_seq, keys, my_obs_loc, my_obs_kind, my_obs_type, obs_time)

if (convert_all_obs_verticals_first .and. is_doing_vertical_conversion) then
   ! convert the vertical of all my observations to the localization coordinate
   if (obs_ens_handle%my_num_vars > 0) then
      call convert_vertical_obs(ens_handle, obs_ens_handle%my_num_vars, my_obs_loc, &
                                my_obs_kind, my_obs_type, get_vertical_localization_coord(), vstatus)
      do i = 1, obs_ens_handle%my_num_vars
         if (good_dart_qc(nint(obs_ens_handle%copies(OBS_GLOBAL_QC_COPY, i)))) then
            !> @todo Can I just use the OBS_GLOBAL_QC_COPY? Is it ok to skip the loop?
            if (vstatus(i) /= 0) obs_ens_handle%copies(OBS_GLOBAL_QC_COPY, i) = DARTQC_FAILED_VERT_CONVERT
         endif
      enddo
   endif 
endif

! Get info on my number and indices for state
my_num_state = get_my_num_vars(ens_handle)
call get_my_vars(ens_handle, my_state_indx)

! Get the location and kind of all my state variables
do i = 1, ens_handle%my_num_vars
   call get_state_meta_data(my_state_indx(i), my_state_loc(i), my_state_kind(i))
end do

!> optionally convert all state location verticals
if (convert_all_state_verticals_first .and. is_doing_vertical_conversion) then
   if (ens_handle%my_num_vars > 0) then
      call convert_vertical_state(ens_handle, ens_handle%my_num_vars, my_state_loc, my_state_kind,  &
                                  my_state_indx, get_vertical_localization_coord(), istatus)
   endif
endif

! Get mean and variance of each group's observation priors for adaptive inflation
! Important that these be from before any observations have been used
if(local_ss_inflate) then
   do group = 1, num_groups
      obs_mean_index = OBS_PRIOR_MEAN_START + group - 1
      obs_var_index  = OBS_PRIOR_VAR_START  + group - 1
         call compute_copy_mean_var(obs_ens_handle, grp_beg(group), grp_end(group), &
           obs_mean_index, obs_var_index)
   end do
endif

!--------------------------------------------------------------------------
! Keep the original obsevation prior ensemble before any obs have been used
! Needed to compute the likelihoods for multi-obs state space QCEFs. 
allocate(all_my_orig_obs_priors(ens_size, my_num_obs), state_likelihood(ens_size + 1, my_num_state), &
   prior_state_mass(ens_size + 1, my_num_state), prior_state_ens(ens_size, my_num_state),            &
   prior_state_index_sort(ens_size, my_num_state))
do i = 1, my_num_obs
   all_my_orig_obs_priors(:, i) = obs_ens_handle%copies(1:ens_size, i)
end do

! State likelihoods start as all 1 (no information)
state_likelihood = 1.0_r8

! Just a naive prior_state_index_sort for now; will be highly inefficient
! Initialize the sorting index; Eventually this could be carried over for efficiency
do j = 1, ens_size
   prior_state_index_sort(j, :) = j
end do

! For MARHF the prior state mass is uniformly distributed
prior_state_mass = 1.0_r8 / (ens_size + 1.0_r8)

!--------------------------------------------------------------------------

! Initialize the method for getting state variables close to a given ob on my process
if (has_special_cutoffs) then
   call get_close_init(gc_state, my_num_state, 2.0_r8*cutoff, my_state_loc, 2.0_r8*cutoff_list)
else
   call get_close_init(gc_state, my_num_state, 2.0_r8*cutoff, my_state_loc)
endif

! Initialize the method for getting obs close to a given ob on my process
if (has_special_cutoffs) then
   call get_close_init(gc_obs, my_num_obs, 2.0_r8*cutoff, my_obs_loc, 2.0_r8*cutoff_list)
else
   call get_close_init(gc_obs, my_num_obs, 2.0_r8*cutoff, my_obs_loc)
endif

if (close_obs_caching) then
   ! Initialize last obs and state get_close lookups, to take advantage below
   ! of sequential observations at the same location (e.g. U,V, possibly T,Q)
   ! (this is getting long enough it probably should go into a subroutine. nsc.)
   last_base_obs_loc           = set_location_missing()
   last_base_states_loc        = set_location_missing()
   last_num_close_obs          = -1
   last_num_close_states       = -1
   last_close_obs_ind(:)       = -1
   last_close_state_ind(:)     = -1
   last_close_obs_dist(:)      = 888888.0_r8   ! something big, not small
   last_close_state_dist(:)    = 888888.0_r8   ! ditto
   num_close_obs_cached        = 0
   num_close_states_cached     = 0
   num_close_obs_calls_made    = 0
   num_close_states_calls_made = 0
endif

allow_missing_in_state = get_missing_ok_status()

! Loop through all the (global) observations sequentially
SEQUENTIAL_OBS: do i = 1, obs_ens_handle%num_vars
   ! Some compilers do not like mod by 0, so test first.
   if (print_every_nth_obs > 0) nth_obs = mod(i, print_every_nth_obs)

   ! If requested, print out a message every Nth observation
   ! to indicate progress is being made and to allow estimates
   ! of how long the assim will take.
   if (nth_obs == 0) then
      write(msgstring, '(2(A,I8))') 'Processing observation ', i, &
                                         ' of ', obs_ens_handle%num_vars
      if (print_timestamps == 0) then
         call error_handler(E_MSG,'filter_assim',msgstring)
      else
         call timestamp(trim(msgstring), pos="brief")
      endif
   endif

   ! Every pe has information about the global obs sequence
   call get_obs_from_key(obs_seq, keys(i), observation)
   call get_obs_def(observation, obs_def)
   base_obs_loc = get_obs_def_location(obs_def)
   obs_err_var = get_obs_def_error_variance(obs_def)
   base_obs_type = get_obs_def_type_of_obs(obs_def)
   if (base_obs_type > 0) then
      base_obs_kind = get_quantity_for_type_of_obs(base_obs_type)
   else
      call get_state_meta_data(-1 * int(base_obs_type,i8), dummyloc, base_obs_kind)  ! identity obs
   endif
   ! Get the value of the observation
   call get_obs_values(observation, obs, obs_val_index)

   ! Find out who has this observation and where it is
   call get_var_owner_index(ens_handle, int(i,i8), owner, owners_index)

   ! Following block is done only by the owner of this observation
   !-----------------------------------------------------------------------
   if(ens_handle%my_pe == owner) then
      ! each task has its own subset of all obs.  if they were converted in the
      ! vertical up above, then we need to broadcast the new values to all the other
      ! tasks so they're computing the right distances when applying the increments.
      if (is_doing_vertical_conversion) then
         vertvalue_obs_in_localization_coord = query_location(my_obs_loc(owners_index), "VLOC")
         whichvert_obs_in_localization_coord = query_location(my_obs_loc(owners_index), "WHICH_VERT")
      else
         vertvalue_obs_in_localization_coord = 0.0_r8
         whichvert_obs_in_localization_coord = 0
      endif

      obs_qc = obs_ens_handle%copies(OBS_GLOBAL_QC_COPY, owners_index)

      ! Only value of 0 for DART QC field should be assimilated
      IF_QC_IS_OKAY: if(nint(obs_qc) ==0) then
         obs_prior = obs_ens_handle%copies(1:ens_size, owners_index)
         ! Note that these are before DA starts, so can be different from current obs_prior
         orig_obs_prior_mean = obs_ens_handle%copies(OBS_PRIOR_MEAN_START: &
            OBS_PRIOR_MEAN_END, owners_index)
         orig_obs_prior_var  = obs_ens_handle%copies(OBS_PRIOR_VAR_START:  &
            OBS_PRIOR_VAR_END, owners_index)
         ! Also need the original obs prior ensemble for multi-obs state QCEF
         orig_obs_prior = all_my_orig_obs_priors(:, owners_index)
      endif IF_QC_IS_OKAY

      !Broadcast the info from this obs to all other processes
      ! orig_obs_prior_mean and orig_obs_prior_var only used with adaptive inflation
      ! my_inflate and my_inflate_sd only used with single state space inflation
      ! vertvalue_obs_in_localization_coord and whichvert_real only used for vertical
      ! coordinate transformation
      whichvert_real = real(whichvert_obs_in_localization_coord, r8)
      call broadcast_send(map_pe_to_task(ens_handle, owner), obs_prior,    &
         orig_obs_prior, orig_obs_prior_mean, orig_obs_prior_var,          &
         scalar1=obs_qc, scalar2=vertvalue_obs_in_localization_coord,      &
         scalar3=whichvert_real, scalar4=my_inflate, scalar5=my_inflate_sd)

   ! Next block is done by processes that do NOT own this observation
   !-----------------------------------------------------------------------
   else
      call broadcast_recv(map_pe_to_task(ens_handle, owner), obs_prior,    &
         orig_obs_prior, orig_obs_prior_mean, orig_obs_prior_var,          & 
         scalar1=obs_qc, scalar2=vertvalue_obs_in_localization_coord,      &
         scalar3=whichvert_real, scalar4=my_inflate, scalar5=my_inflate_sd)
      whichvert_obs_in_localization_coord = nint(whichvert_real)

   endif
   !-----------------------------------------------------------------------

   ! Everybody is doing this section, cycle if qc is bad
   if(nint(obs_qc) /= 0) cycle SEQUENTIAL_OBS

   !> all tasks must set the converted vertical values into the 'base' version of this loc
   !> because that's what we pass into the get_close_xxx() routines below.
   if (is_doing_vertical_conversion) &
      call set_vertical(base_obs_loc, vertvalue_obs_in_localization_coord, whichvert_obs_in_localization_coord)

   ! Compute observation space increments for each group
   do group = 1, num_groups
      grp_bot = grp_beg(group); grp_top = grp_end(group)
      call obs_increment(obs_prior(grp_bot:grp_top), grp_size, obs(1), &
         obs_err_var, base_obs_type, obs_inc(grp_bot:grp_top), obs_prior_mean(group), obs_prior_var(group), &
         net_a(group))
   end do

   ! Need to compute the likelihoods for the original prior ensemble for multi-obs state QCEF
   ! No thought about groups yet. Note that obs_err_var is only param we have for now
   call get_obs_likelihood(orig_obs_prior, ens_size, obs(1), obs_err_var, &
      base_obs_type, orig_obs_likelihood)

   ! Compute updated values for single state space inflation
   if(local_single_ss_inflate) then
      ! Update for each group separately
      do group = 1, num_groups
         call update_single_state_space_inflation(inflate, my_inflate, my_inflate_sd, &
            ens_handle%copies(ENS_SD_COPY, 1), orig_obs_prior_mean(group), &
            orig_obs_prior_var(group), obs(1), obs_err_var, grp_size, inflate_only)
      end do
   endif
  
   ! Adaptive localization needs number of other observations within localization radius.
   ! Do get_close_obs first, even though state space increments are computed before obs increments.
   ! JLA: ens_handle doesn't ever appear to be used. Get rid of it. Should be obs_ens_handle anyway?
   call  get_close_obs_cached(close_obs_caching, gc_obs, base_obs_loc, base_obs_type,      &
      my_obs_loc, my_obs_kind, my_obs_type, num_close_obs, close_obs_ind, close_obs_dist,  &
      ens_handle, last_base_obs_loc, last_num_close_obs, last_close_obs_ind,               &
      last_close_obs_dist, num_close_obs_cached, num_close_obs_calls_made)
   n_close_obs_items(i) = num_close_obs

   ! set the cutoff default, keep a copy of the original value, and avoid
   ! looking up the cutoff in a list if the incoming obs is an identity ob
   ! (and therefore has a negative kind).  specific types can never be 0;
   ! generic kinds (not used here) start their numbering at 0 instead of 1.
   if (base_obs_type > 0) then
      cutoff_orig = cutoff_list(base_obs_type)
   else
      cutoff_orig = cutoff
   endif

   ! JLA, could also cache for adaptive_localization which may be expensive?
   call adaptive_localization_and_diags(cutoff_orig, cutoff_rev, adaptive_localization_threshold, &
      adaptive_cutoff_floor, num_close_obs, close_obs_ind, close_obs_dist, my_obs_type, &
      i, base_obs_loc, obs_def, localization_unit)

   ! Find state variables on my process that are close to observation being assimilated
   call  get_close_state_cached(close_obs_caching, gc_state, base_obs_loc, base_obs_type,      &
      my_state_loc, my_state_kind, my_state_indx, num_close_states, close_state_ind, close_state_dist,  &
      ens_handle, last_base_states_loc, last_num_close_states, last_close_state_ind,               &
      last_close_state_dist, num_close_states_cached, num_close_states_calls_made)
   n_close_state_items(i) = num_close_states
   !call test_close_obs_dist(close_state_dist, num_close_states, i)

   ! Loop through to update each of my state variables that is potentially close
   STATE_UPDATE: do j = 1, num_close_states
      state_index = close_state_ind(j)

      if ( allow_missing_in_state ) then
         ! Don't allow update of state ensemble with any missing values
         if (any(ens_handle%copies(1:ens_size, state_index) == MISSING_R8)) cycle STATE_UPDATE
      endif

      call obs_updates_ens(ens_size, num_groups, ens_handle%copies(1:ens_size, state_index), &
         updated_ens, my_state_loc(state_index), my_state_kind(state_index), obs_prior, obs_inc, &
         obs_prior_mean, obs_prior_var, base_obs_loc, base_obs_type, obs_time, &
         close_state_dist(j), cutoff_rev, net_a, adjust_obs_impact, obs_impact_table, &
         grp_size, grp_beg, grp_end, i, my_state_indx(state_index), final_factor, correl)

      ! If doing full assimilation, update the state variable ensemble with weighted increments
      if(.not. inflate_only) ens_handle%copies(1:ens_size, state_index) = updated_ens

      ! Update the likelihood for this state variable
      call update_state_like(prior_state_index_sort(:, j), state_likelihood(:, j), &
         orig_obs_likelihood, prior_state_mass(:, j), ens_size, final_factor)

      ! Compute spatially-varying state space inflation
      if(local_varying_ss_inflate .and. final_factor > 0.0_r8) then
         do group = 1, num_groups
            call update_varying_state_space_inflation(inflate,                     &
               ens_handle%copies(ENS_INF_COPY, state_index),                       &
               ens_handle%copies(ENS_INF_SD_COPY, state_index),                    &
               ens_handle%copies(ENS_SD_COPY, state_index),                        &
               orig_obs_prior_mean(group), orig_obs_prior_var(group), obs(1),      &
               obs_err_var, grp_size, final_factor, correl(group), inflate_only)
         end do
      endif
   end do STATE_UPDATE

   if(.not. inflate_only) then
      ! Now everybody updates their obs priors (only ones after this one)
      OBS_UPDATE: do j = 1, num_close_obs
         obs_index = close_obs_ind(j)

         ! Only have to update obs that have not yet been used
         if(my_obs_indx(obs_index) > i) then

            ! If forward observation operator failed, no need to update unassimilated observations
            if (any(obs_ens_handle%copies(1:ens_size, obs_index) == MISSING_R8)) cycle OBS_UPDATE

            call obs_updates_ens(ens_size, num_groups, obs_ens_handle%copies(1:ens_size, obs_index), &
               updated_ens, my_obs_loc(obs_index), my_obs_kind(obs_index), obs_prior, obs_inc, &
               obs_prior_mean, obs_prior_var, base_obs_loc, base_obs_type, obs_time, &
               close_obs_dist(j), cutoff_rev, net_a, adjust_obs_impact, obs_impact_table, &
               grp_size, grp_beg, grp_end, i, -1*my_obs_indx(obs_index), final_factor, correl)

            obs_ens_handle%copies(1:ens_size, obs_index) = updated_ens
         endif
      end do OBS_UPDATE
   endif
end do SEQUENTIAL_OBS

!--------------------------------------------------------------------------------
! Now do the marginal adjustment steps
! First get the update posterior with the likelihood

!--------------------------------------------------------------------------------

! Every pe needs to get the current my_inflate and my_inflate_sd back
if(local_single_ss_inflate) then
   ens_handle%copies(ENS_INF_COPY, :) = my_inflate
   ens_handle%copies(ENS_INF_SD_COPY, :) = my_inflate_sd
end if

! Free up the storage
call destroy_obs(observation)
call get_close_destroy(gc_state)
call get_close_destroy(gc_obs)

! do some stats - being aware that unless we do a reduce() operation
! this is going to be per-task.  so only print if something interesting
! shows up in the stats?  maybe it would be worth a reduce() call here?

!>@todo FIXME:  
!  we have n_close_obs_items and n_close_state_items for each assimilated
!  observation.  what we really want to know is across the tasks is there
!  a big difference in counts?  so that means communication.  maybe just
!  the largest value?  and the number of 0 values?  and if the largest val
!  is way off compared to the other tasks, warn the user?
!  we don't have space or time to do all the obs * tasks but could we
!  send enough info to make a histogram?  compute N bin counts and then
!  reduce that across all the tasks and have task 0 print out?
! still thinking on this idea.
!   write(msgstring, *) 'max state items per observation: ', maxval(n_close_state_items)
!   call error_handler(E_MSG, 'filter_assim:', msgstring)
! if i come up with something i like, can we use the same idea
! for the threed_sphere locations boxes?

! Assure user we have done something
if (print_trace_details >= 0) then
write(msgstring, '(A,I8,A)') &
   'Processed', obs_ens_handle%num_vars, ' total observations'
   call error_handler(E_MSG,'filter_assim:',msgstring)
endif

! diagnostics for stats on saving calls by remembering obs at the same location.
! change .true. to .false. in the line below to remove the output completely.
if (close_obs_caching) then
   if (num_close_obs_cached > 0 .and. do_output()) then
      print *, "Total number of calls made    to get_close_obs for obs/states:    ", &
                num_close_obs_calls_made + num_close_states_calls_made
      print *, "Total number of calls avoided to get_close_obs for obs/states:    ", &
                num_close_obs_cached + num_close_states_cached
      if (num_close_obs_cached+num_close_obs_calls_made+ &
          num_close_states_cached+num_close_states_calls_made > 0) then
         print *, "Percent saved: ", 100.0_r8 * &
                   (real(num_close_obs_cached+num_close_states_cached, r8) /  &
                   (num_close_obs_calls_made+num_close_obs_cached +           &
                    num_close_states_calls_made+num_close_states_cached))
      endif
   endif
endif

!call test_state_copies(ens_handle, 'end')

! Close the localization diagnostics file
if(output_localization_diagnostics .and. my_task_id() == 0) call close_file(localization_unit)

! get rid of mpi window
call free_mean_window()

! deallocate space
deallocate(close_obs_dist,      &
           last_close_obs_dist, &
           my_obs_indx,         &
           my_obs_kind,         &
           my_obs_type,         &
           close_obs_ind,       &
           last_close_obs_ind,  &
           vstatus,             &
           my_obs_loc)

deallocate(close_state_dist,      &
           last_close_state_dist, &
           my_state_indx,         &
           close_state_ind,       &
           last_close_state_ind,  &
           my_state_kind,         &
           my_state_loc)

deallocate(n_close_state_items, &
           n_close_obs_items)

deallocate(all_my_orig_obs_priors, state_likelihood, prior_state_mass, prior_state_ens, &
   prior_state_index_sort)
! end dealloc

end subroutine filter_assim

!-------------------------------------------------------------

subroutine obs_increment(ens_in, ens_size, obs, obs_var, obs_type, &
   obs_inc, prior_mean, prior_var, net_a)

! Given the ensemble prior for an observation, the observation, and
! the observation error variance, computes increments and adjusts
! observation space inflation values

integer,                     intent(in)    :: ens_size
real(r8),                    intent(in)    :: ens_in(ens_size), obs, obs_var
integer,                     intent(in)    :: obs_type
real(r8),                    intent(out)   :: obs_inc(ens_size)
real(r8),                    intent(out)   :: prior_mean, prior_var
real(r8),                    intent(out)   :: net_a

real(r8) :: ens(ens_size), new_val(ens_size), likelihood(ens_size)
integer  :: i, ens_index(ens_size), new_index(ens_size)

! Declarations for bounded rank histogram filter
logical  :: is_bounded(2)
real(r8) :: bound(2)

! Most general observation space algorithms require:
!   1. A class of prior continuous distribution which may require a number of parameters
!   2. A class of likelihood functions which may require a number of parameters
!   3. A specific method for computing a continous posterior which could have parameters
! The EnKF is an exception since it cannot be expressed as a QCEF
! Some of this information might need to be on a per obs basis so needs to be in obs_sequence file
! Examples include the mean and variance for a normal likelihood
! Other parts of the information could be on a per observation type basis. For instance 
! a tracer might have a bounded normal prior or likelihood with bounds fixed for that type.

! Copy the input ensemble to something that can be modified
ens = ens_in

! Compute prior variance and mean from sample
prior_mean = sum(ens) / ens_size
prior_var  = sum((ens - prior_mean)**2) / (ens_size - 1)
prior_var = max(prior_var, 0.0_r8)

! If obs_var == 0, delta function.  The mean becomes obs value with no spread.
! If prior_var == 0, obs has no effect.  The increments are 0.
! If both obs_var and prior_var == 0 there is no right thing to do, so Stop.
if ((obs_var == 0.0_r8) .and. (prior_var == 0.0_r8)) then

   ! fail if both obs variance and prior spreads are 0.
   write(msgstring,  *) 'Observation value is ', obs, ' ensemble mean value is ', prior_mean
   write(msgstring2, *) 'The observation has 0.0 error variance, and the ensemble members have 0.0 spread.'
   write(msgstring3, *) 'These require inconsistent actions and the algorithm cannot continue.'
   call error_handler(E_ERR, 'obs_increment', msgstring, &
           source, text2=msgstring2, text3=msgstring3)

else if (obs_var == 0.0_r8) then

   ! new mean is obs value, so increments are differences between obs
   ! value and current value.  after applying obs, all state will equal obs.
   obs_inc(:) = obs - ens

else if (prior_var == 0.0_r8) then

   ! if all state values are the same, nothing changes.
   obs_inc(:) = 0.0_r8

else

   ! Call the appropriate filter option to compute increments for ensemble
   ! note that at this point we've taken care of the cases where either the
   ! obs_var or the prior_var is 0, so the individual routines no longer need
   ! to have code to test for those cases.
   !--------------------------------------------------------------------------
   if(filter_kind == 1) then
      ! Null value of net spread change factor is 1.0
      net_a = 0.0_r8
      call obs_increment_eakf(ens, ens_size, prior_mean, prior_var, &
         obs, obs_var, obs_inc, net_a)
   !--------------------------------------------------------------------------
   else if(filter_kind == 2) then
      call obs_increment_enkf(ens, ens_size, prior_var, obs, obs_var, obs_inc)
      ! To minimize regression errors for this non-deterministic update, can sort to minimize increments
      if (sort_obs_inc) then
         new_val = ens_in + obs_inc
         ! Sorting to make increments as small as possible
         call index_sort(ens_in, ens_index, ens_size)
         call index_sort(new_val, new_index, ens_size)
         do i = 1, ens_size
            obs_inc(ens_index(i)) = new_val(new_index(i)) - ens_in(ens_index(i))
         end do
      endif
   !--------------------------------------------------------------------------
   else if(filter_kind == 8) then
      call obs_increment_rank_histogram(ens, ens_size, prior_var, obs, obs_var, obs_inc)
   !--------------------------------------------------------------------------
   else if(filter_kind == 101) then
      ! Bounded normal RHF with hard-coded bounds specified here
      is_bounded = .false.
      bound = (/-10.0_r8, 13.0_r8/)
      ! Test bounded normal likelihood; Could use an arbitrary likelihood
      do i = 1, ens_size
         likelihood(i) = get_truncated_normal_like(ens(i), obs, obs_var, is_bounded, bound)
      end do
      !likelihood = exp(-1.0_r8 * (ens - obs)**2 / (2.0_r8 * obs_var))
      call obs_increment_bounded_norm_rhf(ens, likelihood, ens_size, prior_var, &
         obs, obs_var, obs_inc, is_bounded, bound)
   !--------------------------------------------------------------------------
   else
      call error_handler(E_ERR,'obs_increment', &
              'Illegal value of filter_kind in assim_tools namelist [1, 2, 8 OK]', source)
   endif
endif


end subroutine obs_increment



subroutine obs_increment_eakf(ens, ens_size, prior_mean, prior_var, obs, obs_var, obs_inc, a)
!========================================================================
!
! EAKF version of obs increment

integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: ens(ens_size), prior_mean, prior_var, obs, obs_var
real(r8), intent(out) :: obs_inc(ens_size)
real(r8), intent(out) :: a

real(r8) :: new_mean, var_ratio

! Compute the new mean
var_ratio = obs_var / (prior_var + obs_var)
new_mean  = var_ratio * (prior_mean  + prior_var*obs / obs_var)

! Compute sd ratio and shift ensemble
a = sqrt(var_ratio)
obs_inc = a * (ens - prior_mean) + new_mean - ens

end subroutine obs_increment_eakf


subroutine obs_increment_enkf(ens, ens_size, prior_var, obs, obs_var, obs_inc)
!========================================================================
! subroutine obs_increment_enkf(ens, ens_size, obs, obs_var, obs_inc)
!

! ENKF version of obs increment

integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: ens(ens_size), prior_var, obs, obs_var
real(r8), intent(out) :: obs_inc(ens_size)

real(r8) :: obs_var_inv, prior_var_inv, new_var, new_mean(ens_size)
! real(r8) :: sx, s_x2
real(r8) :: temp_mean, temp_obs(ens_size)
integer  :: i

! Compute mt_rinv_y (obs error normalized by variance)
obs_var_inv = 1.0_r8 / obs_var
prior_var_inv = 1.0_r8 / prior_var

new_var       = 1.0_r8 / (prior_var_inv + obs_var_inv)

! If this is first time through, need to initialize the random sequence.
! This will reproduce exactly for multiple runs with the same task count,
! but WILL NOT reproduce for a different number of MPI tasks.
! To make it independent of the number of MPI tasks, it would need to
! use the global ensemble number or something else that remains constant
! as the processor count changes.  this is not currently an argument to
! this function and so we are not trying to make it task-count invariant.
if(first_inc_ran_call) then
   call init_random_seq(inc_ran_seq, my_task_id() + 1)
   first_inc_ran_call = .false.
endif

! Generate perturbed obs
do i = 1, ens_size
    temp_obs(i) = random_gaussian(inc_ran_seq, obs, sqrt(obs_var))
end do

! Move this so that it has original obs mean
temp_mean = sum(temp_obs) / ens_size
temp_obs(:) = temp_obs(:) - temp_mean + obs

! Loop through pairs of priors and obs and compute new mean
do i = 1, ens_size
   new_mean(i) = new_var * (prior_var_inv * ens(i) + temp_obs(i) / obs_var)
   obs_inc(i)  = new_mean(i) - ens(i)
end do

! Can also adjust mean (and) variance of final sample; works fine
!sx         = sum(new_mean)
!s_x2       = sum(new_mean * new_mean)
!temp_mean = sx / ens_size
!temp_var  = (s_x2 - sx**2 / ens_size) / (ens_size - 1)
!new_mean = (new_mean - temp_mean) * sqrt(new_var / temp_var) + updated_mean
!obs_inc = new_mean - ens


end subroutine obs_increment_enkf


subroutine update_from_obs_inc(obs, obs_prior_mean, obs_prior_var, obs_inc, &
               state, ens_size, state_inc, reg_coef, net_a_in, correl_out)
!========================================================================

! Does linear regression of a state variable onto an observation and
! computes state variable increments from observation increments

integer,            intent(in)    :: ens_size
real(r8),           intent(in)    :: obs(ens_size), obs_inc(ens_size)
real(r8),           intent(in)    :: obs_prior_mean, obs_prior_var
real(r8),           intent(in)    :: state(ens_size)
real(r8),           intent(out)   :: state_inc(ens_size), reg_coef
real(r8),           intent(in)    :: net_a_in
real(r8), optional, intent(inout) :: correl_out

real(r8) :: obs_state_cov, intermed
real(r8) :: restoration_inc(ens_size), state_mean, state_var, correl
real(r8) :: factor, exp_true_correl, mean_factor, net_a


! For efficiency, just compute regression coefficient here unless correl is needed

state_mean = sum(state) / ens_size
obs_state_cov = sum( (state - state_mean) * (obs - obs_prior_mean) ) / (ens_size - 1)

if (obs_prior_var > 0.0_r8) then
   reg_coef = obs_state_cov/obs_prior_var
else
   reg_coef = 0.0_r8
endif

! If correl_out is present, need correl for adaptive inflation
! Also needed for file correction below.

! WARNING: we have had several different numerical problems in this
! section, especially with users running in single precision floating point.
! Be very cautious if changing any code in this section, taking into
! account underflow and overflow for 32 bit floats.

if(present(correl_out) .or. sampling_error_correction) then
   if (obs_state_cov == 0.0_r8 .or. obs_prior_var <= 0.0_r8) then
      correl = 0.0_r8
   else
      state_var = sum((state - state_mean)**2) / (ens_size - 1)
      if (state_var <= 0.0_r8) then
         correl = 0.0_r8
      else
         intermed = sqrt(obs_prior_var) * sqrt(state_var)
         if (intermed <= 0.0_r8) then
            correl = 0.0_r8
         else
            correl = obs_state_cov / intermed
         endif
      endif
   endif
   if(correl >  1.0_r8) correl =  1.0_r8
   if(correl < -1.0_r8) correl = -1.0_r8
endif
if(present(correl_out)) correl_out = correl


! Get the expected actual correlation and the regression weight reduction factor
if(sampling_error_correction) then
   call get_correction_from_table(correl, mean_factor, exp_true_correl, ens_size)
   ! Watch out for division by zero; if correl is really small regression is safely 0
   if(abs(correl) > 0.001_r8) then
      reg_coef = reg_coef * (exp_true_correl / correl) * mean_factor
   else
      reg_coef = 0.0_r8
   endif
   correl = exp_true_correl
endif



! Then compute the increment as product of reg_coef and observation space increment
state_inc = reg_coef * obs_inc

!
! FIXME: craig schwartz has a degenerate case involving externally computed
! forward operators in which the obs prior variance is in fact exactly 0.
! adding this test allowed him to continue to  use spread restoration
! without numerical problems.  we don't know if this is sufficient;
! for now we'll leave the original code but it needs to be revisited.
!
! Spread restoration algorithm option.
!if(spread_restoration .and. obs_prior_var > 0.0_r8) then
!

! Spread restoration algorithm option.
if(spread_restoration) then
   ! Don't use this to reduce spread at present (should revisit this line)
   net_a = min(net_a_in, 1.0_r8)

   ! Default restoration increment is 0.0
   restoration_inc = 0.0_r8

   ! Compute the factor by which to inflate
   ! These come from correl_error.f90 in system_simulation and the files ens??_pairs and
   ! ens_pairs_0.5 in work under system_simulation. Assume a linear reduction from 1
   ! as a function of the net_a. Assume that the slope of this reduction is a function of
   ! the reciprocal of the ensemble_size (slope = 0.80 / ens_size). These are empirical
   ! for now. See also README in spread_restoration_paper documentation.
   !!!factor = 1.0_r8 / (1.0_r8 + (net_a - 1.0_r8) * (0.8_r8 / ens_size)) - 1.0_r8
   factor = 1.0_r8 / (1.0_r8 + (net_a - 1.0_r8) / (-2.4711_r8 + 1.6386_r8 * ens_size)) - 1.0_r8
   !!!factor = 1.0_r8 / (1.0_r8 + (net_a**2 - 1.0_r8) * (-0.0111_r8 + .8585_r8 / ens_size)) - 1.0_r8

   ! Variance restoration
   state_mean = sum(state) / ens_size
   restoration_inc = factor * (state - state_mean)
   state_inc = state_inc + restoration_inc
endif

!! NOTE: if requested to be returned, correl_out is set further up in the
!! code, before the sampling error correction, if enabled, is applied.
!! this means it's returning a different larger value than the correl
!! being returned here.  it's used by the adaptive inflation and so the
!! inflation will see a slightly different correlation value.  it isn't
!! clear that this is a bad thing; it means the inflation might be a bit
!! larger than it would otherwise.  before we move any code this would
!! need to be studied to see what the real impact would be.

end subroutine update_from_obs_inc


!------------------------------------------------------------------------

subroutine get_correction_from_table(scorrel, mean_factor, expected_true_correl, ens_size)

real(r8),  intent(in) :: scorrel
real(r8), intent(out) :: mean_factor, expected_true_correl
integer,  intent(in)  :: ens_size

! Uses interpolation to get correction factor into the table

integer             :: low_indx, high_indx
real(r8)            :: correl, fract, low_correl, low_exp_correl, low_alpha
real(r8)            :: high_correl, high_exp_correl, high_alpha

logical, save :: first_time = .true.

if (first_time) then
   call read_sampling_error_correction(ens_size, exp_true_correl, alpha)
   first_time = .false.
endif

! Interpolate to get values of expected correlation and mean_factor
if(scorrel < -1.0_r8) then
   correl = -1.0_r8
   mean_factor = 1.0_r8
else if(scorrel > 1.0_r8) then
   correl = 1.0_r8
   mean_factor = 1.0_r8
else if(scorrel <= -0.995_r8) then
   fract = (scorrel + 1.0_r8) / 0.005_r8
   correl = (exp_true_correl(1) + 1.0_r8) * fract - 1.0_r8
   mean_factor = (alpha(1) - 1.0_r8) * fract + 1.0_r8
else if(scorrel >= 0.995_r8) then
   fract = (scorrel - 0.995_r8) / 0.005_r8
   correl = (1.0_r8 - exp_true_correl(sec_table_size)) * fract + exp_true_correl(sec_table_size)
   mean_factor = (1.0_r8 - alpha(sec_table_size)) * fract + alpha(sec_table_size)
else
   ! given the ifs above, the floor() computation below for low_indx
   ! should always result in a value in the range 1 to 199.  but if this
   ! code is compiled with r8=r4 (single precision reals) it turns out
   ! to be possible to get values a few bits below 0 which results in
   ! a very large negative integer.  the limit tests below ensure the
   ! index stays in a legal range.
   low_indx = floor((scorrel + 0.995_r8) / 0.01_r8 + 1.0_r8)
   if (low_indx <   1) low_indx =   1
   if (low_indx > 199) low_indx = 199
   low_correl = -0.995_r8 + (low_indx - 1) * 0.01_r8
   low_exp_correl = exp_true_correl(low_indx)
   low_alpha = alpha(low_indx)
   high_indx = low_indx + 1
   high_correl = low_correl + 0.01_r8
   high_exp_correl = exp_true_correl(high_indx)
   high_alpha = alpha(high_indx)
   fract = (scorrel - low_correl) / (high_correl - low_correl)
   correl = (high_exp_correl - low_exp_correl) * fract + low_exp_correl
   mean_factor = (high_alpha - low_alpha) * fract + low_alpha
endif

expected_true_correl = correl

! Don't want Monte Carlo interpolation problems to put us outside of a
! ratio between 0 and 1 for expected_true_correl / sample_correl
! If they have different signs, expected should just be 0
if(expected_true_correl * scorrel <= 0.0_r8) then
   expected_true_correl = 0.0_r8
else if(abs(expected_true_correl) > abs(scorrel)) then
   ! If same sign, expected should not be bigger in absolute value
   expected_true_correl = scorrel
endif

end subroutine get_correction_from_table


subroutine obs_increment_rank_histogram(ens, ens_size, prior_var, &
   obs, obs_var, obs_inc)
!------------------------------------------------------------------------
!
! Revised 14 November 2008
!
! Does observation space update by approximating the prior distribution by
! a rank histogram. Prior and posterior are assumed to have 1/(n+1) probability
! mass between each ensemble member. The tails are assumed to be gaussian with
! a variance equal to sample variance of the entire ensemble and a mean
! selected so that 1/(n+1) of the mass is in each tail.
!
! The likelihood between the extreme ensemble members is approximated by
! quadrature. Two options are available and controlled by the namelist entry
! rectangular_quadrature. If this namelist is true than the likelihood between
! a pair of ensemble members is assumed to be uniform with the average of
! the likelihood computed at the two ensemble members. If it is false then
! the likelihood between two ensemble members is approximated by a line
! connecting the values of the likelihood computed at each of the ensemble
! members (trapezoidal quadrature).
!
! Two options are available for approximating the likelihood on the tails.
! If gaussian_likelihood_tails is true that the likelihood is assumed to
! be N(obs, obs_var) on the tails. If this is false, then the likelihood
! on the tails is taken to be uniform (to infinity) with the value at the
! outermost ensemble members.
!
! A product of the approximate prior and approximate posterior is taken
! and new ensemble members are located so that 1/(n+1) of the mass is between
! each member and on the tails.

! This code is still under development. Please contact Jeff Anderson at
! jla@ucar.edu if you are interested in trying it.

integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: ens(ens_size), prior_var, obs, obs_var
real(r8), intent(out) :: obs_inc(ens_size)

integer  :: i, e_ind(ens_size), lowest_box, j
real(r8) :: prior_sd, var_ratio, umass, left_amp, right_amp
real(r8) :: left_sd, left_var, right_sd, right_var, left_mean, right_mean
real(r8) :: mass(ens_size + 1), like(ens_size), cumul_mass(0:ens_size + 1)
real(r8) :: nmass(ens_size + 1)
real(r8) :: new_mean_left, new_mean_right, prod_weight_left, prod_weight_right
real(r8) :: new_var_left, new_var_right, new_sd_left, new_sd_right
real(r8) :: new_ens(ens_size), mass_sum
real(r8) :: x(ens_size)
real(r8) :: like_dense(2:ens_size), height(2:ens_size)
real(r8) :: dist_for_unit_sd
real(r8) :: a, b, c, hright, hleft, r1, r2, adj_r1, adj_r2

! Do an index sort of the ensemble members; Will want to do this very efficiently
call index_sort(ens, e_ind, ens_size)

do i = 1, ens_size
   ! The boundaries of the interior bins are just the sorted ensemble members
   x(i) = ens(e_ind(i))
   ! Compute likelihood for each ensemble member; just evaluate the gaussian
   ! No need to compute the constant term since relative likelihood is what matters
   like(i) = exp(-1.0_r8 * (x(i) - obs)**2 / (2.0_r8 * obs_var))
end do

! Prior distribution is boxcar in the central bins with 1/(n+1) density
! in each intermediate bin. BUT, distribution on the tails is a normal with
! 1/(n + 1) of the mass on each side.

! Can now compute the mean likelihood density in each interior bin
do i = 2, ens_size
   like_dense(i) = ((like(i - 1) + like(i)) / 2.0_r8)
end do

! Compute the s.d. of the ensemble for getting the gaussian tails
prior_sd = sqrt(prior_var)

! For unit normal, find distance from mean to where cdf is 1/(n+1)
! Lots of this can be done once in first call and then saved
call weighted_norm_inv(1.0_r8, 0.0_r8, 1.0_r8, &
   1.0_r8 / (ens_size + 1.0_r8), dist_for_unit_sd)
dist_for_unit_sd = -1.0_r8 * dist_for_unit_sd

! Have variance of tails just be sample prior variance
! Mean is adjusted so that 1/(n+1) is outside
left_mean = x(1) + dist_for_unit_sd * prior_sd
left_var = prior_var
left_sd = prior_sd
! Same for right tail
right_mean = x(ens_size) - dist_for_unit_sd * prior_sd
right_var = prior_var
right_sd = prior_sd

if(gaussian_likelihood_tails) then
   !*************** Block to do Gaussian-Gaussian on tail **************
   ! Compute the product of the obs likelihood gaussian with the priors
   ! Left tail gaussian first
   var_ratio = obs_var / (left_var + obs_var)
   new_var_left = var_ratio * left_var
   new_sd_left = sqrt(new_var_left)
   new_mean_left  = var_ratio * (left_mean  + left_var*obs / obs_var)
   ! REMEMBER, this product has an associated weight which must be taken into account
   ! See Anderson and Anderson for this weight term (or tutorial kernel filter)
   ! NOTE: The constant term has been left off the likelihood so we don't have
   ! to divide by sqrt(2 PI) in this expression
   prod_weight_left =  exp(-0.5_r8 * (left_mean**2 / left_var + &
         obs**2 / obs_var - new_mean_left**2 / new_var_left)) / &
         sqrt(left_var + obs_var)
   ! Determine how much mass is in the updated tails by computing gaussian cdf
   mass(1) = norm_cdf(x(1), new_mean_left, new_sd_left) * prod_weight_left

   ! Same for the right tail
   var_ratio = obs_var / (right_var + obs_var)
   new_var_right = var_ratio * right_var
   new_sd_right = sqrt(new_var_right)
   new_mean_right  = var_ratio * (right_mean  + right_var*obs / obs_var)
   ! NOTE: The constant term has been left off the likelihood so we don't have
   ! to divide by sqrt(2 PI) in this expression
   prod_weight_right =  exp(-0.5_r8 * (right_mean**2 / right_var + &
         obs**2 / obs_var - new_mean_right**2 / new_var_right)) / &
         sqrt(right_var + obs_var)
   ! Determine how much mass is in the updated tails by computing gaussian cdf
   mass(ens_size + 1) = (1.0_r8 - norm_cdf(x(ens_size), new_mean_right, &
      new_sd_right)) * prod_weight_right
   !************ End Block to do Gaussian-Gaussian on tail **************
else
   !*************** Block to do flat tail for likelihood ****************
   ! Flat tails: THIS REMOVES ASSUMPTIONS ABOUT LIKELIHOOD AND CUTS COST
   new_var_left = left_var
   new_sd_left = left_sd
   new_mean_left = left_mean
   prod_weight_left = like(1)
   mass(1) = like(1) / (ens_size + 1.0_r8)

   ! Same for right tail
   new_var_right = right_var
   new_sd_right = right_sd
   new_mean_right = right_mean
   prod_weight_right = like(ens_size)
   mass(ens_size + 1) = like(ens_size) / (ens_size + 1.0_r8)
   !*************** End block to do flat tail for likelihood ****************
endif

! The mass in each interior box is the height times the width
! The height of the likelihood is like_dense
! For the prior, mass is 1/(n+1),   and mass = height x width so...
! The height of the prior is 1 / ((n+1) width);   multiplying by width leaves 1/(n+1)

! In prior, have 1/(n+1) mass in each bin, multiply by mean likelihood density
! to get approximate mass in updated bin
do i = 2, ens_size
   mass(i) = like_dense(i) / (ens_size + 1.0_r8)
   ! Height of prior in this bin is mass/width; Only needed for trapezoidal
   ! If two ensemble members are the same, set height to -1 as flag
   if(x(i) == x(i - 1)) then
      height(i) = -1.0_r8
   else
      height(i) = 1.0_r8 / ((ens_size + 1.0_r8) * (x(i) - x(i-1)))
   endif
end do

! Now normalize the mass in the different bins to get a pdf
mass_sum = sum(mass)
nmass = mass / mass_sum

! Get the weight for the final normalized tail gaussians
! This is the same as left_amp=(ens_size + 1)*nmass(1)
left_amp = prod_weight_left / mass_sum
! This is the same as right_amp=(ens_size + 1)*nmass(ens_size + 1)
right_amp = prod_weight_right / mass_sum

! Find cumulative mass at each box boundary and middle boundary
cumul_mass(0) = 0.0_r8
do i = 1, ens_size + 1
   cumul_mass(i) = cumul_mass(i - 1) + nmass(i)
end do

! Begin intenal box search at bottom of lowest box, update for efficiency
lowest_box = 1

! Find each new ensemble members location
do i = 1, ens_size
   ! Each update ensemble member has 1/(n+1) mass before it
   umass = (1.0_r8 * i) / (ens_size + 1.0_r8)

   ! If it is in the inner or outer range have to use normal
   if(umass < cumul_mass(1)) then
      ! It's in the left tail
      ! Get position of x in weighted gaussian where the cdf has value umass
      call weighted_norm_inv(left_amp, new_mean_left, new_sd_left, &
         umass, new_ens(i))
   else if(umass > cumul_mass(ens_size)) then
      ! It's in the right tail
      ! Get position of x in weighted gaussian where the cdf has value umass
      call weighted_norm_inv(right_amp, new_mean_right, new_sd_right, &
         1.0_r8 - umass, new_ens(i))
      ! Coming in from the right, use symmetry after pretending its on left
      new_ens(i) = new_mean_right + (new_mean_right - new_ens(i))
   else
      ! In one of the inner uniform boxes.
      FIND_BOX:do j = lowest_box, ens_size - 1
         ! Find the box that this mass is in
         if(umass >= cumul_mass(j) .and. umass <= cumul_mass(j + 1)) then

            if(rectangular_quadrature) then
               !********* Block for rectangular quadrature *******************
               ! Linearly interpolate in mass
               new_ens(i) = x(j) + ((umass - cumul_mass(j)) / &
                  (cumul_mass(j+1) - cumul_mass(j))) * (x(j + 1) - x(j))
               !********* End block for rectangular quadrature *******************

            else

               !********* Block for trapezoidal interpolation *******************
               ! Assume that mass has linear profile, quadratic interpolation
               ! If two ensemble members are the same, just keep that value
               if(height(j + 1) < 0) then
                  new_ens(i) = x(j)
               else
                  ! Height on left side and right side
                  hleft = height(j + 1) * like(j) / mass_sum
                  hright = height(j + 1) * like(j + 1) / mass_sum
                  ! Will solve a quadratic for desired x-x(j)
                  ! a is 0.5(hright - hleft) / (x(j+1) - x(j))
                  a = 0.5_r8 * (hright - hleft) / (x(j+1) - x(j))
                  ! b is hleft
                  b = hleft
                  ! c is cumul_mass(j) - umass
                  c = cumul_mass(j) - umass
                  ! Use stable quadratic solver
                  call solve_quadratic(a, b, c, r1, r2)
                  adj_r1 = r1 + x(j)
                  adj_r2 = r2 + x(j)
                  if(adj_r1 >= x(j) .and. adj_r1 <= x(j+1)) then
                     new_ens(i) = adj_r1
                  elseif (adj_r2 >= x(j) .and. adj_r2 <= x(j+1)) then
                     new_ens(i) = adj_r2
                  else
                     msgstring = 'Did not get a satisfactory quadratic root'
                     call error_handler(E_ERR, 'obs_increment_rank_histogram', msgstring, &
                        source)
                  endif
               endif
               !********* End block for quadratic interpolation *******************

            endif

            ! Don't need to search lower boxes again
            lowest_box = j
            exit FIND_BOX
         end if
      end do FIND_BOX
   endif
end do

! Convert to increments for unsorted
do i = 1, ens_size
   obs_inc(e_ind(i)) = new_ens(i) - x(i)
end do

end subroutine obs_increment_rank_histogram



subroutine obs_increment_bounded_norm_rhf(ens, ens_like, ens_size, prior_var, &
   obs, obs_var, obs_inc, is_bounded, bound)
!------------------------------------------------------------------------
integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: ens(ens_size)
real(r8), intent(in)  :: ens_like(ens_size)
real(r8), intent(in)  :: prior_var, obs, obs_var
real(r8), intent(out) :: obs_inc(ens_size)
logical,  intent(in)  :: is_bounded(2)
real(r8), intent(in)  :: bound(2)

! Does bounded RHF assuming that the prior in outer regions is part of a normal. 
! is_bounded indicates if a bound exists on left/right and the 
! bound value says what the bound is if is_bounded is true

real(r8) :: s_ens(ens_size), sort_ens_like(ens_size), post(ens_size)
real(r8) :: region_likelihood(0:ens_size), post_weight(0:ens_size)
real(r8) :: tail_mean(2), tail_sd(2), inv_tail_amp(2), bound_quantile(2)
real(r8) :: prior_inv_tail_amp(2)
real(r8) :: prior_sd, base_prior_prob
integer  :: i, e_ind(ens_size)

! Save to avoid a modestly expensive computation redundancy
real(r8), save :: dist_for_unit_sd

! For unit normal, find distance from mean to where cdf is 1/(ens_size+1).
! Saved to avoid redundant computation for repeated calls with same ensemble size
if(bounded_norm_rhf_ens_size /= ens_size) then
   call norm_inv(1.0_r8 / (ens_size + 1.0_r8), dist_for_unit_sd)
   ! This will be negative, want it to be a distance so make it positive
   dist_for_unit_sd = -1.0_r8 * dist_for_unit_sd
   ! Keep a record of the ensemble size used to compute dist_for_unit_sd
   bounded_norm_rhf_ens_size = ens_size
endif

! If all ensemble members are identical, this algorithm becomes undefined, so fail
if(prior_var <= 0.0_r8) then
      msgstring = 'Ensemble variance <= 0 '
      call error_handler(E_ERR, 'obs_increment_bounded_norm_rhf', msgstring, source)
endif

! Do an index sort of the ensemble members; Use prior info for efficiency in the future
call index_sort(ens, e_ind, ens_size)

! Get the sorted ensemble
s_ens = ens(e_ind)

! Get the sorted likelihood
sort_ens_like = ens_like(e_ind)

! Compute the mean likelihood in each interior interval (bin)
do i = 1, ens_size - 1
   region_likelihood(i) = (sort_ens_like(i) + sort_ens_like(i + 1)) / 2.0_r8
end do

! Likelihoods for outermost regions (bounded or unbounded); just outermost ensemble like
region_likelihood(0) = sort_ens_like(1)
region_likelihood(ens_size) = sort_ens_like(ens_size)

! Fail if lower bound is larger than smallest ensemble member 
if(is_bounded(1)) then
   ! Do in two ifs in case the bound is not defined
   if(s_ens(1) < bound(1)) then
      msgstring = 'Ensemble member less than lower bound'
      call error_handler(E_ERR, 'obs_increment_bounded_norm_rhf', msgstring, source)
   endif
endif

! Fail if upper bound is smaller than the largest ensemble member 
if(is_bounded(2)) then
   if(s_ens(ens_size) > bound(2)) then
      msgstring = 'Ensemble member greater than upper bound'
      call error_handler(E_ERR, 'obs_increment_bounded_norm_rhf', msgstring, source)
   endif
endif

! Posterior is prior times likelihood, normalized so the sum of weight is 1
! Prior has 1 / (ens_size + 1) probability in each region, so it just normalizes out.
! Posterior weights are then just the likelihood in each region normalized
post_weight = region_likelihood / sum(region_likelihood)

! Standard deviation of prior tails is prior ensemble standard deviation
prior_sd = sqrt(prior_var)
tail_sd(1:2) = prior_sd
! Find a mean so that 1 / (ens_size + 1) probability is in outer regions
tail_mean(1) = s_ens(1) + dist_for_unit_sd * prior_sd
tail_mean(2) = s_ens(ens_size) - dist_for_unit_sd * prior_sd

! If the distribution is bounded, still want 1 / (ens_size + 1) in outer regions
! Put an amplitude term (greater than 1) in front of the tail normals 
! The quantiles for the unbounded case are set first, then changed if bounded
bound_quantile(1) = 0.0_r8
bound_quantile(2) = 1.0_r8

do i = 1, 2
   if(is_bounded(i)) then
      ! Compute the CDF at the bounds for the two tail normals
      bound_quantile(i) = norm_cdf(bound(i), tail_mean(i), tail_sd(i))
   endif
end do

! Prior tail amplitude is  ratio of original probability to that retained in tail after bounding
! Numerical concern, if ensemble is close to bound amplitude can become unbounded? Use inverse.
base_prior_prob = 1.0_r8 / (ens_size + 1.0_r8)
prior_inv_tail_amp(1) = (base_prior_prob - bound_quantile(1)) / base_prior_prob
prior_inv_tail_amp(2) = (base_prior_prob - (1.0_r8 - bound_quantile(2))) / base_prior_prob

! Also multiply by the normalization factor for the posterior
! The change in amplitude is the posterior weight / prior weight (which is 1 / ens_size + 1)
! The post weights can technically get arbitrarily small
! Should incorporate some bound to avoid division by 0 here
inv_tail_amp(1) = prior_inv_tail_amp(1) / (post_weight(0) * (ens_size + 1.0_r8))
inv_tail_amp(2) = prior_inv_tail_amp(2) / (post_weight(ens_size) * (ens_size + 1.0_r8))

! To reduce code complexity, use a subroutine to find the update ensembles with this info
call find_bounded_norm_rhf_post(s_ens, ens_size, post_weight, tail_mean, tail_sd, &
   inv_tail_amp, bound, is_bounded, post)

! These are increments for sorted ensemble; convert to increments for unsorted
do i = 1, ens_size
   obs_inc(e_ind(i)) = post(i) - ens(e_ind(i))
end do

end subroutine obs_increment_bounded_norm_rhf


subroutine find_bounded_norm_rhf_post(ens, ens_size, post_weight, tail_mean, &
   tail_sd, inv_tail_amp, bound, is_bounded, post)
!------------------------------------------------------------------------
! Modifying code to make a more general capability top support bounded rhf
integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: ens(ens_size)
real(r8), intent(in)  :: post_weight(ens_size + 1)
real(r8), intent(in)  :: tail_mean(2)
real(r8), intent(in)  :: tail_sd(2)
real(r8), intent(in)  :: inv_tail_amp(2)
real(r8), intent(in)  :: bound(2)
logical,  intent(in)  :: is_bounded(2)
real(r8), intent(out) :: post(ens_size)

! Given a sorted set of points that bound rhf intervals and a 
! posterior weight for each interval, find an updated ensemble. 
! The tail mean and sd are dimensioned (2), first for the left tail, then for the right tail.
! Allowing the sd to be different could allow a Gaussian likelihood tail to be supported.
! The distribution on either side may be bounded and the bound is provided if so. The 
! distribution on the tails is a doubly truncated normal. The inverse of the posterior amplitude
! for the outermost regions is passed to minimize the possibility of overflow.

real(r8) :: cumul_mass(0:ens_size + 1), umass, target_mass
real(r8) :: smallest_ens_mass, largest_ens_mass
integer  :: i, j, lowest_box

! The posterior weight is already normalized here, see obs_increment_bounded_norm_rhf

! Find cumulative posterior probability mass at each box boundary
cumul_mass(0) = 0.0_r8
do i = 1, ens_size + 1
   cumul_mass(i) = cumul_mass(i - 1) + post_weight(i)
end do

! This reduces the impact of possible round-off errors on the cumulative mass
cumul_mass = cumul_mass / cumul_mass(ens_size + 1)

! Begin intenal box search at bottom of lowest box, update for efficiency
lowest_box = 1

! Find each new ensemble member's location
do i = 1, ens_size
   ! Each update ensemble member has 1/(ens_size+1) mass before it
   umass = (1.0_r8 * i) / (ens_size + 1.0_r8)

   !--------------------------------------------------------------------------
   ! If it is in the inner or outer range have to use normal tails
   if(umass < cumul_mass(1)) then
      ! It's in the left tail

      ! If the bound and the smallest ensemble member are identical then any posterior 
      ! in the lower interval is set to the value of the smallest ensemble member. 
      if(is_bounded(1) .and. ens(1) == bound(1)) then
         post(i) = ens(1)
      else
         !--------------------------------------------------------------------
         ! The obvious way to do this is in this commented block. However, there is a 
         ! risk of numerical problems if an ensemble member gets very close to the
         ! bound and generates very large tail amplitudes. The next block is identical
         ! with infinite precision arithmetic but will tolerate large amplitudes.
         ! Just divide everything by the amplitude and do same computations.
         ! Come in from the right (from the smallest ensemble member)
         !!! smallest_ens_mass = tail_amp(1) * norm_cdf(ens(1), tail_mean(1), tail_sd(1))
         ! Compute the target mass in the tail normal 
         !!! target_mass = smallest_ens_mass_mass + (umass - cumul_mass(1))
         !!! call weighted_norm_inv(tail_amp(1), tail_mean(1), tail_sd(1), target_mass, post(i))
         !--------------------------------------------------------------------

         ! Scale out the amplitude factor to safeguard against large amplitudes
         smallest_ens_mass = norm_cdf(ens(1), tail_mean(1), tail_sd(1))
         ! Compute the target mass in the tail normal 
         target_mass = smallest_ens_mass + (umass - cumul_mass(1)) * inv_tail_amp(1)
         call weighted_norm_inv(1.0_r8, tail_mean(1), tail_sd(1), target_mass, post(i))

         ! If posterior is less than bound, set it to bound. (Only possible thru roundoff).
         if(is_bounded(1) .and. post(i) < bound(1)) then
            ! Informative message for now can be turned off when code is mature
            write(*, *) 'SMALLER THAN BOUND', i, post(i), bound(1)
         endif
         if(is_bounded(1)) post(i) = max(post(i), bound(1))

         ! It might be possible to get a posterior from the tail that exceeds the smallest 
         ! prior ensemble member since the cdf and the inverse cdf are not exactly inverses. 
         ! This has not been observed and is not obviously problematic.
      endif

   !--------------------------------------------------------------------------
   else if(umass > cumul_mass(ens_size)) then
      ! It's in the right tail; will work coming in from the right using symmetry of tail normal
      if(is_bounded(2) .and. ens(ens_size) == bound(2)) then
         post(i) = ens(ens_size)
      else
         !--------------------------------------------------------------------
         ! See detailed comment on block for lower tail above
         ! Find the cdf of the (bounded) tail normal at the largest ensemble member
         !!! largest_ens_mass = tail_amp(2) * norm_cdf(ens(ens_size), tail_mean(2), tail_sd(2))
         ! Compute the target mass in the tail normal 
         !!! target_mass = largest_ens_mass + (umass - cumul_mass(ens_size))
         !!! call weighted_norm_inv(tail_amp(2), tail_mean(2), tail_sd(2), target_mass, post(i))
         !--------------------------------------------------------------------

         ! Find the cdf of the (bounded) tail normal at the largest ensemble member
         largest_ens_mass = norm_cdf(ens(ens_size), tail_mean(2), tail_sd(2))
         ! Compute the target mass in the tail normal 
         target_mass = largest_ens_mass + (umass - cumul_mass(ens_size)) * inv_tail_amp(2)
         call weighted_norm_inv(1.0_r8, tail_mean(2), tail_sd(2), target_mass, post(i))

        ! If post is larger than bound, set it to bound. (Only possible thru roundoff).
         if(is_bounded(2) .and. post(i) > bound(2)) then
            write(*, *) 'BIGGER THAN BOUND', i, post(i), bound(2)
         endif
         if(is_bounded(2)) post(i) = min(post(i), bound(2))
      endif

   !--------------------------------------------------------------------------
   else
      ! In one of the inner uniform boxes.
      FIND_BOX:do j = lowest_box, ens_size - 1
         ! Find the box that this mass is in
         if(umass >= cumul_mass(j) .and. umass <= cumul_mass(j + 1)) then

            ! Only supporting rectangular quadrature here: Linearly interpolate in mass
            post(i) = ens(j) + ((umass - cumul_mass(j)) / &
               (cumul_mass(j+1) - cumul_mass(j))) * (ens(j + 1) - ens(j))
            ! Don't need to search lower boxes again
            lowest_box = j
            exit FIND_BOX
         end if
      end do FIND_BOX
   endif
end do

end subroutine find_bounded_norm_rhf_post


subroutine get_obs_likelihood(obs_prior, ens_size, obs, obs_err_var, &
      base_obs_type, likelihood)
!------------------------------------------------------------------------
! Generic wrapper routine to control what kind of likelihood is computed for a given obs type
! For initial test it will just use the truncated normal likelihood
integer,  intent(in)  :: ens_size
real(r8), intent(in)  :: obs_prior(ens_size)
real(r8), intent(in)  :: obs
real(r8), intent(in)  :: obs_err_var
integer,  intent(in)  :: base_obs_type
real(r8), intent(out) :: likelihood(ens_size)

integer  :: i
logical  :: is_bounded(2)
real(r8) :: bound(2)

! For now just do a truncated normal likelihood (just a normal if no bounds)
is_bounded = .false.
bound = -99.9_r8

do i = 1, ens_size
   likelihood(i) = get_truncated_normal_like(obs_prior(i), obs, obs_err_var, is_bounded, bound)
end do

end subroutine get_obs_likelihood



! Computes a normal or truncated normal (above and/or below) likelihood.
function get_truncated_normal_like(x, obs, obs_var, is_bounded, bound)
!------------------------------------------------------------------------
real(r8)             :: get_truncated_normal_like
real(r8), intent(in) :: x
real(r8), intent(in) :: obs, obs_var
logical,  intent(in) :: is_bounded(2)
real(r8), intent(in) :: bound(2)

integer :: i
real(r8) :: cdf(2), obs_sd, weight

obs_sd = sqrt(obs_var)

! If the truth were at point x, what is the weight of the truncated normal obs error dist?
! If no bounds, the whole cdf is possible
cdf(1) = 0
cdf(2) = 1

! Compute the cdf's at the bounds if they exist
do i = 1, 2
   if(is_bounded(i)) then
      cdf(i) = norm_cdf(bound(i), x, obs_sd)
   endif
end do

! The weight is the reciprocal of the fraction of the cdf that is in legal range
weight = 1.0_r8 / (cdf(2) - cdf(1))

get_truncated_normal_like = weight * exp(-1.0_r8 * (x - obs)**2 / (2.0_r8 * obs_var))

end function get_truncated_normal_like



subroutine update_state_like(prior_state_index_sort, state_like, like, prior_state_mass, ens_size, alpha)
!-----------------------------------------------------------------------------------------------
! Computes cumulative localized likelihood for a given state variable ensmble
integer,  intent(in)              :: prior_state_index_sort(ens_size)
real(r8), intent(inout)           :: state_like(ens_size + 1)
real(r8), intent(in)              :: like(ens_size)
real(r8), intent(in)              :: prior_state_mass(ens_size + 1)
integer,  intent(in)              :: ens_size
real(r8), intent(in)              :: alpha

real(r8) :: weight(ens_size + 1), post_mass(ens_size + 1), loc_like(ens_size), s_like(ens_size)
real(r8) :: total_post_mass

integer :: i

integer, parameter :: smooth_width = 0

! Sort the likelihood for this state variable
s_like = like(prior_state_index_sort)

! First compute the localized piecewise constant likelihood for this state variable
! Get the weight for each of the intervals
weight(1) = s_like(1)
do i = 2, ens_size
   weight(i) = (s_like(i) + s_like(i-1)) / 2.0_r8
end do
weight(ens_size + 1) = s_like(ens_size)

! Posterior probability in each bin by multiplying by likelihood
post_mass = prior_state_mass * weight
! Normalize the total posterior mass
total_post_mass = sum(post_mass)

! GEFFQ localization
! Total post mass is the denominator in Bayes and the normalizing factor for the localization
do i = 1, ens_size
   loc_like(i) = alpha * s_like(i) + (1 - alpha) * total_post_mass
end do

! Now recompute the weights; Look at algebra for simpler way
weight(1) = loc_like(1)
do i = 2, ens_size
   weight(i) = (loc_like(i) + loc_like(i-1)) / 2.0_r8
end do
weight(ens_size + 1) = loc_like(ens_size)

! The weight is the values of the piecewise constant localized likelihood
! Take the product with the existing likelihood
state_like = state_like * weight

! Avoid underflow with lots of obs by normalizing 
! Which way is better?
state_like = state_like / (sum(state_like) / ens_size)
!***************************** Maybe this instead *****
!!!state_like = state_like / maxval(state_like)

end subroutine update_state_like



!---------------------------------------------------------------

subroutine obs_updates_ens(ens_size, num_groups, ens, updated_ens, ens_loc, ens_kind, &
   obs_prior, obs_inc, obs_prior_mean, obs_prior_var, obs_loc, obs_type, obs_time, &
   dist, cutoff_rev, net_a, adjust_obs_impact, obs_impact_table, &
   grp_size, grp_beg, grp_end, reg_factor_obs_index, reg_factor_ens_index, &
   final_factor, correl)

integer,             intent(in)  :: ens_size
integer,             intent(in)  :: num_groups
real(r8),            intent(in)  :: ens(ens_size)
real(r8),            intent(out) :: updated_ens(ens_size)
type(location_type), intent(in)  :: ens_loc
integer,             intent(in)  :: ens_kind
real(r8),            intent(in)  :: obs_prior(ens_size)
real(r8),            intent(in)  :: obs_inc(ens_size)
real(r8),            intent(in)  :: obs_prior_mean(num_groups)
real(r8),            intent(in)  :: obs_prior_var(num_groups)
type(location_type), intent(in)  :: obs_loc
integer,             intent(in)  :: obs_type
type(time_type),     intent(in)  :: obs_time
real(r8),            intent(in)  :: dist
real(r8),            intent(in)  :: cutoff_rev
real(r8),            intent(in)  :: net_a(num_groups)
logical,             intent(in)  :: adjust_obs_impact
real(r8),            intent(in)  :: obs_impact_table(:, :)
integer,             intent(in)  :: grp_size
integer,             intent(in)  :: grp_beg(num_groups)
integer,             intent(in)  :: grp_end(num_groups)
integer,             intent(in)  :: reg_factor_obs_index
integer(i8),         intent(in)  :: reg_factor_ens_index
real(r8),            intent(out) :: final_factor
real(r8),            intent(out) :: correl(num_groups)

real(r8) :: reg_coef(num_groups), increment(ens_size)
real(r8) :: cov_factor, reg_factor
integer  :: group, grp_bot, grp_top

! Compute the covariance localization and adjust_obs_impact factors
cov_factor = cov_and_impact_factors(obs_loc, obs_type, ens_loc, &
   ens_kind, dist, cutoff_rev, adjust_obs_impact, obs_impact_table)

! If no impact, don't do anything else
if(cov_factor <= 0.0_r8) then
   final_factor = cov_factor
   updated_ens = ens
   return
endif

! Loop through groups to update the state variable ensemble members
do group = 1, num_groups
   grp_bot = grp_beg(group); grp_top = grp_end(group)
   ! Do update of state, correl only needed for varying ss inflate but compute for all
   call update_from_obs_inc(obs_prior(grp_bot:grp_top), obs_prior_mean(group), &
      obs_prior_var(group), obs_inc(grp_bot:grp_top), ens(grp_bot:grp_top), grp_size, &
      increment(grp_bot:grp_top), reg_coef(group), net_a(group), correl(group))
end do

if(num_groups <= 1) then
   final_factor = cov_factor
else
   reg_factor = comp_reg_factor(num_groups, reg_coef, obs_time, &
      reg_factor_obs_index, reg_factor_ens_index)
   final_factor = min(cov_factor, reg_factor)
endif

! Get the updated ensemble
updated_ens = ens + final_factor * increment

end subroutine obs_updates_ens

!-------------------------------------------------------------

function cov_and_impact_factors(base_obs_loc, base_obs_type, state_loc, state_kind, &
dist, cutoff_rev, adjust_obs_impact, obs_impact_table)

! Computes the cov_factor and multiplies by obs_impact_factor if selected

real(r8) :: cov_and_impact_factors
type(location_type), intent(in) :: base_obs_loc
integer, intent(in) :: base_obs_type
type(location_type), intent(in) :: state_loc
integer, intent(in) :: state_kind
real(r8), intent(in) :: dist
real(r8), intent(in) :: cutoff_rev
logical, intent(in)  :: adjust_obs_impact
real(r8), intent(in) :: obs_impact_table(:, 0:)

real(r8) :: impact_factor, cov_factor

! Get external impact factors, cycle if impact of this ob on this state is zerio
if (adjust_obs_impact) then
   ! Get the impact factor from the table if requested
   impact_factor = obs_impact_table(base_obs_type, state_kind)
   if(impact_factor <= 0.0_r8) then
      ! Avoid the cost of computing cov_factor if impact is 0
      cov_and_impact_factors = 0.0_r8
      return
   endif
else
   impact_factor = 1.0_r8
endif

! Compute the covariance factor
cov_factor = comp_cov_factor(dist, cutoff_rev, &
   base_obs_loc, base_obs_type, state_loc, state_kind)

! Combine the impact_factor and the cov_factor
cov_and_impact_factors = cov_factor * impact_factor

end function cov_and_impact_factors


!------------------------------------------------------------------------

function norm_cdf(x_in, mean, sd)

! Approximate cumulative distribution function for normal
! with mean and sd evaluated at point x_in
! Only works for x>= 0.

real(r8)             :: norm_cdf
real(r8), intent(in) :: x_in, mean, sd

real(digits12) :: x, p, b1, b2, b3, b4, b5, t, density, nx

! Convert to a standard normal
nx = (x_in - mean) / sd

x = abs(nx)


! Use formula from Abramowitz and Stegun to approximate
p = 0.2316419_digits12
b1 = 0.319381530_digits12
b2 = -0.356563782_digits12
b3 = 1.781477937_digits12
b4 = -1.821255978_digits12
b5 = 1.330274429_digits12

t = 1.0_digits12 / (1.0_digits12 + p * x)

density = (1.0_digits12 / sqrt(2.0_digits12 * PI)) * exp(-x*x / 2.0_digits12)

norm_cdf = 1.0_digits12 - density * &
   ((((b5 * t + b4) * t + b3) * t + b2) * t + b1) * t

if(nx < 0.0_digits12) norm_cdf = 1.0_digits12 - norm_cdf

!write(*, *) 'cdf is ', norm_cdf

end function norm_cdf


!------------------------------------------------------------------------

subroutine weighted_norm_inv(alpha, mean, sd, p, x)

! Find the value of x for which the cdf of a N(mean, sd) multiplied times
! alpha has value p.

real(r8), intent(in)  :: alpha, mean, sd, p
real(r8), intent(out) :: x

real(r8) :: np

! Can search in a standard normal, then multiply by sd at end and add mean
! Divide p by alpha to get the right place for weighted normal
np = p / alpha

! Find spot in standard normal
call norm_inv(np, x)

! Add in the mean and normalize by sd
x = mean + x * sd

end subroutine weighted_norm_inv


!------------------------------------------------------------------------

subroutine norm_inv(p, x)

real(r8), intent(in)  :: p
real(r8), intent(out) :: x

! normal inverse
! translate from http://home.online.no/~pjacklam/notes/invnorm
! a routine written by john herrero

real(r8) :: p_low,p_high
real(r8) :: a1,a2,a3,a4,a5,a6
real(r8) :: b1,b2,b3,b4,b5
real(r8) :: c1,c2,c3,c4,c5,c6
real(r8) :: d1,d2,d3,d4
real(r8) :: q,r
a1 = -39.69683028665376_digits12
a2 =  220.9460984245205_digits12
a3 = -275.9285104469687_digits12
a4 =  138.357751867269_digits12
a5 = -30.66479806614716_digits12
a6 =  2.506628277459239_digits12
b1 = -54.4760987982241_digits12
b2 =  161.5858368580409_digits12
b3 = -155.6989798598866_digits12
b4 =  66.80131188771972_digits12
b5 = -13.28068155288572_digits12
c1 = -0.007784894002430293_digits12
c2 = -0.3223964580411365_digits12
c3 = -2.400758277161838_digits12
c4 = -2.549732539343734_digits12
c5 =  4.374664141464968_digits12
c6 =  2.938163982698783_digits12
d1 =  0.007784695709041462_digits12
d2 =  0.3224671290700398_digits12
d3 =  2.445134137142996_digits12
d4 =  3.754408661907416_digits12
p_low  = 0.02425_digits12
p_high = 1_digits12 - p_low
! Split into an inner and two outer regions which have separate fits
if(p < p_low) then
   q = sqrt(-2.0_digits12 * log(p))
   x = (((((c1*q + c2)*q + c3)*q + c4)*q + c5)*q + c6) / &
      ((((d1*q + d2)*q + d3)*q + d4)*q + 1.0_digits12)
else if(p > p_high) then
   q = sqrt(-2.0_digits12 * log(1.0_digits12 - p))
   x = -(((((c1*q + c2)*q + c3)*q + c4)*q + c5)*q + c6) / &
      ((((d1*q + d2)*q + d3)*q + d4)*q + 1.0_digits12)
else
   q = p - 0.5_digits12
   r = q*q
   x = (((((a1*r + a2)*r + a3)*r + a4)*r + a5)*r + a6)*q / &
      (((((b1*r + b2)*r + b3)*r + b4)*r + b5)*r + 1.0_digits12)
endif

end subroutine norm_inv

!------------------------------------------------------------------------

subroutine set_assim_tools_trace(execution_level, timestamp_level)
 integer, intent(in) :: execution_level
 integer, intent(in) :: timestamp_level

! set module local vars from the calling code to indicate how much
! output we should generate from this code.  execution level is
! intended to make it easier to figure out where in the code a crash
! is happening; timestamp level is intended to help with gross levels
! of overall performance profiling.  eventually, a level of 1 will
! print out only basic info; level 2 will be more detailed.
! (right now, only > 0 prints anything and it doesn't matter how
! large the value is.)

! Initialize assim_tools_module if needed
if (.not. module_initialized) call assim_tools_init()

print_trace_details = execution_level
print_timestamps    = timestamp_level

end subroutine set_assim_tools_trace

!--------------------------------------------------------------------

function revised_distance(orig_dist, newcount, oldcount, base, cutfloor)
 real(r8),            intent(in) :: orig_dist
 integer,             intent(in) :: newcount, oldcount
 type(location_type), intent(in) :: base
 real(r8),            intent(in) :: cutfloor

 real(r8)                        :: revised_distance

! take the ratio of the old and new counts, and revise the
! original cutoff distance to match.

! for now, only allow the code to do a 2d area adaption.
! to experiment with other schemes, set this local variable
! to .false. at the top of the file and recompile.

if (only_area_adapt) then

   revised_distance = orig_dist * sqrt(real(newcount, r8) / oldcount)

   ! allow user to set a minimum cutoff, so even if there are very dense
   ! observations the cutoff distance won't go below this floor.
   if (revised_distance < cutfloor) revised_distance = cutfloor
   return

endif

! alternatives for different dimensionalities and schemes

! Change the cutoff radius to get the appropriate number
if (LocationDims == 1) then
   ! linear (be careful of cyclic domains; if > domain, this is
   ! not going to be right)
   revised_distance = orig_dist * real(newcount, r8) / oldcount

else if (LocationDims == 2) then
   ! do an area scaling
   revised_distance = orig_dist * sqrt(real(newcount, r8) / oldcount)

else if (LocationDims == 3) then
   ! do either a volume or area scaling (depending on whether we are
   ! localizing in the vertical or not.)   if surface obs, assume a hemisphere
   ! and shrink more.

   if (vertical_localization_on()) then
      ! cube root for volume
      revised_distance = orig_dist * ((real(newcount, r8) / oldcount) &
                                      ** 0.33333333333333333333_r8)

      ! Cut the adaptive localization threshold in half again for 'surface' obs
      if (is_vertical(base, "SURFACE")) then
         revised_distance = revised_distance * (0.5_r8 ** 0.33333333333333333333_r8)
      endif
   else
      ! do an area scaling, even if 3d obs
      revised_distance = orig_dist * sqrt(real(newcount, r8) / oldcount)

      ! original code was:
      !cutoff_rev =  sqrt((2.0_r8*cutoff)**2 * adaptive_localization_threshold / &
      !   total_num_close_obs) / 2.0_r8

      ! original comment
      ! Need to get thinning out of assim_tools and into something about locations
   endif
else
   call error_handler(E_ERR, 'revised_distance', 'unknown locations dimension, not 1, 2 or 3', &
      source)
endif

! allow user to set a minimum cutoff, so even if there are very dense
! observations the cutoff distance won't go below this floor.
if (revised_distance < cutfloor) revised_distance = cutfloor

end function revised_distance

!--------------------------------------------------------------------

function count_close(num_close, index_list, my_types, dist, maxdist)
 integer, intent(in)  :: num_close, index_list(:), my_types(:)
 real(r8), intent(in) :: dist(:), maxdist
 integer :: count_close

! return the total number of items from the index_list which
! are types which are going to be assimilated, and within distance.
! this excludes items on the eval list only, not listed, or
! items too far away.   this routine does a global communication
! so if any MPI tasks make this call, all must.

integer :: k, thistype, local_count

local_count = 0
do k=1, num_close

   ! only accept items closer than limit
   if (dist(k) > maxdist) cycle

   ! include identity obs, plus types on assim list.
   ! you have to do the if tests separately because fortran allows
   ! both parts of an if(a .or. b) test to be eval'd at the same time.
   ! you'd be using a negative index if it was an identity obs.
   thistype = my_types(index_list(k))
   if (thistype < 0) then
      local_count = local_count + 1
   else if (assimilate_this_type_of_obs(thistype)) then
      local_count = local_count + 1
   endif
end do

! broadcast sums from all tasks to compute new total
call sum_across_tasks(local_count, count_close)

end function count_close

!----------------------------------------------------------------------
! Revise the cutoff for this observation if adaptive localization is required
! Output diagnostics for localization if requested

subroutine adaptive_localization_and_diags(cutoff_orig, cutoff_rev, adaptive_localization_threshold, &
   adaptive_cutoff_floor, num_close_obs, close_obs_ind, close_obs_dist, my_obs_type, &
   base_obs_index, base_obs_loc, obs_def, out_unit)

real(r8),            intent(in)  :: cutoff_orig
real(r8),            intent(out) :: cutoff_rev
integer,             intent(in)  :: adaptive_localization_threshold
real(r8),            intent(in)  :: adaptive_cutoff_floor
integer,             intent(in)  :: num_close_obs
integer,             intent(in)  :: close_obs_ind(:)
real(r8),            intent(in)  :: close_obs_dist(:)
integer,             intent(in)  :: my_obs_type(:)
integer,             intent(in)  :: base_obs_index
type(location_type), intent(in)  :: base_obs_loc
type(obs_def_type),  intent(in)  :: obs_def
integer,             intent(in)  :: out_unit

integer :: total_num_close_obs, rev_num_close_obs, secs, days
type(time_type) :: this_obs_time
character(len = 200) :: base_loc_text   ! longer than longest location formatting possible

! Default is that cutoff is not revised
cutoff_rev = cutoff_orig

! For adaptive localization, need number of other obs close to the chosen observation
if(adaptive_localization_threshold > 0) then
   ! this does a cross-task sum, so all tasks must make this call.
   total_num_close_obs = count_close(num_close_obs, close_obs_ind, my_obs_type, &
                                     close_obs_dist, cutoff_rev*2.0_r8)

   ! Want expected number of close observations to be reduced to some threshold;
   ! accomplish this by cutting the size of the cutoff distance.
   if(total_num_close_obs > adaptive_localization_threshold) then
      cutoff_rev = revised_distance(cutoff_rev*2.0_r8, adaptive_localization_threshold, &
                                    total_num_close_obs, base_obs_loc, &
                                    adaptive_cutoff_floor*2.0_r8) / 2.0_r8
   endif
endif

if ( output_localization_diagnostics ) then
   ! Warning, this can be costly and generate large output
   ! This is referred to as revised in case adaptive localization was done
   rev_num_close_obs = count_close(num_close_obs, close_obs_ind, my_obs_type, &
                                     close_obs_dist, cutoff_rev*2.0_r8)

   ! Output diagnostic information about the number of close obs
   if (my_task_id() == 0) then
      this_obs_time = get_obs_def_time(obs_def)
      call get_time(this_obs_time,secs,days)
      call write_location(-1, base_obs_loc, charstring=base_loc_text)

      ! If adaptive localization did something, output info about what it did
      ! Probably would be more consistent to just output for all observations
      if(adaptive_localization_threshold > 0 .and. &
         total_num_close_obs > adaptive_localization_threshold) then
         write(out_unit,'(i12,1x,i5,1x,i8,1x,A,2(f14.5,1x,i12))') base_obs_index, &
            secs, days, trim(base_loc_text), cutoff_orig, total_num_close_obs, cutoff_rev, &
            rev_num_close_obs
      else
         write(out_unit,'(i12,1x,i5,1x,i8,1x,A,f14.5,1x,i12)') base_obs_index, &
            secs, days, trim(base_loc_text), cutoff_rev, rev_num_close_obs
      endif
   endif
endif

end subroutine adaptive_localization_and_diags

!----------------------------------------------------------------------
!> gets the location of of all my observations
subroutine get_my_obs_loc(obs_ens_handle, obs_seq, keys, my_obs_loc, my_obs_kind, my_obs_type, my_obs_time)

type(ensemble_type),      intent(in)  :: obs_ens_handle
type(obs_sequence_type),  intent(in)  :: obs_seq
integer,                  intent(in)  :: keys(:)
type(location_type),      intent(out) :: my_obs_loc(:)
integer,                  intent(out) :: my_obs_type(:), my_obs_kind(:)
type(time_type),          intent(out) :: my_obs_time

type(obs_type) :: observation
type(obs_def_type)   :: obs_def
integer :: this_obs_key
integer i
type(location_type) :: dummyloc

Get_Obs_Locations: do i = 1, obs_ens_handle%my_num_vars

   this_obs_key = keys(obs_ens_handle%my_vars(i)) ! if keys becomes a local array, this will need changing
   call get_obs_from_key(obs_seq, this_obs_key, observation)
   call get_obs_def(observation, obs_def)
   my_obs_loc(i)  = get_obs_def_location(obs_def)
   my_obs_type(i) = get_obs_def_type_of_obs(obs_def)
   if (my_obs_type(i) > 0) then
         my_obs_kind(i) = get_quantity_for_type_of_obs(my_obs_type(i))
   else
      call get_state_meta_data(-1 * int(my_obs_type(i),i8), dummyloc, my_obs_kind(i))
   endif
end do Get_Obs_Locations

! Need the time for regression diagnostics potentially; get from first observation
my_obs_time = get_obs_def_time(obs_def)

end subroutine get_my_obs_loc

!--------------------------------------------------------------------
!> Get close obs from cache if appropriate. Cache new get_close_obs info
!> if requested.

subroutine get_close_obs_cached(close_obs_caching, gc_obs, base_obs_loc, base_obs_type, &
   my_obs_loc, my_obs_kind, my_obs_type, num_close_obs, close_obs_ind, close_obs_dist,  &
   ens_handle, last_base_obs_loc, last_num_close_obs, last_close_obs_ind,               &
   last_close_obs_dist, num_close_obs_cached, num_close_obs_calls_made)

logical, intent(in) :: close_obs_caching
type(get_close_type),          intent(in)  :: gc_obs
type(location_type),           intent(inout) :: base_obs_loc, my_obs_loc(:)
integer,                       intent(in)  :: base_obs_type, my_obs_kind(:), my_obs_type(:)
integer,                       intent(out) :: num_close_obs, close_obs_ind(:)
real(r8),                      intent(out) :: close_obs_dist(:)
type(ensemble_type),           intent(in)  :: ens_handle
type(location_type), intent(inout) :: last_base_obs_loc
integer, intent(inout) :: last_num_close_obs
integer, intent(inout) :: last_close_obs_ind(:)
real(r8), intent(inout) :: last_close_obs_dist(:)
integer, intent(inout) :: num_close_obs_cached, num_close_obs_calls_made

! This logic could be arranged to make code less redundant
if (.not. close_obs_caching) then
   call get_close_obs(gc_obs, base_obs_loc, base_obs_type, &
                      my_obs_loc, my_obs_kind, my_obs_type, &
                      num_close_obs, close_obs_ind, close_obs_dist, ens_handle)
else
   if (base_obs_loc == last_base_obs_loc) then
      num_close_obs     = last_num_close_obs
      close_obs_ind(:)  = last_close_obs_ind(:)
      close_obs_dist(:) = last_close_obs_dist(:)
      num_close_obs_cached = num_close_obs_cached + 1
   else
      call get_close_obs(gc_obs, base_obs_loc, base_obs_type, &
                         my_obs_loc, my_obs_kind, my_obs_type, &
                         num_close_obs, close_obs_ind, close_obs_dist, ens_handle)

      last_base_obs_loc      = base_obs_loc
      last_num_close_obs     = num_close_obs
      last_close_obs_ind(:)  = close_obs_ind(:)
      last_close_obs_dist(:) = close_obs_dist(:)
      num_close_obs_calls_made = num_close_obs_calls_made +1
   endif
endif

end subroutine get_close_obs_cached

!--------------------------------------------------------------------
!> Get close state from cache if appropriate. Cache new get_close_state info
!> if requested.

subroutine get_close_state_cached(close_obs_caching, gc_state, base_obs_loc, base_obs_type, &
   my_state_loc, my_state_kind, my_state_indx, num_close_states, close_state_ind, close_state_dist,  &
   ens_handle, last_base_states_loc, last_num_close_states, last_close_state_ind,               &
   last_close_state_dist, num_close_states_cached, num_close_states_calls_made)

logical, intent(in) :: close_obs_caching
type(get_close_type),          intent(in)    :: gc_state
type(location_type),           intent(inout) :: base_obs_loc, my_state_loc(:)
integer,                       intent(in)    :: base_obs_type, my_state_kind(:)
integer(i8),                   intent(in)    :: my_state_indx(:)
integer,                       intent(out)   :: num_close_states, close_state_ind(:)
real(r8),                      intent(out)   :: close_state_dist(:)
type(ensemble_type),           intent(in)    :: ens_handle
type(location_type), intent(inout) :: last_base_states_loc
integer, intent(inout) :: last_num_close_states
integer, intent(inout) :: last_close_state_ind(:)
real(r8), intent(inout) :: last_close_state_dist(:)
integer, intent(inout) :: num_close_states_cached, num_close_states_calls_made

! This logic could be arranged to make code less redundant
if (.not. close_obs_caching) then
   call get_close_state(gc_state, base_obs_loc, base_obs_type, &
                      my_state_loc, my_state_kind, my_state_indx, &
                      num_close_states, close_state_ind, close_state_dist, ens_handle)
else
   if (base_obs_loc == last_base_states_loc) then
      num_close_states     = last_num_close_states
      close_state_ind(:)  = last_close_state_ind(:)
      close_state_dist(:) = last_close_state_dist(:)
      num_close_states_cached = num_close_states_cached + 1
   else
      call get_close_state(gc_state, base_obs_loc, base_obs_type, &
                         my_state_loc, my_state_kind, my_state_indx, &
                         num_close_states, close_state_ind, close_state_dist, ens_handle)

      last_base_states_loc      = base_obs_loc
      last_num_close_states     = num_close_states
      last_close_state_ind(:)  = close_state_ind(:)
      last_close_state_dist(:) = close_state_dist(:)
      num_close_states_calls_made = num_close_states_calls_made +1
   endif
endif

end subroutine get_close_state_cached

!--------------------------------------------------------------------
!> log what the user has selected via the namelist choices

subroutine log_namelist_selections(num_special_cutoff, cache_override)

integer, intent(in) :: num_special_cutoff
logical, intent(in) :: cache_override

integer :: i

select case (filter_kind)
 case (1)
   msgstring = 'Ensemble Adjustment Kalman Filter (EAKF)'
 case (2)
   msgstring = 'Ensemble Kalman Filter (ENKF)'
 case (8)
   msgstring = 'Rank Histogram Filter'
 case (101)
   msgstring = 'Bounded Normal Rank Histogram Filter'
 case default
   call error_handler(E_ERR, 'assim_tools_init:', 'illegal filter_kind value, valid values are 1, 2, 8, 101', &
                      source)
end select
call error_handler(E_MSG, 'assim_tools_init:', 'Selected filter type is '//trim(msgstring))

if (adjust_obs_impact) then
   call allocate_impact_table(obs_impact_table)
   call read_impact_table(obs_impact_filename, obs_impact_table, allow_any_impact_values, "allow_any_impact_values")
   call error_handler(E_MSG, 'assim_tools_init:', &
                      'Using observation impact table from file "'//trim(obs_impact_filename)//'"')
endif

write(msgstring,  '(A,F18.6)') 'The cutoff namelist value is ', cutoff
write(msgstring2, '(A)') 'cutoff is the localization half-width parameter,'
write(msgstring3, '(A,F18.6)') 'so the effective localization radius is ', cutoff*2.0_r8
call error_handler(E_MSG,'assim_tools_init:', msgstring, text2=msgstring2, text3=msgstring3)

if (has_special_cutoffs) then
   call error_handler(E_MSG, '', '')
   call error_handler(E_MSG,'assim_tools_init:','Observations with special localization treatment:')
   call error_handler(E_MSG,'assim_tools_init:','(type name, specified cutoff distance, effective localization radius)')

   do i = 1, num_special_cutoff
      write(msgstring, '(A32,F18.6,F18.6)') special_localization_obs_types(i), &
            special_localization_cutoffs(i), special_localization_cutoffs(i)*2.0_r8
      call error_handler(E_MSG,'assim_tools_init:', msgstring)
   end do
   call error_handler(E_MSG,'assim_tools_init:','all other observation types will use the default cutoff distance')
   call error_handler(E_MSG, '', '')
endif

if (cache_override) then
   call error_handler(E_MSG,'assim_tools_init:','Disabling the close obs caching because specialized localization')
   call error_handler(E_MSG,'assim_tools_init:','distances are enabled. ')
endif

if(adaptive_localization_threshold > 0) then
   write(msgstring, '(A,I10,A)') 'Using adaptive localization, threshold ', &
                                  adaptive_localization_threshold, ' obs'
   call error_handler(E_MSG,'assim_tools_init:', msgstring)
   if(adaptive_cutoff_floor > 0.0_r8) then
      write(msgstring, '(A,F18.6)') 'Minimum cutoff will not go below ', &
                                     adaptive_cutoff_floor
      call error_handler(E_MSG,'assim_tools_init:', 'Using adaptive localization cutoff floor.', &
                         text2=msgstring)
   endif
endif

if(output_localization_diagnostics) then
   call error_handler(E_MSG,'assim_tools_init:', 'Writing localization diagnostics to file:')
   call error_handler(E_MSG,'assim_tools_init:', trim(localization_diagnostics_file))
endif

if(sampling_error_correction) then
   call error_handler(E_MSG,'assim_tools_init:', 'Using Sampling Error Correction')
endif

if (task_count() > 1) then
    if(distribute_mean) then
       msgstring  = 'Distributing one copy of the ensemble mean across all tasks'
       msgstring2 = 'uses less memory per task but may run slower if doing vertical '
    else
       msgstring  = 'Replicating a copy of the ensemble mean on every task'
       msgstring2 = 'uses more memory per task but may run faster if doing vertical '
    endif
    call error_handler(E_MSG,'assim_tools_init:', msgstring, text2=msgstring2, &
                       text3='coordinate conversion; controlled by namelist item "distribute_mean"')
endif

if (has_vertical_choice()) then
   if (.not. vertical_localization_on()) then
      msgstring = 'Not doing vertical localization, no vertical coordinate conversion required'
      call error_handler(E_MSG,'assim_tools_init:', msgstring)
   else
      msgstring = 'Doing vertical localization, vertical coordinate conversion may be required'
      if (convert_all_state_verticals_first) then
         msgstring2 = 'Converting all state vector verticals to localization coordinate first.'
      else
         msgstring2 = 'Converting all state vector verticals only as needed.'
      endif
      if (convert_all_obs_verticals_first) then
         msgstring3 = 'Converting all observation verticals to localization coordinate first.'
      else
         msgstring3 = 'Converting all observation verticals only as needed.'
      endif
      call error_handler(E_MSG,'assim_tools_init:', msgstring, text2=msgstring2, text3=msgstring3)
   endif
endif

end subroutine log_namelist_selections

!===========================================================
! TEST FUNCTIONS BELOW THIS POINT
!-----------------------------------------------------------
!> test get_state_meta_data
!> Write out the resutls of get_state_meta_data for each task
!> They should be the same as the Trunk version
subroutine test_get_state_meta_data(locations, num_vars)

type(location_type), intent(in) :: locations(:)
integer,             intent(in) :: num_vars

character*20  :: task_str !< string to hold the task number
character*129 :: file_meta !< output file name
character(len=128) :: locinfo
integer :: i

write(task_str, '(i10)') my_task_id()
file_meta = TRIM('test_get_state_meta_data' // TRIM(ADJUSTL(task_str)))

open(15, file=file_meta, status = 'unknown')

do i = 1, num_vars
   call write_location(-1, locations(i), charstring=locinfo)
   write(15,*) trim(locinfo)
enddo

close(15)


end subroutine test_get_state_meta_data

!--------------------------------------------------------
!> dump out the copies array for the state ens handle
subroutine test_state_copies(state_ens_handle, information)

type(ensemble_type), intent(in) :: state_ens_handle
character(len=*),        intent(in) :: information

character*20  :: task_str !< string to hold the task number
character*129 :: file_copies !< output file name
integer :: i

write(task_str, '(i10)') state_ens_handle%my_pe
file_copies = TRIM('statecopies_'  // TRIM(ADJUSTL(information)) // '.' // TRIM(ADJUSTL(task_str)))
open(15, file=file_copies, status ='unknown')

do i = 1, state_ens_handle%num_copies - state_ens_handle%num_extras
   write(15, *) state_ens_handle%copies(i,:)
enddo

close(15)

end subroutine test_state_copies

!--------------------------------------------------------
!> dump out the distances calculated in get_close_obs
subroutine test_close_obs_dist(distances, num_close, ob)

real(r8), intent(in) :: distances(:) !< array of distances calculated in get_close
integer,  intent(in) :: num_close !< number of close obs
integer,  intent(in) :: ob

character*20  :: task_str !< string to hold the task number
character*20  :: ob_str !< string to hold ob number
character*129 :: file_dist !< output file name
integer :: i

write(task_str, '(i10)') my_task_id()
write(ob_str, '(i20)') ob
file_dist = TRIM('distances'   // TRIM(ADJUSTL(task_str)) // '.' // TRIM(ADJUSTL(ob_str)))
open(15, file=file_dist, status ='unknown')

write(15, *) num_close

do i = 1, num_close
   write(15, *) distances(i)
enddo

close(15)

end subroutine test_close_obs_dist

!> @}

!========================================================================
! end module assim_tools_mod
!========================================================================

end module assim_tools_mod

