set -e

# Two iterations using type inference infers most (user-facing) return
# types correctly.
for v in xc icxc icxc; do
    ./mudlle                                    \
	-c 'garbage_collect(1024*1024)'         \
	-e "${v}.mud"                           \
	-e "pxslow.mud"
done
