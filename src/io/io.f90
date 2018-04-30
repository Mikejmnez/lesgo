!!
!!  Copyright (C) 2009-2018  Johns Hopkins University
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

!*******************************************************************************
module io
!*******************************************************************************
use param, only : rprec
use param, only : ld, nx, ny, nz, nz_tot, path, coord, rank, nproc, jt_total
use param, only : total_time, total_time_dim, lbz, jzmin, jzmax, njz
use param, only : cumulative_time, fcumulative_time
use sim_param, only : w, dudz, dvdz
use sgs_param, only : Cs_opt2
use string_util
use messages
use time_average
#ifdef PPMPI
use mpi
#endif

#ifdef PPCGNS
use cgns
#ifdef PPMPI
use param, only: ierr
#endif
#endif

implicit none
save
private

public jt_total, openfiles, output_loop, output_final, output_init,            &
    write_tau_wall_bot, write_tau_wall_top

type point_t
    integer :: istart, jstart, kstart, coord
    real(rprec) :: xdiff, ydiff, zdiff
    integer :: fid
end type point_t

type plane_t
    integer :: istart
    real(rprec) :: ldiff
end type plane_t

type zplane_t
    integer :: istart, coord
    real(rprec) :: ldiff
end type zplane_t

! Where to end with nz index.
integer :: nz_end

! time averaging
type(tavg_t) :: tavg

! Create param for outputting data
type(point_t), allocatable, dimension(:) :: point
type(plane_t), allocatable, dimension(:) :: xplane, yplane
type(zplane_t), allocatable, dimension(:) :: zplane

contains

!*******************************************************************************
subroutine openfiles()
!*******************************************************************************
use param, only : use_cfl_dt, dt, cfl_f
implicit none
logical :: exst

! Temporary values used to read time step and CFL from file
real(rprec) :: dt_r, cfl_r

if (cumulative_time) then
    inquire (file=fcumulative_time, exist=exst)
    if (exst) then
        open (1, file=fcumulative_time)
        read(1, *) jt_total, total_time, total_time_dim, dt_r, cfl_r
        close (1)
    else
        ! assume this is the first run on cumulative time
        if ( coord == 0 ) then
            write (*, *) '--> Assuming jt_total = 0, total_time = 0.0'
        end if
        jt_total = 0
        total_time = 0._rprec
        total_time_dim = 0._rprec
    end if
end if

! Update dynamic time stepping info if required; otherwise discard.
if ( use_cfl_dt ) then
    dt = dt_r
    cfl_f = cfl_r
end if

end subroutine openfiles

!*******************************************************************************
subroutine energy ()
!*******************************************************************************
use param, only : rprec
use param
use sim_param, only : u, v, w, ke
use messages
implicit none
integer :: jx, jy, jz, nan_count
real(rprec) :: temp_w
#ifdef PPMPI
real(rprec) :: ke_global
#endif

! Initialize variables
nan_count = 0
ke = 0._rprec

do jz = 1, nz-1
do jy = 1, ny
do jx = 1, nx
    temp_w = 0.5_rprec*(w(jx,jy,jz)+w(jx,jy,jz+1))
    ke = ke + (u(jx,jy,jz)**2+v(jx,jy,jz)**2+temp_w**2)
end do
end do
end do

! Perform spatial averaging
ke = ke*0.5_rprec/(nx*ny*(nz-1))

#ifdef PPMPI
call mpi_reduce (ke, ke_global, 1, MPI_RPREC, MPI_SUM, 0, comm, ierr)
if (rank == 0) then  ! note that it's rank here, not coord
    ke = ke_global/nproc
#endif
    open(2,file=path // 'output/check_ke.dat', status='unknown',               &
        form='formatted', position='append')
    write(2,*) total_time,ke
    close(2)
#ifdef PPMPI
end if
#endif

end subroutine energy

!*******************************************************************************
subroutine write_tau_wall_bot()
!*******************************************************************************
use param, only: rprec
use param, only: jt_total, total_time, total_time_dim, dt, dt_dim, wbase
use param, only: L_x, z_i, u_star
use functions ,only: get_tau_wall_bot
implicit none

real(rprec) :: turnovers

turnovers = total_time_dim / (L_x * z_i / u_star)

open(2,file=path // 'output/tau_wall_bot.dat', status='unknown',               &
    form='formatted', position='append')

