#!/usr/bin/env bash
set -e

# This script builds various binary artifacts from a checkout of the docker
# source code.
#
# Requirements:
# - The current directory should be a checkout of the docker source code
#   (https://github.com/docker/docker). Whatever version is checked out
#   will be built.
# - The VERSION file, at the root of the repository, should exist, and
#   will be used as Docker binary version and package version.
# - The hash of the git commit will also be included in the Docker binary,
#   with the suffix -unsupported if the repository isn't clean.
# - The script is intended to be run inside the docker container specified
#   in the Dockerfile at the root of the source. In other words:
#   DO NOT CALL THIS SCRIPT DIRECTLY.
# - The right way to call this script is to invoke "make" from
#   your checkout of the Docker repository.
#   the Makefile will do a "docker build -t docker ." and then
#   "docker run hack/make.sh" in the resulting image.
#

set -o pipefail

export DOCKER_PKG='github.com/docker/docker'
export SCRIPTDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export MAKEDIR="$SCRIPTDIR/make"
export PKG_CONFIG=${PKG_CONFIG:-pkg-config}

# We're a nice, sexy, little shell script, and people might try to run us;
# but really, they shouldn't. We want to be in a container!
inContainer="AssumeSoInitially"
if [ "$(go env GOHOSTOS)" = 'windows' ]; then
	if [ -z "$FROM_DOCKERFILE" ]; then
		unset inContainer
	fi
else
	if [ "$PWD" != "/go/src/$DOCKER_PKG" ] || [ -z "$DOCKER_CROSSPLATFORMS" ]; then
		unset inContainer
	fi
fi

if [ -z "$inContainer" ]; then
	{
		echo "# WARNING! I don't seem to be running in a Docker container."
		echo "# The result of this command might be an incorrect build, and will not be"
		echo "# officially supported."
		echo "#"
		echo "# Try this instead: make all"
		echo "#"
	} >&2
fi

echo

# List of bundles to create when no argument is passed
DEFAULT_BUNDLES=(
	binary-client
	binary-daemon
	dynbinary

	test-unit
	test-integration-cli
	test-docker-py

	cross
	tgz
)

VERSION=$(< ./VERSION)
if command -v git &> /dev/null && [ -d .git ] && git rev-parse &> /dev/null; then
	GITCOMMIT=$(git rev-parse --short HEAD)
	if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
		GITCOMMIT="$GITCOMMIT-unsupported"
		echo "#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
		echo "# GITCOMMIT = $GITCOMMIT"
		echo "# The version you are building is listed as unsupported because"
		echo "# there are some files in the git repository that are in an uncommitted state."
		echo "# Commit these changes, or add to .gitignore to remove the -unsupported from the version."
		echo "# Here is the current list:"
		git status --porcelain --untracked-files=no
		echo "#~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
	fi
	! BUILDTIME=$(date --rfc-3339 ns 2> /dev/null | sed -e 's/ /T/') &> /dev/null
	if [ -z $BUILDTIME ]; then
		# If using bash 3.1 which doesn't support --rfc-3389, eg Windows CI
		BUILDTIME=$(date -u)
	fi
elif [ "$DOCKER_GITCOMMIT" ]; then
	GITCOMMIT="$DOCKER_GITCOMMIT"
else
	echo >&2 'error: .git directory missing and DOCKER_GITCOMMIT not specified'
	echo >&2 '  Please either build with the .git directory accessible, or specify the'
	echo >&2 '  exact (--short) commit hash you are building using DOCKER_GITCOMMIT for'
	echo >&2 '  future accountability in diagnosing build issues.  Thanks!'
	exit 1
fi

if [ "$AUTO_GOPATH" ]; then
	rm -rf .gopath
	mkdir -p .gopath/src/"$(dirname "${DOCKER_PKG}")"
	ln -sf ../../../.. .gopath/src/"${DOCKER_PKG}"
	export GOPATH="${PWD}/.gopath"

	if [ "$(go env GOOS)" = 'solaris' ]; then
		# sys/unix is installed outside the standard library on solaris
		# TODO need to allow for version change, need to get version from go
		export GO_VERSION=${GO_VERSION:-"1.7.1"}
		export GOPATH="${GOPATH}:/usr/lib/gocode/${GO_VERSION}"
	fi
