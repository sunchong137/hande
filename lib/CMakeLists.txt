add_subdirectory(aotus)
add_subdirectory(cephes)
add_subdirectory(external)
add_subdirectory(local)

# Compile dSFMT and dSFMT_F03_interface
add_library(dSFMT OBJECT
  dSFMT-src-2.2/dSFMT-common.h
  dSFMT-src-2.2/dSFMT-params.h
  dSFMT-src-2.2/dSFMT-params11213.h
  dSFMT-src-2.2/dSFMT-params1279.h
  dSFMT-src-2.2/dSFMT-params132049.h
  dSFMT-src-2.2/dSFMT-params19937.h
  dSFMT-src-2.2/dSFMT-params216091.h
  dSFMT-src-2.2/dSFMT-params2203.h
  dSFMT-src-2.2/dSFMT-params4253.h
  dSFMT-src-2.2/dSFMT-params44497.h
  dSFMT-src-2.2/dSFMT-params521.h
  dSFMT-src-2.2/dSFMT-params86243.h
  dSFMT-src-2.2/dSFMT.c
  dSFMT-src-2.2/dSFMT.h
  dSFMT_F03_interface/dSFMT_interface.F90
  dSFMT_F03_interface/dSFMT_utils.c
  )
target_compile_definitions(dSFMT
  PRIVATE
    DSFMT_MEXP=${HANDE_DSFMT_MEXP}
    $<$<BOOL:${USE_MPI}>:PARALLEL>
    $<$<CONFIG:Debug>:DEBUG>
  )
target_include_directories(dSFMT
  PRIVATE
    dSFMT-src-2.2
  )
add_library(HANDE::dSFMT ALIAS dSFMT)