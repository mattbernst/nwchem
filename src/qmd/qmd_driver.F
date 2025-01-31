c
c     qmd_driver: main driver
c
      logical function qmd_driver(rtdb)
c
      implicit none
c
#include "errquit.fh"
#include "rtdb.fh"
#include "mafdecls.fh"
#include "inp.fh"
#include "util.fh"
#include "global.fh"
#include "geom.fh"
#include "stdio.fh"
c
#include "qmd_common.fh"
c
      integer rtdb
c
      integer geom                    ! geometry object
c
      integer l_r, k_r                ! coordinates
      double precision r(3)
      integer l_c, k_c                ! centroid of geometry
c
      integer l_v, k_v                ! velocities
      double precision v(3)
c
      integer l_g, k_g                ! gradients
      integer l_m, k_m                ! masses
c
      integer l_act, k_act            ! active atoms
c
      integer nat                     ! number of atoms
      integer nactive                 ! number of active atoms
      integer nstep_nucl              ! total nuclear steps
      integer sstep_nucl              ! first nuclear step
      integer istep_nucl              ! nuclear md step
      integer com_step                ! how often to remove trans/rot
      integer print_xyz               ! how often to print trajectory
      double precision dt_nucl        ! nuclear md time step
      double precision eltime         ! elapsed time (in fs)
      double precision esys           ! system energy (from task_gradient)
      double precision ekin           ! kinetic energy from the md part
      double precision etotal         ! total energy: esys + ekin
      double precision ekin_targ      ! target kinetic energy
      double precision dipole(3)      ! electric dipole moment
c
      logical do_cavity               ! include cavity constraints
      double precision cavity_axis(3) ! cavity axes
      double precision cavity_spring  ! cavity force spring constant
c
      logical status
      logical rst_exists
      logical do_none
      logical dip_exists
c
      character*32 pname
      integer xyzfileunit
      character*255 xyzfilename
      integer rstfileunit
      character*255 rstfilename
c
      logical task_gradient
      external task_gradient
c
      logical geom_centroid
      external geom_centroid
c
c     preliminaries
      status = .true.
      dip_exists=.true.
      pname = "qmd_driver: "
      esys = 0.d0
      ekin = 0.d0
      etotal = 0.d0
      dipole(1) = 0.d0
      dipole(2) = 0.d0
      dipole(3) = 0.d0
c
c     check if we need cavity constraints
      if(.not.rtdb_get(rtdb,'qmd:cavity',mt_log,1,do_cavity))
     &     do_cavity = .false.
      if (do_cavity) then
      if(.not.rtdb_get(rtdb,'qmd:cavity_axis',mt_dbl,3,cavity_axis))
     &    call errquit("cannot get cavity axes",0,0)
      if(.not.rtdb_get(rtdb,'qmd:cavity_spring',mt_dbl,1,cavity_spring))
     &    call errquit("cannot get cavity spring constant",0,0)
      end if ! do_cavity
c
c     get xyzfileunit
      if(.not.util_get_io_unit(xyzfileunit))
     &   call errquit("cannot get file unit",0,0)
c
c     get xyzfilename
      call util_file_name('xyz',.false.,.false.,xyzfilename)
c
c     get rstfileunit
      if(.not.util_get_io_unit(rstfileunit))
     &   call errquit("cannot get file unit",0,0)
c
c     get rstfilename
      call util_file_name('qmdrst',.false.,.false.,rstfilename)
c
c     initialize parameters
      call qmd_init(rtdb,nstep_nucl,dt_nucl,do_none,com_step,
     &       print_xyz)
