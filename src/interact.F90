module interact

! Module for interacting with running calculations.

implicit none

character(*), parameter :: comms_file = "HANDE.COMM"

contains

    subroutine calc_interact(comms_found, out_unit, soft_exit, qs)

        ! Read HANDE.COMM if it exists in the working directory of any
        ! processor and set the variables according to the options defined in
        ! HANDE.COMM.

        ! In:
        !    comms_found: true if the file HANDE.COMM exists on nay processor.
        !    out_unit: File unit to write output to.
        ! Out:
        !    softexit: true if SOFTEXIT is defined in HANDE.COMM, in which case
        !        any calculation should exit immediately and go to the
        !        post-processing steps.
        ! In/Out:
        !    qs (optional): QMC calculation state. The shift and/or timestep may be updated.

        use aotus_module, only: open_config_chunk
        use aot_table_module, only: aot_get_val, aot_exists, aot_table_open, aot_table_close
        use aot_vector_module, only: aot_get_val
        use flu_binding, only: flu_State, flu_close

        use utils, only: read_file_to_buffer
        use errors, only: warning
        use parallel

        use qmc_data, only: qmc_in_t, qmc_state_t

        logical, intent(in) :: comms_found
        integer, intent(in) :: out_unit
        logical, intent(out) :: soft_exit
        type(qmc_state_t), optional, intent(inout) :: qs

        real(p), allocatable :: tmpshift(:)
        logical :: comms_exists, comms_read
        integer :: proc, i, j, ierr, lua_err, iunit, shnd
        integer, allocatable :: ierr_arr(:)
        integer :: ios
#ifdef PARALLEL
        integer :: buf_len
#endif
        character(:), allocatable :: buffer
        type(flu_State) :: lua_state
        character(255) :: err_str

        ! Note that all output in this subroutine *must* be prepended with #.
        ! This enables the blocking script to ignore these lines whilst doing
        ! data analysis.

        soft_exit = .false.

        if (comms_found) then
            ! Check if file is on *this* process
            comms_exists = check_comms_file()

            ! Read in the HANDE.COMM file.
            ! This should be a very rare event, so we don't worry too much
            ! about optimised communications in this section.
            if (parent) then
                write (out_unit,'(1X,"#",1X,62("-"))')
                write (out_unit,'(1X,"#",1X,a21)') comms_file//' detected.'
                write (out_unit,'(1X,"#",/,1X,"#",1X,a24,/,1X,"#")') 'Contents of '//comms_file//':'
                ! Flush output from parent processor so that processor which
                ! has the HANDE.COMM file can print out the contents without
                ! mixing the output.
                flush(out_unit)
            end if
            ! Quick pause to ensure output is all done by this point.
#ifdef PARALLEL
            call mpi_barrier(mpi_comm_world, ierr)
