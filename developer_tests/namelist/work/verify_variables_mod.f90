module verify_variables_mod

use              types_mod, only : r8, MISSING_R8
use          utilities_mod, only : error_handler, E_ERR, E_MSG, do_output, to_upper
use   netcdf_utilities_mod, only : NF90_MAX_NAME
use           obs_kind_mod, only : QTY_TEMPERATURE, QTY_SALINITY, QTY_DRY_LAND,      &
                             QTY_U_CURRENT_COMPONENT,QTY_V_CURRENT_COMPONENT,  &
                             QTY_SEA_SURFACE_HEIGHT, QTY_SEA_SURFACE_PRESSURE, &
                             QTY_POTENTIAL_TEMPERATURE, QTY_SEA_SURFACE_ANOMALY, &
                             get_index_for_quantity, get_name_for_quantity

implicit none

private
public :: verify_variables

character(len=256), parameter :: source   = "$URL$"
character(len=32 ), parameter :: revision = "$Revision$"
character(len=128), parameter :: revdate  = "$Date$"
character(len=512) :: string1
character(len=512) :: string2

contains

!-----------------------------------------------------------------------
! Subroutine for verifying state variables.
! - state_variables: list of state variables from namelist
! - ngood: amount of state variable rows validated
! - table: 2D string array of state variables
! - var_names: array of NetCDF variable names
! - var_qtys: array of DART QUANTITY
! - var_update: array of UPDATE flags (optional)
! - var_ranges: 2D array of ranges (optional)
! - default_vars: flag to check DART QUANTITY (optional, default = true)
!-----------------------------------------------------------------------
subroutine verify_variables(state_variables, ngood, table, var_names, &
                       var_qtys, var_update, var_ranges, default_vars)

character(len=*),   intent(inout) :: state_variables(:)
integer,            intent(out)   :: ngood
character(len=*),   intent(out)   :: table(:,:)
character(len=*),   intent(out)   :: var_names(:)
integer,            intent(out)   :: var_qtys(:) ! - kind_list
logical,  optional, intent(out)   :: var_update(:) ! - update_var, optional
real(r8), optional, intent(out)   :: var_ranges(:,:) ! - optional
logical,  optional, intent(in)    :: default_vars ! - optional
 
character(len=*), parameter :: routine = 'verify_variables'

integer  :: io, i, nrows, ncols
real(r8) :: minvalue, maxvalue
logical  :: check_obs
character(len=NF90_MAX_NAME) :: varname, dartstr, minvalstring, maxvalstring, update

nrows = size(table,1)
ncols = size(table) / size(table,1)
check_obs = .true.

ngood = 0

MyLoop : do i = 1, nrows
    
    varname = trim(state_variables(ncols * i - (ncols - 1)))
    dartstr = trim(state_variables(ncols * i - (ncols - 2)))

    if ( table(i,1) == ' ' .and. table(i,2) == ' ') exit MyLoop ! Found end of list.

    if ( table(i,1) == ' ' .or. table(i,2) == ' ') then
      string1 = 'model_nml:state_variables not fully specified'
      call error_handler(E_ERR,routine,string1,source,revision,revdate)
    endif


    if (present(default_vars)) check_obs = default_vars

    ! The internal DART routines check if the variable name is valid.
    
    if (check_obs)  then
        var_qtys(i) = get_index_for_quantity(dartstr)
        if( var_qtys(i) < 0 ) then
            write(string1,'(''there is no obs_kind <'',a,''> in obs_kind_mod.f90'')') trim(dartstr)
            write(string2,'(A)') 'Hint: set default_vars as false if using non default state_variables'
            call error_handler(E_ERR,routine,string1,source,revision,revdate, text2=string2)
        endif
    endif

    ! All good to here - fill the output variables
    ngood = ngood + 1

    var_names(ngood) = varname

    table(i,1) = trim(varname)
    table(i,2) = trim(dartstr)

    ! Check to see if other columns variables are present from default

    if (ncols == 5) then
        var_ranges(ngood,:) = (/ MISSING_R8, MISSING_R8 /)

        minvalstring = trim(state_variables(ncols * i - (ncols - 3)))
        maxvalstring = trim(state_variables(ncols * i - (ncols - 4)))
        update = trim(state_variables(ncols * i - (ncols - 5)))

        ! Convert the [min,max] valstrings to numeric values if possible

        read(minvalstring,*,iostat=io) minvalue
        if (io == 0) var_ranges(ngood,1) = minvalue
        table(i,3) = trim(minvalstring)

        read(maxvalstring,*,iostat=io) maxvalue
        if (io == 0) var_ranges(ngood,2) = maxvalue
        table(i,4) = trim(maxvalstring)

        call to_upper(update) 
        table(i,5) = trim(update)

    else if (ncols == 3) then
        update = trim(state_variables(ncols * i - (ncols - 3)))

        call to_upper(update)
        table(i,3) = trim(update)
    end if

    ! Records false in var_update if string is anything but "UPDATE"

    if ( present(var_update) )then
        var_update(ngood) = .false.
        if (update == 'UPDATE') var_update(ngood) = .true.
    endif

    ! Record the contents of the DART state vector

    if (do_output()) then
        SELECT CASE (ncols) 
            CASE (5)
                write(string1,'(A,I2,10A)') 'variable ',i,' is ',trim(varname), ', ', trim(dartstr), &
                    ', ', trim(minvalstring), ', ', trim(maxvalstring), ', ', trim(update)
                call error_handler(E_MSG,routine,string1,source,revision,revdate)
            CASE (3)
                write(string1,'(A,I2,6A)') 'variable ',i,' is ',trim(varname), ', ', trim(dartstr), &
                    ', ', trim(update)
                call error_handler(E_MSG,routine,string1,source,revision,revdate)
            CASE DEFAULT
                write(string1,'(A,I2,4A)') 'variable ',i,' is ',trim(varname), ', ', trim(dartstr)
                call error_handler(E_MSG,routine,string1,source,revision,revdate)
        END SELECT
    endif
enddo MyLoop

! check to see if temp and salinity are both in the state otherwise you will not
! be able to interpolate in XXX subroutine
if ( any(var_qtys == QTY_SALINITY) ) then
   ! check to see that temperature is also in the variable list
   if ( .not. any(var_qtys == QTY_POTENTIAL_TEMPERATURE) ) then
      write(string1,'(A)') 'in order to compute temperature you need to have both '
      write(string2,'(A)') 'QTY_SALINITY and QTY_POTENTIAL_TEMPERATURE in the model state'
      call error_handler(E_ERR,routine,string1,source,revision,revdate, text2=string2)
   endif
endif

end subroutine verify_variables
!-----------------------------------------------------------------------
!-----------------------------------------------------------------------
end module verify_variables_mod
