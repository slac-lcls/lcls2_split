#!/bin/bash

set -e

# choose local directory where packages will be installed
if [ -z "$TESTRELDIR" ]; then
  export INSTDIR=`pwd`/install
else
  export INSTDIR="$TESTRELDIR"
fi

cmake_option="RelWithDebInfo"
pyInstallStyle="develop"
psana_setup_args=""
force_clean=0
no_ana=0
no_shmem=0
build_ext_list=""

if [ -d "/sdf/group/lcls/" ]
then
    no_daq=1
else
    no_daq=0
fi

while getopts "c:p:s:b:fdam" opt; do
  case $opt in
    c) cmake_option="$OPTARG"
    ;;
    d) no_daq=1
    ;;
    a) no_ana=1
    ;;
    m) no_shmem=1
    ;;
    p) pyInstallStyle="$OPTARG"
    ;;
    s) psana_setup_args="$OPTARG"
    ;;
    b) build_ext_list="$OPTARG"
    ;;
    f) force_clean=1                       # Force clean is required building between rhel6&7
    ;;
    \?) echo "Invalid option -$OPTARG" >&2
        exit 1
    ;;
  esac
done

pyver=$(python -c "import sys; print(str(sys.version_info.major)+'.'+str(sys.version_info.minor))")

echo "CMAKE_BUILD_TYPE:" $cmake_option
echo "Python install option:" $pyInstallStyle
echo "build_ext_list:" $build_ext_list
export BUILD_LIST=$build_ext_list

if [ $force_clean == 1 ]; then
    echo "force_clean"
    if [ -d "$INSTDIR" ]; then
        rm -rf "$INSTDIR"
    fi
    if [ -d xtcdata/build ]; then
        rm -rf xtcdata/build
    fi
    if [ -d psdaq/build ]; then
        rm -rf psdaq/build
    fi
    if [ -d psalg/build ]; then
        rm -rf psalg/build
    fi
fi

function calculate_working_tree_hash() {
    local target_dir="$1"
    if [ ! -d "$target_dir" ]; then
        echo ""
        return
    fi
    
    cd "$target_dir"
    {   git diff-index --name-only HEAD 2>/dev/null || true
        git ls-files -o --exclude-standard 2>/dev/null || true
    } | while read path; do
        if [ -n "$path" ]; then
            if [ -f "$path" ]; then
                printf "100644 blob %s\t$path\n" $(git hash-object -w "$path" 2>/dev/null || echo "0000000000000000000000000000000000000000")
            elif [ -d "$path" ]; then
                printf "160000 commit %s\t$path\n" $(cd "$path" 2>/dev/null && git rev-parse HEAD 2>/dev/null || echo "0000000000000000000000000000000000000000")
            fi
        fi
    done | sed 's,/,\\,g' | git mktree --missing 2>/dev/null || echo "no_changes"
    cd - > /dev/null
}

function get_stored_hash() {
    local component="$1"
    local hash_file="$INSTDIR/.build_hashes/${component}.hash"
    if [ -f "$hash_file" ]; then
        cat "$hash_file"
    else
        echo ""
    fi
}

function store_hash() {
    local component="$1"
    local hash="$2"
    local hash_dir="$INSTDIR/.build_hashes"
    mkdir -p "$hash_dir"
    echo "$hash" > "$hash_dir/${component}.hash"
}

function has_component_changed() {
    local component="$1"
    local current_hash=$(calculate_working_tree_hash "$component")
    local stored_hash=$(get_stored_hash "$component")
    
    if [ "$current_hash" != "$stored_hash" ] || [ -z "$stored_hash" ]; then
        return 0  # Component has changed
    else
        return 1  # Component has not changed
    fi
}

function cmake_build() {
    cd $1
    shift
    mkdir -p build
    cd build
    cmake -DCMAKE_INSTALL_PREFIX=$INSTDIR -DCMAKE_PREFIX_PATH=$CONDA_PREFIX -DCMAKE_BUILD_TYPE=$cmake_option $@ ..
    make -j 4 install
    cd ../..
}

# "python setup.py develop" seems to not create this for you
# (although "install" does)
mkdir -p $INSTDIR/lib/python$pyver/site-packages/
if [ $pyInstallStyle == "develop" ]; then
    pipOptions="--editable"
else
    pipOptions=""
fi

# Check for dependency changes (force_clean overrides dependency checking)
xtcdata_changed=1
psalg_changed=1
dependencies_changed=1