! one time header output
if (jt_total==wbase) write(2,*)                                                &
    'jt_total, total_time, total_time_dim, turnovers, dt, dt_dim, 1.0, tau_wall'

! continual time-related output
write(2,*) jt_total, total_time, total_time_dim, turnovers, dt, dt_dim,        &
    1.0, get_tau_wall_bot()
close(2)

end subroutine write_tau_wall_bot

!*******************************************************************************
subroutine write_tau_wall_top()
!*******************************************************************************
use param, only : rprec
use param, only : jt_total, total_time, total_time_dim, dt, dt_dim, wbase
use param, only : L_x, z_i, u_star
use functions, only : get_tau_wall_top
implicit none

real(rprec) :: turnovers

turnovers = total_time_dim / (L_x * z_i / u_star)

open(2,file=path // 'output/tau_wall_top.dat', status='unknown',               &
    form='formatted', position='append')

! one time header output
if (jt_total==wbase) write(2,*)                                                &
    'jt_total, total_time, total_time_dim, turnovers, dt, dt_dim, 1.0, tau_wall'

! continual time-related output
write(2,*) jt_total, total_time, total_time_dim, turnovers, dt, dt_dim,        &
    1.0, get_tau_wall_top()
close(2)

end subroutine write_tau_wall_top

!*******************************************************************************
subroutine output_loop()
!*******************************************************************************
!
!  This subroutine is called every time step and acts as a driver for
!  computing statistics and outputing instantaneous data. No actual
!  calculations are performed here.
!
use param, only : jt_total, dt
use param, only : nenergy
use param, only : checkpoint_data, checkpoint_nskip
use param, only : tavg_calc, tavg_nstart, tavg_nend, tavg_nskip
use param, only : point_calc, point_nstart, point_nend, point_nskip
use param, only : domain_calc, domain_nstart, domain_nend, domain_nskip
use param, only : xplane_calc, xplane_nstart, xplane_nend, xplane_nskip
use param, only : yplane_calc, yplane_nstart, yplane_nend, yplane_nskip
use param, only : zplane_calc, zplane_nstart, zplane_nend, zplane_nskip
implicit none

! Determine if we are to checkpoint intermediate times
if( checkpoint_data ) then
    ! Now check if data should be checkpointed this time step
    if ( modulo (jt_total, checkpoint_nskip) == 0) call checkpoint()
end if

! Write ke to file
if (modulo (jt_total, nenergy) == 0) call energy()

!  Determine if time summations are to be calculated
if (tavg_calc) then
    ! Are we between the start and stop timesteps?
    if ((jt_total >= tavg_nstart).and.(jt_total <= tavg_nend)) then
        ! Every timestep (between nstart and nend), add to tavg%dt
        tavg%dt = tavg%dt + dt

        ! Are we at the beginning or a multiple of nstart?
        if ( mod(jt_total-tavg_nstart,tavg_nskip)==0 ) then
            ! Check if we have initialized tavg
            if (.not.tavg%initialized) then
                if (coord == 0) then
                    write(*,*) '-------------------------------'
                    write(*,"(1a,i9,1a,i9)")                                   &
                        'Starting running time summation from ',               &
                        tavg_nstart, ' to ', tavg_nend
                    write(*,*) '-------------------------------'
                end if

                call tavg%init()
            else
                call tavg%compute()
            end if
        end if
    end if
end if

!  Determine if instantaneous point velocities are to be recorded
if (point_calc) then
    if (jt_total >= point_nstart .and. jt_total <= point_nend .and.            &
        ( mod(jt_total-point_nstart,point_nskip)==0) ) then
        if (jt_total == point_nstart) then
            if (coord == 0) then
                write(*,*) '-------------------------------'
                write(*,"(1a,i9,1a,i9)")                                       &
                    'Writing instantaneous point velocities from ',            &
                    point_nstart, ' to ', point_nend
                write(*,"(1a,i9)") 'Iteration skip:', point_nskip
                write(*,*) '-------------------------------'
            end if
        end if
        call write_points
    end if
end if

