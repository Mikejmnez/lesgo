!!
!!  Copyright (C) 2009-2013  Johns Hopkins University
!!
!!  This file is part of lesgo.
!!
!!  lesgo is free software: you can redistribute it and/or modify
!!  it under the terms of the GNU General Public License as published by
!!  the Free Software Foundation, either version 3 of the License, or
!!  (at your option) any later version.
!!
!!  lesgo is distributed in the hope that it will be useful,
!!  but WITHOUT ANY WARRANTY; without even the implied warranty of
!!  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
!!  GNU General Public License for more details.
!!
!!  You should have received a copy of the GNU General Public License
!!  along with lesgo.  If not, see <http://www.gnu.org/licenses/>.
!!

!--this assumes MPI
subroutine tridag_array_pipelined (tag, a, b, c, r, u)
use types,only:rprec
use param
implicit none

integer, intent (in) :: tag  !--base tag
real(kind=rprec),dimension(lh, ny, nz+1),intent(in):: a, b, c
!complex(kind=rprec),dimension(lh, ny, nz+1),intent(in) :: r
!complex(kind=rprec),dimension(lh, ny, nz+1),intent(out):: u

!  u and r are interleaved as complex arrays
real(rprec), dimension(ld,ny,nz+1), intent(in) :: r
real(rprec), dimension(ld,ny,nz+1), intent(out) :: u

! integer, parameter :: n = nz+1
! integer, parameter :: nchunks = ny  !--need to experiment to get right value
integer :: n, nchunks

!integer :: nchunks
integer :: chunksize
integer :: cstart, cend
integer::jx, jy, j, j_min, j_max
integer :: tag0
integer :: q
integer :: ir, ii

real(kind=rprec)::bet(lh, ny)
real(kind=rprec),dimension(lh, ny, nz+1)::gam

!--want to skip ny/2+1 and 1, 1

! Initialize variables
n = nz + 1
nchunks = ny

chunksize = ny / nchunks  !--make sure nchunks divides ny evenly

if (coord == 0) then

  do jy = 1, ny
    do jx = 1, lh-1

$if ($SAFETYMODE)
      if (b(jx, jy, 1) == 0._rprec) then
        write (*, *) 'tridag_array: rewrite eqs, jx, jy= ', jx, jy
        stop
      end if
$endif

      ii = 2*jx
      ir = ii - 1

      u(ir:ii,jy,1) = r(ir:ii,jy,1) / b(jx,jy,1)

    end do
  end do

  bet = b(:, :, 1)
  ! u is now set above
  !u(:, :, 1) = r(:, :, 1) / bet

  j_min = 1  !--this is only for backward pass
else
  j_min = 2  !--this is only for backward pass
end if

if (coord == nproc-1) then
  j_max = n
else
  j_max = n-1
end if

do q = 1, nchunks

  cstart = 1 + (q - 1) * chunksize
  cend = cstart + chunksize - 1

  tag0 = tag + 10 * (q - 1)

  if (coord /= 0) then

    !--wait for c(:,:,1), bet(:,:), u(:,:,1) from "down"
    !--may want irecv here with a wait at the end
    call mpi_recv (c(1, cstart, 1), lh*chunksize, MPI_RPREC, down, tag0+1,  &
                   comm, status, ierr)
    call mpi_recv (bet(1, cstart), lh*chunksize, MPI_RPREC, down, tag0+2,  &
                   comm, status, ierr)
    !call mpi_recv (u(1, cstart, 1), lh*chunksize, MPI_CPREC, down, tag0+3,  &
    !               comm, status, ierr)
    call mpi_recv(u(1,cstart,1), ld*chunksize, MPI_RPREC, down, tag0+3,  &
                   comm, status, ierr)

  end if

  do j = 2, j_max

    do jy = cstart, cend

      if (jy == ny/2+1) cycle

      do jx = 1, lh-1

        if (jx*jy == 1) cycle

        gam(jx, jy, j) = c(jx, jy, j-1) / bet(jx, jy)
        bet(jx, jy) = b(jx, jy, j) - a(jx, jy, j)*gam(jx, jy, j)

$if ($SAFETYMODE)
        if (bet(jx, jy) == 0._rprec) then
          write (*, *) 'tridag_array failed at jx,jy,j=', jx, jy, j
          write (*, *) 'a,b,c,gam,bet=', a(jx, jy, j), b(jx, jy, j),  &
                       c(jx, jy, j), gam(jx, jy, j), bet(jx, jy)
          stop
        end if
$endif
        ii = 2*jx
        ir = ii - 1
        !u(jx, jy, j) = (r(jx, jy, j) - a(jx, jy, j) * u(jx, jy, j-1)) /  &
        !               bet(jx, jy)
        u(ir:ii, jy, j) = (r(ir:ii, jy, j) - a(jx, jy, j) * u(ir:ii, jy, j-1)) /  &
                       bet(jx, jy)

      end do

    end do

  end do

  if (coord /= nproc - 1) then

    !--send c(n-1), bet, u(n-1) to "up"
    !--may not want blocking sends here
    call mpi_send (c(1, cstart, n-1), lh*chunksize, MPI_RPREC, up, tag0+1,  &
                   comm, ierr)
    call mpi_send (bet(1, cstart), lh*chunksize, MPI_RPREC, up, tag0+2,  &
                   comm, ierr)
    !call mpi_send (u(1, cstart, n-1), lh*chunksize, MPI_CPREC, up, tag0+3,  &
    !               comm, ierr)
    call mpi_send (u(1, cstart, n-1), ld*chunksize, MPI_RPREC, up, tag0+3,  &
                   comm, ierr)                   

  end if

end do

do q = 1, nchunks

  cstart = 1 + (q - 1) * chunksize
  cend = cstart + chunksize - 1

  tag0 = tag + 10 * (q - 1)

  if (coord /= nproc - 1) then  

    !--wait for u(n), gam(n) from "up"
    !call mpi_recv (u(1, cstart, n), lh*chunksize, MPI_CPREC, up, tag0+4,  &
    !               comm, status, ierr)
    call mpi_recv (u(1, cstart, n), ld*chunksize, MPI_RPREC, up, tag0+4,  &
                   comm, status, ierr)
    call mpi_recv (gam(1, cstart, n), lh*chunksize, MPI_RPREC, up, tag0+5,  &
                   comm, status, ierr)

  end if

!$if ($MPI)
!  if (coord == nproc-1) then
!    j_max = n
!  else
!    j_max = n-1
!  endif
!$else
!  j_max = n
!$endif

  do j = n-1, j_min, -1

    !--intend on removing cycle statements/repl with something faster
    do jy = cstart, cend

      if (jy == ny/2+1) cycle

      do jx = 1, lh-1

        if (jx*jy == 1) cycle

        ii = 2*jx
        ir = ii - 1
        !u(jx, jy, j) = u(jx, jy, j) - gam(jx, jy, j+1) * u(jx, jy, j+1)
        u(ir:ii, jy, j) = u(ir:ii, jy, j) - gam(jx, jy, j+1) * u(ir:ii, jy, j+1)

      end do

    end do
  
  end do

  !--send u(2), gam(2) to "down"
  !call mpi_send (u(1, cstart, 2), lh*chunksize, MPI_CPREC, down, tag0+4,  &
  !               comm, ierr)
  call mpi_send (u(1, cstart, 2), ld*chunksize, MPI_RPREC, down, tag0+4,  &
                 comm, ierr)
  call mpi_send (gam(1, cstart, 2), lh*chunksize, MPI_RPREC, down, tag0+5,  &
                 comm, ierr)

end do

end subroutine tridag_array_pipelined