#endif
            ! Slightly tricky bit: need to take into account multi-core
            ! machines where multiple processors can share the same disk and so
            ! be picking up the same HANDE.COMM file.  We want to ensure that
            ! only one processor reads it in (avoid race conditions!).
            ! Solution: loop over processors and place a blocking comms call at
            ! the end of each iteration.
            ! proc will end up holding the processor id that read in
            ! HANDE.COMM.
            comms_read = .false.
            do proc = 0, nprocs-1
                if (proc == iproc .and. comms_exists) then
                    ! Read in file.
                    ! It's possible that there is a latency in the inquire for
                    ! the existence of comms_file, so comms_exists = .true., but
                    ! the file has actually been deleted.  Account for this
                    ! gracefully by checking iostat
                    open(newunit=iunit, file=comms_file, status='old',iostat=ios)
                    if (ios==0) then !all is fine
                        call read_file_to_buffer(buffer, in_unit=iunit)
                        ! Don't want to keep HANDE.COMM around to be detected again on
                        ! the next Monte Carlo iteration.
                        close(iunit, status="delete")
                    else
                        call warning('calc_interact', 'Error reading '//comms_file//'.  Assuming empty.')
                        flush(out_unit)
                        buffer = ''
                    end if
                    comms_read = .true.
                end if
#ifdef PARALLEL
                call mpi_bcast(comms_read, 1, mpi_logical, proc, mpi_comm_world, ierr)
#endif
                if (comms_read) exit
            end do

#ifdef PARALLEL
            if (iproc == proc) buf_len = len_trim(buffer)
            call mpi_bcast(buf_len, 1, MPI_INTEGER, proc, mpi_comm_world, ierr)
            if (iproc /= proc) allocate(character(len=buf_len) :: buffer)
            call mpi_bcast(buffer, buf_len, MPI_CHARACTER, proc, mpi_comm_world, ierr)
#endif

            ! Only print out the HANDE.COMM file from the parent processor;
            ! prepend each line with # to ease data extraction.
            if (parent) then
                i = 1
                do
                    j = index(buffer(i:), new_line(buffer))
                    if (j == 0) exit
                    write (out_unit,'(1X, "#", 1X, a)', advance='no') trim(buffer(i:j+i-1))
                    i = i+j
                end do
                write (out_unit,'(1X, "#", 1X, a)') trim(buffer(i:))
            end if

            ! Now each processor has the HANDE.COMM script, attempt to execute it...
            call open_config_chunk(lua_state, buffer, lua_err, err_str)

            if (lua_err == 0) then
                ! ... and get variables from global state.
                call aot_get_val(soft_exit, ierr, lua_state, key='softexit')
                if (present(qs)) then
                    if (aot_exists(lua_state, key='write_restart')) then
                        ! This is very similar to get_flag_and_id in lua_hand_utils but it does less checks and does not need a handle.
                        call aot_get_val(qs%restart_in%write_restart, ierr, lua_state, key='write_restart')
                        if (ierr /= 0) then
                            ! Passed an id instead.
                            qs%restart_in%write_restart = .true.
                            call aot_get_val(qs%restart_in%write_id, ierr, lua_state, key='write_restart')
                        end if
                    end if
                    call aot_get_val(qs%tau, ierr, lua_state, key='tau')
                    ! Only get shift if it is given, to avoid unwanted reallocation.
                    if (aot_exists(lua_state, key='shift')) then
                        call aot_table_open(lua_state, thandle=shnd, key='shift')
                        if (shnd == 0) then
                            ! Given a single value...
                            allocate(tmpshift(1))
                            call aot_get_val(tmpshift(1), ierr, lua_state, key='shift')
                            qs%shift = tmpshift(1)
                            deallocate(tmpshift)
                        else
                            call aot_table_close(lua_state, shnd)
                            call aot_get_val(tmpshift, ierr_arr, size(qs%shift), lua_state, key='shift')
                            if (parent) write (out_unit,'(1X,"# Using ", i2, " shift values from HANDE.COMM.")') size(tmpshift)
                            qs%shift(:size(tmpshift)) = tmpshift(:)
                        end if
                    end if
                    call aot_get_val(qs%target_particles, ierr, lua_state, key='target_population')
                end if

                call flu_close(lua_state)
            end if

            if (parent) then
                if (lua_err == 0) then
                    write (out_unit,'(1X,"#",/,1X,"#",1X,a)') "From now on we use the information provided in "//comms_file//"."
                else
                    write (out_unit,'(1X,"# aotus/lua error code:", i3)') ierr
                    write (out_unit,'(1X,"# error message:", a)') trim(err_str)
                    write (out_unit,'(1X,"# Ignoring variables in ",a)') trim(comms_file)
                end if
                write (out_unit,'(1X,"#",1X,62("-"))')
            end if

        end if

    end subroutine calc_interact

    subroutine check_interact(comms_found)

        ! Checks if there is a HANDE.COMM file present to interact with the calculation

        ! In/Out:
        !   comms_found: on entry, whether HANDE.COMM exists on this processor; on exit whether it
        !   exists on any

        use parallel

        logical, intent(inout) :: comms_found

#ifdef PARALLEL
        logical :: comms_found_any
        integer :: ierr

        call mpi_allreduce(comms_found, comms_found_any, 1, mpi_logical, mpi_lor, mpi_comm_world, ierr)
        comms_found = comms_found_any
#endif

    end subroutine check_interact

    function check_comms_file()

        ! Test whether HANDE.COMM is present on this processor

        logical :: check_comms_file

        inquire(file=comms_file, exist=check_comms_file)
        
    end function check_comms_file

end module interact