!  Determine if instantaneous domain velocities are to be recorded
if (domain_calc) then
    if (jt_total >= domain_nstart .and. jt_total <= domain_nend .and.          &
        ( mod(jt_total-domain_nstart,domain_nskip)==0) ) then
        if (jt_total == domain_nstart) then
            if (coord == 0) then
                write(*,*) '-------------------------------'
                write(*,"(1a,i9,1a,i9)")                                       &
                    'Writing instantaneous domain velocities from ',           &
                    domain_nstart, ' to ', domain_nend
                write(*,"(1a,i9)") 'Iteration skip:', domain_nskip
                write(*,*) '-------------------------------'
            end if

        end if
        call write_domain
    end if
end if

!  Determine if instantaneous x-plane velocities are to be recorded
if (xplane_calc) then
    if (jt_total >= xplane_nstart .and. jt_total <= xplane_nend .and.          &
        ( mod(jt_total-xplane_nstart,xplane_nskip)==0) ) then
    if (jt_total == xplane_nstart) then
        if (coord == 0) then
            write(*,*) '-------------------------------'
            write(*,"(1a,i9,1a,i9)")                                           &
                'Writing instantaneous x-plane velocities from ',              &
                xplane_nstart, ' to ', xplane_nend
            write(*,"(1a,i9)") 'Iteration skip:', xplane_nskip
            write(*,*) '-------------------------------'
            end if
        end if

        call write_xplanes
    end if
end if

!  Determine if instantaneous y-plane velocities are to be recorded
if (yplane_calc) then
    if (jt_total >= yplane_nstart .and. jt_total <= yplane_nend .and.          &
        ( mod(jt_total-yplane_nstart,yplane_nskip)==0) ) then
        if (jt_total == yplane_nstart) then
            if (coord == 0) then
                write(*,*) '-------------------------------'
                write(*,"(1a,i9,1a,i9)")                                       &
                    'Writing instantaneous y-plane velocities from ',          &
                    yplane_nstart, ' to ', yplane_nend
                write(*,"(1a,i9)") 'Iteration skip:', yplane_nskip
                write(*,*) '-------------------------------'
            end if
        end if

        call write_yplanes
    end if
end if

!  Determine if instantaneous z-plane velocities are to be recorded
if (zplane_calc) then
    if (jt_total >= zplane_nstart .and. jt_total <= zplane_nend .and.          &
        ( mod(jt_total-zplane_nstart,zplane_nskip)==0) ) then
        if (jt_total == zplane_nstart) then
            if (coord == 0) then
                write(*,*) '-------------------------------'
                write(*,"(1a,i9,1a,i9)")                                       &
                    'Writing instantaneous z-plane velocities from ',          &
                    zplane_nstart, ' to ', zplane_nend
                write(*,"(1a,i9)") 'Iteration skip:', zplane_nskip
                write(*,*) '-------------------------------'
            end if
        end if

        call write_zplanes
    end if
end if

end subroutine output_loop

!*******************************************************************************
subroutine write_points
!*******************************************************************************
use functions, only : interp_to_uv_grid, trilinear_interp
use param, only : point_nloc, point_loc
use sim_param, only : u, v, w

integer :: n
character (64) :: fname
real(rprec), dimension(:,:,:), allocatable :: w_uv

!  Allocate space for the interpolated w values
allocate(w_uv(nx,ny,lbz:nz))

!  Make sure w has been interpolated to uv-grid
w_uv = interp_to_uv_grid(w(1:nx,1:ny,lbz:nz), lbz)

do n = 1, point_nloc
    ! Common file name for all output param
    call string_splice(fname, path // 'output/vel.x-', point_loc(n)%xyz(1),&
        '.y-', point_loc(n)%xyz(2), '.z-', point_loc(n)%xyz(3), '.dat')

    if (point(n)%coord == coord) then
        open(unit=13, position="append", file=fname)
        write(13,*) total_time,                                                &
        trilinear_interp(u(1:nx,1:ny,lbz:nz), lbz, point_loc(n)%xyz),          &
        trilinear_interp(v(1:nx,1:ny,lbz:nz), lbz, point_loc(n)%xyz),          &
        trilinear_interp(w_uv(1:nx,1:ny,lbz:nz), lbz, point_loc(n)%xyz)
        close(13)
    end if
end do

deallocate(w_uv)

end subroutine write_points

!*******************************************************************************
subroutine write_domain
!*******************************************************************************
use grid_m
use functions, only : interp_to_w_grid, interp_to_uv_grid, trilinear_interp
use sim_param, only : u, v, w, dvdx, dudy, dwdy, dvdz, dudz, dwdx, p
use data_writer