fi

if [ ! "$GOPATH" ]; then
	echo >&2 'error: missing GOPATH; please see https://golang.org/doc/code.html#GOPATH'
	echo >&2 '  alternatively, set AUTO_GOPATH=1'
	exit 1
fi

DOCKER_BUILDTAGS+=" daemon"
if ${PKG_CONFIG} 'libsystemd >= 209' 2> /dev/null ; then
	DOCKER_BUILDTAGS+=" journald"
elif ${PKG_CONFIG} 'libsystemd-journal' 2> /dev/null ; then
	DOCKER_BUILDTAGS+=" journald journald_compat"
fi

# test whether "btrfs/version.h" exists and apply btrfs_noversion appropriately
if \
	command -v gcc &> /dev/null \
	&& ! gcc -E - -o /dev/null &> /dev/null <<<'#include <btrfs/version.h>' \
; then
	DOCKER_BUILDTAGS+=' btrfs_noversion'
fi

# test whether "libdevmapper.h" is new enough to support deferred remove
# functionality.
if \
	command -v gcc &> /dev/null \
	&& ! ( echo -e  '#include <libdevmapper.h>\nint main() { dm_task_deferred_remove(NULL); }'| gcc -xc - -o /dev/null -ldevmapper &> /dev/null ) \
; then
       DOCKER_BUILDTAGS+=' libdm_no_deferred_remove'
fi

# Use these flags when compiling the tests and final binary

IAMSTATIC='true'
source "$SCRIPTDIR/make/.go-autogen"
if [ -z "$DOCKER_DEBUG" ]; then
	LDFLAGS='-w'
fi

LDFLAGS_STATIC=''
EXTLDFLAGS_STATIC='-static'
# ORIG_BUILDFLAGS is necessary for the cross target which cannot always build
# with options like -race.
ORIG_BUILDFLAGS=( -tags "autogen netgo static_build sqlite_omit_load_extension $DOCKER_BUILDTAGS" -installsuffix netgo )
# see https://github.com/golang/go/issues/9369#issuecomment-69864440 for why -installsuffix is necessary here

# When $DOCKER_INCREMENTAL_BINARY is set in the environment, enable incremental
# builds by installing dependent packages to the GOPATH.
REBUILD_FLAG="-a"
if [ "$DOCKER_INCREMENTAL_BINARY" ]; then
	REBUILD_FLAG="-i"
fi
ORIG_BUILDFLAGS+=( $REBUILD_FLAG )

BUILDFLAGS=( $BUILDFLAGS "${ORIG_BUILDFLAGS[@]}" )
# Test timeout.

if [ "${DOCKER_ENGINE_GOARCH}" == "arm" ]; then
	: ${TIMEOUT:=10m}
elif [ "${DOCKER_ENGINE_GOARCH}" == "windows" ]; then
	: ${TIMEOUT:=8m}
else
	: ${TIMEOUT:=5m}
fi

LDFLAGS_STATIC_DOCKER="
	$LDFLAGS_STATIC
	-extldflags \"$EXTLDFLAGS_STATIC\"
"

if [ "$(uname -s)" = 'FreeBSD' ]; then
	# Tell cgo the compiler is Clang, not GCC
	# https://code.google.com/p/go/source/browse/src/cmd/cgo/gcc.go?spec=svne77e74371f2340ee08622ce602e9f7b15f29d8d3&r=e6794866ebeba2bf8818b9261b54e2eef1c9e588#752
	export CC=clang

	# "-extld clang" is a workaround for
	# https://code.google.com/p/go/issues/detail?id=6845
	LDFLAGS="$LDFLAGS -extld clang"
fi

