program test_read_variable_namelist

use    utilities_mod, only : find_namelist_in_file, check_namelist_read 
use    mpi_utilities_mod, only : initialize_mpi_utilities,                &
                                 finalize_mpi_utilities
use    types_mod, only : r8, vtablenamelength
use    verify_variables_mod, only : verify_variables

implicit none

integer, parameter :: nrows = 5 ! - Hard Coded
integer, parameter :: ncols = 3 ! - Hard Coded
 
character(len=vtablenamelength) :: state_variables(nrows * ncols)
 
integer :: iunit, io, ngood
integer :: var_qtys(nrows)
character(len=vtablenamelength) :: table(nrows, ncols)
character(len=vtablenamelength) :: var_names(nrows)
logical  :: var_update(nrows)
real(r8) :: var_ranges(nrows, 2)

namelist /model_nml/  &
   state_variables

call initialize_mpi_utilities('test_read_write_restarts')

call find_namelist_in_file('input.nml', 'model_nml', iunit)
read(iunit, nml = model_nml, iostat = io)
call check_namelist_read(iunit, io, 'model_nml')

print*, "Hello World!"

call verify_variables(state_variables, ngood, table, var_names, &
                       var_qtys, var_update, var_ranges)!, .false.) 

!print*, state_variables, ngood, table, var_names, & 
!                       var_qtys, var_update, var_ranges

print*, var_qtys

call finalize_mpi_utilities()

end program test_read_variable_namelist