program furcashell

  use network
  use table_rates, only: j_na23_ne23, j_ne23_na23
  use actual_rhs_module, only: rate_eval_t, evaluate_rates
  use burner_module, only: burner_init
  use burn_type_module, only: burn_t, burn_to_eos, eos_to_burn
  use eos_module, only: eos, eos_init
  use eos_type_module, only: eos_t, eos_input_rt
  use rpar_indices
  use bl_space, only: MAX_SPACEDIM
  use bl_error_module
  use bl_constants_module
  use bl_IO_module
  use bl_types
  use plotfile_module
  use multifab_module
  use omp_module

  implicit none

  ! argument variables
  character(len=256) :: pltfile, outputfile
  logical :: use_tfromp

  ! f2kcli variables
  integer :: narg, farg
  character(len=256) :: fname

  ! local variables
  integer :: uin, dim, nlevs, i, j, ii, jj, kk
  type(plotfile) :: pf
  type(layout) :: la
  type(boxarray) :: ba
  type(list_box) :: bl
  type(box) :: bx,pd
  type(multifab), allocatable :: rates(:)
  integer :: dens_comp, temp_comp, spec_comp
  integer, dimension(MAX_SPACEDIM) :: lo, hi
  integer, allocatable :: rr(:,:)
  real(kind=dp_t), pointer :: p(:,:,:,:), r(:,:,:,:)

  type (burn_t) :: burn_state
  type (eos_t)  :: eos_state
  type (rate_eval_t) :: rate_state

  integer, parameter :: size_rate_eval = 7

  character(len=20) :: plot_names(size_rate_eval)

  ! For AMReX, disable nested parallel regions
  if (omp_get_max_threads() > 1) call omp_set_nested(.false.)

  uin = unit_new()

  ! defaults
  pltfile =''
  outputfile = 'urca'
  use_tfromp = .false.
  
  ! parse arguments
  narg = command_argument_count()

  farg = 1
  do while (farg<=narg)
     call get_command_argument(farg,value=fname)

     select case(fname)

     case ('-i', '--input')
        farg = farg + 1
        call get_command_argument(farg,value=pltfile)
     case ('-o', '--output')
        farg = farg + 1
        call get_command_argument(farg,value=outputfile)
     case ('--tfromp')
        use_tfromp = .true.
     case default
        exit
     end select
     farg = farg + 1
  end do

  ! sanity check
  if (pltfile == '') then
     call print_usage()
     stop
  end if

  print *, 'working on pltfile: ', trim(pltfile)
  print *, 'saving to pltfile: ', trim(outputfile)

  call burner_init()
  call network_init()
  call eos_init()
  
  ! build the input plotfile
  call build(pf,pltfile,uin)

  nlevs = plotfile_nlevels(pf)
  dim = plotfile_dim(pf)

  allocate(rr(nlevs,dim),rates(nlevs))
  rr = plotfile_refrat(pf)

  plot_names(1) = "ecap23"
  plot_names(2) = "beta23"
  plot_names(3) = "epart_ecap23"
  plot_names(4) = "epart_beta23"
  plot_names(5) = "X(na23)"
  plot_names(6) = "X(ne23)"
  plot_names(7) = "density"

  dens_comp = plotfile_var_index(pf,"density")
  if (use_tfromp) then
     temp_comp = plotfile_var_index(pf,"tfromp")
  else
     temp_comp = plotfile_var_index(pf,"tfromh")
  end if
  spec_comp = plotfile_var_index(pf,"X(" // trim(short_spec_names(1)) // ")")

  if (dens_comp < 0 .or. spec_comp < 0 .or. temp_comp < 0) then
     print *, dens_comp, temp_comp, spec_comp
     call bl_error("Variables not found")
  endif

  do i = 1, nlevs
     do j = 1, nboxes(pf,i)
        call push_back(bl,get_box(pf,i,j))
     end do

     call build(ba,bl)
     call build(la,ba,plotfile_get_pd_box(pf,i))
     call destroy(bl)
     call destroy(ba)

     ! build the multifab with 0 ghost cells and size_rate_eval components
     call multifab_build(rates(i),la,size_rate_eval,0)
  end do

  ! loop over the plotfile data starting at the finest
  do i = nlevs, 1, -1
     ! loop over each box at this level
     do j = 1, nboxes(pf,i)
        ! read in the data 1 patch at a time
        call fab_bind(pf,i,j)

        lo(1:dim) = lwb(get_box(pf,i,j))
        hi(1:dim) = upb(get_box(pf,i,j))

        p => dataptr(pf,i,j)
        r => dataptr(rates(i),j)

        !$OMP PARALLEL DO PRIVATE(kk, jj, ii, eos_state, burn_state, rate_state) &
        !$OMP SCHEDULE(DYNAMIC,1)
        do kk = lo(3), hi(3)
           do jj = lo(2), hi(2)
              do ii = lo(1), hi(1)

                 eos_state % rho = p(ii,jj,kk,dens_comp)
                 eos_state % T   = p(ii,jj,kk,temp_comp)
                 eos_state % xn  = p(ii,jj,kk,spec_comp:spec_comp+nspec-1)

                 call eos(eos_input_rt, eos_state)
                 call eos_to_burn(eos_state, burn_state)

                 call evaluate_rates(burn_state, rate_state)

                 ! Electron capture rate (A=23)
                 r(ii,jj,kk,1) = rate_state % screened_rates(k_na23_ne23)

                 ! Beta decay rate (A=23)
                 r(ii,jj,kk,2) = rate_state % screened_rates(k_ne23_na23)

                 ! Particle energy from electron capture (A=23)
                 r(ii,jj,kk,3) = rate_state % epart(j_na23_ne23)

                 ! Particle energy from beta decay (A=23)
                 r(ii,jj,kk,4) = rate_state % epart(j_ne23_na23)

                 ! Mass fraction of Na-23
                 r(ii,jj,kk,5) = burn_state % xn(jna23)

                 ! Mass fraction of Ne-23
                 r(ii,jj,kk,6) = burn_state % xn(jne23)

                 ! Density
                 r(ii,jj,kk,7) = burn_state % rho

              end do
           end do
        end do
        !$OMP END PARALLEL DO

        call fab_unbind(pf,i,j)
        
     end do
  end do

  call fabio_ml_multifab_write_d(rates, rr(:,1), &
                                 trim(outputfile), &
                                 plot_names, plotfile_get_pd_box(pf,1), &
                                 pf%plo, pf%phi, plotfile_time(pf), &
                                 plotfile_get_dx(pf,1))
  call destroy(pf)


contains

  subroutine print_usage()
    implicit none
    
    print *,""
    print *, "This program takes a 3D plotfile and extracts the electron capture, "
    print *, " beta decay rate, mass fractions, and particle energy -- "
    print *, " then dumps a new plotfile containing these quantities."
    print *, ""
    print *, "This is set up for the URCA-simple network in StarKiller Microphysics."
    print *, ""
    print *, "usage: "
    print *, " *furcashell* -i|--input <pltfile in> [-o|--output <pltfile out>]"
    print *, ""
    print *, "    -i|--input: <pltfile in>"
    print *, "        Specify which plotfile to work on. (Required)"
    print *, "    -o|--output:"
    print *, "        Name of the out new plotfile to create. (Default: 'urcashell')"
    print *, "    --tfromp:"
    print *, "        Toggles the use of 'temperature' to be tfromp instead", &
         " of tfromh."
    print *, "        (Default: use tfromh)"
    print *, ""

  end subroutine print_usage

end program furcashell