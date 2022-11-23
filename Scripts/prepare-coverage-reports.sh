#!/bin/zsh -l
set -e

function exportlcov() {
    build_type=$1
    executable_name=$2

    executable=$(find "${directory}" -type f -name $executable_name)
    profile=$(find "${directory}" -type f -name 'Coverage.profdata')
    output_file_name="$executable_name.lcov"

    can_proceed=true
    if [[ $build_type == watchOS* ]]; then
        echo "\tAborting creation of $output_file_name – watchOS not supported."
    elif [[ -z $profile ]]; then
        echo "\tAborting creation of $output_file_name – no profile found."
    elif [[ -z $executable ]]; then
        echo "\tAborting creation of $output_file_name – no executable found."
    else
        output_dir=".build/artifacts/$build_type"
        mkdir -p $output_dir

        output_file="$output_dir/$output_file_name"
        echo "\tExporting $output_file"
        xcrun llvm-cov export -format="lcov" $executable -instr-profile $profile > $output_file
    fi
}

for directory in $(git rev-parse --show-toplevel)/.build/derivedData/*/; do
    build_type=$(basename $directory)
    echo "Finding coverage information for $build_type"

    exportlcov $build_type 'AsyncQueueTests'
done