if [ $force_clean == 0 ]; then
    if has_component_changed "xtcdata"; then
        xtcdata_changed=1
        echo "xtcdata has changed, will rebuild"
    else
        xtcdata_changed=0
        echo "xtcdata unchanged, skipping rebuild"
    fi
    
    if has_component_changed "psalg"; then
        psalg_changed=1
        echo "psalg has changed, will rebuild"
    else
        psalg_changed=0
        echo "psalg unchanged"
    fi
    
    # Dependencies changed if either xtcdata or psalg changed
    if [ $xtcdata_changed == 1 ] || [ $psalg_changed == 1 ]; then
        dependencies_changed=1
        echo "Dependencies (xtcdata/psalg) have changed, will rebuild dependent components"
    else
        dependencies_changed=0
        echo "Dependencies (xtcdata/psalg) unchanged, skipping dependent component rebuilds"
    fi
else
    echo "Force clean enabled, will rebuild all components"
fi

# Build xtcdata (always build if changed or force_clean)
if [ $xtcdata_changed == 1 ]; then
    echo "Building xtcdata..."
    cmake_build xtcdata
    store_hash "xtcdata" "$(calculate_working_tree_hash "xtcdata")"
fi

# Build psalg (build if xtcdata or psalg changed)
if [ $xtcdata_changed == 1 ] || [ $psalg_changed == 1 ]; then
    echo "Building psalg..."
    if [ $no_shmem == 0 ]; then
        cmake_build psalg
    else
        cmake_build psalg -DBUILD_SHMEM=OFF
    fi
    cd psalg
    pip install --no-deps --prefix=$INSTDIR $pipOptions .
    cd ..
    store_hash "psalg" "$(calculate_working_tree_hash "psalg")"
fi

# Build psdaq (build if dependencies changed)
if [ $no_daq == 0 ] && [ $dependencies_changed == 1 ]; then
    echo "Building psdaq..."
    # to build psdaq with setuptools
    cmake_build psdaq
    cd psdaq
    # force build of the extensions.  do this because in some cases
    # setup.py is unable to detect if an external header file changed
    # (e.g. in xtcdata).  but in many cases it is fine without "-f" - cpo
    if [ $pyInstallStyle == "develop" ]; then
        python setup.py build_ext -f --inplace
    fi
    pip install --no-deps --prefix=$INSTDIR $pipOptions .
    cd ..
elif [ $no_daq == 0 ]; then
    echo "Skipping psdaq build (dependencies unchanged)"
fi

# Build psana (build if dependencies changed)  
if [ $no_ana == 0 ] && [ $dependencies_changed == 1 ]; then
    echo "Building psana..."
    # to build psana with setuptools
    cd psana
    # force build of the extensions.  do this because in some cases
    # setup.py is unable to detect if an external header file changed
    # (e.g. in xtcdata).  but in many cases it is fine without "-f" - cpo
    if [ $pyInstallStyle == "develop" ]; then
        python setup.py build_ext -f --inplace
    fi
    pip install --no-deps --prefix=$INSTDIR $pipOptions .
elif [ $no_ana == 0 ]; then
    echo "Skipping psana build (dependencies unchanged)"
fi
# The removal of site.py in setup 49.0.0 breaks "develop" installations
# which are outside the normal system directories: /usr, /usr/local,
# $HOME/.local. etc. See: https://github.com/pypa/setuptools/issues/2295
# The suggested fix, in the bug report, is the following: "I recommend
# that the project use pip install --prefix or possibly pip install
# --target to install packages and supply a sitecustomize.py to ensure
# that directory ends up as a site dir and gets .pth processing. That
# approach should be future-proof (at least against the sunset of
# easy_install). All python setup.py commands in the code above have
# been replaced with pip commands. The following code implements the
# sitecustomize.py file. Pip bilds the python modules in a sandbox,
# so it requires all the code for the module to be in the same
# folder. The C++ code for the modules built in psana was therefore
# moved from psalg to psana.
if [ $pyInstallStyle == "develop" ]; then
  if [ ! -f $INSTDIR/lib/python$pyver/site-packages/site.py ] && \
     [ ! -f $INSTDIR/lib/python$pyver/site-packages/sitecustomize.py ]; then
cat << EOF > $INSTDIR/lib/python$pyver/site-packages/sitecustomize.py
import site

site.addsitedir('$INSTDIR/lib/python$pyver/site-packages')
EOF
  fi
fi