c
c     create geometry object 
      if (.not. geom_create(geom,'geometry'))
     &   call errquit(pname//'geom_create', 911, GEOM_ERR)
c
c     load in the geometry
      if (.not. geom_rtdb_load(rtdb,geom,'geometry'))
     &   call errquit(pname//'geom_rtdb_load', geom, RTDB_ERR)
c
c     get number of atoms
      if (.not. geom_ncent(geom,nat))
     $   call errquit(pname//'geom_ncent',geom, GEOM_ERR)
      if (nat.eq.0) return
c
c     local memory and initialization
      if(.not.ma_push_get(mt_dbl,nat,'mass',l_m,k_m))  ! mass
     $   call errquit(pname//'ma_push_get mass', nat,MA_ERR)
      call dfill(nat, 0.0d0, dbl_mb(k_m), 1)
c
      if(.not.ma_push_get(mt_dbl,3*nat,'coords',l_r,k_r)) ! coords
     $   call errquit(pname//'ma_push_get coords', 3*nat,MA_ERR)
      call dfill(3*nat, 0.0d0, dbl_mb(k_r), 1)
c
      if(.not.ma_push_get(mt_dbl,3,'centroid',l_c,k_c))  ! centroid
     $   call errquit(pname//'ma_push_get centroid', 3,MA_ERR)
      call dfill(3, 0.0d0, dbl_mb(k_c), 1)
c
      if(.not.ma_push_get(mt_dbl,3*nat,'vels',l_v,k_v))  ! vels
     $   call errquit(pname//'ma_push_get vels', 3*nat,MA_ERR)
      call dfill(3*nat, 0.0d0, dbl_mb(k_v), 1)
      if (.not.geom_vel_set(geom,dbl_mb(k_v))) ! init vels
     $   call errquit(pname//'geom_vel_set',0,GEOM_ERR)
c
      if(.not.ma_push_get(mt_dbl,3*nat,'grads',l_g,k_g))  ! grads
     $   call errquit(pname//'ma_push_get grads',3*nat,MA_ERR)
      call dfill(3*nat, 0.0d0, dbl_mb(k_g), 1)
c     get the active atoms (also need a check for linearity)
c     need to implement constraints
      if (.not. ma_push_get(mt_log,nat,'active atoms',l_act,k_act)) ! active
     $   call errquit(pname//'grad_active_atoms',nat,MA_ERR)
      call grad_active_atoms(rtdb, nat, log_mb(k_act), nactive)
      if (do_linear) then    ! check for linear flag
        ndeg = 3*nactive-5   ! 3N-5 (linear)
      else
        ndeg = 3*nactive-6   ! 3N-6 (general)
      end if ! do_linear
c
      if (ndeg.le.0)
     $   call errquit(pname//'ndeg<=0',geom,GEOM_ERR)
c
c     get the masses, initial coordinates
      if (.not.geom_masses_get(geom,nat,dbl_mb(k_m)))  ! masses
     $   call errquit(pname//'geom_masses_get',geom,GEOM_ERR)
      if (.not.geom_cart_coords_get(geom,dbl_mb(k_r)))
     $   call errquit(pname//'geom_cart_coords_get',0,GEOM_ERR)
c
c     check for restart file in directory
c     if it exists, read data from that and start trajectory from there
      inquire(file=rstfilename,exist=rst_exists)
      if (rst_exists) then
        if (ga_nodeid().eq.0) then
          write(luout,*) 'Restart file found'
          write(luout,*) 'Reading positions, velocities, KE,'
          write(luout,*) 'and last time step from file.'
        end if
c
c       read velocities from file
        call qmd_read_rst(rstfilename,rstfileunit,nat,dbl_mb(k_v),
     $         dbl_mb(k_r),ekin,sstep_nucl)
c
c       remove global translations and rotations
c       kinetic energy is the same on exit as was on entry
        call qmd_fix_momentum(nat,dbl_mb(k_m),dbl_mb(k_v),dbl_mb(k_r))
        call qmd_freeze_inactive(nat,dbl_mb(k_m),dbl_mb(k_v),
     $         log_mb(k_act))
c
c       update geom and store in rtdb
        call qmd_geom_store(rtdb,geom,nat,dbl_mb(k_r))
      else
        if (ga_nodeid().eq.0) then
          write(luout,*) 'No restart file found'
          write(luout,*) 'Beginning with random velocities'
        end if
c
c       randomize velocities for the given temperature
        call qmd_randomize(nat,dbl_mb(k_m),dbl_mb(k_v))
        sstep_nucl=1
c
c       remove global translations and rotations
c       kinetic energy is the same on exit as was on entry
        call qmd_fix_momentum(nat,dbl_mb(k_m),dbl_mb(k_v),dbl_mb(k_r))
        call qmd_freeze_inactive(nat,dbl_mb(k_m),dbl_mb(k_v),
     $         log_mb(k_act))
      end if ! rst_exists
c
c     persist updated velocity in geom
      if (.not.geom_vel_set(geom,dbl_mb(k_v)))
     $ call errquit(pname//'geom_vel_set',0,GEOM_ERR)
c
      call ga_sync()
c
      call qmd_kinetic(nat,dbl_mb(k_m),dbl_mb(k_v),ekin)
      if (ga_nodeid().eq.0) then
        final_temp = 2.0d0*ekin/kb/(1.d0*ndeg)
        write(luout,120) "Current temp. (K):",final_temp
      end if
c
c     target kinetic energy (only used if thermostat is rescale)
      ekin_targ=(1.d0*ndeg)*kb*targ_temp/2.d0
c
c     perform energy gradient calculation on initial coordinates
      call qmd_gradient(rtdb,nat,dbl_mb(k_g),esys)
c
c     calculate the centroid of the structure
      if (.not.geom_centroid(geom,dbl_mb(k_c)))
     $      call errquit(pname//'geom_centroid',0,GEOM_ERR)
c
c     include cavity constraints, if requested
      if (do_cavity) then
       call qmd_cavity(nat,cavity_axis,cavity_spring,dbl_mb(k_c),
     &       dbl_mb(k_r),dbl_mb(k_g))
      end if ! do_cavity
c
c     if starting fresh write initial structure to xyz
      if (.not.rst_exists) then
c
c       pull dipole from RTDB
        if(.not.rtdb_get(rtdb,'task:dipole',mt_dbl,3,dipole))
     &     dip_exists=.false.
c
c       instantaneous total energy: instantaneous kinetic energy + system energy
        etotal = ekin + esys
c
c       write trajectory
        call qmd_write_trj(xyzfilename,xyzfileunit,.false.,nat,
     &         0,etotal,geom,dipole)
      end if  ! rst_exists
c
c     start nuclear molecular dynamics loop
      do istep_nucl = sstep_nucl,nstep_nucl
c
c       don't attempt to remove COM rot/tran if we have inactive atoms
        if (mod(istep_nucl,com_step).eq.0.and.nat.eq.nactive) then
c         remove global translations and rotations
c         kinetic energy is the same on exit as was on entry
          call qmd_fix_momentum(nat,dbl_mb(k_m),dbl_mb(k_v),dbl_mb(k_r))
        end if
c
        if (.not.do_none) then
c
c         apply thermostat to velocities
          call qmd_thermostat(nat,dt_nucl,dbl_mb(k_m),dbl_mb(k_v),
     &           ekin,ekin_targ,log_mb(k_act))
        end if ! do_none
c
c       update velocity at half step (dt/2)
        call qmd_nucl_vel(nat,0.5d0*dt_nucl,dbl_mb(k_m),dbl_mb(k_v),
     &         dbl_mb(k_g))
c
c       update position at dt
        call qmd_nucl_pos(nat,dt_nucl,dbl_mb(k_m),dbl_mb(k_r),
     &        dbl_mb(k_v))
c
c       update geom and store in rtdb
        call qmd_geom_store(rtdb,geom,nat,dbl_mb(k_r))
c
c       calculate energy and gradient
        call qmd_gradient(rtdb,nat,dbl_mb(k_g),esys)
c
c       include cavity reflection if requested
        if (do_cavity) then
         call qmd_cavity(nat,cavity_axis,cavity_spring,dbl_mb(k_c),
     &         dbl_mb(k_r),dbl_mb(k_g))
        end if ! do_cavity
c
c       pull dipole from RTDB
        if(.not.rtdb_get(rtdb,'task:dipole',mt_dbl,3,dipole))
     &     dip_exists=.false.
c
c       update velocity at half step (dt/2)
        call qmd_nucl_vel(nat,0.5d0*dt_nucl,dbl_mb(k_m),dbl_mb(k_v),
     &         dbl_mb(k_g))
c
        if (.not.do_none) then
c         apply thermostat to velocities
          call qmd_thermostat(nat,dt_nucl,dbl_mb(k_m),dbl_mb(k_v),
     &           ekin,ekin_targ,log_mb(k_act))
        end if ! do_none
c
c       persist updated velocity in geom
        if (.not.geom_vel_set(geom,dbl_mb(k_v)))
     $   call errquit(pname//'geom_vel_set',0,GEOM_ERR)
c
c       calculate current kinetic energy
        call qmd_kinetic(nat,dbl_mb(k_m),dbl_mb(k_v),ekin)
c       instantaneous total energy: instantaneous kinetic energy + system energy
        etotal = ekin + esys
c
c       instantaneous temperature
        final_temp = 2.0d0*ekin/kb/(1.d0*ndeg)
c
c       print md run information
        if (ga_nodeid().eq.0) then
c
         write(luout,*)
         write(luout,*)
         call util_print_centered(LuOut,'QMD Run Information',20,.true.)
c         write(luout,110) "Current time step:",istep_nucl
         eltime=dble(istep_nucl)*dt_nucl*au2fs
         write(luout,130) "Time elapsed (fs) :",eltime
         write(luout,135) "Kin. energy (a.u.):",istep_nucl,ekin
         write(luout,135) "Pot. energy (a.u.):",istep_nucl,esys
         write(luout,135) "Tot. energy (a.u.):",istep_nucl,etotal
         write(luout,125) "Target temp. (K)  :",istep_nucl,targ_temp
         write(luout,125) "Current temp. (K) :",istep_nucl,final_temp
         if (dip_exists) then
           write(luout,140) "Dipole (a.u.)     :",istep_nucl,dipole(:)
         else
           write(luout,'(A21)') "No dipole on RTDB"
         end if
         write(luout,*)
         write(luout,*)

c        check how often to write out the tracjectory
         if (mod(istep_nucl,print_xyz).eq.0) then
c
c          write trajectory
           call qmd_write_trj(xyzfilename,xyzfileunit,.true.,nat,
     &            istep_nucl,etotal,geom,dipole)
         end if
c
c        write restart
         call qmd_write_rst(rstfilename,rstfileunit,
     &             nat,istep_nucl,ekin,geom)
c
        end if  ! ga_nodeid()
c
      end do  ! istep_nucl
  110 format(A20,I20)
  120 format(A25,F20.2)
  125 format(A21,I9,F20.2)
  130 format(A21,F29.6)
  135 format(A21,I9,F20.6)
  140 format(A21,I9,3ES15.6)
c
c     clear memory
      if(.not.ma_pop_stack(l_act))! active
     + call errquit(pname//'ma_pop_stack act',0,MA_ERR)
      if(.not.ma_pop_stack(l_g))  ! gradient
     + call errquit(pname//'ma_pop_stack g',0,MA_ERR)
      if(.not.ma_pop_stack(l_v))  ! velocity
     + call errquit(pname//'ma_pop_stack v',0,MA_ERR)
      if(.not.ma_pop_stack(l_c))  ! positions
     + call errquit(pname//'ma_pop_stack c',0,MA_ERR)
      if(.not.ma_pop_stack(l_r))  ! positions
     + call errquit(pname//'ma_pop_stack r',0,MA_ERR)
      if(.not.ma_pop_stack(l_m))  ! masses
     + call errquit(pname//'ma_pop_stack m',0,MA_ERR)
      if(.not.ma_verify_allocator_stuff())
     + call errquit(pname//'ma_verify_allocator_stuff',0,MA_ERR)
      if(.not.geom_destroy(geom))
     + call errquit(pname//'geom_destroy',0,GEOM_ERR)
c
      qmd_driver = status
c
      end
c $Id$
