# arguments: <.mud dir> <.obj dir> <dst dir> <loader> <slice> <slices>

set -e

srcdir=$1
objdir=$2
dstdir=$3
loader=$4
slice=$5
slices=$6

./mudlle                                        \
    -c 'silent = true'                          \
    -c 'garbage_collect(1024*1024)'             \
    -c "objdir = \"${objdir}/\""                \
    -c "dstdir = \"${dstdir}/\""                \
    -c "build_slice = '(${slice} . ${slices})"  \
    -e "${srcdir}${loader}.mud"                 \
    -e "${srcdir}pxslow.mud"