# If sqlite3.h doesn't exist under /usr/include,
# check /usr/local/include also just in case
# (e.g. FreeBSD Ports installs it under the directory)
if [ ! -e /usr/include/sqlite3.h ] && [ -e /usr/local/include/sqlite3.h ]; then
	export CGO_CFLAGS='-I/usr/local/include'
	export CGO_LDFLAGS='-L/usr/local/lib'
fi

HAVE_GO_TEST_COVER=
if \
	go help testflag | grep -- -cover > /dev/null \
	&& go tool -n cover > /dev/null 2>&1 \
; then
	HAVE_GO_TEST_COVER=1
fi

# a helper to provide ".exe" when it's appropriate
binary_extension() {
	if [ "$(go env GOOS)" = 'windows' ]; then
		echo -n '.exe'
	fi
}

hash_files() {
	while [ $# -gt 0 ]; do
		f="$1"
		shift
		dir="$(dirname "$f")"
		base="$(basename "$f")"
		for hashAlgo in md5 sha256; do
			if command -v "${hashAlgo}sum" &> /dev/null; then
				(
					# subshell and cd so that we get output files like:
					#   $HASH docker-$VERSION
					# instead of:
					#   $HASH /go/src/github.com/.../$VERSION/binary/docker-$VERSION
					cd "$dir"
					"${hashAlgo}sum" "$base" > "$base.$hashAlgo"
				)
			fi
		done
	done
}

bundle() {
	local bundle="$1"; shift
	echo "---> Making bundle: $(basename "$bundle") (in $DEST)"
	source "$SCRIPTDIR/make/$bundle" "$@"
}

copy_binaries() {
	dir="$1"
	# Add nested executables to bundle dir so we have complete set of
	# them available, but only if the native OS/ARCH is the same as the
	# OS/ARCH of the build target
	if [ "$(go env GOOS)/$(go env GOARCH)" == "$(go env GOHOSTOS)/$(go env GOHOSTARCH)" ]; then
		if [ -x /usr/local/bin/docker-runc ]; then
			echo "Copying nested executables into $dir"
			for file in containerd containerd-shim containerd-ctr runc init proxy; do
				cp `which "docker-$file"` "$dir/"
				if [ "$2" == "hash" ]; then
					hash_files "$dir/docker-$file"
				fi
			done
		fi
	fi
}

install_binary() {
	file="$1"
	target="${DOCKER_MAKE_INSTALL_PREFIX:=/usr/local}/bin/"
	if [ "$(go env GOOS)" == "linux" ]; then
		echo "Installing $(basename $file) to ${target}"
		cp -L "$file" "$target"
	else
		echo "Install is only supported on linux"
		return 1
	fi
}

main() {
	# We want this to fail if the bundles already exist and cannot be removed.
	# This is to avoid mixing bundles from different versions of the code.
	mkdir -p bundles
	if [ -e "bundles/$VERSION" ] && [ -z "$KEEPBUNDLE" ]; then
		echo "bundles/$VERSION already exists. Removing."
		rm -fr "bundles/$VERSION" && mkdir "bundles/$VERSION" || exit 1
		echo
	fi

	if [ "$(go env GOHOSTOS)" != 'windows' ]; then
		# Windows and symlinks don't get along well

		rm -f bundles/latest
		ln -s "$VERSION" bundles/latest
	fi

	if [ $# -lt 1 ]; then
		bundles=(${DEFAULT_BUNDLES[@]})
	else
		bundles=($@)
	fi
	for bundle in ${bundles[@]}; do
		export DEST="bundles/$VERSION/$(basename "$bundle")"
		# Cygdrive paths don't play well with go build -o.
		if [[ "$(uname -s)" == CYGWIN* ]]; then
			export DEST="$(cygpath -mw "$DEST")"
		fi
		mkdir -p "$DEST"
		ABS_DEST="$(cd "$DEST" && pwd -P)"
		bundle "$bundle"
		echo
	done
}

main "$@"
