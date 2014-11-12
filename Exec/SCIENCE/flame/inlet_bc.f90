! inlet_bc_module serves as a container to hold the inflow boundary 
! condition information.
!
! These quantities are initialized through a call to set_inlet_bcs(),
! which should be done on initialization and restart.

module inlet_bc_module

  use bl_types
  use bl_constants_module
  use bl_error_module
  use bl_space
  use network

  implicit none

  real(dp_t), save    :: INLET_VEL         ! normal velocity through boundary
  real(dp_t), save    :: INLET_RHO
  real(dp_t), save    :: INLET_RHOH
  real(dp_t), save    :: INLET_TEMP
  real(dp_t), save    :: INLET_RHOX(nspec)
  real(dp_t), save    :: INLET_TRA

  logical, save :: inlet_bc_initialized = .false.

contains

  subroutine set_inlet_bcs()

    ! initialize the inflow boundary condition variables
    use eos_module, only: eos, eos_input_rt
    use eos_type_module
    use probin_module, ONLY: dens_fuel, temp_fuel, xc12_fuel, vel_fuel

    integer :: ic12, io16

    type (eos_t) :: eos_state

    ! figure out the indices for different species
    ic12  = network_species_index("carbon-12")
    io16  = network_species_index("oxygen-16")

    if (ic12 < 0 .or. io16 < 0) then
       call bl_error("ERROR: species indices undefined in inlet_bc")
    endif

    eos_state%rho = dens_fuel
    eos_state%T   = temp_fuel

    eos_state%xn(:)    = ZERO
    eos_state%xn(ic12) = xc12_fuel
    eos_state%xn(io16) = 1.d0 - xc12_fuel

    call eos(eos_input_rt, eos_state, .false.)

    INLET_RHO     = dens_fuel
    INLET_RHOH    = dens_fuel*eos_state%h
    INLET_TEMP    = temp_fuel
    INLET_RHOX(:) = dens_fuel*eos_state%xn(:)
    INLET_VEL     = vel_fuel
    INLET_TRA     = ZERO

    inlet_bc_initialized = .true.

  end subroutine set_inlet_bcs

end module inlet_bc_module
