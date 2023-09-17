program test_read_variable_namelist

use    utilities_mod, only : find_namelist_in_file, check_namelist_read 
use    mpi_utilities_mod, only : initialize_mpi_utilities,                &
                                 finalize_mpi_utilities
use    types_mod, only : r8, vtablenamelength
use    verify_variables_mod, only : verify_variables

implicit none

integer, parameter :: nrows = 3 ! - Hard Coded
integer, parameter :: ncols = 5 ! - Hard Coded

character(len=vtablenamelength) :: state_variables(nrows, ncols)

integer :: iunit, io, ngood
integer :: var_qtys(ncols)
character(len=vtablenamelength) :: var_names(ncols)
logical  :: var_update(ncols)
real(r8) :: var_ranges(ncols, 2)

namelist /model_nml/  &
   state_variables

call initialize_mpi_utilities('test_read_write_restarts')

call find_namelist_in_file('input.nml', 'model_nml', iunit)
read(iunit, nml = model_nml, iostat = io)
call check_namelist_read(iunit, io, 'model_nml')

print*, "Hello World!"

call verify_variables(state_variables, ngood, var_names, &
                        var_qtys, var_update, var_ranges)

call finalize_mpi_utilities()

end program test_read_variable_namelist