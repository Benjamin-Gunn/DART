! Data Assimilation Research Testbed -- DART
! Copyright 2004-2006, Data Assimilation Research Section
! University Corporation for Atmospheric Research
! Licensed under the GPL -- www.gpl.org/licenses/gpl.html

PROGRAM convertdate

! <next five lines automatically updated by CVS, do not edit>
! $Source$
! $Revision$
! $Date$
! $Author$
! $Name$

use time_manager_mod

implicit none

! CVS Generated file description for error handling, do not edit
character(len=128) :: &
source   = "$Source$", &
revision = "$Revision$", &
revdate  = "$Date$"

integer :: direction
type(time_type)   :: atime
integer           :: year, month, day, hour, minute, second
integer           :: jday
integer           :: days, seconds

integer :: days_per_month(12) = (/31,28,31,30,31,30,31,31,30,31,30,31/)

!  days prior to beginning of each month (non&) leap year

integer, parameter, dimension( 13) :: &
   bgn_day = (/ 0,  31,  59,  90, 120, 151, &
              181, 212, 243, 273, 304, 334, 365 /), &
   bgn_day_ly = (/ 0,  31,  60,  91, 121, 152, &
                 182, 213, 244, 274, 305, 335, 366 /)


!  begin
write(6,*) 'Which direction? '
write(6,*) 'YYYY MM DD HH MM SS ===>  Gregorian day and second  (1)'
write(6,*) 'YYYY MM DD HH MM SS <===  Gregorian day and second  (2)'
write(6,*) 'YYYY MM DD          ===>  Julian day of year YYYY   (3)'
write(6,*) 'YYYY MM DD          <===  Julian day of year YYYY   (4)'

read(5,*) direction

if ( direction == 1 ) then
   write(*,*) 'Input YYYY MM DD HH MM SS: '
   read(*,*) year, month, day, hour, minute, second
   atime=set_date_gregorian(year, month, day, hour, minute, second)
   call get_time (atime, seconds, days)
   write(*,*) 'Gregorian days and second: ', days, seconds

else if ( direction == 2 ) then
   write(*,*) 'Input Gregorian days and second: '
   read(*,*) days, seconds
   atime = set_time(seconds, days)
   call get_date_gregorian(atime, year, month, day, hour, minute, second)
   write (*,FMT='(I4,5I3.2)') year, month, day, hour, minute, second

else if ( direction == 3 ) then
   write(*,*) 'Input YYYY MM DD: '
   read(*,*) year, month, day
   if(isleapyear(year)) then
      jday=bgn_day_ly(month)+day
   else
      jday=bgn_day(month)+day
   endif
   write(*,*) 'Julian day: ', year, jday

else if ( direction == 4 ) then
   write(*,*) 'Input Julian YYYY and JDAY: '
   read(*,*) year, jday
   do month=1,12
      if(isleapyear(year)) then
        if( (jday>bgn_day_ly(month)) .and. (jday<=bgn_day_ly(month+1)) ) then
          day = jday - bgn_day_ly(month)
          exit
        endif
      else
        if( (jday>bgn_day(month)) .and. (jday<=bgn_day(month+1)) ) then
          day = jday - bgn_day(month)
          exit
        endif
      endif
   enddo
   write(*,*) year, month, day
endif

contains

function isleapyear(year)
! check if year is leapyear
implicit none
integer,intent(in) :: year
logical :: isleapyear

if( mod(year,4) .ne. 0 ) then
  isleapyear=.FALSE.
else 
  isleapyear=.TRUE.
  if ( mod(year,100) == 0 .and. mod(year,400) .ne. 0 ) isleapyear=.FALSE.
endif
end function isleapyear

end program convertdate