character (64) :: fname
real(rprec), dimension(:,:,:), allocatable :: w_uv
type(data_writer_t) :: dw
! Vorticity
real(rprec), dimension (:,:,:), allocatable :: vortx, vorty, vortz
! Pressure
real(rprec), dimension(:,:,:), allocatable :: pres_real

!  Allocate space for the interpolated w values
allocate(w_uv(nx,ny,lbz:nz))

!  Make sure w has been interpolated to uv-grid
w_uv = interp_to_uv_grid(w(1:nx,1:ny,lbz:nz), lbz)

! Velocity
call string_splice(fname, path //'output/vel.', jt_total)
call dw%open_file(fname, nx, ny, njz, grid%x(1:nx), grid%y(1:ny),              &
    grid%z(1:nz), 3)
call dw%write_field(u(1:nx,1:ny,jzmin:jzmax), 'VelocityX')
call dw%write_field(v(1:nx,1:ny,jzmin:jzmax), 'VelocityY')
call dw%write_field(w_uv(1:nx,1:ny,jzmin:jzmax), 'VelocityZ')
call dw%close_file

! Vorticity
! Use vorticityx as an intermediate step for performing uv-w interpolation
! Vorticity is written in w grid
allocate(vortx(nx,ny,lbz:nz), vorty(nx,ny,lbz:nz), vortz(nx,ny,lbz:nz))
vortx(1:nx,1:ny,lbz:nz) = 0._rprec
vorty(1:nx,1:ny,lbz:nz) = 0._rprec
vortz(1:nx,1:ny,lbz:nz) = 0._rprec
vortx(1:nx,1:ny,lbz:nz) = dvdx(1:nx,1:ny,lbz:nz) - dudy(1:nx,1:ny,lbz:nz)
vortz(1:nx,1:ny,lbz:nz) = interp_to_w_grid( vortx(1:nx,1:ny,lbz:nz), lbz)
vortx(1:nx,1:ny,lbz:nz) = dwdy(1:nx,1:ny,lbz:nz) - dvdz(1:nx,1:ny,lbz:nz)
vorty(1:nx,1:ny,lbz:nz) = dudz(1:nx,1:ny,lbz:nz) - dwdx(1:nx,1:ny,lbz:nz)
if (coord == 0) then
    vortz(1:nx,1:ny, 1) = 0._rprec
end if

call string_splice(fname, path //'output/vort.', jt_total)
call dw%open_file(fname, nx, ny, njz, grid%x(1:nx), grid%y(1:ny),              &
    grid%z(1:nz), 3)
call dw%write_field(vortx(1:nx,1:ny,jzmin:jzmax), 'VorticityX')
call dw%write_field(vorty(1:nx,1:ny,jzmin:jzmax), 'VorticityY')
call dw%write_field(vortz(1:nx,1:ny,jzmin:jzmax), 'VorticityZ')
call dw%close_file

deallocate(vortx, vorty, vortz)

! Real pressure
allocate(pres_real(nx,ny,lbz:nz))
pres_real(1:nx,1:ny,lbz:nz) = 0._rprec
pres_real(1:nx,1:ny,lbz:nz) = p(1:nx,1:ny,lbz:nz) - 0.5*(u(1:nx,1:ny,lbz:nz)**2&
    + interp_to_uv_grid(w(1:nx,1:ny,lbz:nz), lbz)**2 + v(1:nx,1:ny,lbz:nz)**2)
call string_splice(fname, path //'output/pres.', jt_total)
call dw%open_file(fname, nx, ny, njz, grid%x(1:nx), grid%y(1:ny),              &
    grid%z(1:nz), 1)
call dw%write_field(pres_real(1:nx,1:ny,jzmin:jzmax), 'Pressure')
call dw%close_file

call string_splice(fname, path //'output/pres.', jt_total)

deallocate(pres_real, w_uv)

end subroutine write_domain

!*******************************************************************************
subroutine write_xplanes
!*******************************************************************************
use grid_m
use functions, only : linear_interp, interp_to_uv_grid
use data_writer
use param, only : dx, nx, ny, nz, xplane_nloc, xplane_loc
use sim_param, only : u, v, w

type(data_writer_t) dw
real(rprec), allocatable, dimension(:,:,:) :: ui, vi, wi, w_uv
integer :: i, j, k
character (64) :: fname

! Allocate space for the interpolated values
allocate(w_uv(nx,ny,lbz:nz))
allocate(ui(1,ny,nz), vi(1,ny,nz), wi(1,ny,nz))

! Make sure w has been interpolated to uv-grid
w_uv = interp_to_uv_grid(w(1:nx,1:ny,lbz:nz), lbz)

! Loop over all xplane locations
do i = 1, xplane_nloc
    do k = 1, nz
        do j = 1, ny
            ui(1,j,k) = linear_interp(u(xplane(i)%istart,j,k),                 &
                 u(xplane(i)%istart+1,j,k), dx, xplane(i)%ldiff)
            vi(1,j,k) = linear_interp(v(xplane(i)%istart,j,k),                 &
                 v(xplane(i)%istart+1,j,k), dx, xplane(i)%ldiff)
            wi(1,j,k) = linear_interp(w_uv(xplane(i)%istart,j,k),              &
                 w_uv(xplane(i)%istart+1,j,k), dx, xplane(i)%ldiff)
        end do
    end do

    ! Write
    call string_splice(fname, path // 'output/vel.x-', xplane_loc(i), '.', &
        jt_total)
    call dw%open_file(fname, 1, ny, njz, xplane_loc(i:i), grid%y(1:ny),        &
        grid%z(1:nz), 3)
    call dw%write_field(ui(1:1,1:ny,jzmin:jzmax), 'VelocityX')
    call dw%write_field(vi(1:1,1:ny,jzmin:jzmax), 'VelocityY')
    call dw%write_field(wi(1:1,1:ny,jzmin:jzmax), 'VelocityZ')
    call dw%close_file
end do

deallocate(ui, vi, wi, w_uv)

end subroutine write_xplanes

!*******************************************************************************
subroutine write_yplanes
!*******************************************************************************
use grid_m
use functions, only : linear_interp, interp_to_uv_grid
use data_writer
use param, only : dy, nx, ny, nz, yplane_nloc, yplane_loc
use sim_param, only : u, v, w

type(data_writer_t) dw
real(rprec), allocatable, dimension(:,:,:) :: ui, vi, wi, w_uv
integer :: i, j, k
character (64) :: fname

!  Allocate space for the interpolated values
allocate(w_uv(nx,ny,lbz:nz))
allocate(ui(nx,1,nz), vi(nx,1,nz), wi(nx,1,nz))

!  Make sure w has been interpolated to uv-grid
w_uv = interp_to_uv_grid(w(1:nx,1:ny,lbz:nz), lbz)

!  Loop over all xplane locations
do j = 1, yplane_nloc
    do k = 1, nz
        do i = 1, nx
            ui(i,1,k) = linear_interp(u(i,yplane(j)%istart,k),                 &
                     u(i,yplane(j)%istart+1,k), dy, yplane(j)%ldiff)
            vi(i,1,k) = linear_interp(v(i,yplane(j)%istart,k),                 &
                 v(i,yplane(j)%istart+1,k), dy, yplane(j)%ldiff)
            wi(i,1,k) = linear_interp(w_uv(i,yplane(j)%istart,k),              &
                 w_uv(i,yplane(j)%istart+1,k), dy, yplane(j)%ldiff)
        end do
    end do

    ! Write
    call string_splice(fname, path // 'output/vel.y-', yplane_loc(j), '.',     &
         jt_total)
    call dw%open_file(fname, nx, 1, njz, grid%x(1:nx), yplane_loc(j:j),        &
        grid%z(1:nz), 3)
    call dw%write_field(ui(1:nx,1:1,jzmin:jzmax), 'VelocityX')
    call dw%write_field(vi(1:nx,1:1,jzmin:jzmax), 'VelocityY')
    call dw%write_field(wi(1:nx,1:1,jzmin:jzmax), 'VelocityZ')
    call dw%close_file
end do
deallocate(ui, vi, wi, w_uv)

end subroutine write_yplanes

!*******************************************************************************
subroutine write_zplanes
!*******************************************************************************
use grid_m
use functions, only : linear_interp, interp_to_uv_grid
use data_writer
use param, only : dz, nx, ny, zplane_nloc, zplane_loc
use sim_param, only : u, v, w

type(data_writer_t) dw
real(rprec), allocatable, dimension(:,:,:) :: ui, vi, wi, w_uv
integer :: i, j, k
character (64) :: fname

!  Allocate space for the interpolated values
allocate(w_uv(nx,ny,lbz:nz))
allocate(ui(nx,ny,1), vi(nx,ny,1), wi(nx,ny,1))

!  Make sure w has been interpolated to uv-grid
w_uv = interp_to_uv_grid(w(1:nx,1:ny,lbz:nz), lbz)

!  Loop over all xplane locations
do k = 1, zplane_nloc
    call string_splice(fname, path // 'output/vel.z-', zplane_loc(k), '.',     &
        jt_total)
    if (zplane(k)%coord == coord) then
        do j = 1, ny
            do i = 1, nx
                ui(i,j,1) = linear_interp(u(i,j,zplane(k)%istart),             &
                     u(i,j,zplane(k)%istart+1), dz, zplane(k)%ldiff)
                vi(i,j,1) = linear_interp(v(i,j,zplane(k)%istart),             &
                     v(i,j,zplane(k)%istart+1), dz, zplane(k)%ldiff)
                wi(i,j,1) = linear_interp(w_uv(i,j,zplane(k)%istart),          &
                     w_uv(i,j,zplane(k)%istart+1), dz, zplane(k)%ldiff)
            end do
        end do

        ! Write
        call dw%open_file(fname, nx, ny, 1, grid%x(1:nx), grid%y(1:ny),        &
            zplane_loc(k:k), 3)
        call dw%write_field(ui(1:nx,1:ny,1:1), 'VelocityX')
        call dw%write_field(vi(1:nx,1:ny,1:1), 'VelocityY')
        call dw%write_field(wi(1:nx,1:ny,1:1), 'VelocityZ')
        call dw%close_file
    else
        call dw%open_file(fname, nx, ny, 0, grid%x(1:nx), grid%y(1:ny),        &
            zplane_loc(k:k), 3)
        call dw%close_file
    end if
end do

deallocate(ui, vi, wi, w_uv)

end subroutine write_zplanes

!*******************************************************************************
subroutine checkpoint ()
!*******************************************************************************
use iwmles
use param, only : nz, checkpoint_file, tavg_calc, lbc_mom
#ifdef PPMPI
use param, only : comm, ierr
#endif
use sim_param, only : u, v, w, RHSx, RHSy, RHSz
use sgs_param, only : Cs_opt2, F_LM, F_MM, F_QN, F_NN
use param, only : jt_total, total_time, total_time_dim, dt, use_cfl_dt, cfl
use param, only : write_endian
use cfl_util, only : get_max_cfl
use string_util, only : string_concat
#if PPUSE_TURBINES
use turbines, only : turbines_checkpoint
#endif

! HIT Inflow
#ifdef PPHIT
use hit_inflow, only : hit_write_restart
#endif

implicit none
character(64) :: fname
real(rprec) :: cfl_w

fname = checkpoint_file
#ifdef PPMPI
call string_concat( fname, '.c', coord )
#endif

!  Open vel.out (lun_default in io) for final output
open(11, file=fname, form='unformatted', convert=write_endian,                 &
    status='unknown', position='rewind')
write (11) u(:, :, 1:nz), v(:, :, 1:nz), w(:, :, 1:nz),                        &
    RHSx(:, :, 1:nz), RHSy(:, :, 1:nz), RHSz(:, :, 1:nz),                      &
    Cs_opt2(:,:,1:nz), F_LM(:,:,1:nz), F_MM(:,:,1:nz),                         &
    F_QN(:,:,1:nz), F_NN(:,:,1:nz)
close(11)

#ifdef PPMPI
call mpi_barrier( comm, ierr )
#endif

! Checkpoint time averaging restart data
if ( tavg_calc .and. tavg%initialized ) call tavg%checkpoint()

! Write time and current simulation state
! Set the current cfl to a temporary (write) value based whether CFL is
! specified or must be computed
if( use_cfl_dt ) then
    cfl_w = cfl
else
    cfl_w = get_max_cfl()
end if

!xiang check point for iwm
if(lbc_mom==3)then
    if (coord == 0) call iwm_checkPoint()
end if

#ifdef PPHIT
    if (coord == 0) call hit_write_restart()
#endif

#if PPUSE_TURBINES
call turbines_checkpoint
#endif

!  Update total_time.dat after simulation
if (coord == 0) then
    !--only do this for true final output, not intermediate recording
    open (1, file=fcumulative_time)
    write(1, *) jt_total, total_time, total_time_dim, dt, cfl_w
    close(1)
end if

end subroutine checkpoint

!*******************************************************************************
subroutine output_final
!*******************************************************************************
use param, only : tavg_calc
implicit none

! Perform final checkpoing
call checkpoint()

!  Check if average quantities are to be recorded
if (tavg_calc .and. tavg%initialized ) call tavg%finalize()

end subroutine output_final

!*******************************************************************************
subroutine output_init
!*******************************************************************************
!
!  This subroutine allocates the memory for arrays used for statistical
!  calculations
!
use param, only : dx, dy, dz, lbz
use param, only : point_calc, point_nloc, point_loc
use param, only : xplane_calc, xplane_nloc, xplane_loc
use param, only : yplane_calc, yplane_nloc, yplane_loc
use param, only : zplane_calc, zplane_nloc, zplane_loc
use grid_m
use functions, only : cell_indx
implicit none

integer :: i,j,k
real(rprec), pointer, dimension(:) :: x,y,z


#ifdef PPMPI
! This adds one more element to the last processor (which contains an extra one)
! Processor nproc-1 has data from 1:nz
! Rest of processors have data from 1:nz-1
if ( coord == nproc-1 ) then
    nz_end = 0
else
    nz_end = 1
end if
#else
nz_end = 0
#endif

nullify(x,y,z)

x => grid%x
y => grid%y
z => grid%z

! Initialize information for x-planar stats/data
if (xplane_calc) then
    allocate(xplane(xplane_nloc))
    xplane(:)%istart = -1
    xplane(:)%ldiff = 0.

    !  Compute istart and ldiff
    do i = 1, xplane_nloc
        xplane(i)%istart = cell_indx('i', dx, xplane_loc(i))
        xplane(i)%ldiff = xplane_loc(i) - x(xplane(i)%istart)
    end do
end if

! Initialize information for y-planar stats/data
if (yplane_calc) then
    allocate(yplane(yplane_nloc))
    yplane(:)%istart = -1
    yplane(:)%ldiff = 0.

    !  Compute istart and ldiff
    do j = 1, yplane_nloc
        yplane(j)%istart = cell_indx('j', dy, yplane_loc(j))
        yplane(j)%ldiff = yplane_loc(j) - y(yplane(j)%istart)
    end do
end if

! Initialize information for z-planar stats/data
if(zplane_calc) then
    allocate(zplane(zplane_nloc))

    !  Initialize
    zplane(:)%istart = -1
    zplane(:)%ldiff = 0.
    zplane(:)%coord = -1

    !  Compute istart and ldiff
    do k = 1, zplane_nloc

#ifdef PPMPI
        if (zplane_loc(k) >= z(1) .and. zplane_loc(k) < z(nz)) then
            zplane(k)%coord = coord
            zplane(k)%istart = cell_indx('k',dz,zplane_loc(k))
            zplane(k)%ldiff = zplane_loc(k) - z(zplane(k)%istart)
        end if
#else
        zplane(k)%coord = 0
        zplane(k)%istart = cell_indx('k',dz,zplane_loc(k))
        zplane(k)%ldiff = zplane_loc(k) - z(zplane(k)%istart)
#endif
    end do
end if

!  Open files for instantaneous writing
if (point_calc) then
    allocate(point(point_nloc))

    !  Intialize the coord values
    ! (-1 shouldn't be used as coord so initialize to this)
    point%coord=-1
    point%fid = -1

    do i = 1, point_nloc
        !  Find the processor in which this point lives
#ifdef PPMPI
        if (point_loc(i)%xyz(3) >= z(1) .and. point_loc(i)%xyz(3) < z(nz)) then
#endif
            point(i)%coord = coord

            point(i)%istart = cell_indx('i',dx,point_loc(i)%xyz(1))
            point(i)%jstart = cell_indx('j',dy,point_loc(i)%xyz(2))
            point(i)%kstart = cell_indx('k',dz,point_loc(i)%xyz(3))

            point(i)%xdiff = point_loc(i)%xyz(1) - x(point(i)%istart)
            point(i)%ydiff = point_loc(i)%xyz(2) - y(point(i)%jstart)
            point(i)%zdiff = point_loc(i)%xyz(3) - z(point(i)%kstart)

#ifdef PPMPI
        end if
#endif
    end do
end if

nullify(x,y,z)

end subroutine output_init

end module io
